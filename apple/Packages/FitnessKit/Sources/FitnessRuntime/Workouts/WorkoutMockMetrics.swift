import FitnessCore
import Foundation

/// Deterministic display examples, not physiological or calibrated estimates.
/// This provider never supplies machine speed, distance or inclination.
public enum WorkoutMockMetrics {
    public static func samples(
        speedKPH: Double, distanceMeters: Double,
        activeSeconds: TimeInterval, at date: Date,
        uptime: TimeInterval
    ) -> [WorkoutRecordedSample] {
        let speed = speedKPH.isFinite ? max(0, speedKPH) : 0
        let distance = distanceMeters.isFinite ? max(0, distanceMeters) : 0
        let elapsed = activeSeconds.isFinite ? max(0, activeSeconds) : 0
        let heartRate = min(175, 88 + speed * 6 + sin(elapsed / 30) * 3).rounded()
        let steps = floor(distance / 0.75)
        let energy = (elapsed / 60 * (2 + speed * 0.4)).rounded()
        return [("heartRateBPM", heartRate), ("steps", steps), ("energyKilocalories", energy)].map {
            metric, value in
            WorkoutRecordedSample(
                metric: metric,
                sample: WorkoutSample(
                    value: value,
                    source: .mock, receivedAt: date, monotonicTime: uptime,
                    eventId: "mock-\(UUID().uuidString.lowercased())"))
        }
    }
}
