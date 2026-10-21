import Foundation

/// Correlates asynchronous readiness with the current preparation. A cancelled
/// ID can never restore an older state, even if its message has a newer date.
public struct CompanionReadinessGate: Sendable {
    public enum Result: Equatable, Sendable {
        case ignored, staleCancelled, accepted, prepared, captureConfirmed
    }
    public private(set) var preparingID: String?
    public private(set) var preparedID: String?
    public private(set) var confirmedCaptureID: String?
    public private(set) var latest = WatchReadiness(updatedAt: .distantPast)
    private var cancelledIDs: Set<String> = []
    private var captureRequests: [String: String] = [:]
    public init() {}
    public mutating func begin(_ id: String) {
        preparingID = id
        preparedID = nil
        confirmedCaptureID = nil
        cancelledIDs.remove(id)
        latest = WatchReadiness(
            state: .preparing, message: "Abriendo el Watch; preparación sin movimiento.")
    }
    public mutating func cancel(_ id: String) {
        cancelledIDs.insert(id)
        captureRequests.removeValue(forKey: id)
        let wasCurrent = preparingID == id || preparedID == id
        if preparingID == id { preparingID = nil }
        if preparedID == id { preparedID = nil }
        if confirmedCaptureID == id { confirmedCaptureID = nil }
        if wasCurrent { latest = WatchReadiness(state: .idle, message: "Preparación cancelada.") }
    }
    public mutating func requestCapture(_ requestID: String, for id: String) {
        guard preparedID == id else { return }
        captureRequests[id] = requestID
        confirmedCaptureID = nil
    }
    public mutating func receive(_ value: WatchReadiness, sessionID id: String) -> Result {
        if cancelledIDs.contains(id) { return .staleCancelled }
        guard
            (id == "setup" && preparingID == nil && preparedID == nil) || id == preparingID
                || id == preparedID,
            value.updatedAt >= latest.updatedAt
        else { return .ignored }
        latest = value
        if value.state == .prepared, id == preparingID {
            preparedID = id
            return .prepared
        }
        if id == preparedID, value.captureRequestID == captureRequests[id],
            value.captureRequestID != nil, value.captureStartedAt != nil,
            [.running, .paused, .recovering].contains(value.state)
        {
            confirmedCaptureID = id
            return .captureConfirmed
        }
        return .accepted
    }
}

/// HealthKit can replace a mirrored session instance after reconnection.
public struct CompanionMirrorIdentity {
    private var current: ObjectIdentifier?
    public init() {}
    public mutating func replace(with session: AnyObject) { current = ObjectIdentifier(session) }
    public func isCurrent(_ session: AnyObject) -> Bool { current == ObjectIdentifier(session) }
}

/// Plans independent background and live paths. WC reachability controls only
/// the immediate path; it never suppresses a queued preparation or capture view.
public struct CompanionDeliveryPlan: Equatable, Sendable {
    public enum LivePath: Equatable, Sendable { case mirror, watchConnectivity, none }
    public let queueBackground: Bool
    public let updateContext: Bool
    public let livePath: LivePath
    public init(
        durable: Bool, contextFallback: Bool, channelActivated: Bool, wcReachable: Bool,
        mirrorConnected: Bool
    ) {
        queueBackground = durable && channelActivated
        updateContext = contextFallback && channelActivated
        livePath = mirrorConnected ? .mirror : wcReachable ? .watchConnectivity : .none
    }
}

/// A recovery result belongs only to the session observed before the await.
public struct WatchRecoveryTicket: Equatable, Sendable {
    public let sessionID: String
    public let generation: UInt64
    public let observedState: WatchCaptureState?
    public init(sessionID: String, generation: UInt64, observedState: WatchCaptureState? = nil) {
        self.sessionID = sessionID
        self.generation = generation
        self.observedState = observedState
    }
    public func matches(
        currentID: String?, generation currentGeneration: UInt64, hasWorkout: Bool,
        currentState: WatchCaptureState? = nil
    ) -> Bool {
        currentID == sessionID && currentGeneration == generation && !hasWorkout
            && (observedState == nil || observedState == currentState)
    }
}

/// Decide whether launch must inspect HealthKit before an operator can
/// discard a restored preparation. A failed preparation without confirmed
/// collection may still have a prepared HK session after process termination.
public enum WatchRecoveryPolicy {
    public static func shouldInspectHealthKit(_ record: WatchSessionRecord?) -> Bool {
        guard let record else { return false }
        switch record.captureState {
        case .preparing, .prepared, .running, .paused, .recovering:
            return true
        case .failed:
            return record.health.state != .saved
        case .idle, .accessNeeded, .ending, .ended, .conflict:
            return false
        }
    }
    public static func mayBindRecoveredFailedPreparation(
        _ record: WatchSessionRecord,
        healthSessionPrepared: Bool,
        collectionStartedAt: Date?,
        collectionEndedAt: Date?,
        builderSessionID: String? = nil
    ) -> Bool {
        record.captureState == .failed && record.captureIntentAt == nil
            && record.captureStartedAt == nil && healthSessionPrepared && collectionStartedAt == nil
            && collectionEndedAt == nil && (builderSessionID == nil || builderSessionID == record.id)
    }
    public static func mayBindRecoveredCapturedSession(
        _ record: WatchSessionRecord,
        builderSessionID: String?,
        collectionStartedAt: Date?,
        healthSessionActive: Bool
    ) -> Bool {
        record.captureStartedAt != nil && builderSessionID == record.id && collectionStartedAt != nil
            && healthSessionActive
    }
}
