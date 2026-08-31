import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1
import os

private let proxyLogger = Logger(subsystem: "io.github.0fuz.SSHTunnelManager", category: "HTTPProxy")

/// HTTP/1.1 reverse proxy, restricted to configured names and loopback upstreams.
/// Ordinary HTTP uses one request per connection; bodies are streamed with backpressure.
/// WebSocket upgrades become a bidirectional byte stream without interpreting frames.
public actor HTTPProxyServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let registry = RouteRegistry()
    private var listener: Channel?

    public init() {}

    deinit { group.shutdownGracefully { _ in } }

    public func setRoutes(_ routes: [WebRoute]) throws {
        var unique: [String: WebRoute] = [:]
        for route in routes {
            let domain = try WebDomain.normalize(route.domain)
            guard unique[domain] == nil, (1...65535).contains(route.port), route.port != 80 else {
                throw ProxyError.invalidRoutes
            }
            unique[domain] = route
        }
        registry.replace(unique)
    }

    @discardableResult
    public func start(port: Int = 80) async throws -> Int {
        if let listener { return listener.localAddress!.port! }
        do {
            let channel = try await bootstrap().bind(host: "127.0.0.1", port: port).get()
            try await channel.pipeline.addHandler(ListenerDiagnostics()).get()
            listener = channel
            proxyLogger.notice("HTTP listener started on port \(channel.localAddress!.port!)")
            return channel.localAddress!.port!
        } catch let error as IOError where error.errnoCode == EACCES || error.errnoCode == EPERM {
            throw ProxyError.portPermissionRequired
        }
    }

    /// Takes ownership of the app-created socket bound by the short-lived authorization helper.
    @discardableResult
    public func adoptListener(_ descriptor: Int32) async throws -> Int {
        if let listener { close(descriptor); return listener.localAddress!.port! }
        let channel = try await bootstrap().withBoundSocket(descriptor).get()
        try await channel.pipeline.addHandler(ListenerDiagnostics()).get()
        listener = channel
        proxyLogger.notice("Adopted authorized HTTP listener on port \(channel.localAddress!.port!)")
        return channel.localAddress!.port!
    }

    func bootstrap() -> ServerBootstrap {
        let registry = self.registry
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelInitializer { channel in
                proxyLogger.debug("Initializing accepted HTTP connection")
                registry.track(channel)
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let encoder = HTTPResponseEncoder()
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        encoder, decoder,
                        IdleStateHandler(allTimeout: .seconds(300)),
                        RequestForwarder(registry: registry, decoder: decoder, encoder: encoder)
                    ])
                }
            }
    }

    public func stop() async {
        let old = listener
        listener = nil
        try? await old?.close().get()
        registry.closeConnections()
    }
}

private final class ListenerDiagnostics: ChannelInboundHandler, Sendable {
    typealias InboundIn = Channel
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        proxyLogger.error("HTTP listener could not accept a connection: \(String(describing: error), privacy: .public)")
    }
}

public enum ProxyError: LocalizedError {
    case invalidRoutes
    case portPermissionRequired
    public var errorDescription: String? {
        switch self {
        case .invalidRoutes: return "Web domains must be unique and forward to a valid local port other than 80."
        case .portPermissionRequired: return "macOS requires administrator authorization to open loopback port 80. Use Enable HTTP in Web domains."
        }
    }
}

private final class RouteRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: WebRoute] = [:]
    private var connections: [ObjectIdentifier: (Channel, String, WebRoute)] = [:]
    private var accepted: [ObjectIdentifier: Channel] = [:]

    func track(_ channel: Channel) {
        lock.lock()
        accepted[ObjectIdentifier(channel)] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { _ in self.remove(channel) }
    }

    func lookup(_ domain: String) -> WebRoute? {
        lock.lock(); defer { lock.unlock() }
        return routes[domain]
    }

    func register(_ channel: Channel, domain: String, route: WebRoute) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard routes[domain] == route else { return false }
        connections[ObjectIdentifier(channel)] = (channel, domain, route)
        return true
    }

    func remove(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(channel))
        accepted.removeValue(forKey: ObjectIdentifier(channel))
    }

    func replace(_ new: [String: WebRoute]) {
        lock.lock()
        routes = new
        let stale = connections.values.filter { new[$0.1] != $0.2 }.map { $0.0 }
        lock.unlock()
        for channel in stale { channel.close(promise: nil) }
    }

    func closeConnections() {
        lock.lock()
        let channels = Array(accepted.values)
        connections.removeAll()
        accepted.removeAll()
        lock.unlock()
        for channel in channels { channel.close(promise: nil) }
    }
}

