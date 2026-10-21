import FitnessCore
import Foundation
import Testing

@MainActor
private final class FakeWatchPreparationEffects: WatchPreparationEffects {
    var preparedByHealthKit = false
    var stored: [String: WatchSessionRecord] = [:]
    var createdOwners: [String?] = []
    var discardedOwners: [String] = []
    var emitted: [(String, WatchCaptureState)] = []
    var cancelled: [String: Set<String>] = [:]
    var suspendOwnedPreparation = false
    var pendingOwnedPreparation: CheckedContinuation<Bool, Never>?
    func prepareHealthSession(ownerID: String?) async throws -> Bool {
        createdOwners.append(ownerID)
        if ownerID != nil, suspendOwnedPreparation {
            return await withCheckedContinuation { pendingOwnedPreparation = $0 }
        }
        return preparedByHealthKit
    }
    func completeOwnedPreparation(_ prepared: Bool) {
        pendingOwnedPreparation?.resume(returning: prepared)
        pendingOwnedPreparation = nil
    }
    func discardOwnedPreparation(ownerID: String) { discardedOwners.append(ownerID) }
    func persistPreparation(_ record: WatchSessionRecord) throws { stored[record.id] = record }
    func persistCancelledAttempt(sessionID: String, attemptID: String) {
        cancelled[sessionID, default: []].insert(attemptID)
    }
    func publishPreparation(_ state: WatchCaptureState, sessionID: String, message: String?) {
        emitted.append((sessionID, state))
    }
}

@MainActor
struct WatchPreparationLifecycleTests {
    /// Sanitized derivative of the historical Watch ledger. IDs and dates are fictional;
    /// states, relative timing and ownership relationships preserve the regression.
    private func capturedLedger() throws -> [String: WatchSessionRecord] {
        let url = try #require(Bundle.module.url(forResource: "WatchLedger081", withExtension: "json"))
        return try JSONDecoder().decode([String: WatchSessionRecord].self, from: Data(contentsOf: url))
    }

    @Test func launchBeforePrepareCannotReviveCapturedFailedRecord() async throws {
        let captured = try capturedLedger()
        let old = try #require(captured["1be17ef5-5975-5925-9dc7-32a53cb42b27"])
        #expect(old.captureState == .failed)
        #expect(old.health.state == .discarded)
        #expect(old.health.deliveryID == nil)  // Captured by 0.8.1 before terminal ACKs existed.
        let effects = FakeWatchPreparationEffects()
        effects.stored[old.id] = old
        effects.preparedByHealthKit = true
        let controller = WatchPreparationController(effects: effects, restored: old)
        try await controller.launchArrived()
        controller.markPrepared(ownerID: nil, generation: controller.generation)
        #expect(effects.stored[old.id]?.captureState == .failed)
        let newID = "new-after-captured-failure"
        let result = try await controller.prepare(
            id: newID, attempt: "attempt-1", view: old.view,
            accessReviewed: true, existing: nil, hasLiveOwnedWorkout: false)
        #expect(result == .accepted)
        #expect(effects.createdOwners.count == 2)
        #expect(effects.createdOwners[0] == nil)
        #expect(effects.createdOwners[1] == newID)
        #expect(effects.stored[old.id]?.captureState == .failed)
        #expect(effects.stored[newID]?.captureState == .prepared)
    }

