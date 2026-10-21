import FitnessCore
import Foundation

public struct RememberedTreadmill: Codable, Equatable, Sendable {
    public let identifier: UUID
    public let name: String?
    public var connectOnOpen = false

    public init(identifier: UUID, name: String?, connectOnOpen: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.connectOnOpen = connectOnOpen
    }
}

public struct ConnectOnOpenPolicy {
    public private(set) var attempted = false
    public mutating func claim(enabled: Bool, foreground: Bool, idle: Bool) -> Bool {
        guard enabled, foreground, idle, !attempted else { return false }
        attempted = true
        return true
    }
    public mutating func suppress() { attempted = true }
}

/// Local CoreBluetooth identifier, not a MAC address or hardware identity proof.
public struct RememberedTreadmillStorage {
    public let url: URL

    public func load() throws -> RememberedTreadmill? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RememberedTreadmill?.self, from: Data(contentsOf: url))
    }

    public func save(_ device: RememberedTreadmill?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // JSON null remembers the decision to forget; a missing file alone
        // permits one-time migration of a historical hardware inventory.
        try JSONEncoder().encode(device).write(to: url, options: .atomic)
    }

    public init(url: URL) { self.url = url }
}