private final class RequestForwarder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let registry: RouteRegistry
    private let decoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let encoder: HTTPResponseEncoder
    private var upstream: Channel?
    private var pending: [HTTPServerRequestPart] = []
    private var pendingBytes = 0
    private var started = false
    private var ended = false
    private var failed = false
    private var websocket = false
    private var switching = false

    init(registry: RouteRegistry, decoder: ByteToMessageHandler<HTTPRequestDecoder>, encoder: HTTPResponseEncoder) {
        self.registry = registry
        self.decoder = decoder
        self.encoder = encoder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed, !ended else { return } // No HTTP pipelining; response closes the connection.
        let part = unwrapInboundIn(data)
        switch part {
        case .head(var head):
            guard !started else { return }
            started = true
            guard head.method != .CONNECT, head.uri.hasPrefix("/"), !head.uri.hasPrefix("//") else {
                fail(context, .badRequest, "Only origin-form HTTP requests are supported."); return
            }
            let hosts = head.headers["host"]
            guard hosts.count == 1 else { fail(context, .badRequest, "Exactly one Host header is required."); return }
            let authority = hosts[0].lowercased().split(separator: ":", omittingEmptySubsequences: false)
            guard authority.count == 1 || (authority.count == 2 && authority[1] == "80"),
                  let domain = try? WebDomain.normalize(String(authority[0])) else {
                fail(context, .badRequest, "Invalid web domain."); return
            }
            guard let route = registry.lookup(domain) else { fail(context, .notFound, "Unknown web domain."); return }
            guard route.available else { fail(context, .serviceUnavailable, "SSH tunnel is disconnected or still connecting."); return }
            guard registry.register(context.channel, domain: domain, route: route) else {
                fail(context, .serviceUnavailable, "Tunnel configuration changed. Retry the request."); return
            }
            websocket = head.method == .GET && head.headers["upgrade"].map { $0.lowercased() } == ["websocket"]
                && head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
            if !websocket {
                removeHopHeaders(&head.headers)
                head.headers.replaceOrAdd(name: "Connection", value: "close")
            }
            // Do not trust forwarding metadata supplied by callers.
            for name in ["Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "Proxy-Authorization"] {
                head.headers.remove(name: name)
            }
            head.headers.add(name: "X-Forwarded-For", value: "127.0.0.1")
            head.headers.add(name: "X-Forwarded-Host", value: hosts[0])
            head.headers.add(name: "X-Forwarded-Proto", value: "http")
            pending.append(.head(head))
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            connect(context, route: route)
        case .body(let buffer):
            if websocket { fail(context, .badRequest, "WebSocket upgrade requests cannot have a body."); return }
            forward(.body(buffer), context: context)
        case .end(let trailers):
            ended = true
            forward(.end(trailers), context: context)
        }
    }

    private func connect(_ context: ChannelHandlerContext, route: WebRoute) {
        let client = context.channel
        let requestEncoder = HTTPRequestEncoder()
        let isWebSocket = websocket
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                if isWebSocket {
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([requestEncoder, ByteRelay(peer: client)])
                    }
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        requestEncoder,
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)),
                        IdleStateHandler(allTimeout: .seconds(300)),
                        ResponseForwarder(client: client)
                    ])
                }
            }.connect(host: "127.0.0.1", port: route.port).whenComplete { result in
                switch result {
                case .failure:
                    self.fail(context, .badGateway, "Cannot reach the SSH tunnel's local port.")
                case .success(let channel):
                    guard client.isActive, !self.failed else { channel.close(promise: nil); return }
                    self.upstream = channel
                    for part in self.pending { self.write(part, to: channel) }
                    self.pending.removeAll()
                    channel.flush()
                    if self.websocket && self.ended {
                        self.switchToBytes(context, requestEncoder: requestEncoder)
                    } else {
                        if !self.websocket { channel.setOption(ChannelOptions.autoRead, value: client.isWritable).whenFailure { _ in } }
                        client.setOption(ChannelOptions.autoRead, value: !self.ended && channel.isWritable).whenFailure { _ in }
                    }
                }
            }
    }

    private func forward(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        if let upstream {
            write(part, to: upstream)
            upstream.flush()
            if ended {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
                if websocket { switchToBytes(context, requestEncoder: nil) }
            } else if !upstream.isWritable {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            }
        } else {
            if case .body(let buffer) = part { pendingBytes += buffer.readableBytes }
            guard pendingBytes <= 256 * 1024 else { fail(context, .payloadTooLarge, "Too much data before the tunnel accepted the connection."); return }
            pending.append(part)
        }
    }

    private func write(_ part: HTTPServerRequestPart, to channel: Channel) {
        let request: HTTPClientRequestPart
        switch part {
        case .head(let head): request = .head(head)
        case .body(let buffer): request = .body(.byteBuffer(buffer))
        case .end(let trailers): request = .end(trailers)
        }
        channel.write(request, promise: nil)
    }

    private func switchToBytes(_ context: ChannelHandlerContext, requestEncoder: HTTPRequestEncoder?) {
        guard !switching, let upstream else { return }
        switching = true
        // Execute outside the decoder callback. Removing it then forwards any bytes
        // coalesced with the upgrade request into the new relay without losing data.
        context.eventLoop.execute {
            let removeEncoder: EventLoopFuture<Void>
            if let requestEncoder { removeEncoder = upstream.pipeline.syncOperations.removeHandler(requestEncoder) }
            else {
                do {
                    let handler = try upstream.pipeline.syncOperations.handler(type: HTTPRequestEncoder.self)
                    removeEncoder = upstream.pipeline.syncOperations.removeHandler(handler)
                } catch { removeEncoder = upstream.eventLoop.makeFailedFuture(error) }
            }
            removeEncoder.flatMap {
                context.eventLoop.makeCompletedFuture { try context.pipeline.syncOperations.addHandler(ByteRelay(peer: upstream)) }
            }.flatMap {
                context.pipeline.syncOperations.removeHandler(self)
            }.flatMap {
                context.pipeline.syncOperations.removeHandler(self.encoder)
            }.flatMap {
                context.pipeline.syncOperations.removeHandler(self.decoder)
            }.whenComplete { result in
                switch result {
                case .success:
                    upstream.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in }
                    context.channel.setOption(ChannelOptions.autoRead, value: upstream.isWritable).whenFailure { _ in }
                    context.channel.closeFuture.whenComplete { _ in self.registry.remove(context.channel) }
                case .failure:
                    context.close(promise: nil)
                    upstream.close(promise: nil)
                }
            }
        }
    }

    private func fail(_ context: ChannelHandlerContext, _ status: HTTPResponseStatus, _ message: String) {
        guard !failed, context.channel.isActive else { return }
        failed = true
        pending.removeAll()
        var body = context.channel.allocator.buffer(capacity: message.utf8.count)
        body.writeString(message + "\n")
        let headers = HTTPHeaders([("Content-Type", "text/plain; charset=utf-8"),
                                   ("Content-Length", String(body.readableBytes)), ("Connection", "close"),
                                   ("Cache-Control", "no-store")])
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        upstream?.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in }
    }

    func channelInactive(context: ChannelHandlerContext) {
        registry.remove(context.channel)
        upstream?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        proxyLogger.error("HTTP request failed: \(String(describing: error), privacy: .public)")
        context.close(promise: nil)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) }
    }
}

