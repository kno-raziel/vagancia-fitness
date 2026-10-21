import Foundation

public enum DiagnosticProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ftms, fitShowFFF0, fitShowFFE0
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ftms: "FTMS"
        case .fitShowFFF0: "FitShow · FFF0"
        case .fitShowFFE0: "FitShow · FFE0"
        }
    }
    public var serviceUUID: String {
        switch self {
        case .ftms: "1826"
        case .fitShowFFF0: "FFF0"
        case .fitShowFFE0: "FFE0"
        }
    }
    public var writeUUID: String {
        switch self {
        case .ftms: "2AD9"
        case .fitShowFFF0: "FFF2"
        case .fitShowFFE0: "FFE1"
        }
    }
    public var notifyUUID: String {
        switch self {
        case .ftms: "2AD9"
        case .fitShowFFF0: "FFF1"
        case .fitShowFFE0: "FFE4"
        }
    }
}

public struct FitShowMessage: Codable, Equatable, Sendable {
    public let frameHex: String
    public let family: UInt8
    public let parameter: UInt8
    public let payload: [UInt8]
    public var recognized: Bool {
        (family == 0x50 && (parameter == 2 || parameter == 3)
            && (payload.count == 4 || payload.count == 5))
            || (family == 0x51 && [1, 3, 4, 10].contains(parameter) && payload.count >= 13)
            || (family == 0x51 && [0, 2, 5, 6, 7].contains(parameter) && (2...3).contains(payload.count))
    }

    public init(
        frameHex: String,
        family: UInt8,
        parameter: UInt8,
        payload: [UInt8]
    ) {
        self.frameHex = frameHex
        self.family = family
        self.parameter = parameter
        self.payload = payload
    }
}

public enum FitShowError: LocalizedError {
    case invalidFrame, overflow
    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .invalidFrame: FitnessText.string("error.fitshow.invalidFrame", locale: locale)
        case .overflow: FitnessText.string("error.fitshow.overflow", locale: locale)
        }
    }
}

/// Independently implemented wire framing, informed by the pinned QZ driver.
/// Only the known INFO speed-range query is exposed. No motor/user/init command.
public enum FitShowProtocol {
    public static let referenceRevision = "87263fb9b7b029005cba3476bdb0579273da1040"
    public static let decoderId = "fitshow-qz-reference-v1"
    // The isolated 0x51 query preceded a simultaneous FTMS/FFF0 silence on
    // this firmware. Decode unsolicited status, but do not encode that query.
    public static func speedRangeQuery() -> Data { frame([0x50, 2]) }
    public static func frame(_ payload: [UInt8]) -> Data {
        Data([2] + payload + [payload.reduce(0, ^), 3])
    }
    public static func decode(_ data: Data) throws -> FitShowMessage {
        let bytes = Array(data)
        guard (5...64).contains(bytes.count), bytes.first == 2, bytes.last == 3,
            bytes.dropFirst().dropLast(2).reduce(0, ^) == bytes[bytes.count - 2]
        else { throw FitShowError.invalidFrame }
        return FitShowMessage(
            frameHex: data.hex, family: bytes[1], parameter: bytes[2],
            payload: Array(bytes.dropFirst().dropLast(2)))
    }
}

public struct FitShowAssembler {
    public private(set) var buffer = Data()
    public mutating func receive(_ data: Data) throws -> [FitShowMessage] {
        buffer.append(data)
        guard buffer.count <= 64 else {
            buffer.removeAll()
            throw FitShowError.overflow
        }
        var messages: [FitShowMessage] = []
        while !buffer.isEmpty {
            guard buffer.first == 2 else {
                buffer.removeAll()
                throw FitShowError.invalidFrame
            }
            var end: Int?
            // Do not split on a footer byte inside a payload. Accept only a
            // checksummed candidate, requiring full known status/range fields.
            for count in 5...max(5, buffer.count) where count <= buffer.count && buffer[count - 1] == 3 {
                if let message = try? FitShowProtocol.decode(Data(buffer.prefix(count))),
                    message.family != 0x51 || ![1, 3, 4, 10].contains(message.parameter)
                        || message.payload.count >= 13,
                    message.family != 0x50 || ![2, 3].contains(message.parameter)
                        || message.payload.count >= 4
                {
                    messages.append(message)
                    end = count
                    break
                }
            }
            if let end {
                buffer = Data(buffer.dropFirst(end))
                continue
            }
            let minimum =
                buffer.count >= 3 && buffer[1] == 0x51 && [1, 3, 4, 10].contains(buffer[2])
                ? 16
                : buffer.count >= 3 && buffer[1] == 0x50 && [2, 3].contains(buffer[2]) ? 7 : 5
            if buffer.count >= minimum && buffer.last == 3 {
                buffer.removeAll()
                throw FitShowError.invalidFrame
            }
            break
        }
        return messages
    }

    public init() {}
}

