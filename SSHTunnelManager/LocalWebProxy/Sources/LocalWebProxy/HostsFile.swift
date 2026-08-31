import Foundation

/// Owns only a delimited block. Never removes or rewrites unrelated hostname entries.
public enum HostsFile {
    public static let begin = "# BEGIN SSH Tunnel Manager web domains"
    public static let end = "# END SSH Tunnel Manager web domains"

    public static func authorizationScript(domains: [String]) throws -> String {
        let shell = try updateScript(domains: domains)
            + "\n/usr/bin/dscacheutil -flushcache\n/usr/bin/killall -HUP mDNSResponder || true\n"
        return appleScript(forShellCommand: shell)
    }

    public static func appleScript(forShellCommand shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    public static func managedDomains(in contents: String) throws -> Set<String> {
        var inside = false
        var blocks = 0
        var domains = Set<String>()
        for line in contents.components(separatedBy: "\n") {
            if line == begin {
                guard !inside, blocks == 0 else { throw WebDomainError.malformedManagedBlock }
                inside = true
                blocks += 1
            } else if line == end {
                guard inside else { throw WebDomainError.malformedManagedBlock }
                inside = false
            } else if inside {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "127.0.0.1" { domains.formUnion(fields.dropFirst().map(String.init)) }
            }
        }
        guard !inside else { throw WebDomainError.malformedManagedBlock }
        return domains
    }

    public static func validate(_ contents: String, domains: [String]) throws {
        _ = try managedDomains(in: contents)
        let desired = Set(try domains.map(WebDomain.normalize))
        var inside = false
        for line in contents.components(separatedBy: "\n") {
            if line == begin { inside = true; continue }
            if line == end { inside = false; continue }
            guard !inside else { continue }
            let fields = line.split(separator: "#", omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard let address = fields.first else { continue }
            for name in fields.dropFirst() where desired.contains(name.lowercased()) && address != "127.0.0.1" {
                throw WebDomainError.conflictingHostsEntry(name)
            }
        }
    }

    /// The privileged operation re-reads and validates the current file, rather than
    /// copying a stale, user-writable snapshot over /etc/hosts. Only normalized names
    /// are inserted. Paths are shell-quoted; alternate paths are for fixture tests.
    public static func updateScript(domains: [String], path: String = "/etc/hosts") throws -> String {
        let names = Array(Set(try domains.map(WebDomain.normalize))).sorted().joined(separator: " ")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        set -eu
        target=\(quote(path))
        [ -f "$target" ] && [ ! -L "$target" ] || { echo 'Hosts file must be a regular file.' >&2; exit 1; }
        tmp=$(/usr/bin/mktemp "${target}.ssh-tunnel-manager.XXXXXX")
        trap '/bin/rm -f "$tmp"' EXIT
        /usr/bin/awk -v names=\(quote(names)) '
        BEGIN { count = split(names, domains, " "); for (i=1; i<=count; i++) wanted[domains[i]]=1 }
        $0 == "\(begin)" { if (inside || blocks++) bad=1; inside=1; next }
        $0 == "\(end)" { if (!inside) bad=1; inside=0; next }
        !inside {
            original=$0; sub(/#.*/, "")
            for (i=2; i<=NF; i++) if (wanted[tolower($i)] && $1 != "127.0.0.1") conflict=1
            print original
        }
        END {
            if (bad || inside || conflict) exit 42
            if (count > 0) {
                print "\(begin)"
                for (i=1; i<=count; i++) print "127.0.0.1 " domains[i]
                print "\(end)"
            }
        }' "$target" > "$tmp" || { echo 'Hosts file has conflicting entries or an invalid managed block. No changes were made.' >&2; exit 1; }
        /bin/chmod 644 "$tmp"
        /bin/mv -f "$tmp" "$target"
        """
    }
}
