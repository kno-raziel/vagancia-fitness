import FitnessCore
import Foundation

struct TargetObservationResult {
    let value: Double
    let eventID: String
    let sampleCount: Int
}

enum TargetObservationError: LocalizedError {
    case notReached(target: Double, observed: Double?, deadline: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notReached(let target, _, _):
            "El objetivo de velocidad de \(target.formatted()) km/h no se observó de forma sostenida. Automatización suspendida; revisa la consola física."
        }
    }
}

/// Owns target observation after an accepted FTMS procedure. It issues no
/// commands, and the caller may invalidate it immediately for Stop.
@MainActor
struct TargetObservationVerifier {
    let transport: any WorkoutControlTransport
    let clock: () -> TimeInterval
    let sleep: @Sendable (Duration) async throws -> Void
    let stableSeconds: TimeInterval
    let deadlineScale: Double

    func confirmSpeed(
        _ target: Double, priorSpeed: Double, acceptedAt: Date,
        checkCurrent: @MainActor () throws -> Void
    ) async throws -> TargetObservationResult {
        let accelerationSeconds = abs(target - priorSpeed) / 0.5
        let deadline = min(35, max(12, accelerationSeconds + 6)) * deadlineScale
        let acceptedUptime = clock()
        var confirmation = TargetConfirmation(
            target: target, acceptedAt: acceptedUptime,
            requiredStableSeconds: stableSeconds, deadline: deadline)
        while !confirmation.expired(at: clock()) {
            try Task.checkCancellation()
            try checkCurrent()
            guard transport.phase == .ready, transport.control.permission,
                transport.control.indicationReady, !transport.control.requiresReconnect
            else {
                throw ControlError.blocked(
                    "Se perdió el control FTMS al verificar el objetivo de velocidad.")
            }
            if let metric = transport.snapshot?.telemetry?.speed,
                metric.receivedAt > acceptedAt, !metric.isStale(at: Date()),
                confirmation.observe(
                    value: metric.value, eventID: metric.eventId,
                    at: acceptedUptime + metric.receivedAt.timeIntervalSince(acceptedAt))
            {
                return TargetObservationResult(
                    value: metric.value, eventID: metric.eventId,
                    sampleCount: confirmation.matchingSamples)
            }
            try await sleep(.milliseconds(100))
        }
        throw TargetObservationError.notReached(
            target: target, observed: confirmation.observed, deadline: deadline)
    }
}
