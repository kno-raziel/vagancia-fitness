import Foundation

public struct WatchRejectedEnvelopeSnapshotReceipt: Codable, Equatable, Sendable {
    public let requestID: String
    public let entryIDs: [String]
    public let capturedAt: Date
    public init(requestID: String, entryIDs: [String], capturedAt: Date = Date()) {
        self.requestID = requestID
        self.entryIDs = entryIDs
        self.capturedAt = capturedAt
    }
}

public struct WatchRejectedEnvelopeChunk: Codable, Equatable, Sendable {
    public let entryID: String
    public let index: Int
    public let count: Int
    public let data: Data
    public init(entryID: String, index: Int, count: Int, data: Data) {
        self.entryID = entryID
        self.index = index
        self.count = count
        self.data = data
    }
    public static func split(_ entry: WatchRejectedEnvelope) throws -> [Self] {
        let encoded = try JSONEncoder().encode(entry)
        let width = 8_192
        let count = max(1, (encoded.count + width - 1) / width)
        guard count <= 1_024 else {
            throw CompanionError.storage(
                "El sobre rechazado excede el límite de transporte diagnóstico; se conserva íntegro en el Watch."
            )
        }
        return (0..<count).map { index in
            let start = index * width
            return Self(
                entryID: entry.id, index: index, count: count,
                data: encoded.subdata(in: start..<min(start + width, encoded.count)))
        }
    }
}

/// Malformed or late traffic must not invalidate an unrelated preparation or
/// collection. Only a rejection owned by the live preparation changes it.
public enum WatchRejectionPolicy {
    public static func failsReadiness(
        activeSessionID: String?, state: WatchCaptureState,
        messageSessionID: String?, messageAttemptID: String?,
        activeAttemptID: String?, reason: String
    ) -> Bool {
        if activeSessionID == nil { return true }
        return state == .preparing && messageSessionID == activeSessionID
            && messageAttemptID == activeAttemptID && reason != "stalePreparation"
            && reason != "wrongSender"
    }
}

/// Original bytes and the state observed at the rejection site. The delivery ID
/// is generated once and survives retries, relaunches and receipt replays.
public struct WatchRejectedEnvelope: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let rejectedAt: Date
    public let channel: String
    public let rawData: Data
    public let reason: String
    public let readinessBefore: WatchReadiness
    public let readinessAfter: WatchReadiness
    public let messageID: String?
    public let payloadType: String?
    public let version: Int?
    public let sessionID: String?
    public let attemptID: String?
    public let sender: String?
    public let sentAt: Date?
    public let errorDescription: String?
    public let errorDomain: String?
    public let errorCode: Int?
    public let decodingPath: [String]?
    public let currentSessionID: String?
    public let ownerSessionID: String?

    public init(
        id: String = UUID().uuidString.lowercased(), rejectedAt: Date = Date(), channel: String,
        rawData: Data, reason: String, readinessBefore: WatchReadiness, readinessAfter: WatchReadiness,
        errorDescription: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil,
        decodingPath: [String]? = nil, currentSessionID: String? = nil, ownerSessionID: String? = nil
    ) {
        self.id = id
        self.rejectedAt = rejectedAt
        self.channel = channel
        self.rawData = rawData
        self.reason = reason
        self.readinessBefore = readinessBefore
        self.readinessAfter = readinessAfter
        self.errorDescription = errorDescription
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.decodingPath = decodingPath
        self.currentSessionID = currentSessionID
        self.ownerSessionID = ownerSessionID
        let envelope = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any]
        messageID = envelope?["id"] as? String
        version = envelope?["version"] as? Int
        sessionID = envelope?["sessionID"] as? String
        attemptID = envelope?["attemptID"] as? String
        sender = envelope?["sender"] as? String
        payloadType = (envelope?["payload"] as? [String: Any])?.keys.sorted().first
        if let value = envelope?["sentAt"] as? Double {
            sentAt = Date(timeIntervalSinceReferenceDate: value)
        } else if let value = envelope?["sentAt"] as? String {
            sentAt = ISO8601DateFormatter().date(from: value)
        } else {
            sentAt = nil
        }
    }
}

/// The same durable format is used on Watch and phone. On Watch, acknowledged
/// IDs suppress retransmission; on phone, entries are exportable evidence.
public final class WatchRejectedEnvelopeJournal {
    private struct Contents: Codable {
        var entries: [WatchRejectedEnvelope] = []
        var acknowledgedIDs: Set<String> = []
    }
    public let url: URL
    private var contents: Contents
    public var entries: [WatchRejectedEnvelope] { contents.entries }
    public var pending: [WatchRejectedEnvelope] {
        contents.entries.filter { !contents.acknowledgedIDs.contains($0.id) }
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = directory.appendingPathComponent("watch-rejected-envelopes-v1.json")
        contents =
            FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url)) : Contents()
    }

    @discardableResult public func record(_ entry: WatchRejectedEnvelope) throws -> Bool {
        guard !contents.entries.contains(where: { $0.id == entry.id }) else { return false }
        var next = contents
        next.entries.append(entry)
        try save(next)
        return true
    }

    public func acknowledge(_ ids: [String]) throws {
        let known = Set(contents.entries.map(\.id))
        var next = contents
        next.acknowledgedIDs.formUnion(ids.filter { known.contains($0) })
        try save(next)
    }

    private func save(_ next: Contents) throws {
        try JSONEncoder().encode(next).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        contents = next
    }
}
