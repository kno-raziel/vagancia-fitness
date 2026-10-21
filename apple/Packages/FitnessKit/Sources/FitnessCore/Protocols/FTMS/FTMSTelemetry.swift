import Foundation

public struct FTMSMetric: Codable, Equatable, Sendable {
    public let value: Double
    public let unit: String
    public let receivedAt: Date
    public let eventId: String

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) > 5 || now < receivedAt
    }

    public init(
        value: Double,
        unit: String,
        receivedAt: Date,
        eventId: String
    ) {
        self.value = value
        self.unit = unit
        self.receivedAt = receivedAt
        self.eventId = eventId
    }
}

public struct FTMSTelemetry: Codable, Equatable, Sendable {
    public let serviceId: String
    public let characteristicId: String
    public let startedAt: Date
    public let subscriptionOperationId: String
    public var subscriptionStatus = "pending"
    public var notificationCount = 0
    public var validSampleCount = 0
    public var invalidSampleCount = 0
    public var lastReceivedAt: Date?
    public var lastPacketHex: String?
    public var lastDecodeError: String?
    public var error: BLEFailure?
    public var speed: FTMSMetric?
    public var distance: FTMSMetric?
    public var inclination: FTMSMetric?
    public var rampAngle: FTMSMetric?

    public mutating func receive(_ data: Data, at date: Date, eventId: String) throws
        -> TreadmillSample
    {
        notificationCount += 1
        lastReceivedAt = date
        lastPacketHex = data.map { String(format: "%02X", $0) }.joined()
        do {
            let sample = try FTMSDecoder.treadmill(data)
            validSampleCount += 1
            lastDecodeError = nil
            if let value = sample.speedKilometersPerHour {
                speed = FTMSMetric(value: value, unit: "km/h", receivedAt: date, eventId: eventId)
            }
            if let value = sample.distanceMeters {
                distance = FTMSMetric(value: Double(value), unit: "m", receivedAt: date, eventId: eventId)
            }
            if let value = sample.inclinationPercent {
                inclination = FTMSMetric(value: value, unit: "%", receivedAt: date, eventId: eventId)
            }
            if let value = sample.rampAngleDegrees {
                rampAngle = FTMSMetric(value: value, unit: "°", receivedAt: date, eventId: eventId)
            }
            return sample
        } catch {
            invalidSampleCount += 1
            lastDecodeError = error.localizedDescription
            throw error
        }
    }

    public init(
        serviceId: String,
        characteristicId: String,
        startedAt: Date,
        subscriptionOperationId: String,
        subscriptionStatus: String = "pending",
        notificationCount: Int = 0,
        validSampleCount: Int = 0,
        invalidSampleCount: Int = 0,
        lastReceivedAt: Date? = nil,
        lastPacketHex: String? = nil,
        lastDecodeError: String? = nil,
        error: BLEFailure? = nil,
        speed: FTMSMetric? = nil,
        distance: FTMSMetric? = nil,
        inclination: FTMSMetric? = nil,
        rampAngle: FTMSMetric? = nil
    ) {
        self.serviceId = serviceId
        self.characteristicId = characteristicId
        self.startedAt = startedAt
        self.subscriptionOperationId = subscriptionOperationId
        self.subscriptionStatus = subscriptionStatus
        self.notificationCount = notificationCount
        self.validSampleCount = validSampleCount
        self.invalidSampleCount = invalidSampleCount
        self.lastReceivedAt = lastReceivedAt
        self.lastPacketHex = lastPacketHex
        self.lastDecodeError = lastDecodeError
        self.error = error
        self.speed = speed
        self.distance = distance
        self.inclination = inclination
        self.rampAngle = rampAngle
    }
}
