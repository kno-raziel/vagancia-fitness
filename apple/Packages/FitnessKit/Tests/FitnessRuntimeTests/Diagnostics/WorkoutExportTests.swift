import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

@MainActor
struct WorkoutExportTests {
    @Test func historyExportReadsItsOwnCaptureAndKeepsMockProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        let firstId = try #require(store.session?.sessionId)
        try store.addNote("Primera rutina")
        try store.closeSession()
        try await store.flush()
        try store.startSession()
        try store.addNote("Segunda rutina")
        let workout: JSONValue = .object([
            "id": .string("first-workout"),
            "metrics": .object(["heartRate": .object(["value": .number(125), "source": .string("mock")])]
            ),
        ])
        let artifact = try await store.exportAsync(
            sessionId: firstId,
            metadata: .init(version: "test", build: "9", osVersion: "26", deviceModel: "simulated"),
            workout: workout)
        #expect(artifact.fileURLs.count == 5)
        let resultURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "results.json" })
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: resultURL))
        #expect(results["sessionId"] == .string(firstId))
        #expect(results["workout"] == workout)
        let eventsURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let text = try String(contentsOf: eventsURL, encoding: .utf8)
        #expect(text.contains("Primera rutina"))
        #expect(!text.contains("Segunda rutina"))
        let manifestURL = try #require(
            artifact.fileURLs.first { $0.lastPathComponent == "manifest.json" })
        let manifest = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: manifestURL))
        #expect(manifest["schemaVersion"] == .string("1.0"))
        #expect(manifest["workoutLocation"] == .string("results.json#/workout"))
        #expect(results["status"] == .string("notRun"))
    }

    @Test func jsonExportRoundTripsAllMetricsAndUnknownValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let value: JSONValue = .object([
            "speed": .object(["value": .number(1.2), "source": .string("machineFTMS")]),
            "heartRate": .object(["value": .number(120), "source": .string("mock")]),
            "inclination": .null,
        ])
        let url = try WorkoutExporter.exportJSON(value, directory: directory)
        #expect(try EvidenceJSON.decoder().decode(JSONValue.self, from: Data(contentsOf: url)) == value)
    }

    @Test func deletingHistoryCapturePreservesOtherSessionsAndBlocksDeletingOpenCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        let firstId = try #require(store.session?.sessionId)
        #expect(throws: SessionError.self) { try store.deleteSession(id: firstId) }
        try store.closeSession()
        try await store.flush()
        try store.startSession()
        let secondId = try #require(store.session?.sessionId)
        try store.deleteSession(id: firstId)
        let metadata = AppMetadata(
            version: "test", build: "9", osVersion: "26", deviceModel: "simulated")
        #expect(throws: SessionError.self) { try store.export(sessionId: firstId, metadata: metadata) }
        #expect(
            try await store.exportAsync(sessionId: secondId, metadata: metadata).fileURLs.count == 5)
    }
}
