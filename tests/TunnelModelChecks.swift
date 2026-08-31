import Foundation

@main
enum TunnelModelChecks {
    static func main() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let original = Tunnel(name: "Research", host: "fixture.invalid", portMappings: [PortMapping(webDomain: "research.test")])
        let items: [SidebarItem] = [.tunnel(original), .divider(GroupDivider(title: "Group"))]
        let roundTrip = try decoder.decode([SidebarItem].self, from: encoder.encode(items))
        precondition(roundTrip == items, "Web domains must survive saving and loading")

        var changed = original
        changed.portMappings[0].webDomain = "renamed.test"
        precondition(changed != original, "The editor must recognize domain changes")
        precondition(original.hasSameConnection(as: changed), "Domain-only edits must not restart SSH")
        changed.portMappings[0].localPort = 55355
        precondition(!original.hasSameConnection(as: changed), "Port changes must restart SSH")

        var oldMapping = try JSONSerialization.jsonObject(with: encoder.encode(original.portMappings[0])) as! [String: Any]
        oldMapping.removeValue(forKey: "webDomain")
        oldMapping.removeValue(forKey: "forward")
        let decodedMapping = try decoder.decode(PortMapping.self, from: JSONSerialization.data(withJSONObject: oldMapping))
        precondition(decodedMapping.webDomain == nil && decodedMapping.forward == .local)

        let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","host":"fixture.invalid","port":22,"autoConnect":false,"localHost":"127.0.0.1","localPort":5432,"remoteHost":"127.0.0.1","remotePort":5432}]"#
        let migrated = try decoder.decode([Tunnel].self, from: Data(legacy.utf8))
        precondition(migrated[0].portMappings[0].localPort == 5432)
        precondition(migrated[0].portMappings[0].webDomain == nil)
        print("PASS: model round-trip, legacy migration, and domain-only edit behavior")
    }
}
