import Foundation
import Darwin
import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import LocalWebProxy

final class ProxyIntegrationTests: XCTestCase {
    func testAcceptedSocketUsesTCPNoDelayWithoutSocketDebugging() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let options = group.next().makePromise(of: (Int32, Int32).self)
        let proxy = HTTPProxyServer()
        let bootstrap = await proxy.bootstrap()
        let listener = try await bootstrap.childChannelInitializer { channel in
            channel.getOption(ChannelOptions.tcpOption(.tcp_nodelay)).and(
                channel.getOption(ChannelOptions.socketOption(.init(rawValue: SO_DEBUG)))
            ).map { values in options.succeed(values) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: listener.localAddress!.port!).get()
        let (noDelay, debugging) = try await options.futureResult.get()
        // TCP_NODELAY and SO_DEBUG both have value 1 on Darwin. Using the
        // wrong option level silently enables debugging on same-user sockets,
        // but fails for connections accepted from a root-created listener.
        XCTAssertNotEqual(noDelay, 0)
        XCTAssertEqual(debugging, 0)
        try await client.close().get()
        try await listener.close().get()
        await proxy.stop()
        try await group.shutdownGracefully()
    }

    func testRoutingStreamingAndLargeUploads() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let backend = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(EchoHTTPHandler())
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let proxy = HTTPProxyServer()
        let port = try await proxy.start(port: 0)
        let upstreamPort = backend.localAddress!.port!
        try await proxy.setRoutes([WebRoute(domain: "research.test", port: upstreamPort, available: true)])
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/upload?q=1")!)
            request.setValue("research.test", forHTTPHeaderField: "Host")
            request.httpMethod = "POST"
            request.httpBody = Data(repeating: 65, count: 1024 * 1024)
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "research.test /upload?q=1 1048576 done")
            request.httpMethod = "HEAD"
            request.httpBody = nil
            let (headData, headResponse) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(headData.isEmpty)
            // Revocation must apply without restarting the listener.
            try await proxy.setRoutes([WebRoute(domain: "research.test", port: upstreamPort, available: false)])
            request.httpMethod = "GET"
            request.httpBody = nil
            let (_, offline) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((offline as? HTTPURLResponse)?.statusCode, 503)
            request.setValue("unknown.test", forHTTPHeaderField: "Host")
            let (_, unknown) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((unknown as? HTTPURLResponse)?.statusCode, 404)
        } catch {
            await proxy.stop()
            try? await backend.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
        await proxy.stop()
        try await backend.close().get()
        try await group.shutdownGracefully()
    }

    func testWebSocketUpgradePreservesCoalescedBytesAndRevokesOpenStream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let received = group.next().makePromise(of: String.self)
        let backend = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(UpgradeEchoHandler(received: received))
        }.bind(host: "127.0.0.1", port: 0).get()
        let proxy = HTTPProxyServer()
        let port = try await proxy.start(port: 0)
        let route = WebRoute(domain: "socket.test", port: backend.localAddress!.port!, available: true, generation: "one")
        try await proxy.setRoutes([route])
        let reply = group.next().makePromise(of: String.self)
        let client = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.pipeline.addHandler(CollectBytes(promise: reply))
        }.connect(host: "127.0.0.1", port: port).get()
        let request = "GET /ws HTTP/1.1\r\nHost: socket.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\npending-frame"
        try await client.writeAndFlush(ByteBuffer(string: request)).get()
        let text = try await received.futureResult.get()
        XCTAssertTrue(text.contains("pending-frame"))
        // Revoking a route must close established WebSocket streams too.
        try await proxy.setRoutes([WebRoute(domain: route.domain, port: route.port, available: false)])
        let response = try await reply.futureResult.get()
        XCTAssertTrue(response.contains("101 Switching Protocols"))
        await proxy.stop()
        try await backend.close().get()
        try await group.shutdownGracefully()
    }

    func testRejectsForwardProxyRequestsAndReportsUnreachableUpstream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let backend = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let unavailablePort = backend.localAddress!.port!
        try await backend.close().get()
        let proxy = HTTPProxyServer()
        let port = try await proxy.start(port: 0)
        try await proxy.setRoutes([WebRoute(domain: "research.test", port: unavailablePort, available: true)])
        for (request, status) in [
            ("CONNECT example.com:443 HTTP/1.1\r\nHost: research.test\r\n\r\n", "400"),
            ("GET http://example.com/ HTTP/1.1\r\nHost: research.test\r\n\r\n", "400"),
            ("GET / HTTP/1.1\r\nHost: research.test\r\nHost: other.test\r\n\r\n", "400"),
            ("GET / HTTP/1.1\r\nHost: research.test\r\n\r\n", "502")
        ] {
            let reply = group.next().makePromise(of: String.self)
            let client = try await ClientBootstrap(group: group).channelInitializer { channel in
                channel.pipeline.addHandler(CollectBytes(promise: reply))
            }.connect(host: "127.0.0.1", port: port).get()
            try await client.writeAndFlush(ByteBuffer(string: request)).get()
            let response = try await reply.futureResult.get()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 \(status)"), response)
        }
        await proxy.stop()
        try await group.shutdownGracefully()
    }

    func testChunkedRequestAndMultipleDomains() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let backend = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(EchoHTTPHandler()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let proxy = HTTPProxyServer()
        let port = try await proxy.start(port: 0)
        try await proxy.setRoutes([
            WebRoute(domain: "one.test", port: backend.localAddress!.port!, available: true),
            WebRoute(domain: "two.test", port: backend.localAddress!.port!, available: true)
        ])
        for domain in ["one.test", "two.test"] {
            let reply = group.next().makePromise(of: String.self)
            let client = try await ClientBootstrap(group: group).channelInitializer { channel in
                channel.pipeline.addHandler(CollectBytes(promise: reply))
            }.connect(host: "127.0.0.1", port: port).get()
            let request = "POST /chunks HTTP/1.1\r\nHost: \(domain)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n"
            try await client.writeAndFlush(ByteBuffer(string: request)).get()
            let response = try await reply.futureResult.get()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
            XCTAssertTrue(response.contains("\(domain) /chunks 6"), response)
        }
        await proxy.stop()
        try await backend.close().get()
        try await group.shutdownGracefully()
    }

    func testOccupiedPortDoesNotTakeOverExistingListener() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let occupied = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let proxy = HTTPProxyServer()
        do {
            try await proxy.start(port: occupied.localAddress!.port!)
            XCTFail("Must not take over another listener")
        } catch { XCTAssertTrue(occupied.isActive) }
        await proxy.stop()
        try await occupied.close().get()
        try await group.shutdownGracefully()
    }
}

