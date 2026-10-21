import FitnessCore
import Foundation
import Testing

@testable import FitnessRuntime

@MainActor
struct WatchSyncIntegrationTests {
    @Test func firstExportWaitsForReceiptChunksAfterSetupFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let companion = SyncTestCompanion()
        let raw = Data((0..<90_000).map { UInt8($0 % 251) })
        companion.snapshotEntry = WatchRejectedEnvelope(
            channel: "applicationContext", rawData: raw,
            reason: "decodeFailure", readinessBefore: .init(state: .prepared),
            readinessAfter: .init(state: .prepared))
        let coordinator = WorkoutCoordinator(directory: directory)
        coordinator.attachCompanion(companion)
        try coordinator.beginDeviceSetup()
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(
            artifact.fileURLs.first { $0.lastPathComponent == "watch-rejected-envelopes.json" })
        let document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let capture = try #require(document["capture"] as? [String: Any])
        let entries = try #require(document["entries"] as? [[String: Any]])
        #expect(capture["syncStatus"] as? String == "snapshotConfirmed")
        #expect(entries.count == 1)
        #expect(entries[0]["rawHex"] as? String == raw.map { String(format: "%02X", $0) }.joined())
        #expect(companion.rejectionACKs == [[companion.snapshotEntry!.id]])
    }

    @Test func lateAndForeignRejectionsPreserveValidWatchReadiness() {
        #expect(
            !WatchRejectionPolicy.failsReadiness(
                activeSessionID: "current", state: .prepared,
                messageSessionID: "old", messageAttemptID: "old-attempt",
                activeAttemptID: "current-attempt", reason: "stalePreparation"))
        #expect(
            !WatchRejectionPolicy.failsReadiness(
                activeSessionID: "current", state: .running,
                messageSessionID: "current", messageAttemptID: "current-attempt",
                activeAttemptID: "current-attempt", reason: "decodeFailure"))
        #expect(
            !WatchRejectionPolicy.failsReadiness(
                activeSessionID: "current", state: .preparing,
                messageSessionID: "old", messageAttemptID: "old-attempt",
                activeAttemptID: "current-attempt", reason: "invalidEnvelopeOrState"))
        #expect(
            WatchRejectionPolicy.failsReadiness(
                activeSessionID: "current", state: .preparing,
                messageSessionID: "current", messageAttemptID: "current-attempt",
                activeAttemptID: "current-attempt", reason: "invalidEnvelopeOrState"))
    }

    @Test func verifiedRunningPublishesCaptureWithoutLaterSaveRecord() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = WatchSyncTransport()
        let companion = SyncTestCompanion()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: WatchSyncBackground(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        let program = WorkoutProgram(
            name: "Watch start",
            intervals: [.init(durationSeconds: 60, targetSpeedKPH: 5, targetInclinationPercent: 0)])
        try await coordinator.start(program: program)
        try await coordinator.prepareWatch()
        try await coordinator.confirmAndStart()
        #expect(coordinator.snapshot?.state == .running)
        #expect(companion.publishedStates.contains(.running))
        #expect(companion.publishedViews.last?.snapshot.state == .running)
        let recordID = try #require(coordinator.currentRecord?.id)
        #expect(try coordinator.loadEvents(for: recordID).contains { $0.kind == "workout.running" })
    }

    @Test func audit082FixtureKeepsObservedDelaySeparateFromSoftwareRegression() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Audit082WatchSync", withExtension: "json"))
        let fixture = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try #require(fixture["sessions"] as? [[String: Any]])
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(rows.count == 2)
        for row in rows {
            let runningText = try #require(row["runningUTC"] as? String)
            let captureText = try #require(row["captureRequestedUTC"] as? String)
            let running = try #require(parser.date(from: runningText))
            let capture = try #require(parser.date(from: captureText))
            #expect(capture.timeIntervalSince(running) > 10)
            #expect(row["watchSamples"] as? Int == row["watchAcknowledgedSamples"] as? Int)
        }
        #expect(fixture["receiveUniqueFailures"] as? Int == 194)
        #expect(fixture["rejectedEnvelopeRecovered"] as? Bool == false)
    }

    @Test func replayedABatchWithNewMessageIDCommitsOnlyBAndAcknowledgesAfterStorage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkoutRepository(directory: directory)
        let record = try watchRecord(in: repository)
        let store = SessionStore(directory: directory)
        let companion = SyncTestCompanion()
        let receiver = CompanionWorkoutReceiver(
            repository: repository, store: store, directory: directory)
        let now = Date()
        let a = sample(id: "A", at: now)
        let b = sample(id: "B", at: now.addingTimeInterval(0.01))
        try await receiver.receive(
            .init(
                sessionID: record.id, sender: "watch", sequence: 1, payload: .samples([a]), id: "batch-a"),
            pendingID: nil, cancelledIDs: [], companion: companion)
        try await receiver.receive(
            .init(
                sessionID: record.id, sender: "watch", sequence: 2, payload: .samples([a, b]),
                id: "batch-a-b"),
            pendingID: nil, cancelledIDs: [], companion: companion)
        #expect(
            try repository.samples(for: record.id).map(\.id).sorted() == [
                "heartRateBPM:A", "heartRateBPM:B",
            ])
        #expect(companion.sampleACKs == [["A"], ["A", "B"]])
        #expect(
            try repository.events(for: record.id).filter { $0.kind == "watch.message.received" }.count
                == 2)

        let restarted = CompanionWorkoutReceiver(
            repository: try WorkoutRepository(directory: directory),
            store: store, directory: directory)
        try await restarted.receive(
            .init(
                sessionID: record.id, sender: "watch", sequence: 3, payload: .samples([a, b]),
                id: "batch-relaunch"),
            pendingID: nil, cancelledIDs: [], companion: companion)
        #expect(try repository.samples(for: record.id).count == 2)
        #expect(companion.sampleACKs.last == ["A", "B"])

        let changed = WatchHealthSample(
            id: "A", metric: "heartRateBPM", value: 177, unit: "count/min",
            sampledAt: now, periodStart: now, device: "Watch fixture", sourceIdentifier: "healthkit.test")
        await #expect(throws: WorkoutRepositoryError.self) {
            try await restarted.receive(
                .init(
                    sessionID: record.id, sender: "watch", sequence: 4,
                    payload: .samples([changed]), id: "batch-conflict"), pendingID: nil, cancelledIDs: [],
                companion: companion)
        }
        #expect(companion.sampleACKs.count == 3)
        #expect(try repository.samples(for: record.id).count == 2)

        let tooOldAt = record.startedAt.addingTimeInterval(-10)
        let tooOld = sample(id: "outside", at: tooOldAt)
        await #expect(throws: CompanionError.self) {
            try await restarted.receive(
                .init(
                    sessionID: record.id, sender: "watch", sequence: 5,
                    payload: .samples([b, tooOld]), id: "batch-outside"), pendingID: nil, cancelledIDs: [],
                companion: companion)
        }
        #expect(companion.sampleACKs.count == 3)
        #expect(try repository.samples(for: record.id).count == 2)
    }

    @Test func concurrentDifferentDeliveriesShareSQLiteIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkoutRepository(directory: directory)
        let record = try watchRecord(in: repository)
        let receiver = CompanionWorkoutReceiver(
            repository: repository, store: SessionStore(directory: directory), directory: directory)
        let companion = SyncTestCompanion()
        let a = sample(id: "concurrent-A", at: Date())
        let b = sample(id: "concurrent-B", at: Date())
        let first = CompanionMessage(
            sessionID: record.id, sender: "watch", sequence: 1, payload: .samples([a]), id: "concurrent-1"
        )
        let second = CompanionMessage(
            sessionID: record.id, sender: "watch", sequence: 2, payload: .samples([a, b]),
            id: "concurrent-2")
        let one = Task {
            try await receiver.receive(first, pendingID: nil, cancelledIDs: [], companion: companion)
        }
        let two = Task {
            try await receiver.receive(second, pendingID: nil, cancelledIDs: [], companion: companion)
        }
        _ = try await one.value
        _ = try await two.value
        #expect(
            try repository.samples(for: record.id).map(\.id).sorted() == [
                "heartRateBPM:concurrent-A", "heartRateBPM:concurrent-B",
            ])
        #expect(companion.sampleACKs.count == 2)
    }

    @Test func rejectionChunksRecoverAfterRelaunchWithExactLargeRawBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchDirectory = directory.appendingPathComponent("Watch")
        let phoneDirectory = directory.appendingPathComponent("Phone")
        let raw = Data((0..<90_000).map { UInt8($0 % 251) })
        let readiness = WatchReadiness(state: .prepared)
        let entry = WatchRejectedEnvelope(
            channel: "healthKitMirror", rawData: raw,
            reason: "decodeFailure", readinessBefore: readiness, readinessAfter: readiness)
        let watch = try WatchRejectedEnvelopeJournal(directory: watchDirectory)
        try watch.record(entry)
        let chunks = try WatchRejectedEnvelopeChunk.split(entry)
        #expect(chunks.count > 8)
        #expect(chunks.allSatisfy { $0.data.count <= 8_192 })
        var assembler = try WatchRejectedEnvelopeAssembler(directory: phoneDirectory)
        for chunk in chunks.prefix(4) { #expect(try await assembler.accept(chunk) == nil) }
        assembler = try WatchRejectedEnvelopeAssembler(directory: phoneDirectory)
        var receipt: String?
        for chunk in chunks.dropFirst(4).reversed() {
            receipt = try await assembler.accept(chunk) ?? receipt
        }
        #expect(receipt == entry.id)
        let saved = try WatchRejectedEnvelopeJournal(directory: phoneDirectory)
        #expect(saved.entries.count == 1)
        #expect(saved.entries.first?.rawData == raw)
        #expect(try await assembler.accept(chunks[0]) == entry.id)
        try watch.acknowledge([entry.id])
        #expect(watch.pending.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WatchSync-\(UUID().uuidString)")
    }
    private func watchRecord(in repository: WorkoutRepository) throws -> WorkoutRecord {
        let program = WorkoutProgram(
            name: "Watch replay", intervals: [.init(durationSeconds: 60, targetSpeedKPH: 1)])
        var record = WorkoutRecord(
            mode: "program", program: program,
            latestSnapshot: WorkoutEngine(program: program).snapshot())
        record.healthSave = HealthSaveResult(state: .pending)
        try repository.save(record)
        return record
    }
    private func sample(id: String, at date: Date) -> WatchHealthSample {
        WatchHealthSample(
            id: id, metric: "heartRateBPM", value: 121, unit: "count/min",
            sampledAt: date, periodStart: date, device: "Watch fixture",
            sourceIdentifier: "healthkit.test")
    }
}

