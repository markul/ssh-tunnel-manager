import Foundation
import XCTest
@testable import LocalWebProxy

final class DomainAndHostsTests: XCTestCase {
    func testAuthorizationScriptCompilesWithoutExecutingOrPrompting() throws {
        let script = try XCTUnwrap(NSAppleScript(source: HostsFile.authorizationScript(domains: ["research.test"])))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testDomainValidation() throws {
        XCTAssertEqual(try WebDomain.normalize(" Research-3600.TEST \n"), "research-3600.test")
        XCTAssertEqual(try WebDomain.normalize(" Artifacts.PROD \n"), "artifacts.prod")
        for input in ["example.com", "test", "foo.local", "http://foo.test", "foo.test:80", "foo.test/path",
                      "-foo.test", "foo-.test", "foo..test", "foo.test\n127.0.0.1 bad.test", "$(touch bad).test", "é.test"] {
            XCTAssertThrowsError(try WebDomain.normalize(input), input)
        }
    }

    func testHostsUpdatePreservesUnrelatedEntriesAndRemovesOnlyManagedNames() throws {
        try withHosts("127.0.0.1 localhost\n192.0.2.1 office.test # keep\n") { url in
            try apply(["research-3600.test", "another.prod"], to: url)
            var contents = try String(contentsOf: url)
            XCTAssertTrue(contents.contains("192.0.2.1 office.test # keep"))
            XCTAssertEqual(try HostsFile.managedDomains(in: contents), ["research-3600.test", "another.prod"])
            try apply(["another.prod"], to: url)
            contents = try String(contentsOf: url)
            XCTAssertFalse(contents.contains("research-3600.test"))
            try apply([], to: url)
            XCTAssertEqual(try String(contentsOf: url), "127.0.0.1 localhost\n192.0.2.1 office.test # keep\n")
        }
    }

    func testConflictsAndBrokenBlocksNeverOverwriteTheOriginal() throws {
        for contents in ["192.0.2.1 RESEARCH.test\n", "\(HostsFile.begin)\n127.0.0.1 research.test\n",
                         "\(HostsFile.end)\n", "\(HostsFile.begin)\n\(HostsFile.end)\n\(HostsFile.begin)\n\(HostsFile.end)\n"] {
            try withHosts(contents) { url in
                XCTAssertThrowsError(try HostsFile.validate(contents, domains: ["research.test"]))
                XCTAssertThrowsError(try apply(["research.test"], to: url))
                XCTAssertEqual(try String(contentsOf: url), contents)
            }
        }
    }

    func testApplyingUnchangedNamesIsIdempotent() throws {
        try withHosts("127.0.0.1 localhost\n") { url in
            try apply(["research.test"], to: url)
            let first = try Data(contentsOf: url)
            try apply(["research.test"], to: url)
            XCTAssertEqual(try Data(contentsOf: url), first)
        }
    }

    private func withHosts(_ contents: String, body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("hosts fixture's file")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try body(file)
    }

    private func apply(_ domains: [String], to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try HostsFile.updateScript(domains: domains, path: url.path)]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw NSError(domain: "Fixture", code: Int(process.terminationStatus)) }
    }
}
