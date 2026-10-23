import SwiftUI

@MainActor
struct WebDomainsView: View {
    @Environment(TunnelManager.self) private var tunnelManager
    private var proxy: WebProxyManager { tunnelManager.webProxy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Web domains").font(.headline)
            Text(proxy.status).font(.callout)
                .foregroundStyle(proxy.isRunning ? .primary : .secondary)
            Text("HTTP only, accessible from this Mac. Assign .test or .prod names in a local port mapping. Once enabled, later hostname changes are applied automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text(".prod is a public domain suffix. A name you assign here overrides that exact hostname on this Mac while its hosts entry exists.")
                .font(.caption).foregroundStyle(.secondary)
            if !proxy.domains.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(proxy.domains, id: \.self) { domain in
                            Text(domain).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            ForEach(proxy.issues, id: \.self) { issue in
                Text(issue).font(.caption).foregroundStyle(.red)
            }
            if let error = proxy.hostsError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Text(proxy.hostsNeedUpdate ? "Hostname changes have not been applied." : "Hostname entries are up to date.")
                .font(.caption)
            HStack {
                if proxy.needsPortAuthorization {
                    Button(proxy.applyingHosts ? "Authorizing…" : "Enable HTTP and apply hostnames…") { proxy.enableHTTP() }
                        .disabled(proxy.applyingHosts || proxy.domains.isEmpty)
                } else {
                Button(proxy.applyingHosts ? "Applying…" : "Apply hostnames…") { proxy.applyHostnames() }
                    .disabled(proxy.applyingHosts || !proxy.hostsNeedUpdate)
                Button("Retry proxy") { proxy.retry() }
                    .disabled(proxy.domains.isEmpty || proxy.isRunning)
                }
            }
            Toggle("Restore HTTP and apply domain changes automatically", isOn: Binding(
                get: { proxy.automaticallyEnableHTTP },
                set: { proxy.automaticallyEnableHTTP = $0 }
            )).font(.caption)
            Text("After HTTP is enabled, the app restores it on launch and applies domain edits automatically. macOS may still ask for administrator authorization. Cancelling leaves the current entries unchanged until you retry or edit the domains again.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The manual button retries a cancelled update. The app changes only its managed block in /etc/hosts; removing every web domain removes that block after authorization.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { proxy.refreshHostsStatus() }
    }
}