private func removeHopHeaders(_ headers: inout HTTPHeaders) {
    let nominated = headers[canonicalForm: "connection"].map(String.init)
    for name in nominated + ["Connection", "Keep-Alive", "Proxy-Connection", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Upgrade"] {
        // Framing is maintained by NIO's decoder/encoder pair.
        if name.lowercased() != "content-length" && name.lowercased() != "transfer-encoding" { headers.remove(name: name) }
    }
}

private final class ResponseForwarder: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private let client: Channel
    private var finalResponse = false
    private var completed = false

    init(client: Channel) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response: HTTPServerResponsePart
        switch unwrapInboundIn(data) {
        case .head(var head):
            finalResponse = head.status.code >= 200 || head.status.code == 101
            removeHopHeaders(&head.headers)
            head.headers.replaceOrAdd(name: "Connection", value: "close")
            response = .head(head)
        case .body(let buffer): response = .body(.byteBuffer(buffer))
        case .end(let trailers):
            if finalResponse {
                completed = true
                client.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { _ in self.client.close(promise: nil) }
                context.close(promise: nil)
                return
            }
            response = .end(trailers)
        }
        client.writeAndFlush(response, promise: nil)
        if !client.isWritable { context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in } }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        client.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Successful final responses close the client after flushing; do not race that write.
        if !completed { client.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { client.close(promise: nil); context.close(promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { client.close(promise: nil); context.close(promise: nil) }
    }
}

private final class ByteRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
        if !peer.isWritable { context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in } }
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        peer.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in }
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { peer.close(promise: nil); context.close(promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { peer.close(promise: nil); context.close(promise: nil) }
    }
}
