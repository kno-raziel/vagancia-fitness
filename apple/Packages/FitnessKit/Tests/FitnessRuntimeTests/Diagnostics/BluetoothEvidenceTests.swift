import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

@MainActor
struct BluetoothEvidenceTests {
    private func device() -> GATTDevice {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var device = GATTDevice(
            localPeripheralIdentifier: "synthetic-peripheral", inspectionId: "synthetic-inspection",
            advertisedName: "Fixture sintética", advertisement: [:], selectedAt: observedAt)
        device.source = .synthetic
        device.connectedAt = observedAt
        device.connectionState = "connected"
        device.serviceDiscovery = "complete"
        device.discoveryStatus = "complete"
        // Duplicate UUIDs are separate GATT instances and must survive export.
        device.services = [
            GATTService(
                id: "service-1", uuid: "1826", isPrimary: true, characteristicDiscovery: "complete",
                characteristics: [
                    GATTCharacteristic(
                        id: "char-1", uuid: "2ACD", properties: ["notify"], rawProperties: 16,
                        descriptorDiscovery: "complete"),
                    GATTCharacteristic(
                        id: "char-2", uuid: "2ACD", properties: ["read"], rawProperties: 2,
                        descriptorDiscovery: "complete"),
                ]),
            GATTService(
                id: "service-2", uuid: "180A", isPrimary: true, characteristicDiscovery: "complete",
                characteristics: [
                    GATTCharacteristic(
                        id: "identity", uuid: "2A29", properties: ["read"], rawProperties: 2,
                        descriptorDiscovery: "complete", readStatus: "complete", valueHex: "4142",
                        textValue: "AB")
                ]),
        ]
        return device
    }

    @Test func inventoryKeepsDistinctInstancesAndOnlyStandardIdentity() async throws {
        let fixture = device()
        let decoded = try EvidenceJSON.decoder().decode(
            GATTDevice.self, from: EvidenceJSON.encoder().encode(fixture))
        #expect(decoded == fixture)
        #expect(decoded.containsFTMS)
        #expect(decoded.characteristicCount == 3)
        #expect(decoded.services[0].characteristics.map(\.id) == ["char-1", "char-2"])
        #expect(decoded.manufacturer == "AB")
        #expect(decoded.firmware == nil)
        #expect(!GATTDevice.identityUUIDs.contains("2AD9"))
    }

    @Test func interruptionPreservesCompletedDataAndMarksPendingOperations() {
        var fixture = device()
        fixture.discoveryStatus = "pending"
        fixture.services[0].characteristics[1].descriptorDiscovery = "pending"
        fixture.services[0].characteristics[1].readStatus = "pending"
        fixture.endPendingDiscovery(as: "timedOut")
        #expect(fixture.discoveryStatus == "timedOut")
        #expect(fixture.services[0].characteristics[1].descriptorDiscovery == "timedOut")
        #expect(fixture.services[0].characteristics[1].readStatus == "timedOut")
        #expect(fixture.manufacturer == "AB")
        #expect(fixture.serviceDiscovery == "complete")
    }

    @Test func oldSessionWithoutDeviceRemainsReadable() async throws {
        let old = DiagnosticSession(
            sessionId: "old", startedAt: Date(), events: [], totalEventCount: 0, droppedEventCount: 0,
            gaps: [])
        let data = try EvidenceJSON.encoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("device"))
        let decoded = try EvidenceJSON.decoder().decode(DiagnosticSession.self, from: data)
        #expect(decoded.device == nil)
    }

    @Test func boundedEventsDoNotEraseThatBluetoothWasAttempted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, maxEvents: 2)
        try store.startSession()
        try store.record(kind: "ble.scan.started", payload: [:])
        try store.addNote("Una nota")
        try store.addNote("Otra nota")
        #expect(store.session?.events.allSatisfy { $0.kind == "operator.note" } == true)
        #expect(store.session?.bleObserved == true)
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "2", osVersion: "test", deviceModel: "simulated"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "manifest.json" })
        let manifest = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: url))
        #expect(manifest["captureMode"] == .string("bluetoothScan"))
    }

    @Test func restorationDoesNotClaimAContinuingBluetoothConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        var fixture = device()
        fixture.discoveryStatus = "pending"
        try store.record(kind: "synthetic.fixture", source: .synthetic, payload: [:], device: fixture)
        try await store.flush()
        let recovered = SessionStore(directory: directory)
        #expect(recovered.session?.device?.connectionState == "notConnectedAfterRestore")
        #expect(recovered.session?.device?.discoveryStatus == "interrupted")
        #expect(recovered.session?.device?.connectedAt == fixture.connectedAt)
        #expect(recovered.session?.gaps.count == 1)
    }

    @Test func exportedInventoryDoesNotPromotePresenceToVerifiedControls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        try store.record(
            kind: "synthetic.fixture", source: .synthetic, payload: ["valueHex": .string("4142")],
            device: device())
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "2", osVersion: "test", deviceModel: "simulated"))
        func file(_ name: String) throws -> [String: JSONValue] {
            let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == name })
            return try EvidenceJSON.decoder().decode(
                [String: JSONValue].self, from: Data(contentsOf: url))
        }
        #expect(try file("manifest.json")["captureMode"] == .string("bluetoothDiscovery"))
        #expect(try file("results.json")["status"] == .string("notRun"))
        #expect(try file("results.json")["capabilities"] == .array([]))
        guard case .array(let services) = try file("device.json")["services"] else {
            Issue.record("Falta inventario")
            return
        }
        #expect(services.count == 2)
        #expect(try file("device.json")["localPeripheralIdentifier"] == .string("synthetic-peripheral"))
        #expect(try file("device.json")["source"] == .string("synthetic"))
    }
}
