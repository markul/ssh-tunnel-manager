## Custom HTTP domains for SSH tunnels

Assign a `.test` hostname to a local port mapping and open forwarded web apps at
addresses such as `http://research-3600.test/monitoring` instead of
`http://localhost:55355/monitoring`. The original localhost URL still works.

- Integrated SwiftNIO HTTP proxy with streaming and WebSocket support; no Caddy installation required.
- Loopback-only listener and upstream connections. No public sharing or LAN listener is added.
- Hostname setup updates only the app's managed block in `/etc/hosts`.
- HTTP enablement is remembered and restored automatically on launch.
- Domain-only edits preserve SSH connections; disconnected or replaced tunnels revoke their proxy connections.
- Existing tunnel configurations remain compatible.
- Includes fixes for helper compilation and signing in clean, sandboxed Xcode builds.

### Feature screenshots

![Web domain in tunnel settings](https://raw.githubusercontent.com/markul/ssh-tunnel-manager/main/.github/web-domain-settings.png)

*App screenshot with hostnames, domain names, and ports replaced by example values.*

### Installation

Download `SSHTunnelManager.dmg`, open it, and drag the app into Applications.
Quit the previous app before replacing it. The universal app contains Apple Silicon
and Intel binaries and requires macOS 14 or later. It is ad-hoc signed, not notarized.

### Setup and limitations

1. Set a local forward's **Web domain (optional)** to `research-3600.test` and save.
2. Open **Preferences → Web domains**, enable HTTP, and apply hostname entries.
3. Approve the macOS administrator prompt, connect the tunnel, and open
   **http://research-3600.test**. Use an explicit `http://` URL.

A mapping from Mac `127.0.0.1:55355` to server `127.0.0.1:3000` now serves the
same web app at the named address. Each mapping can have a unique `.test` hostname.

On Macs that restrict port 80, macOS requests administrator authorization. A temporary
helper binds the app's socket to `127.0.0.1:80` and exits; no privileged daemon is installed.
Automatic restoration may still show the administrator prompt after an app restart.
HTTPS and `.local` names are not supported. Applications that call a separate backend
need their API port forward connected and may need the exact new frontend origin,
for example `http://research-3600.test` without a path, added to the backend's CORS
allowlist. The proxy does not rewrite frontend API URLs or bypass browser security.

See the [full setup, CORS, and troubleshooting guide](https://github.com/markul/ssh-tunnel-manager#local-web-domains-http-only).

### Verification

16 automated tests cover domain validation, hosts-file updates, HTTP streaming,
WebSockets, socket handoff, authorization cancellation, and route revocation.
Legacy configuration and domain-only edit behavior are checked separately.
Live HTTP domains and browser rendering were verified on Apple Silicon; the Intel
binary is cross-compiled but has not been run on Intel hardware.
