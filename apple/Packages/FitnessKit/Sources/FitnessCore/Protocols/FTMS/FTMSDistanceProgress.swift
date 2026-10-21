import Foundation

/// Lower bound of distance observed within one diagnostic session, never a
/// speed integration or a replacement for the original treadmill counter.
public struct FTMSDistanceProgress: Codable, Equatable, Sendable {
    public var accumulatedMeters: UInt64 = 0
    public var zeroResetCount = 0
    public var discontinuityCount = 0
    public var lastCounterMeters: UInt32?
    public var lastInspectionId: String?
    public var lastReceivedAt: Date?
    public var lastEventId: String?
    public var lastTransition = "baseline"

    public mutating func observe(
        _ counter: UInt32, inspectionId: String, at date: Date, eventId: String
    ) {
        guard lastEventId != eventId, lastReceivedAt.map({ date >= $0 }) ?? true else { return }
        if let previous = lastCounterMeters {
            if inspectionId != lastInspectionId {
                // A gap/reconnection cannot distinguish continued distance
                // from a new workout. Establish a baseline, never invent it.
                discontinuityCount += 1
                lastTransition = "connectionBaseline"
            } else if counter >= previous {
                accumulatedMeters += UInt64(counter - previous)
                lastTransition = "delta"
            } else if counter == 0 {
                zeroResetCount += 1
                lastTransition = "counterResetToZero"
            } else {
                discontinuityCount += 1
                lastTransition = "ambiguousDecreaseBaseline"
            }
        } else {
            lastTransition = "baseline"
        }
        lastCounterMeters = counter
        lastInspectionId = inspectionId
        lastReceivedAt = date
        lastEventId = eventId
    }

    public var metric: FTMSMetric? {
        guard let at = lastReceivedAt, let eventId = lastEventId else { return nil }
        return FTMSMetric(value: Double(accumulatedMeters), unit: "m", receivedAt: at, eventId: eventId)
    }

    public init(
        accumulatedMeters: UInt64 = 0,
        zeroResetCount: Int = 0,
        discontinuityCount: Int = 0,
        lastCounterMeters: UInt32? = nil,
        lastInspectionId: String? = nil,
        lastReceivedAt: Date? = nil,
        lastEventId: String? = nil,
        lastTransition: String = "baseline"
    ) {
        self.accumulatedMeters = accumulatedMeters
        self.zeroResetCount = zeroResetCount
        self.discontinuityCount = discontinuityCount
        self.lastCounterMeters = lastCounterMeters
        self.lastInspectionId = lastInspectionId
        self.lastReceivedAt = lastReceivedAt
        self.lastEventId = lastEventId
        self.lastTransition = lastTransition
    }
}
