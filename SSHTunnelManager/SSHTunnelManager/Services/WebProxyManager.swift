import AppKit
import Darwin
import Foundation
import LocalWebProxy
import Observation

@Observable
@MainActor
final class WebProxyManager {
    private static let automaticHTTPKey = "webDomainsAutomaticallyEnableHTTP"
    private let defaults: UserDefaults
    var automaticallyEnableHTTP: Bool {
        didSet { defaults.set(automaticallyEnableHTTP, forKey: Self.automaticHTTPKey) }
    }
    private(set) var domains: [String] = []
    private(set) var issues: [String] = []
    private(set) var status = "No web domains configured"
    private(set) var isRunning = false
    private(set) var applyingHosts = false
    private(set) var needsPortAuthorization = false
    private(set) var hostsNeedUpdate = false
    private(set) var hostsError: String?
    private let server = HTTPProxyServer()
    private var desiredRoutes: [WebRoute] = []
    private var appliedRoutes: [WebRoute]?
    private var updateTask: Task<Void, Never>?
    private var stopped = false
    private var authorizingPort = false
    private var attemptedAutomaticAuthorization = false
    private var lastAutomaticHostsSnapshot: Set<String>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.automaticHTTPKey) == nil {
            // Earlier builds did not save this preference. Their managed hosts
            // block records that the user already completed hostname setup.
            let contents = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
            let existingDomains = (try? HostsFile.managedDomains(in: contents)) ?? []
            defaults.set(!existingDomains.isEmpty, forKey: Self.automaticHTTPKey)
        }
        automaticallyEnableHTTP = defaults.bool(forKey: Self.automaticHTTPKey)
    }

    static func validationError(for mapping: PortMapping) -> String? {
        guard mapping.forward == .local, let input = mapping.webDomain,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try WebDomain.normalize(input) } catch { return error.localizedDescription }
        guard ["127.0.0.1", "localhost", "0.0.0.0"].contains(mapping.localHost.trimmingCharacters(in: .whitespaces)) else {
            return "Web domains require a local forward listening on 127.0.0.1, localhost, or 0.0.0.0."
        }
        guard (1...65535).contains(mapping.localPort), mapping.localPort != 80 else {
            return "Choose a local tunnel port from 1–65535 other than 80; the web proxy uses port 80."
        }
        return nil
    }

    func configure(tunnels: [Tunnel], established: Set<UUID>, processIDs: [UUID: Int32]) {
        guard !stopped else { return }
        var candidates: [WebRoute] = []
        var errors: [String] = []
        for tunnel in tunnels {
            for mapping in tunnel.portMappings where mapping.forward == .local {
                guard let input = mapping.webDomain, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let error = Self.validationError(for: mapping) {
                    errors.append("\(tunnel.name): \(error)")
                    continue
                }
                guard let domain = try? WebDomain.normalize(input) else { continue }
                candidates.append(WebRoute(domain: domain, port: mapping.localPort,
                                           available: established.contains(tunnel.id) && processIDs[tunnel.id] != nil,
                                           generation: "\(tunnel.id):\(processIDs[tunnel.id] ?? 0)"))
            }
        }
        let counts = Dictionary(grouping: candidates, by: \.domain)
        let duplicates = Set(counts.filter { $0.value.count > 1 }.keys)
        for domain in duplicates.sorted() { errors.append("\(domain) is assigned to more than one mapping. It will not be served.") }
        desiredRoutes = candidates.filter { !duplicates.contains($0.domain) }.sorted { $0.domain < $1.domain }
        domains = desiredRoutes.map(\.domain)
        issues = errors
        refreshHostsStatus()
        scheduleUpdate()
    }

    func retry() {
        appliedRoutes = nil
        scheduleUpdate()
    }

    /// Serialize listener changes; if settings change across an await, apply the newest snapshot next.
    private func scheduleUpdate() {
        guard updateTask == nil, !authorizingPort else { return }
        updateTask = Task {
            while appliedRoutes != desiredRoutes || stopped {
                if stopped {
                    await server.stop()
                    isRunning = false
                    break
                }
                let routes = desiredRoutes
                do {
                    try await server.setRoutes(routes)
                    if routes.isEmpty {
                        await server.stop()
                        isRunning = false
                        needsPortAuthorization = false
                        status = "No web domains configured"
                    } else {
                        _ = try await server.start()
                        isRunning = true
                        needsPortAuthorization = false
                        status = "HTTP proxy listening on 127.0.0.1:80"
                    }
                } catch ProxyError.portPermissionRequired {
                    isRunning = false
                    needsPortAuthorization = true
                    status = "macOS authorization is needed to open HTTP port 80."
                } catch {
                    isRunning = false
                    needsPortAuthorization = false
                    status = "Cannot start the web proxy: \(error.localizedDescription). Check whether port 80 is already in use, then retry."
                }
                appliedRoutes = routes
            }
            updateTask = nil
            restoreHTTPIfNeeded()
            applyHostnamesIfNeeded()
        }
    }

    private func restoreHTTPIfNeeded() {
        guard automaticallyEnableHTTP, needsPortAuthorization, !attemptedAutomaticAuthorization,
              !authorizingPort, !applyingHosts, !stopped, !domains.isEmpty else { return }
        enableHTTP()
    }

    private func applyHostnamesIfNeeded() {
        let snapshot = Set(domains)
        guard automaticallyEnableHTTP, hostsNeedUpdate, hostsError == nil,
              !applyingHosts, !authorizingPort, !stopped,
              lastAutomaticHostsSnapshot != snapshot else { return }
        // Avoid repeatedly asking for authorization after cancellation while
        // tunnel status changes. Editing the domain set enables another try,
        // and the manual button remains available for an immediate retry.
        lastAutomaticHostsSnapshot = snapshot
        applyHostnames()
    }

    func stop() {
        stopped = true
        desiredRoutes = []
        scheduleUpdate()
    }

    func enableHTTP() {
        guard !stopped, !applyingHosts, !isRunning, !domains.isEmpty else { return }
        // A cancellation or failure must not trigger repeated prompts as SSH
        // status changes. The next launch can try again; manual retry still works.
        attemptedAutomaticAuthorization = true
        applyingHosts = true
        authorizingPort = true
        hostsError = nil
        let snapshot = domains
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/web-proxy-bind")
        Task {
            defer {
                applyingHosts = false
                authorizingPort = false
                scheduleUpdate()
            }
            // Finish any in-progress unprivileged bind attempt before adopting
            // the authorized socket, so its result cannot overwrite our state.
            await updateTask?.value
            do {
                guard !stopped else { return }
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    throw NSError(domain: "WebProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "The port authorization helper is missing. Rebuild or reinstall the app."])
                }
                try HostsFile.validate(String(contentsOfFile: "/etc/hosts", encoding: .utf8), domains: snapshot)
                let descriptor = try await PortAuthorization.requestListener(helper: helper, domains: snapshot)
                guard !stopped else { close(descriptor); return }
                let routes = desiredRoutes
                do { try await server.setRoutes(routes) } catch { close(descriptor); throw error }
                _ = try await server.adoptListener(descriptor)
                appliedRoutes = routes
                isRunning = true
                automaticallyEnableHTTP = true
                needsPortAuthorization = false
                status = "HTTP proxy listening on 127.0.0.1:80"
                refreshHostsStatus()
            } catch { hostsError = error.localizedDescription }
        }
    }

    func refreshHostsStatus() {
        do {
            let contents = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            try HostsFile.validate(contents, domains: domains)
            hostsNeedUpdate = try HostsFile.managedDomains(in: contents) != Set(domains)
            hostsError = nil
        } catch {
            hostsError = error.localizedDescription
            hostsNeedUpdate = true
        }
    }

    /// Updates the managed hosts block. The OS owns the password prompt.
    func applyHostnames() {
        guard !applyingHosts else { return }
        let snapshot = domains
        applyingHosts = true
        hostsError = nil
        Task {
            do {
                let contents = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
                try HostsFile.validate(contents, domains: snapshot)
                let source = try HostsFile.authorizationScript(domains: snapshot)
                try await Task.detached {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", source]
                    process.standardOutput = FileHandle.nullDevice
                    let errors = Pipe()
                    process.standardError = errors
                    try process.run()
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw NSError(domain: "WebHostnames", code: Int(process.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)
                        ])
                    }
                }.value
                refreshHostsStatus()
            } catch {
                hostsError = error.localizedDescription
            }
            let domainsChangedWhileApplying = Set(domains) != Set(snapshot)
            applyingHosts = false
            if domainsChangedWhileApplying {
                refreshHostsStatus()
                scheduleUpdate()
            }
        }
    }
}
