import Foundation

/// The platform boundary used by the real Watch service and by deterministic
/// tests. `prepare` may create an unbound HealthKit session after a launch
/// configuration; it must never start collection or move exercise equipment.
@MainActor public protocol WatchPreparationEffects: AnyObject {
    func prepareHealthSession(ownerID: String?) async throws -> Bool
    func discardOwnedPreparation(ownerID: String)
    func persistPreparation(_ record: WatchSessionRecord) throws
    func persistCancelledAttempt(sessionID: String, attemptID: String)
    func publishPreparation(_ state: WatchCaptureState, sessionID: String, message: String?)
}

@MainActor public final class WatchPreparationController {
    public enum PrepareResult: Equatable, Sendable {
        case accepted, duplicate, conflict, accessNeeded, cancelledAttempt
    }
    public private(set) var ownerID: String?
    public private(set) var attemptID: String?
    public private(set) var generation: UInt64 = 0
    public private(set) var record: WatchSessionRecord?
    private var cancelledAttempts: [String: Set<String>] = [:]
    private weak var effects: (any WatchPreparationEffects)?

    public init(
        effects: any WatchPreparationEffects, restored: WatchSessionRecord? = nil,
        cancelledAttempts: [String: Set<String>] = [:]
    ) {
        self.effects = effects
        record = restored
        self.cancelledAttempts = cancelledAttempts
    }

    public func restore(_ value: WatchSessionRecord?) {
        record = value
        ownerID = nil
        attemptID = nil
        generation &+= 1
    }
    public func observePersisted(_ value: WatchSessionRecord) { record = value }
    public func attachRecovered(ownerID id: String) {
        guard record?.id == id else { return }
        ownerID = id
        attemptID = record?.lastPreparationAttemptID ?? "legacy"
        generation &+= 1
    }

    /// A HealthKit launch is unbound. In particular it cannot reopen a
    /// terminal ledger row or make that row own a new session.
    public func launchArrived() async throws {
        guard ownerID == nil else { return }
        generation &+= 1
        _ = try await effects?.prepareHealthSession(ownerID: nil)
    }

    public func prepare(
        id: String, attempt: String, sequence: UInt64 = 0, view: CompanionWorkoutView,
        accessReviewed: Bool, existing: WatchSessionRecord?, hasLiveOwnedWorkout: Bool
    ) async throws -> PrepareResult {
        if cancelledAttempts[id]?.contains(attempt) == true { return .cancelledAttempt }
        if existing?.cancelledPreparationAttemptIDs?.contains(attempt) == true {
            return .cancelledAttempt
        }
        if let existing, existing.lastPreparationAttemptID != attempt,
            sequence > 0, let oldSequence = existing.lastPreparationSequence,
            sequence <= oldSequence
        {
            return .cancelledAttempt
        }
        if let existing, existing.lastPreparationAttemptID == attempt,
            [.ended, .failed].contains(existing.captureState)
        {
            return .cancelledAttempt
        }
        if let old = record, old.id != id,
            !old.canYieldToNewPreparation(hasLiveWorkout: hasLiveOwnedWorkout)
        {
            return .conflict
        }
        if let old = record, old.id == id, old.captureStartedAt != nil { return .duplicate }
        guard accessReviewed else { return .accessNeeded }
        if let old = existing, old.captureStartedAt != nil || old.viewGate.terminal {
            return .duplicate
        }
        // A new attempt explicitly supersedes a cancelled attempt of the same
        // logical workout. Old cancel packets remain scoped to their attempt.
        var next: WatchSessionRecord
        if let existing, ![WatchCaptureState.ended, .failed].contains(existing.captureState) {
            next = existing
        } else {
            next = WatchSessionRecord(id: id, view: view)
        }
        next.lastPreparationAttemptID = attempt
        next.lastPreparationSequence = sequence > 0 ? sequence : existing?.lastPreparationSequence
        next.cancelledPreparationAttemptIDs = existing?.cancelledPreparationAttemptIDs
        let newGeneration = generation &+ 1
        generation = newGeneration
        try effects?.persistPreparation(next)
        record = next
        ownerID = id
        attemptID = attempt
        let prepared = try await effects?.prepareHealthSession(ownerID: id) ?? false
        guard generation == newGeneration, ownerID == id, attemptID == attempt else {
            return .cancelledAttempt
        }
        if prepared {
            markPrepared(ownerID: id, generation: newGeneration)
        } else {
            effects?.publishPreparation(.preparing, sessionID: id, message: nil)
        }
        return .accepted
    }

    /// The HK callback includes the owner and generation captured when the
    /// session was created. A late callback from a replaced instance is inert.
    public func markPrepared(ownerID callbackOwner: String?, generation callbackGeneration: UInt64) {
        guard let callbackOwner, callbackOwner == ownerID, callbackGeneration == generation,
            var next = record, next.id == callbackOwner, next.captureState == .preparing
        else { return }
        next.captureState = .prepared
        do {
            try effects?.persistPreparation(next)
            record = next
            effects?.publishPreparation(.prepared, sessionID: callbackOwner, message: nil)
        } catch {
            effects?.publishPreparation(
                .failed, sessionID: callbackOwner, message: error.localizedDescription)
        }
    }

    @discardableResult public func cancel(id: String, attempt: String?) -> Bool {
        let key = attempt ?? "legacy"
        cancelledAttempts[id, default: []].insert(key)
        effects?.persistCancelledAttempt(sessionID: id, attemptID: key)
        guard id == ownerID, (attempt ?? "legacy") == attemptID,
            var next = record, next.canDiscardPreparation(for: id)
        else { return false }
        generation &+= 1
        effects?.discardOwnedPreparation(ownerID: id)
        next.captureState = .ended
        next.cancelledPreparationAttemptIDs = (next.cancelledPreparationAttemptIDs ?? []).union([key])
        next.health = HealthSaveResult(
            state: .discarded, message: "Preparación cancelada; no se guardó entrenamiento.",
            deliveryID: UUID().uuidString.lowercased())
        do {
            try effects?.persistPreparation(next)
            record = next
        } catch {
            effects?.publishPreparation(.failed, sessionID: id, message: error.localizedDescription)
            return false
        }
        ownerID = nil
        attemptID = nil
        effects?.publishPreparation(.ended, sessionID: id, message: nil)
        return true
    }

    /// Explicit operator resolution is limited to this app's preparation.
    /// Capturing records and unowned/external HK sessions are never ended.
    @discardableResult public func resolveOrphan(id: String) -> Bool {
        guard record?.canDiscardPreparation(for: id) == true else { return false }
        if ownerID == nil {
            guard var next = record else { return false }
            next.captureState = .ended
            next.health = HealthSaveResult(
                state: .discarded,
                message: "Preparación anterior descartada por el operador; no hubo captura.",
                deliveryID: UUID().uuidString.lowercased())
            do {
                try effects?.persistPreparation(next)
                record = next
                effects?.publishPreparation(.ended, sessionID: id, message: nil)
                return true
            } catch {
                effects?.publishPreparation(.failed, sessionID: id, message: error.localizedDescription)
                return false
            }
        }
        guard id == ownerID else { return false }
        return cancel(id: id, attempt: attemptID)
    }

    public func detachTerminalOwner(id: String) {
        guard id == ownerID else { return }
        ownerID = nil
        attemptID = nil
        generation &+= 1
    }
}