@MainActor
private final class SyncTestCompanion: WorkoutCompanion {
    var useWatch = true
    var readiness = WatchReadiness(state: .prepared)
    var preparedSessionID: String?
    var onMessage: ((CompanionMessage) async throws -> Void)?
    var sampleACKs: [[String]] = []
    var rejectionACKs: [[String]] = []
    var snapshotEntry: WatchRejectedEnvelope?
    var rejectionSnapshotAvailable: Bool { snapshotEntry != nil }
    var publishedViews: [CompanionWorkoutView] = []
    var publishedStates: [WorkoutState] { publishedViews.map(\.snapshot.state) }
    func prepare(id: String, view: CompanionWorkoutView) async throws { preparedSessionID = id }
    func publish(id: String, view: CompanionWorkoutView) { publishedViews.append(view) }
    func cancelPreparation(id: String) {}
    func finalize(id: String, view: CompanionWorkoutView) {}
    func acknowledge(id: String, sampleIDs: [String]) { sampleACKs.append(sampleIDs) }
    func acknowledgeRejectedEnvelopes(_ ids: [String]) { rejectionACKs.append(ids) }
    func collectRejectedEnvelopeSnapshot() async -> WatchRejectedEnvelopeSnapshotReceipt? {
        guard let snapshotEntry, let chunks = try? WatchRejectedEnvelopeChunk.split(snapshotEntry)
        else { return nil }
        let receipt = WatchRejectedEnvelopeSnapshotReceipt(
            requestID: UUID().uuidString.lowercased(),
            entryIDs: [snapshotEntry.id])
        Task { [weak self] in
            guard let self else { return }
            for (index, chunk) in chunks.enumerated() {
                if index == chunks.count - 1 { try? await Task.sleep(for: .milliseconds(50)) }
                try? await self.onMessage?(
                    .init(
                        sessionID: "diagnostics", sender: "watch", sequence: UInt64(index + 1),
                        payload: .rejectedEnvelopeChunk(chunk)))
            }
        }
        return receipt
    }
}

