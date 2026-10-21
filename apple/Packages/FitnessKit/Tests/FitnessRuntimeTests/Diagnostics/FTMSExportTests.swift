import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

@MainActor
struct FTMSExportTests {
    @Test func persistedTelemetryAndFeatureEvidenceRemainTraceableWithoutVerifyingControl()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, maxEvents: 3)
        try store.startSession()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var device = GATTDevice(
            localPeripheralIdentifier: "synthetic", inspectionId: "inspection", advertisedName: "Fixture",
            advertisement: [:], selectedAt: now)
        device.source = .synthetic
        device.services = [
            GATTService(
                id: "service", uuid: "1826", isPrimary: true, characteristicDiscovery: "complete",
                characteristics: [
                    GATTCharacteristic(
                        id: "feature", uuid: "2ACC", properties: ["read"], rawProperties: 2,
                        descriptorDiscovery: "complete", readStatus: "complete", valueHex: "0400000001000000",
                        valueEventId: "feature-evidence",
                        ftmsFeatures: FTMSFeatures(machineBits: 4, targetBits: 1))
                ])
        ]
        try store.record(
            kind: "ftms.value.read", source: .synthetic,
            payload: ["valueHex": .string("0400000001000000")], device: device,
            eventId: "feature-evidence")
        device.telemetry = FTMSTelemetry(
            serviceId: "service", characteristicId: "char", startedAt: now,
            subscriptionOperationId: "subscription")
        _ = try device.telemetry?.receive(
            Data([4, 0, 244, 1, 123, 0, 0]), at: now, eventId: "sample-evidence")
        try store.record(
            kind: "ftms.treadmill.received", source: .synthetic,
            payload: ["valueHex": .string("0400F4017B0000")], device: device, eventId: "sample-evidence")
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "4", osVersion: "test", deviceModel: "simulated"))
        let resultURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "results.json" })
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: resultURL))
        #expect(results["status"] == .string("notRun"))
        #expect(results["tests"] == .array([]))
        guard case .array(let capabilities) = results["capabilities"] else {
            Issue.record("Sin capacidades")
            return
        }
        #expect(capabilities.count == 34)
        let recovered = SessionStore(directory: directory)
        #expect(recovered.session?.device?.telemetry?.subscriptionStatus == "interrupted")
        #expect(recovered.session?.device?.telemetry?.distance?.value == 123)
        #expect(recovered.session?.device?.telemetry?.distance?.eventId == "sample-evidence")
        #expect(recovered.session?.events.contains { $0.eventId == "sample-evidence" } == true)
    }
}
