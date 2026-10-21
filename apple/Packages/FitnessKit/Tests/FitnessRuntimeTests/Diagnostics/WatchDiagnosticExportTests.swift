import FitnessCore
import Foundation
import Testing

@testable import FitnessRuntime

@MainActor
struct WatchDiagnosticExportTests {
    @Test func largeRejectedMessageTravelsThroughReceiverAndExportsBeforeAnyWorkout() async throws {
        // Keep temporary stores until xctest exits: async persistence may outlive
        // a local reference. The archive is also inspected with Python zipfile.
        let directory = temporaryDirectory()
        let coordinator = WorkoutCoordinator(directory: directory)
        let companion = ExportWatchCompanion()
        coordinator.attachCompanion(companion)
        try coordinator.store.startSession()
        let raw = Data((0..<90_000).map { UInt8($0 % 251) })
        let ready = WatchReadiness(state: .prepared)
        let entry = WatchRejectedEnvelope(
            id: "rejection-large", channel: "watchConnectivity.applicationContext",
            rawData: raw, reason: "decodeFailure", readinessBefore: ready, readinessAfter: ready)
        let chunks = try WatchRejectedEnvelopeChunk.split(entry)
        let receive = try #require(companion.onMessage)
        for (index, chunk) in chunks.enumerated() {
            try await receive(
                .init(
                    sessionID: "diagnostics", sender: "watch", sequence: UInt64(index),
                    payload: .rejectedEnvelopeChunk(chunk)))
            if index < chunks.count - 1 { #expect(companion.rejectionACKs.isEmpty) }
        }
        #expect(companion.rejectionACKs == [[entry.id]])
        #expect(coordinator.currentRecord == nil)
        let archive = try await coordinator.exportDiagnostic(metadata: metadata)
        #expect(companion.flushRequests == 1)
        #expect(archive.fileURLs.count == 7)
        let document = try readObject("watch-rejected-envelopes.json", in: archive)
        guard case .array(let entries) = document["entries"], case .object(let row) = entries.first
        else {
            Issue.record("Missing rejection in exported JSON")
            return
        }
        #expect(row["id"] == .string(entry.id))
        #expect(row["rawByteCount"] == .number(Double(raw.count)))
        let base64 = try #require(row["rawData"]?.text)
        #expect(Data(base64Encoded: base64) == raw)
        #expect(row["rawHex"] == .string(raw.map { String(format: "%02X", $0) }.joined()))
        #expect(row["readinessBefore"] == row["readinessAfter"])
        let manifest = try readObject("manifest.json", in: archive)
        guard case .object(let coverage) = manifest["watchDiagnostics"] else {
            Issue.record("Missing Watch coverage metadata")
            return
        }
        #expect(coverage["syncStatus"] == .string("unavailable"))
        #expect(coverage["allWatchRejectionsReceived"] == .null)
        #expect(coverage["receivedEntryCount"] == .number(1))
        let jsonlURL = try #require(
            archive.fileURLs.first { $0.lastPathComponent == "watch-rejected-envelopes.jsonl" })
        let lines = try String(contentsOf: jsonlURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let jsonl = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(lines[0].utf8))
        #expect(jsonl == row)
        #expect(try Data(contentsOf: archive.archiveURL).starts(with: [0x50, 0x4b, 0x03, 0x04]))
    }

    @Test func emptyOfflineSnapshotDoesNotClaimWatchHasNoErrors() async throws {
        let store = SessionStore(directory: temporaryDirectory())
        try store.startSession()
        let archive = try await store.exportAsync(
            metadata: metadata,
            watchDiagnostics: .init(entries: [], syncStatus: .unavailable))
        let manifest = try readObject("manifest.json", in: archive)
        guard case .object(let coverage) = manifest["watchDiagnostics"] else {
            Issue.record("Missing Watch coverage metadata")
            return
        }
        #expect(coverage["receivedEntryCount"] == .number(0))
        #expect(coverage["allWatchRejectionsReceived"] == .null)
        #expect(coverage["syncStatus"] == .string("unavailable"))
        let jsonlURL = try #require(
            archive.fileURLs.first { $0.lastPathComponent == "watch-rejected-envelopes.jsonl" })
        #expect(try Data(contentsOf: jsonlURL).isEmpty)
    }

    @Test func damagedRejectionJournalFailsExportInsteadOfSilentlyReportingZeroErrors() async throws {
        let directory = temporaryDirectory()
        let coordinator = WorkoutCoordinator(directory: directory)
        try coordinator.store.startSession()
        try Data("invalid-journal".utf8).write(
            to: directory.appendingPathComponent("watch-rejected-envelopes-v1.json"))
        await #expect(throws: DecodingError.self) {
            try await coordinator.exportDiagnostic(metadata: metadata)
        }
    }

    private var metadata: AppMetadata {
        .init(
            version: "0.8.3-test", build: "16", osVersion: "26",
            deviceModel: "Synthetic test; no hardware")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "WatchDiagnosticsExport-\(UUID().uuidString)")
    }

    private func readObject(_ name: String, in archive: DiagnosticExport) throws -> [String:
        JSONValue]
    {
        let url = try #require(archive.fileURLs.first { $0.lastPathComponent == name })
        return try EvidenceJSON.decoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }
}

@MainActor
private final class ExportWatchCompanion: WorkoutCompanion {
    var useWatch = true
    var readiness = WatchReadiness(state: .prepared)
    var preparedSessionID: String?
    var onMessage: ((CompanionMessage) async throws -> Void)?
    var rejectionACKs: [[String]] = []
    var flushRequests = 0
    func prepare(id: String, view: CompanionWorkoutView) async throws {}
    func publish(id: String, view: CompanionWorkoutView) {}
    func cancelPreparation(id: String) {}
    func finalize(id: String, view: CompanionWorkoutView) {}
    func acknowledge(id: String, sampleIDs: [String]) {}
    func acknowledgeRejectedEnvelopes(_ ids: [String]) { rejectionACKs.append(ids) }
    func requestRejectedEnvelopes() { flushRequests += 1 }
}
