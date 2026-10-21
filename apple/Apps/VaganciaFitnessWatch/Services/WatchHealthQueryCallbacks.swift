import Foundation
@preconcurrency import HealthKit

/// HealthKit invokes these result handlers on its own queues. The factories
/// are explicitly nonisolated, and the handlers only resume continuations.
enum WatchHealthQueryCallbacks {
    nonisolated static func workouts(
        _ continuation: CheckedContinuation<[HKWorkout], Error>
    ) -> @Sendable (HKSampleQuery, [HKSample]?, Error?) -> Void {
        { _, samples, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
        }
    }

    nonisolated static func heartSamples(
        _ continuation: CheckedContinuation<([HKQuantitySample], HKQueryAnchor?), Error>
    )
        -> @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) ->
        Void
    {
        { _, samples, _, newAnchor, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: (samples as? [HKQuantitySample] ?? [], newAnchor))
            }
        }
    }
}
