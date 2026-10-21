import FitnessCore
import Foundation

/// Durable phone receipt for terminal Watch results, including results whose
/// workout never existed on this phone. ACK follows an atomic receipt write.
struct WatchTerminalResultLedger {
    struct Receipt: Codable {
        let sessionID: String
        let deliveryID: String
        let receivedAt: Date
        let result: HealthSaveResult
    }

    private let url: URL
    private var receipts: [String: Receipt]

    init(directory: URL) throws {
        url = directory.appendingPathComponent("watch-terminal-results.json")
        if FileManager.default.fileExists(atPath: url.path) {
            receipts = try EvidenceJSON.decoder().decode(
                [String: Receipt].self, from: Data(contentsOf: url))
        } else {
            receipts = [:]
        }
    }

    func contains(sessionID: String, deliveryID: String) -> Bool {
        receipts["\(sessionID):\(deliveryID)"] != nil
    }

    mutating func accept(sessionID: String, result: HealthSaveResult) throws {
        guard let deliveryID = result.deliveryID, !deliveryID.isEmpty else {
            throw CompanionError.invalidMessage
        }
        let key = "\(sessionID):\(deliveryID)"
        guard receipts[key] == nil else { return }
        var next = receipts
        next[key] = Receipt(
            sessionID: sessionID, deliveryID: deliveryID, receivedAt: Date(), result: result)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceJSON.encoder().encode(next).write(to: url, options: .atomic)
        receipts = next
    }
}