private final class EchoHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var count = 0
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(let buffer): count += buffer.readableBytes
        case .end:
            let text = "\(head!.headers.first(name: "Host")!) \(head!.uri) \(count)"
            if head!.method == .HEAD {
                let response = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Content-Length", "123")]))
                context.write(wrapOutboundOut(.head(response)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
                return
            }
            let response = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "chunked")]))
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
            context.eventLoop.scheduleTask(in: .milliseconds(30)) {
                context.write(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: " done")))), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
            }
        }
    }
}

private final class UpgradeEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let received: EventLoopPromise<String>
    var bytes = ""
    var reported = false
    init(received: EventLoopPromise<String>) { self.received = received }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes += String(buffer: unwrapInboundIn(data))
        guard !reported, bytes.contains("pending-frame") else { return }
        reported = true
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        context.writeAndFlush(NIOAny(ByteBuffer(string: response))).whenComplete { _ in
            self.received.succeed(self.bytes)
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !reported { received.fail(NSError(domain: "UpgradeFixture", code: 1)) }
    }
}

private final class CollectBytes: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<String>
    var bytes = ""
    init(promise: EventLoopPromise<String>) { self.promise = promise }
    func handlerAdded(context: ChannelHandlerContext) {
        context.eventLoop.scheduleTask(in: .seconds(10)) { context.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { bytes += String(buffer: unwrapInboundIn(data)) }
    func channelInactive(context: ChannelHandlerContext) { promise.succeed(bytes) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
