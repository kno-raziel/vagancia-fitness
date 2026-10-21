import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

struct InteractiveEvidenceTests {
    @MainActor @Test func allIndeterminateTerminalsRemainCorrelatedAfterLaterProcedures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // The store keeps SQLite handles open through the test's lifetime.
        // Leave this unique directory in temporary storage until xctest exits.
        let store = SessionStore(directory: directory, maxEvents: 2)
        try store.startSession()
        var expected: [String: String] = [:]
        for reason in ["write", "malformed", "permission", "disconnect"] {
            let now = Date()
            var control = FTMSControl()
            control.indicationReady = true
            control.permission = true
            let stopTime = now.addingTimeInterval(-0.2)
            _ = try control.begin(.stop, authorized: true, at: stopTime)
            _ = try control.response(Data([0x80, 8, 1]), eventId: "stop-\(reason)")
            let zero = FTMSMetric(
                value: 0, unit: "km/h", receivedAt: now.addingTimeInterval(-0.1), eventId: "zero-\(reason)")
            control.observed(zero, at: now)
            let procedure = try control.begin(
                .start, authorized: true,
                observedSpeed: zero, at: now)
            try store.record(
                kind: "ftms.control.requested", source: .synthetic,
                payload: [
                    "procedureId": .string(procedure.id), "action": .string("start"),
                    "valueHex": .string("07"),
                ])
            switch reason {
            case "write": control.written(error: "synthetic failure")
            case "malformed":
                #expect(throws: ControlError.self) {
                    try control.response(Data([0x80, 7]), eventId: "malformed")
                }
            case "permission": control.permissionLost()
            default: control.disconnected()
            }
            let last = try #require(control.last)
            #expect(last.result == "indeterminate")
            let terminal = try #require(last.terminalEvidence)
            let terminalId = "terminal-\(reason)"
            expected[procedure.id] = terminalId
            // No flat procedureId: this reproduces the original missing
            // correlation paths and checks the shared terminal envelope.
            try store.record(
                kind: reason == "disconnect" ? "ble.disconnected" : "ftms.control.failure",
                source: .synthetic,
                payload: ["procedureTerminal": .object(terminal)], eventId: terminalId)
        }
        try store.addNote("Otra observación después de todos los fallos")
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "6", osVersion: "test", deviceModel: "simulated"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "results.json" })
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let tests) = results["tests"] else {
            Issue.record("Sin pruebas")
            return
        }
        #expect(tests.count == 4)
        for value in tests {
            guard case .object(let procedure) = value, let id = procedure["procedureId"]?.text else {
                Issue.record("Sin ID")
                continue
            }
            #expect(procedure["protocolResult"] == .string("indeterminate"))
            #expect(procedure["terminalEventId"] == expected[id].map(JSONValue.string))
            #expect(procedure["physicalVerification"] == .string("notRun"))
        }
    }
    @MainActor @Test func procedureExportCorrelatesResponseWithoutClaimingPhysicalSuccess()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        try store.record(
            kind: "ftms.control.requested", source: .synthetic,
            payload: [
                "procedureId": .string("synthetic-command"), "action": .string("start"),
                "valueHex": .string("07"),
            ], eventId: "request")
        try store.record(
            kind: "ftms.control.response", source: .synthetic,
            payload: ["procedureId": .string("synthetic-command"), "valueHex": .string("800701")],
            eventId: "response")
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "6", osVersion: "test", deviceModel: "simulated"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "results.json" })
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let tests) = results["tests"], case .object(let procedure) = tests.first
        else {
            Issue.record("Sin procedimiento")
            return
        }
        #expect(procedure["protocolResult"] == .string("accepted"))
        #expect(procedure["responseEventId"] == .string("response"))
        #expect(procedure["physicalVerification"] == .string("notRun"))
        #expect(results["status"] == .string("notRun"))
    }
    @Test func replaysRealMotionCaptureWithoutBluetoothAndKeepsDistanceGranularity() async throws {
        struct Fixture: Decodable {
            struct Packet: Decodable {
                let hex: String
                let speed: Double
                let distance: UInt32
            }
            let source: String
            let packets: [Packet]
            let uninterpretedHex: String
        }
        let url = try #require(
            Bundle.module.url(forResource: "yk-motion-replay", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.source == "hardware")
        var telemetry = FTMSTelemetry(
            serviceId: "replay-s", characteristicId: "replay-c", startedAt: Date(),
            subscriptionOperationId: "replay")
        for (index, packet) in fixture.packets.enumerated() {
            let sample = try telemetry.receive(
                try #require(Data(hex: packet.hex)), at: Date(), eventId: "replay-\(index)")
            #expect(sample.speedKilometersPerHour == packet.speed)
            #expect(sample.distanceMeters == packet.distance)
        }
        #expect(telemetry.speed?.value == 2 && telemetry.distance?.value == 50)
        let before = telemetry.distance
        #expect(throws: FTMSDecodeError.self) {
            try telemetry.receive(
                try #require(Data(hex: fixture.uninterpretedHex)), at: Date(), eventId: "rfu")
        }
        #expect(telemetry.distance == before)
        #expect(Set(fixture.packets.map(\.distance)) == Set([0, 10, 20, 30, 40, 50]))
    }

    @MainActor @Test func comparativeExportKeepsRawFitShowAndFTMSSeparateAndRestoresWithoutAuthority()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, maxEvents: 2)
        try store.startSession()
        var device = GATTDevice(
            localPeripheralIdentifier: "synthetic", inspectionId: "synthetic-inspection",
            advertisedName: "Fixture", advertisement: [:], selectedAt: Date())
        device.source = .synthetic
        device.interactive = InteractiveEvidence()
        device.interactive?.control.indicationReady = true
        device.interactive?.control.permission = true
        device.interactive?.control.stopAccepted = true
        var channel = FitShowObservation(
            channel: .fitShowFFF0, serviceId: "s", writeCharacteristicId: "tx",
            notifyCharacteristicId: "rx")
        let raw = FitShowProtocol.frame([0x51, 3, 20, 0, 60, 0, 5, 0, 0, 0, 0, 0, 80])
        channel.observe(
            try FitShowProtocol.decode(raw), eventId: "fitshow-evidence", matchedRangeQuery: false)
        device.interactive?.fitShow = [channel]
        try store.record(
            kind: "fitshow.notification.received", source: .synthetic,
            payload: ["protocol": .string("FitShow · FFF0"), "valueHex": .string(raw.hex)],
            device: device, eventId: "fitshow-evidence")
        try store.addNote("Nota posterior 1")
        try store.addNote("Nota posterior 2")
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "6", osVersion: "test", deviceModel: "simulated"))
        let resultsURL = try #require(
            artifact.fileURLs.first { $0.lastPathComponent == "results.json" })
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: resultsURL))
        guard case .object(let comparison) = results["comparison"] else {
            Issue.record("Sin comparación")
            return
        }
        #expect(comparison["fitShowControlEnabled"] == .bool(false))
        #expect(comparison["unitEquivalence"] == .string("unconfirmed"))
        #expect(comparison["ftmsDistance"] == .null)
        let eventsURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        #expect(try String(contentsOf: eventsURL, encoding: .utf8).contains("fitshow-evidence"))
        let recovered = SessionStore(directory: directory)
        #expect(recovered.session?.device?.interactive?.control.permission == false)
        #expect(recovered.session?.device?.interactive?.control.stopAccepted == false)
        #expect(recovered.session?.device?.interactive?.fitShow[0].subscriptionStatus == "interrupted")
        #expect(recovered.session?.device?.interactive?.fitShow[0].distanceCounterRaw == 5)
    }
}
