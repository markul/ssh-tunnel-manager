import Foundation

public enum WebDomain {
    /// Limits local routes to the reserved .test suffix and the explicitly supported .prod suffix.
    public static func normalize(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2,
              labels.last.map({ $0 == "test" || $0 == "prod" }) == true,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else {
            throw WebDomainError.invalidName
        }
        return name
    }
}

public enum WebDomainError: LocalizedError {
    case invalidName
    case conflictingHostsEntry(String)
    case malformedManagedBlock

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Use a hostname ending in .test or .prod, such as research-3600.test, without http://, a port, or a path."
        case .conflictingHostsEntry(let domain): return "The hosts file already maps \(domain) to another address. Resolve that entry before applying web domains."
        case .malformedManagedBlock: return "The SSH Tunnel Manager block in the hosts file is incomplete or duplicated. No changes were made."
        }
    }
}

public struct WebRoute: Equatable, Sendable {
    public let domain: String
    public let port: Int
    public let available: Bool
    /// Identifies this specific SSH process, so a reconnect revokes old streams.
    public let generation: String

    public init(domain: String, port: Int, available: Bool, generation: String = "") {
        self.domain = domain
        self.port = port
        self.available = available
        self.generation = generation
    }
}