public struct FitShowObservation: Codable, Equatable, Identifiable, Sendable {
    public let channel: DiagnosticProtocol
    public let serviceId: String
    public let writeCharacteristicId: String
    public let notifyCharacteristicId: String
    public var id: String { channel.id }
    public var subscriptionStatus = "pending"
    public var notificationCount = 0
    public var validFrameCount = 0
    public var recognizedFrameCount = 0
    public var rejectedCount = 0
    public var rangeResponseEventId: String?
    public var statusEventId: String?
    public var statusReceivedAt: Date?
    public var rangeReceivedAt: Date?
    public var metricReceivedAt: Date?
    public var lastReceivedAt: Date?
    public var lastHex: String?
    public var lastError: String?
    public var minimumSpeedTenthsRaw: UInt8?
    public var maximumSpeedTenthsRaw: UInt8?
    public var unitByteRaw: UInt8?
    public var speedTenthsRaw: UInt8?
    public var distanceCounterRaw: UInt16?
    public var machineStatusRaw: UInt8?
    // Message recognition is deliberately separate from control compatibility.
    public var controlEnabled: Bool { false }
    public var compatibility: String {
        if rangeResponseEventId != nil && statusEventId != nil {
            "messagesRecognizedUnitsUnconfirmed"
        } else if recognizedFrameCount > 0 {
            "partialMessagesRecognized"
        } else {
            "unconfirmed"
        }
    }
    public mutating func observe(
        _ message: FitShowMessage, eventId: String, matchedRangeQuery: Bool, at date: Date = Date()
    ) {
        validFrameCount += 1
        guard message.recognized else { return }
        recognizedFrameCount += 1
        let p = message.payload
        if message.family == 0x50 && message.parameter == 2 {
            guard p[3] <= p[2] else {
                lastError = "Rango propietario invertido; se conserva sin validar."
                return
            }
            maximumSpeedTenthsRaw = p[2]
            minimumSpeedTenthsRaw = p[3]
            rangeReceivedAt = date
            unitByteRaw = p.count > 4 ? p[4] : nil
            if matchedRangeQuery { rangeResponseEventId = eventId }
        } else if message.family == 0x51 {
            machineStatusRaw = message.parameter
            if p.count >= 13 {
                speedTenthsRaw = p[2]
                distanceCounterRaw = UInt16(p[6]) | UInt16(p[7]) << 8
                metricReceivedAt = date
            }
            statusEventId = eventId
            statusReceivedAt = date
        }
    }

    public init(
        channel: DiagnosticProtocol,
        serviceId: String,
        writeCharacteristicId: String,
        notifyCharacteristicId: String,
        subscriptionStatus: String = "pending",
        notificationCount: Int = 0,
        validFrameCount: Int = 0,
        recognizedFrameCount: Int = 0,
        rejectedCount: Int = 0,
        rangeResponseEventId: String? = nil,
        statusEventId: String? = nil,
        statusReceivedAt: Date? = nil,
        rangeReceivedAt: Date? = nil,
        metricReceivedAt: Date? = nil,
        lastReceivedAt: Date? = nil,
        lastHex: String? = nil,
        lastError: String? = nil,
        minimumSpeedTenthsRaw: UInt8? = nil,
        maximumSpeedTenthsRaw: UInt8? = nil,
        unitByteRaw: UInt8? = nil,
        speedTenthsRaw: UInt8? = nil,
        distanceCounterRaw: UInt16? = nil,
        machineStatusRaw: UInt8? = nil
    ) {
        self.channel = channel
        self.serviceId = serviceId
        self.writeCharacteristicId = writeCharacteristicId
        self.notifyCharacteristicId = notifyCharacteristicId
        self.subscriptionStatus = subscriptionStatus
        self.notificationCount = notificationCount
        self.validFrameCount = validFrameCount
        self.recognizedFrameCount = recognizedFrameCount
        self.rejectedCount = rejectedCount
        self.rangeResponseEventId = rangeResponseEventId
        self.statusEventId = statusEventId
        self.statusReceivedAt = statusReceivedAt
        self.rangeReceivedAt = rangeReceivedAt
        self.metricReceivedAt = metricReceivedAt
        self.lastReceivedAt = lastReceivedAt
        self.lastHex = lastHex
        self.lastError = lastError
        self.minimumSpeedTenthsRaw = minimumSpeedTenthsRaw
        self.maximumSpeedTenthsRaw = maximumSpeedTenthsRaw
        self.unitByteRaw = unitByteRaw
        self.speedTenthsRaw = speedTenthsRaw
        self.distanceCounterRaw = distanceCounterRaw
        self.machineStatusRaw = machineStatusRaw
    }
}

public struct InteractiveEvidence: Codable, Equatable, Sendable {
    public var selectedProtocol: DiagnosticProtocol = .ftms
    public var control = FTMSControl()
    public var fitShow: [FitShowObservation] = []

    public init(
        selectedProtocol: DiagnosticProtocol = .ftms,
        control: FTMSControl = FTMSControl(),
        fitShow: [FitShowObservation] = []
    ) {
        self.selectedProtocol = selectedProtocol
        self.control = control
        self.fitShow = fitShow
    }
}

public struct LivePoint: Identifiable {
    public let id: String
    public let date: Date
    public let speed: Double

    public init(
        id: String,
        date: Date,
        speed: Double
    ) {
        self.id = id
        self.date = date
        self.speed = speed
    }
}
