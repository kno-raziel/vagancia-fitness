import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

struct DistanceAndReceptionTests {
    let date = Date(timeIntervalSince1970: 1_000)

    @Test func resetsKeepObservedDistanceWithoutCountingTheInitialCounter() {
        var progress = FTMSDistanceProgress()
        for (i, value) in [100, 110, 130, 0, 0, 10, 0, 10].enumerated() {
            progress.observe(
                UInt32(value), inspectionId: "same", at: date.addingTimeInterval(Double(i)),
                eventId: "e\(i)")
        }
        #expect(progress.accumulatedMeters == 50)
        #expect(progress.zeroResetCount == 2)
        #expect(progress.lastCounterMeters == 10)
    }

    @Test func reconnectAndAmbiguousDecreaseDoNotInventDistance() {
        var p = FTMSDistanceProgress()
        for (i, value) in [0, 30, 10, 20].enumerated() {
            p.observe(
                UInt32(value), inspectionId: "first", at: date.addingTimeInterval(Double(i)),
                eventId: "e\(i)")
        }
        #expect(p.accumulatedMeters == 40 && p.discontinuityCount == 1)
        p.observe(200, inspectionId: "second", at: date.addingTimeInterval(4), eventId: "reconnect")
        p.observe(210, inspectionId: "second", at: date.addingTimeInterval(5), eventId: "after")
        #expect(p.accumulatedMeters == 50 && p.discontinuityCount == 2)
        #expect(p.zeroResetCount == 0)
        let before = p
        p.observe(500, inspectionId: "second", at: date.addingTimeInterval(6), eventId: "after")
        p.observe(500, inspectionId: "second", at: date, eventId: "old")
        #expect(p == before)
    }

    @Test func receptionSilenceIsPerChannelOnceAndResumesWithoutCommands() {
        var health = ReceptionHealth()
        health.subscribe("FTMS", at: date)
        health.subscribe("FFF0", at: date)
        let initial = health.received("FTMS", at: date.addingTimeInterval(4), eventId: "metric")
        #expect(!initial)
        let check1 = health.check(at: date.addingTimeInterval(6))
        #expect(check1 == ["FFF0"])
        let check2 = health.check(at: date.addingTimeInterval(10))
        #expect(check2 == ["FTMS"])
        let check3 = health.check(at: date.addingTimeInterval(11))
        #expect(check3.isEmpty)
        let resumed = health.received("FFF0", at: date.addingTimeInterval(12), eventId: "back")
        #expect(resumed)
        let check4 = health.check(at: date.addingTimeInterval(17))
        #expect(check4.isEmpty)
        let check5 = health.check(at: date.addingTimeInterval(18))
        #expect(check5 == ["FFF0"])
    }

    @Test func realCaptureReplaysResetAndRecognizesOnlyFFF0Messages() async throws {
        struct Fixture: Decodable {
            struct Event: Decodable {
                let kind: String
                let timestamp: Date
                let channel: String?
                let hex: String?
            }
            let source: String
            let events: [Event]
        }
        let url = try #require(
            Bundle.module.url(forResource: "yk-fitshow-interruption", withExtension: "json"))
        let fixture = try EvidenceJSON.decoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.source == "hardware")
        var progress = FTMSDistanceProgress()
        var count = 0
        var range: FitShowMessage?
        var lastFTMS: Date?
        var lastFFF0: Date?
        var statusQuery: Date?
        for (i, e) in fixture.events.enumerated() {
            if e.kind == "ftms.treadmill.received", let hex = e.hex {
                let sample = try FTMSDecoder.treadmill(try #require(Data(hex: hex)))
                if let counter = sample.distanceMeters {
                    progress.observe(
                        counter, inspectionId: "real-replay", at: e.timestamp, eventId: "real-\(i)")
                }
                lastFTMS = e.timestamp
            } else if e.kind == "fitshow.notification.received" {
                #expect(e.channel == "FFF0")
                let frame = try FitShowProtocol.decode(try #require(Data(hex: e.hex!)))
                #expect(frame.recognized)
                if frame.family == 0x50 { range = frame } else { #expect(frame.payload == [0x51, 0]) }
                count += 1
                lastFFF0 = e.timestamp
            } else if e.kind == "fitshow.query.requested", e.hex == "02515103", e.channel == "FFF0" {
                statusQuery = e.timestamp
            }
        }
        #expect(count == 64 && range?.payload == [0x50, 2, 160, 8])
        #expect(
            progress.accumulatedMeters == 30 && progress.lastCounterMeters == 0
                && progress.zeroResetCount == 1)
        #expect(try #require(lastFTMS) < #require(statusQuery))
        #expect(try #require(lastFFF0).timeIntervalSince(#require(statusQuery)) < 0.2)
        // The ordering is real evidence, not proof that the query caused silence.
    }

    @Test func resumedCallbackPreservesGapEvenWhenTimerWasSuspended() {
        var health = ReceptionHealth()
        health.subscribe("FTMS", at: date)
        let resumed = health.received("FTMS", at: date.addingTimeInterval(60), eventId: "wake")
        #expect(resumed)
        #expect(health.streams[0].lastGapFrom == date)
        #expect(health.streams[0].lastGapTo == date.addingTimeInterval(60))
        #expect(!health.streams[0].silent)
        let next = health.received("FTMS", at: date.addingTimeInterval(60.5), eventId: "next")
        #expect(!next)
    }

    @MainActor @Test func sessionDistancePersistsAndExportsBeyondTheUIWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir, maxEvents: 2)
        try store.startSession()
        for (i, counter) in [0, 10, 30, 0].enumerated() {
            try store.record(
                kind: "ftms.treadmill.received", source: .synthetic,
                payload: [
                    "inspectionId": .string("inspection-1"),
                    "sample": .object(["distanceMeters": .number(Double(counter))]),
                ], eventId: "packet-\(i)")
        }
        try await store.flush()
        #expect(store.session?.distanceProgress?.accumulatedMeters == 30)
        try store.record(
            kind: "ftms.treadmill.received", source: .hardware, payload: ["decodeError": .string("RFU")])
        try await store.flush()
        #expect(store.session?.distanceProgress?.lastCounterMeters == 0)
        try await store.flush()
        let recovered = SessionStore(directory: dir, maxEvents: 2)
        #expect(recovered.session?.distanceProgress?.accumulatedMeters == 30)
        try recovered.record(
            kind: "ftms.treadmill.received", source: .synthetic,
            payload: [
                "inspectionId": .string("inspection-2"), "sample": .object(["distanceMeters": .number(50)]),
            ])
        try await recovered.flush()
        #expect(recovered.session?.distanceProgress?.accumulatedMeters == 30)
        #expect(recovered.session?.distanceProgress?.discontinuityCount == 1)
        let artifact = try await recovered.exportAsync(
            metadata: .init(version: "test", build: "7", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "results.json" })
        let result = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: url))
        guard case .object(let progress) = result["distanceProgress"] else {
            Issue.record("Missing distance")
            return
        }
        #expect(progress["accumulatedMeters"] == .number(30))
        let events = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        #expect(try String(contentsOf: events, encoding: .utf8).contains("counterResetToZero"))
        try recovered.closeSession()
        try await recovered.flush()
        try recovered.startSession()
        #expect(recovered.session?.distanceProgress == nil)
    }
}