    @Test func capturedFailedPreparationMustInspectHealthKitBeforeResolution() throws {
        let captured = try capturedLedger()
        let failed = try #require(captured["1be17ef5-5975-5925-9dc7-32a53cb42b27"])
        let ended = try #require(captured["50760708-3bea-5d61-b1e8-5e22ed7e5cd8"])
        #expect(failed.captureState == .failed)
        #expect(failed.captureStartedAt == nil)
        #expect(WatchRecoveryPolicy.shouldInspectHealthKit(failed))
        #expect(!WatchRecoveryPolicy.shouldInspectHealthKit(ended))
        #expect(
            WatchRecoveryPolicy.mayBindRecoveredFailedPreparation(
                failed,
                healthSessionPrepared: true, collectionStartedAt: nil, collectionEndedAt: nil))
        #expect(
            !WatchRecoveryPolicy.mayBindRecoveredFailedPreparation(
                failed,
                healthSessionPrepared: false, collectionStartedAt: nil, collectionEndedAt: nil))
        #expect(
            !WatchRecoveryPolicy.mayBindRecoveredFailedPreparation(
                failed,
                healthSessionPrepared: true, collectionStartedAt: Date(), collectionEndedAt: nil))
        #expect(
            !WatchRecoveryPolicy.mayBindRecoveredFailedPreparation(
                failed,
                healthSessionPrepared: true, collectionStartedAt: nil, collectionEndedAt: nil,
                builderSessionID: "another-session"))
        var capturedFailure = failed
        capturedFailure.captureStartedAt = Date(timeIntervalSince1970: 1)
        #expect(WatchRecoveryPolicy.shouldInspectHealthKit(capturedFailure))
        #expect(
            WatchRecoveryPolicy.mayBindRecoveredCapturedSession(
                capturedFailure,
                builderSessionID: capturedFailure.id, collectionStartedAt: capturedFailure.captureStartedAt,
                healthSessionActive: true))
        #expect(
            !WatchRecoveryPolicy.mayBindRecoveredCapturedSession(
                capturedFailure,
                builderSessionID: "another-session", collectionStartedAt: capturedFailure.captureStartedAt,
                healthSessionActive: true))
        #expect(
            !WatchRecoveryPolicy.mayBindRecoveredCapturedSession(
                capturedFailure,
                builderSessionID: capturedFailure.id, collectionStartedAt: nil,
                healthSessionActive: true))
        capturedFailure.captureState = .recovering
        capturedFailure.health = HealthSaveResult(state: .pending)
        #expect(
            capturedFailure.canFinishRecoveredCapture(
                builderSessionID: capturedFailure.id,
                collectionConfirmed: true))
        #expect(
            !capturedFailure.canFinishRecoveredCapture(
                builderSessionID: "another-session",
                collectionConfirmed: true))
        capturedFailure.health = HealthSaveResult(state: .uncertain)
        #expect(
            !capturedFailure.canFinishRecoveredCapture(
                builderSessionID: capturedFailure.id,
                collectionConfirmed: true))
    }

    @Test func duplicateLaunchDuringPendingPrepareDoesNotInvalidateOwner() async throws {
        let view = try #require(capturedLedger().values.first?.view)
        let effects = FakeWatchPreparationEffects()
        effects.suspendOwnedPreparation = true
        let controller = WatchPreparationController(effects: effects)
        let preparing = Task {
            try await controller.prepare(
                id: "session", attempt: "one", sequence: 1,
                view: view, accessReviewed: true, existing: nil, hasLiveOwnedWorkout: false)
        }
        for _ in 0..<100 where effects.pendingOwnedPreparation == nil { await Task.yield() }
        #expect(effects.pendingOwnedPreparation != nil)
        let generation = controller.generation
        try await controller.launchArrived()
        #expect(controller.generation == generation)
        effects.completeOwnedPreparation(true)
        #expect(try await preparing.value == .accepted)
        #expect(effects.stored["session"]?.captureState == .prepared)
        #expect(effects.createdOwners == ["session"])
    }

    @Test func capturedTerminalResultIsStableUntilDurableAcknowledgement() throws {
        let captured = try capturedLedger()
        var old = try #require(captured["1be17ef5-5975-5925-9dc7-32a53cb42b27"])
        let firstRaw = old.terminalHealthResultForDelivery()
        let first = try #require(firstRaw)
        let id = try #require(first.deliveryID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try WatchSessionLedger(directory: directory)
        try ledger.save(old)
        var restored = try #require(WatchSessionLedger(directory: directory).sessions[old.id])
        let duplicateID = restored.terminalHealthResultForDelivery()?.deliveryID
        #expect(duplicateID == id)
        let wrongACK = restored.acknowledgeHealthResult("wrong")
        #expect(!wrongACK)
        let acceptedACK = restored.acknowledgeHealthResult(id)
        #expect(acceptedACK)
        try ledger.save(restored)
        var acknowledged = try #require(WatchSessionLedger(directory: directory).sessions[old.id])
        let pending = acknowledged.terminalHealthResultForDelivery()
        #expect(pending == nil)
        let previousID = acknowledged.health.deliveryID
        acknowledged.replaceHealthResult(
            HealthSaveResult(
                state: .discarded,
                // The public fixture replaces the original free text. Reconcile
                // the same persisted status, preserving the receipt after ACK.
                message: acknowledged.health.message))
        #expect(acknowledged.health.deliveryID == previousID)
        acknowledged.replaceHealthResult(
            HealthSaveResult(state: .saved, workoutUUID: "later-confirmed"))
        #expect(acknowledged.health.deliveryID != previousID)
    }

    @Test func repeatedHealthReconciliationRetainsSavedReceiptAcrossRestart() throws {
        let captured = try capturedLedger()
        var record = try #require(captured.values.first)
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        record.replaceHealthResult(
            HealthSaveResult(
                state: .saved, workoutUUID: "health-uuid",
                captureStartedAt: start, captureEndedAt: end))
        let firstDelivery = record.terminalHealthResultForDelivery()
        let receipt = try #require(firstDelivery?.deliveryID)
        let accepted = record.acknowledgeHealthResult(receipt)
        #expect(accepted)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try WatchSessionLedger(directory: directory)
        try ledger.save(record)
        var restored = try #require(WatchSessionLedger(directory: directory).sessions[record.id])
        restored.replaceHealthResult(
            HealthSaveResult(
                state: .saved, workoutUUID: "health-uuid",
                updatedAt: Date(), captureStartedAt: start, captureEndedAt: end,
                heartRateAverageBPM: 120))
        #expect(restored.health.deliveryID == receipt)
        let duplicate = restored.terminalHealthResultForDelivery()
        #expect(duplicate == nil)
        restored.replaceHealthResult(
            HealthSaveResult(
                state: .saved, workoutUUID: "different-health-uuid",
                captureStartedAt: start, captureEndedAt: end))
        let newDelivery = restored.terminalHealthResultForDelivery()
        #expect(newDelivery?.deliveryID != receipt)
    }

    @Test func cancellationAndRetrySameWorkoutIDUsesNewAttempt() async throws {
        let view = try #require(capturedLedger().values.first?.view)
        let effects = FakeWatchPreparationEffects()
        effects.preparedByHealthKit = true
        let controller = WatchPreparationController(effects: effects)
        #expect(
            try await controller.prepare(
                id: "same", attempt: "one", view: view,
                accessReviewed: true, existing: nil, hasLiveOwnedWorkout: false) == .accepted)
        #expect(controller.cancel(id: "same", attempt: "one"))
        #expect(effects.stored["same"]?.health.state == .discarded)
        #expect(effects.discardedOwners == ["same"])
        let restarted = WatchPreparationController(
            effects: effects, restored: effects.stored["same"],
            cancelledAttempts: effects.cancelled)
        #expect(
            try await restarted.prepare(
                id: "same", attempt: "one", sequence: 1, view: view,
                accessReviewed: true, existing: effects.stored["same"], hasLiveOwnedWorkout: false)
                == .cancelledAttempt)
        #expect(
            try await controller.prepare(
                id: "same", attempt: "two", view: view,
                accessReviewed: true, existing: effects.stored["same"], hasLiveOwnedWorkout: false)
                == .accepted)
        #expect(effects.stored["same"]?.captureState == .prepared)
        #expect(!controller.cancel(id: "same", attempt: "one"))
        #expect(effects.stored["same"]?.captureState == .prepared)
    }

    @Test func reorderedCallbackAndOperatorResolutionCannotEndCapture() async throws {
        let view = try #require(capturedLedger().values.first?.view)
        let effects = FakeWatchPreparationEffects()
        let controller = WatchPreparationController(effects: effects)
        try await controller.launchArrived()
        let stale = controller.generation
        controller.markPrepared(ownerID: nil, generation: stale)
        #expect(
            try await controller.prepare(
                id: "owned", attempt: "one", view: view,
                accessReviewed: true, existing: nil, hasLiveOwnedWorkout: false) == .accepted)
        controller.markPrepared(ownerID: "owned", generation: stale)
        #expect(effects.stored["owned"]?.captureState == .preparing)
        controller.markPrepared(ownerID: "owned", generation: controller.generation)
        #expect(effects.stored["owned"]?.captureState == .prepared)
        var captured = try #require(effects.stored["owned"])
        let beganCapture = captured.beginCaptureIntent(requestID: "confirmed-phone", at: Date())
        #expect(beganCapture)
        try effects.persistPreparation(captured)
        controller.observePersisted(captured)
        #expect(!controller.resolveOrphan(id: "owned"))
        #expect(effects.discardedOwners.isEmpty)
    }
}
