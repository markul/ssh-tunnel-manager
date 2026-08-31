import Darwin
import Foundation
import XCTest
import PortSocketSupport
@testable import LocalWebProxy

final class SocketTransferTests: XCTestCase {
    func testAppOwnedListenerSurvivesBinderProcessExit() async throws {
        let directory = URL(fileURLWithPath: "/tmp/stm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("socket").path
        let receiver = stm_create_receiver(path)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { close(receiver) }
        let listener = stm_create_listener()
        XCTAssertGreaterThanOrEqual(listener, 0)
        let sender = Process()
        sender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        sender.arguments = ["-c", """
        import array, socket, sys
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(5)
        connection.connect(sys.argv[1])
        data, ancillary, flags, address = connection.recvmsg(1, socket.CMSG_SPACE(array.array('i').itemsize))
        descriptors = array.array('i')
        descriptors.frombytes(ancillary[0][2])
        listener = socket.socket(fileno=descriptors[0])
        listener.bind(('127.0.0.1', 0))
        listener.listen(8)
        connection.sendall(b'B')
        listener.close()
        connection.close()
        """, path]
        try sender.run()
        let authorized = stm_authorize_listener(receiver, listener, getuid())
        let savedError = errno
        sender.waitUntilExit()
        XCTAssertEqual(sender.terminationStatus, 0)
        guard authorized == 0 else { close(listener); throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedError)) }
        let proxy = HTTPProxyServer()
        let port = try await proxy.adoptListener(listener)
        try await proxy.setRoutes([WebRoute(domain: "research.test", port: 55355, available: false)])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!, timeoutInterval: 5)
        request.setValue("research.test", forHTTPHeaderField: "Host")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }

    func testCancellingAuthorizationWakesHandshake() async throws {
        let directory = URL(fileURLWithPath: "/tmp/stm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("socket").path
        let receiver = stm_create_receiver(path)
        let listener = stm_create_listener()
        defer { close(receiver); close(listener) }
        let finished = expectation(description: "Cancelled handshake returned")
        DispatchQueue.global().async {
            XCTAssertEqual(stm_authorize_listener(receiver, listener, 0), -1)
            finished.fulfill()
        }
        XCTAssertEqual(stm_cancel_authorization(path), 0)
        await fulfillment(of: [finished], timeout: 2)
    }

    func testTransferredSocketWorksWhileAppRetainsItsDescriptor() async throws {
        let directory = URL(fileURLWithPath: "/tmp/stm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("socket").path
        let receiver = stm_create_receiver(path)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { close(receiver) }
        let sender = try connectUnix(path)
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        // The production app keeps its original descriptor throughout the
        // exchange. Do not leave the socket owned only by a queued message.
        defer { close(listening) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listening, 8), 0)
        XCTAssertEqual(stm_send_listener(sender, listening), 0)
        close(sender)
        // The fixture uses our UID and an ephemeral port. The app requires UID 0 and port 80.
        let transferred = stm_receive_listener(receiver, getuid())
        guard transferred >= 0 else {
            XCTFail("Socket transfer failed: \(String(cString: strerror(errno)))")
            return
        }
        let proxy = HTTPProxyServer()
        let port = try await proxy.adoptListener(transferred)
        try await proxy.setRoutes([WebRoute(domain: "research.test", port: 55355, available: false)])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.setValue("research.test", forHTTPHeaderField: "Host")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        await proxy.stop()
    }

    func testRejectsUntrustedSenderAndNonSocketDescriptor() throws {
        for requireRoot in [true, false] {
            let directory = URL(fileURLWithPath: "/tmp/stm-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("socket").path
            let receiver = stm_create_receiver(path)
            defer { close(receiver) }
            let sender = try connectUnix(path)
            let file = open("/dev/null", O_RDONLY)
            XCTAssertEqual(stm_send_listener(sender, file), 0)
            close(file)
            close(sender)
            XCTAssertEqual(stm_receive_listener(receiver, requireRoot ? 0 : getuid()), -1)
        }
    }

    func testBinderRefusesToRunWithoutAuthorization() {
        guard geteuid() != 0 else { return }
        XCTAssertEqual(stm_bind_for_app("/tmp/not-a-receiver", getuid()), -1)
        XCTAssertEqual(errno, EPERM)
    }

    private func connectUnix(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                _ = strcpy(UnsafeMutableRawPointer(target).assumingMemoryBound(to: CChar.self), source)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(descriptor); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return descriptor
    }
}
