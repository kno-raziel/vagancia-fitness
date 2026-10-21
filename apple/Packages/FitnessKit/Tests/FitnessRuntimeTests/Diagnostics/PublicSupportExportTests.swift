import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

@MainActor
struct PublicSupportExportTests {
    @Test func publicSupportOmitsOriginalsAcrossFilesAndCompleteExportPreservesThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        let originalSessionID = try #require(store.session?.sessionId)
        try store.addNote("OPERATOR_NOTE_SENTINEL_7F9A")
        let gattDevice = GATTDevice(
            localPeripheralIdentifier: "PERIPHERAL_ID_SENTINEL",
            inspectionId: "INSPECTION_ID_SENTINEL", advertisedName: "DEVICE_NAME_SENTINEL",
            advertisement: [:], selectedAt: Date(),
            services: [
                GATTService(
                    id: "SERVICE_ID_SENTINEL", uuid: "1826", isPrimary: true,
                    characteristics: [
                        GATTCharacteristic(
                            id: "CHARACTERISTIC_ID_SENTINEL", uuid: "2AD4", properties: [], rawProperties: 0),
                        GATTCharacteristic(
                            id: "BAD_CHARACTERISTIC_ID", uuid: "CHARACTERISTIC_UUID_SENTINEL", properties: [],
                            rawProperties: 0),
                        GATTCharacteristic(
                            id: "PRIVATE_CHARACTERISTIC_ID", uuid: "A1B2C3D4-1234-5678-9ABC-DEF012345678",
                            properties: [], rawProperties: 0),
                        GATTCharacteristic(
                            id: "UNKNOWN_CHARACTERISTIC_ID", uuid: "BEEF", properties: [], rawProperties: 0),
                    ]),
                GATTService(id: "BAD_SERVICE_ID", uuid: "SERVICE_UUID_SENTINEL", isPrimary: true),
                GATTService(
                    id: "PRIVATE_SERVICE_ID", uuid: "A1B2C3D4-1234-5678-9ABC-DEF012345678", isPrimary: true),
                GATTService(id: "UNKNOWN_SERVICE_ID", uuid: "FEE7", isPrimary: true),
            ])
        try store.record(
            kind: "ble.device.discovered", payload: ["message": .string("EVENT_TEXT_SENTINEL")],
            device: gattDevice)
        try store.record(kind: "ble.connected", payload: [:])
        try store.record(kind: "PRIVATE_EVENT_KIND_SENTINEL", payload: [:])
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = Data("WATCH_SECRET_SENTINEL_83CA".utf8)
        let readiness = WatchReadiness(state: .prepared)
        let watch = WatchDiagnosticExportSnapshot(
            entries: [
                WatchRejectedEnvelope(
                    id: "WATCH_ID_SENTINEL_22AB", rejectedAt: base.addingTimeInterval(5),
                    channel: "WATCH_CHANNEL_SENTINEL", rawData: raw,
                    reason: "WATCH_REASON_SENTINEL", readinessBefore: readiness, readinessAfter: readiness,
                    errorDescription: "WATCH_ERROR_SENTINEL", currentSessionID: "OTHER_SESSION_SENTINEL")
            ],
            capturedAt: base.addingTimeInterval(6), syncStatus: .snapshotConfirmed,
            collectionRequestID: "WATCH_REQUEST_SENTINEL", watchSnapshotAt: base.addingTimeInterval(5))
        let workout: JSONValue = .object([
            "record": .object([
                "id": .string("WORKOUT_ID_SENTINEL"),
                "healthSave": .string("HEALTH_SENTINEL"),
            ]), "notes": .string("WORKOUT_NOTE_SENTINEL"),
        ])
        let metadata = AppMetadata(
            version: "APP_VERSION_SENTINEL", build: "APP_BUILD_SENTINEL", osVersion: "OS_SENTINEL",
            deviceModel: "DEVICE_SENTINEL")

        let complete = try await store.exportAsync(
            sessionId: originalSessionID, metadata: metadata, workout: workout,
            watchDiagnostics: watch)
        let completeBytes = try allExportBytes(complete)
        #expect(completeBytes.contains("OPERATOR_NOTE_SENTINEL_7F9A"))
        #expect(completeBytes.contains("WORKOUT_ID_SENTINEL"))
        #expect(completeBytes.contains("WATCH_REASON_SENTINEL"))
        #expect(completeBytes.contains(raw.base64EncodedString()))
        #expect(completeBytes.contains(raw.map { String(format: "%02X", $0) }.joined()))

