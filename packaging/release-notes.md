## Custom HTTP domains for SSH tunnels

This release includes a fix for helper signing in clean, sandboxed Xcode builds.

Assign a `.test` hostname to a local port mapping and open forwarded web apps at
addresses such as `http://research.test` instead of remembering a localhost port.

- Integrated SwiftNIO HTTP proxy with streaming and WebSocket support; no Caddy installation required.
- Loopback-only listener and upstream connections. No public sharing or LAN listener is added.
- Hostname setup updates only the app's managed block in `/etc/hosts`.
- HTTP enablement is remembered and restored automatically on launch.
- Domain-only edits preserve SSH connections; disconnected or replaced tunnels revoke their proxy connections.
- Existing tunnel configurations remain compatible.

### Installation

Download `SSHTunnelManager.dmg`, open it, and drag the app into Applications.
Quit the previous app before replacing it. The universal app contains Apple Silicon
and Intel binaries and requires macOS 14 or later. It is ad-hoc signed, not notarized.

### Setup and limitations

Set a local mapping's **Web domain**, save it, then open **Preferences → Web domains**
to enable HTTP and apply hostname entries. Use an explicit `http://` URL.

On Macs that restrict port 80, macOS requests administrator authorization. A temporary
helper binds the app's socket to `127.0.0.1:80` and exits; no privileged daemon is installed.
Automatic restoration may still show the administrator prompt after an app restart.
HTTPS and `.local` names are not supported. Applications that call a separate backend
may need their new frontend origin added to the backend's CORS allowlist.

### Verification

16 automated tests cover domain validation, hosts-file updates, HTTP streaming,
WebSockets, socket handoff, authorization cancellation, and route revocation.
Legacy configuration and domain-only edit behavior are checked separately.
Live HTTP domains and browser rendering were verified on Apple Silicon; the Intel
binary is cross-compiled but has not been run on Intel hardware.