@MainActor
private final class WatchSyncBackground: WorkoutBackgroundService {
    func begin(totalSeconds: Int, onExpiration: @escaping @MainActor () -> Void) async throws {}
    func update(completedSeconds: Int, totalSeconds: Int) {}
    func end(success: Bool) async {}
}

@MainActor
private final class WatchSyncTransport: WorkoutControlTransport {
    var phase: BluetoothPhase = .ready
    var selectedProtocol: DiagnosticProtocol = .ftms
    var control = FTMSControl()
    var snapshot: GATTDevice?
    private var sequence = 0

    init() {
        control.indicationReady = true
        control.permission = true
        control.stopAccepted = true
        let now = Date()
        let telemetry = FTMSTelemetry(
            serviceId: "ftms", characteristicId: "data", startedAt: now,
            subscriptionOperationId: "sync-fixture", subscriptionStatus: "subscribed",
            speed: FTMSMetric(value: 0, unit: "km/h", receivedAt: now, eventId: "initial-zero"),
            inclination: FTMSMetric(value: 0, unit: "%", receivedAt: now, eventId: "initial-flat"))
        let features = GATTCharacteristic(
            id: "feature", uuid: "2ACC", properties: ["read"], rawProperties: 2,
            ftmsFeatures: FTMSFeatures(machineBits: 0, targetBits: (1 << 0) | (1 << 1)))
        let speedRange = GATTCharacteristic(
            id: "speed-range", uuid: "2AD4", properties: ["read"], rawProperties: 2,
            ftmsRange: FTMSRange(minimum: 0.8, maximum: 16, increment: 0.1, unit: "km/h"))
        let inclineRange = GATTCharacteristic(
            id: "incline-range", uuid: "2AD5", properties: ["read"], rawProperties: 2,
            ftmsRange: FTMSRange(minimum: 0, maximum: 15, increment: 1, unit: "%"))
        let service = GATTService(
            id: "ftms", uuid: "1826", isPrimary: true,
            characteristicDiscovery: "complete", characteristics: [features, speedRange, inclineRange])
        snapshot = GATTDevice(
            localPeripheralIdentifier: UUID().uuidString, inspectionId: "watch-sync-synthetic",
            advertisedName: "Synthetic treadmill", advertisement: [:], selectedAt: now,
            source: .synthetic,
            connectedAt: now, connectionState: "connected", serviceDiscovery: "complete",
            discoveryStatus: "complete", services: [service], telemetry: telemetry)
    }
    func prepareControlAndWait(timeout: Duration) async throws { control.indicationReady = true }
    func executeAndWait(
        _ action: FTMSAction, speed: Double?, inclination: Double?,
        allowProgramBackground: Bool, timeout: Duration
    ) async throws -> FTMSProcedure {
        sequence += 1
        let requestedAt = Date()
        let result = FTMSProcedure(
            id: "sync-\(sequence)", action: action, requestedAt: requestedAt,
            valueHex: "", writeStatus: "complete", result: "accepted")
        control.last = result
        switch action {
        case .requestControl: control.permission = true
        case .stop:
            control.stopAccepted = true
            setSpeed(0)
        case .start: setSpeed(1)
        case .speed:
            if let speed {
                Task { @MainActor in
                    for _ in 0..<5 {
                        try? await Task.sleep(for: .milliseconds(75))
                        self.setSpeed(speed)
                    }
                }
            }
        case .inclination: break
        }
        return result
    }
    func setProgramBackgroundLease(_ enabled: Bool) {}
    private func setSpeed(_ speed: Double) {
        guard var device = snapshot, var telemetry = device.telemetry else { return }
        telemetry.speed = FTMSMetric(
            value: speed, unit: "km/h", receivedAt: Date(), eventId: "sync-speed-\(UUID().uuidString)")
        device.telemetry = telemetry
        snapshot = device
    }
}
