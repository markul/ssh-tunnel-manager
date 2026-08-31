import Darwin
import Foundation
import PortSocketSupport

public enum PortAuthorization {
    /// The app creates and retains its socket; the helper only binds port 80. It exits before the
    /// unprivileged app starts accepting HTTP requests. No daemon is installed.
    public static func requestListener(helper: URL, domains: [String]) async throws -> Int32 {
        try await Task.detached {
            let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("stm-port-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("socket").path
            let receiver = stm_create_receiver(path)
            guard receiver >= 0 else { throw posixError() }
            defer { close(receiver) }
            let listener = stm_create_listener()
            guard listener >= 0 else { throw posixError() }
            var handedOff = false
            defer { if !handedOff { close(listener) } }
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let shell = "set -eu\n\(quote(helper.path)) \(quote(path)) \(getuid())\n"
                + (try HostsFile.updateScript(domains: domains))
                + "\n/usr/bin/dscacheutil -flushcache\n/usr/bin/killall -HUP mDNSResponder || true\n"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", HostsFile.appleScript(forShellCommand: shell)]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let handshake = Task.detached { () -> Result<Void, NSError> in
                if stm_authorize_listener(receiver, listener, 0) < 0 { return .failure(posixError()) }
                return .success(())
            }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                // Wake the handshake before closing its descriptors, including
                // when the user cancels before the helper has connected.
                _ = stm_cancel_authorization(path)
                _ = await handshake.value
                throw NSError(domain: "PortAuthorization", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)
                ])
            }
            try await handshake.value.get()
            handedOff = true
            return listener
        }.value
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