        let publicExport = try await store.exportAsync(
            sessionId: originalSessionID, metadata: metadata, workout: workout,
            watchDiagnostics: watch, profile: .publicSupport)
        let publicBytes = try allExportBytes(publicExport)
        for sentinel in [
            "OPERATOR_NOTE_SENTINEL_7F9A", "WORKOUT_ID_SENTINEL", "HEALTH_SENTINEL",
            "WATCH_SECRET_SENTINEL_83CA", "WATCH_REASON_SENTINEL", "WATCH_ERROR_SENTINEL",
            "WATCH_CHANNEL_SENTINEL", "OTHER_SESSION_SENTINEL", "WATCH_ID_SENTINEL_22AB",
            "WATCH_REQUEST_SENTINEL", "OS_SENTINEL", "DEVICE_SENTINEL",
            "APP_VERSION_SENTINEL", "APP_BUILD_SENTINEL", "PERIPHERAL_ID_SENTINEL",
            "INSPECTION_ID_SENTINEL", "DEVICE_NAME_SENTINEL", "SERVICE_UUID_SENTINEL",
            "CHARACTERISTIC_UUID_SENTINEL", "EVENT_TEXT_SENTINEL", "PRIVATE_EVENT_KIND_SENTINEL",
            "A1B2C3D4-1234-5678-9ABC-DEF012345678",
            raw.base64EncodedString(), raw.map { String(format: "%02X", $0) }.joined(),
        ] {
            #expect(!publicBytes.contains(sentinel))
        }
        #expect(!publicBytes.contains(originalSessionID))
        #expect(!publicExport.archiveURL.lastPathComponent.contains(originalSessionID))
        #expect(publicBytes.contains("watchReceivedEntryCount"))
        #expect(publicBytes.contains("omitted"))
        #expect(store.session?.sessionId == originalSessionID)
        #expect(
            store.session?.events.contains(where: {
                $0.payload["note"]?.text == "OPERATOR_NOTE_SENTINEL_7F9A"
            }) == true)

        let eventURL = try #require(
            publicExport.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let eventText = try String(contentsOf: eventURL, encoding: .utf8)
        let publicEvents = try eventText.split(separator: "\n").map {
            try EvidenceJSON.decoder().decode([String: JSONValue].self, from: Data($0.utf8))
        }
        #expect(publicEvents.contains { $0["kind"] == .string("ble.connected") })
        #expect(publicEvents.contains { $0["kind"] == .string("other") })
        let first = try #require(eventText.split(separator: "\n").first)
        let event = try EvidenceJSON.decoder().decode([String: JSONValue].self, from: Data(first.utf8))
        #expect(event["eventId"] == .string("event-1"))
        #expect(event["elapsedSeconds"] == .number(0))
        #expect(event["payload"] == .object([:]))
        let second = try #require(eventText.split(separator: "\n").dropFirst().first)
        let secondEvent = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(second.utf8))
        #expect(secondEvent["eventId"] == .string("event-2"))
        if case .number(let firstTime) = event["elapsedSeconds"],
            case .number(let secondTime) = secondEvent["elapsedSeconds"]
        {
            #expect(secondTime >= firstTime)
        } else {
            Issue.record("Expected relative event times")
        }
        let manifestURL = try #require(
            publicExport.fileURLs.first { $0.lastPathComponent == "manifest.json" })
        let manifest = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: manifestURL))
        #expect(manifest["sessionId"] == .string("session-1"))
        #expect(manifest["profile"] == .string("publicSupport"))
        let resultsURL = try #require(
            publicExport.fileURLs.first { $0.lastPathComponent == "results.json" })
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: resultsURL))
        #expect(results["workoutIncluded"] == .bool(false))
        #expect(results["workoutPresentBeforeOmission"] == .bool(true))
        let deviceURL = try #require(
            publicExport.fileURLs.first { $0.lastPathComponent == "device.json" })
        let device = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: deviceURL))
        guard case .array(let services) = device["services"], case .object(let service) = services.first
        else {
            Issue.record("Missing safe GATT service projection")
            return
        }
        #expect(service["uuid"] == .string("1826"))
        guard case .array(let characteristicUUIDs) = service["characteristicUUIDs"] else {
            Issue.record("Missing safe characteristic UUID projection")
            return
        }
        #expect(characteristicUUIDs == [.string("2ad4")])
        guard case .object(let omissions) = manifest["omissions"] else {
            Issue.record("Missing omissions metadata")
            return
        }
        #expect(omissions["invalidAppMetadata"] == .number(2))
        #expect(omissions["unrecognizedServiceUUIDs"] == .number(3))
        #expect(omissions["unrecognizedCharacteristicUUIDs"] == .number(3))
        guard case .object(let capture) = manifest["watchDiagnostics"] else {
            Issue.record("Missing Watch omissions metadata")
            return
        }
        #expect(capture["receivedEntryCount"] == .number(1))
        #expect(capture["allWatchRejectionsReceived"] == .bool(true))
    }

    private func allExportBytes(_ export: DiagnosticExport) throws -> String {
        let fileText = try export.fileURLs.map {
            String(decoding: try Data(contentsOf: $0), as: UTF8.self)
        }.joined(separator: "\n")
        let zip = String(decoding: try Data(contentsOf: export.archiveURL), as: UTF8.self)
        return fileText + zip
    }
}
