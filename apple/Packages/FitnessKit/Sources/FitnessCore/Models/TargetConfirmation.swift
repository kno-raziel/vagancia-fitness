import Foundation

/// FTMS procedure acceptance is separate from observed treadmill speed.
/// Feed each distinct, fresh telemetry event after the accepted procedure.
public struct TargetConfirmation {
    public let target: Double
    public let acceptedAt: TimeInterval
    public let tolerance: Double
    public let requiredStableSeconds: TimeInterval
    public let deadline: TimeInterval
    private var firstMatchingAt: TimeInterval?
    private var seenEventIDs: Set<String> = []
    private var lastObservedAt: TimeInterval?
    public private(set) var observed: Double?
    public private(set) var matchingSamples = 0

    public init(
        target: Double, acceptedAt: TimeInterval, tolerance: Double = 0.15,
        requiredStableSeconds: TimeInterval = 3, deadline: TimeInterval = 25
    ) {
        self.target = target
        self.acceptedAt = acceptedAt
        self.tolerance = tolerance
        self.requiredStableSeconds = requiredStableSeconds
        self.deadline = deadline
    }

    public mutating func observe(value: Double, eventID: String, at time: TimeInterval) -> Bool {
        guard value.isFinite, time >= acceptedAt, time <= acceptedAt + deadline,
            !seenEventIDs.contains(eventID), time > (lastObservedAt ?? acceptedAt - 1)
        else { return false }
        seenEventIDs.insert(eventID)
        if seenEventIDs.count > 256 { seenEventIDs = [eventID] }
        if let lastObservedAt, time - lastObservedAt > 2.5 {
            firstMatchingAt = nil
            matchingSamples = 0
        }
        lastObservedAt = time
        observed = value
        guard abs(value - target) <= tolerance else {
            firstMatchingAt = nil
            matchingSamples = 0
            return false
        }
        if firstMatchingAt == nil { firstMatchingAt = time }
        matchingSamples += 1
        return matchingSamples >= 3 && time - (firstMatchingAt ?? time) >= requiredStableSeconds
    }

    public func expired(at time: TimeInterval) -> Bool { time >= acceptedAt + deadline }
}
