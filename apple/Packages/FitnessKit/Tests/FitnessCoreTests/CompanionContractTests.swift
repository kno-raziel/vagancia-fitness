import Foundation
import Testing

@testable import FitnessCore

struct CompanionContractTests {
    private func view() -> CompanionWorkoutView {
        let engine = WorkoutEngine(program: WorkoutProgram.seedPrograms[0])
        return CompanionWorkoutView(
            snapshot: engine.snapshot(), metrics: [:], startedAt: nil, endedAt: nil)
    }
    @Test func legacySampleWithoutHealthFieldsDecodes() throws {
        let json = "{\"value\":3,\"source\":\"machineFTMS\",\"receivedAt\":0}"
        let sample = try JSONDecoder().decode(WorkoutSample.self, from: Data(json.utf8))
        #expect(sample.source == .machineFTMS)
        #expect(sample.sampledAt == nil)
        #expect(sample.sourceDevice == nil)
    }
    @Test func messageRoundTripKeepsOriginalDatesAndRejectsVersions() throws {
        let date = Date(timeIntervalSince1970: 123)
        let sample = WatchHealthSample(
            metric: "heartRateBPM", value: 124, unit: "count/min", sampledAt: date, periodStart: date,
            device: "Ultra 2", sourceIdentifier: "test")
        let message = CompanionMessage(
            sessionID: "session", sender: "watch", sequence: 7, payload: .samples([sample]))
        #expect(try CompanionMessage.decode(message.encoded()) == message)
        var future = message
        future.version = 99
        #expect(throws: CompanionError.self) { try CompanionMessage.decode(future.encoded()) }
        #expect(sample.isValid)
    }
    @Test func stateOrderingNeverReopensTerminalOrCrossesSession() {
        var gate = CompanionViewGate()
        gate.begin("one")
        func message(_ sequence: UInt64, id: String = "one") -> CompanionMessage {
            .init(sessionID: id, sender: "iphone", sequence: sequence, payload: .statusRequest)
        }
        #expect(gate.accept(message(3)) == true)
        #expect(gate.accept(message(2)) == false)
        #expect(gate.accept(message(4, id: "two")) == false)
        #expect(gate.accept(message(5), final: true) == true)
        #expect(gate.accept(message(6)) == false)
    }
    @Test func distanceIncrementIsNonnegativeAndNotRepeated() {
        var accumulator = HealthDistanceAccumulator()
        func sample(_ value: Double, id: String, t: TimeInterval, source: MetricSource = .derived)
            -> WorkoutSample
        {
            .init(value: value, source: source, receivedAt: Date(timeIntervalSince1970: t), eventId: id)
        }
        #expect(accumulator.increment(for: sample(10, id: "a", t: 1)) == 10)
        #expect(accumulator.increment(for: sample(10, id: "a", t: 1)) == nil)
        #expect(accumulator.increment(for: sample(20, id: "b", t: 2)) == 10)
        #expect(accumulator.increment(for: sample(0, id: "reset", t: 3)) == nil)
        #expect(accumulator.increment(for: sample(30, id: "c", t: 4)) == 10)
        #expect(accumulator.increment(for: sample(40, id: "old", t: 2)) == nil)
        #expect(accumulator.increment(for: sample(40, id: "mock", t: 5, source: .mock)) == nil)
        #expect(accumulator.totalMeters == 30)
        accumulator.reconcileStoredTotal(40)
        #expect(accumulator.increment(for: sample(40, id: "recovered", t: 6)) == 0)
        #expect(accumulator.increment(for: sample(50, id: "after-recovery", t: 7)) == 10)
    }
    @Test func ledgerSurvivesRestartAndAcknowledgesOnlyPersistedSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try WatchSessionLedger(directory: directory)
        var record = WatchSessionRecord(id: "session", view: view())
        let sample = WatchHealthSample(
            id: "pulse", metric: "heartRateBPM", value: 120, unit: "count/min", sampledAt: .now,
            periodStart: .now.addingTimeInterval(-1), device: "Watch", sourceIdentifier: "source")
        #expect(record.add(sample) == true)
        #expect(record.add(sample) == false)
        try journal.save(record)
        let restored = try WatchSessionLedger(directory: directory)
        #expect(restored.sessions["session"]?.pendingSamples == [sample])
        record.acknowledge(["unknown"])
        #expect(record.pendingSamples == [sample])
        record.acknowledge([sample.id])
        try journal.save(record)
        #expect(
            try WatchSessionLedger(directory: directory).sessions["session"]?.pendingSamples.isEmpty
                == true)
    }
    @Test func uncertainHealthWriteIsNeverRepeatedAfterRecovery() {
        var record = WatchSessionRecord(id: "session", view: view())
        record.health = HealthSaveResult(state: .pending)
        #expect(record.beginHealthSave() == true)
        #expect(record.beginHealthSave() == false)
        record.markRecovered()
        #expect(record.health.state == .uncertain)
        #expect(record.beginHealthSave() == false)
    }
    @Test func repeatedFreshViewsRecoverDroppedCaptureRequestWithoutRestarting() throws {
        var engine = WorkoutEngine(program: WorkoutProgram.seedPrograms[0])
        engine.start()
        engine.updateEffectiveTargets(speedKPH: 3, inclinationPercent: 0)
        engine.markRunning()
        let now = Date()
        let request = WatchCaptureRequest(requestedAt: now.addingTimeInterval(-60))
        var delivery = CompanionWorkoutView(
            snapshot: engine.snapshot(), metrics: [:], startedAt: now.addingTimeInterval(-60),
            endedAt: nil, generatedAt: now)
        delivery.captureRequest = request
        // First delivery is lost. A later fresh view carries the same permission.
        let message = CompanionMessage(
            sessionID: "session", sender: "iphone", sequence: 2, payload: .view(delivery))
        let decoded = try CompanionMessage.decode(message.encoded())
        guard case .view(let recovered) = decoded.payload else {
            Issue.record("Missing view")
            return
        }
        var record = WatchSessionRecord(id: "session", view: view())
        record.captureState = .prepared
        #expect(record.viewGate.accept(decoded) == true)
        #expect(record.canBeginCapture(from: recovered, now: now))
        // Actual capture time is now, not the original request time.
        record.captureRequestID = request.id
        record.captureStartedAt = now
        record.captureState = .running
        let ack = WatchReadiness(state: .running, captureRequestID: request.id, captureStartedAt: now)
        #expect(try JSONDecoder().decode(WatchReadiness.self, from: JSONEncoder().encode(ack)) == ack)
        #expect(!record.canBeginCapture(from: recovered, now: now))  // lost ACK cannot double-start
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try WatchSessionLedger(directory: directory)
        try ledger.save(record)
        let restored = try WatchSessionLedger(directory: directory).sessions["session"]!
        #expect(restored.captureRequestID == request.id)
        #expect(!restored.canBeginCapture(from: recovered, now: now))
    }
    @Test func captureRecoveryRejectsStaleSyntheticUnrequestedAndTerminalViews() {
        var engine = WorkoutEngine(program: WorkoutProgram.seedPrograms[0])
        engine.start()
        engine.updateEffectiveTargets(speedKPH: 3, inclinationPercent: 0)
        engine.markRunning()
        let now = Date()
        func delivery(age: TimeInterval = 0, synthetic: Bool = false, ended: Bool = false)
            -> CompanionWorkoutView
        {
            var result = CompanionWorkoutView(
                snapshot: engine.snapshot(), metrics: [:], startedAt: now, endedAt: ended ? now : nil,
                generatedAt: now.addingTimeInterval(-age), synthetic: synthetic)
            result.captureRequest = WatchCaptureRequest(requestedAt: now)
            return result
        }
        var record = WatchSessionRecord(id: "session", view: view())
        record.captureState = .prepared
        #expect(!record.canBeginCapture(from: delivery(age: 20), now: now))
        #expect(!record.canBeginCapture(from: delivery(synthetic: true), now: now))
        #expect(!record.canBeginCapture(from: delivery(ended: true), now: now))
        var absent = delivery()
        absent.captureRequest = nil
        #expect(!record.canBeginCapture(from: absent, now: now))
        #expect(record.canBeginCapture(from: delivery(), now: now))
        let final = CompanionMessage(
            sessionID: "session", sender: "iphone", sequence: 10, payload: .finish(delivery(ended: true)))
        #expect(record.viewGate.accept(final, final: true) == true)
        #expect(!record.canBeginCapture(from: delivery(), now: now))
    }
    @Test func invalidSamplesAndCorruptJournalsAreNotSilentlyAccepted() throws {
        let invalid = WatchHealthSample(
            metric: "heartRateBPM", value: 0, unit: "count/min", sampledAt: .now,
            periodStart: .now.addingTimeInterval(-1), device: "Watch", sourceIdentifier: "test")
        #expect(!invalid.isValid)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try WatchSessionLedger(directory: directory)
        try Data("corrupt".utf8).write(to: journal.url)
        #expect(throws: (any Error).self) { try WatchSessionLedger(directory: directory) }
    }
    @Test func backgroundPreparationDoesNotDependOnLiveWatchConnectivity() {
        let backgroundWatch = CompanionDeliveryPlan(
            durable: true, contextFallback: true,
            channelActivated: true, wcReachable: false, mirrorConnected: false)
        #expect(backgroundWatch.queueBackground)
        #expect(backgroundWatch.updateContext)
        #expect(backgroundWatch.livePath == .none)
        let mirroredWorkout = CompanionDeliveryPlan(
            durable: false, contextFallback: true,
            channelActivated: true, wcReachable: false, mirrorConnected: true)
        #expect(mirroredWorkout.livePath == .mirror)
        #expect(mirroredWorkout.updateContext)
    }
    @Test func lateCancelledReadinessCannotReplaceCurrentSessionOrConfirmCapture() {
        var gate = CompanionReadinessGate()
        gate.begin("old")
        gate.cancel("old")
        gate.begin("new")
        let late = WatchReadiness(state: .prepared, updatedAt: Date().addingTimeInterval(60))
        let lateResult = gate.receive(late, sessionID: "old")
        #expect(lateResult == .staleCancelled)
        #expect(gate.preparedID == nil)
        #expect(gate.latest.state == .preparing)
        let preparedResult = gate.receive(WatchReadiness(state: .prepared), sessionID: "new")
        #expect(preparedResult == .prepared)
        gate.requestCapture("request-new", for: "new")
        let wrong = WatchReadiness(
            state: .running, updatedAt: Date().addingTimeInterval(1),
            captureRequestID: "request-old", captureStartedAt: Date())
        let wrongResult = gate.receive(wrong, sessionID: "new")
        #expect(wrongResult == .accepted)
        #expect(gate.confirmedCaptureID == nil)
        let confirmed = WatchReadiness(
            state: .running, updatedAt: Date().addingTimeInterval(2),
            captureRequestID: "request-new", captureStartedAt: Date())
        let confirmedResult = gate.receive(confirmed, sessionID: "new")
        #expect(confirmedResult == .captureConfirmed)
        #expect(gate.confirmedCaptureID == "new")
    }
    @Test func oldMirrorInstanceCannotChangeCurrentMirror() {
        let first = NSObject()
        let second = NSObject()
        var identity = CompanionMirrorIdentity()
        identity.replace(with: first)
        identity.replace(with: second)
        #expect(!identity.isCurrent(first))
        #expect(identity.isCurrent(second))
    }
    @Test func recoveredCaptureIntentNeedsEvidenceFromHealthKitBuilder() throws {
        var engine = WorkoutEngine(program: WorkoutProgram.seedPrograms[0])
        engine.start()
        engine.updateEffectiveTargets(speedKPH: 3, inclinationPercent: 0)
        engine.markRunning()
        let active = CompanionWorkoutView(
            snapshot: engine.snapshot(), metrics: [:], startedAt: Date(), endedAt: nil)
        var record = WatchSessionRecord(id: "intent-only", view: active)
        record.captureState = .prepared
        let beganIntent = record.beginCaptureIntent(requestID: "stable", at: Date())
        #expect(beganIntent)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try WatchSessionLedger(directory: directory)
        try ledger.save(record)
        var restored = try #require(WatchSessionLedger(directory: directory).sessions["intent-only"])
        let missingBuilder = restored.reconcileRecoveredCollection(
            builderStartAt: nil, workoutActive: true, builderEnded: false)
        #expect(!missingBuilder)
        #expect(restored.captureStartedAt == nil)
        #expect(restored.captureState == .recovering)
        let inactiveWorkout = restored.reconcileRecoveredCollection(
            builderStartAt: Date(), workoutActive: false, builderEnded: false)
        #expect(!inactiveWorkout)
        let actualStart = Date().addingTimeInterval(-2)
        let recoveredCollection = restored.reconcileRecoveredCollection(
            builderStartAt: actualStart, workoutActive: true, builderEnded: false)
        #expect(recoveredCollection)
        #expect(restored.captureStartedAt == actualStart)
        #expect(restored.health.state == .pending)
        let duplicateIntent = restored.beginCaptureIntent(requestID: "duplicate", at: Date())
        #expect(!duplicateIntent)
        var legacy = record
        legacy.captureStartedAt = Date()  // 0.8.0 conflated this with intent.
        let legacyWithoutBuilder = legacy.reconcileRecoveredCollection(
            builderStartAt: nil, workoutActive: true, builderEnded: false)
        #expect(!legacyWithoutBuilder)
        #expect(legacy.captureState == .recovering)
    }
    @Test func acknowledgingOneBatchLeavesLaterSamplesPendingAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try WatchSessionLedger(directory: directory)
        var record = WatchSessionRecord(id: "batches", view: view())
        let now = Date()
        for number in 0..<12 {
            let added = record.add(
                .init(
                    id: "pulse-\(number)", metric: "heartRateBPM", value: 100,
                    unit: "count/min", sampledAt: now, periodStart: now, device: "Watch",
                    sourceIdentifier: "test"))
            #expect(added)
        }
        try ledger.save(record)
        record.acknowledge((0..<10).map { "pulse-\($0)" })
        try ledger.save(record)
        let restored = try #require(WatchSessionLedger(directory: directory).sessions["batches"])
        #expect(restored.pendingSamples.map(\.id) == ["pulse-10", "pulse-11"])
    }
    @Test func delayedCancellationCannotDiscardAnotherPreparation() {
        var record = WatchSessionRecord(id: "new-session", view: view())
        record.captureState = .prepared
        #expect(!record.canDiscardPreparation(for: "old-session"))
        #expect(record.canDiscardPreparation(for: "new-session"))
        let newIntent = record.beginCaptureIntent(requestID: "capture", at: Date())
        #expect(newIntent)
        #expect(!record.canDiscardPreparation(for: "new-session"))
    }
    @Test func delayedPhoneCancellationLeavesNewPreparationUntouched() {
        var gate = CompanionReadinessGate()
        gate.begin("old")
        gate.cancel("old")
        gate.begin("new")
        let updated = gate.latest.updatedAt
        gate.cancel("old")
        #expect(gate.preparingID == "new")
        #expect(gate.latest.state == .preparing)
        #expect(gate.latest.updatedAt == updated)
    }
    @Test func failedCaptureKeepsLiveSessionBoundAndBlocksNewPreparation() {
        var failed = WatchSessionRecord(id: "old", view: view())
        failed.captureState = .prepared
        let intent = failed.beginCaptureIntent(requestID: "capture", at: Date())
        #expect(intent)
        failed.captureState = .failed  // HealthKit failed after durable intent.
        #expect(!failed.canYieldToNewPreparation(hasLiveWorkout: true))
        #expect(failed.canYieldToNewPreparation(hasLiveWorkout: false))
    }
    @Test func recoveredSessionCannotOverwriteNewPreparationAfterAwait() {
        let ticket = WatchRecoveryTicket(sessionID: "old", generation: 7)
        #expect(ticket.matches(currentID: "old", generation: 7, hasWorkout: false))
        #expect(!ticket.matches(currentID: "new", generation: 7, hasWorkout: false))
        #expect(!ticket.matches(currentID: "old", generation: 8, hasWorkout: false))
        #expect(!ticket.matches(currentID: "old", generation: 7, hasWorkout: true))
        let pending = WatchRecoveryTicket(sessionID: "old", generation: 7, observedState: .prepared)
        #expect(
            pending.matches(currentID: "old", generation: 7, hasWorkout: false, currentState: .prepared))
        #expect(
            !pending.matches(currentID: "old", generation: 7, hasWorkout: false, currentState: .ended))
        #expect(
            !pending.matches(currentID: "old", generation: 8, hasWorkout: false, currentState: .prepared))
    }
}
