import FitnessCore
import Foundation

/// Describes exactly the Watch evidence available at the export barrier.
/// A local snapshot does not imply that an offline Watch has delivered everything.
public struct WatchDiagnosticExportSnapshot: Sendable {
    public enum SyncStatus: String, Codable, Sendable {
        case localSnapshot, snapshotConfirmed, timedOut, unavailable
    }

    public let entries: [WatchRejectedEnvelope]
    public let capturedAt: Date
    public let syncStatus: SyncStatus
    public let collectionRequestID: String?
    public let watchSnapshotAt: Date?

    public init(
        entries: [WatchRejectedEnvelope], capturedAt: Date = Date(),
        syncStatus: SyncStatus = .localSnapshot, collectionRequestID: String? = nil,
        watchSnapshotAt: Date? = nil
    ) {
        self.entries = entries.sorted {
            $0.rejectedAt == $1.rejectedAt ? $0.id < $1.id : $0.rejectedAt < $1.rejectedAt
        }
        self.capturedAt = capturedAt
        self.syncStatus = syncStatus
        self.collectionRequestID = collectionRequestID
        self.watchSnapshotAt = watchSnapshotAt
    }

    var manifestValue: JSONValue {
        .object([
            "schemaVersion": .string("1.0"),
            "scope": .string(
                "allWatchAppRejectionsReceivedOnThisPhone; includes setup and other sessions"),
            "capturedAt": .string(EvidenceJSON.timestamp(capturedAt)),
            "syncStatus": .string(syncStatus.rawValue),
            "allWatchRejectionsReceived": syncStatus == .snapshotConfirmed ? .bool(true) : .null,
            "collectionRequestID": collectionRequestID.map(JSONValue.string) ?? .null,
            "watchSnapshotAt": watchSnapshotAt.map { .string(EvidenceJSON.timestamp($0)) } ?? .null,
            "receivedEntryCount": .number(Double(entries.count)),
            "files": .array([
                .string("watch-rejected-envelopes.json"), .string("watch-rejected-envelopes.jsonl"),
            ]),
            "rawBytes": .string(
                "rawData is Base64; rawHex is the same complete bytes in hexadecimal; no truncation"),
            "coverage": .string(
                "Entries cover received and durably assembled records. An empty local snapshot does not establish absence of errors on the Watch. Rejections before logging was installed cannot be recovered."
            ),
        ])
    }

    func files() throws -> [StoredZIP.Entry] {
        let values: [JSONValue] = try entries.map { entry in
            let value = try EvidenceJSON.decoder().decode(
                JSONValue.self, from: EvidenceJSON.encoder().encode(entry))
            guard case .object(var fields) = value else {
                throw EncodingError.invalidValue(
                    entry, .init(codingPath: [], debugDescription: "Watch rejection must encode as an object")
                )
            }
            fields["rawHex"] = .string(entry.rawData.map { String(format: "%02X", $0) }.joined())
            fields["rawByteCount"] = .number(Double(entry.rawData.count))
            fields["source"] = .string("watchApplicationObserved")
            return .object(fields)
        }
        var lines = Data()
        for value in values {
            lines.append(try EvidenceJSON.encoder().encode(value))
            lines.append(0x0a)
        }
        let document: JSONValue = .object(["capture": manifestValue, "entries": .array(values)])
        return [
            .init(
                name: "watch-rejected-envelopes.json",
                data: try EvidenceJSON.encoder(pretty: true).encode(document)),
            .init(name: "watch-rejected-envelopes.jsonl", data: lines),
        ]
    }
}
