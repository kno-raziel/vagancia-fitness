import FitnessCore
import Foundation

/// Product opts in explicitly. Debug and tests never activate HealthKit or WC.
@MainActor public protocol WorkoutCompanion: AnyObject {
    var useWatch: Bool { get }
    var readiness: WatchReadiness { get }
    var preparedSessionID: String? { get }
    var onMessage: ((CompanionMessage) async throws -> Void)? { get set }
    func prepare(id: String, view: CompanionWorkoutView) async throws
    func publish(id: String, view: CompanionWorkoutView)
    func cancelPreparation(id: String)
    func finalize(id: String, view: CompanionWorkoutView)
    func acknowledge(id: String, sampleIDs: [String])
    func acknowledgeHealthResult(sessionID: String, resultID: String)
    func acknowledgeRejectedEnvelopes(_ ids: [String])
    func requestRejectedEnvelopes()
    var rejectionSnapshotAvailable: Bool { get }
    func collectRejectedEnvelopeSnapshot() async -> WatchRejectedEnvelopeSnapshotReceipt?
}

extension WorkoutCompanion {
    public func acknowledgeHealthResult(sessionID: String, resultID: String) {}
    public func acknowledgeRejectedEnvelopes(_ ids: [String]) {}
    public func requestRejectedEnvelopes() {}
    public var rejectionSnapshotAvailable: Bool { false }
    public func collectRejectedEnvelopeSnapshot() async -> WatchRejectedEnvelopeSnapshotReceipt? {
        requestRejectedEnvelopes()
        return nil
    }
}
