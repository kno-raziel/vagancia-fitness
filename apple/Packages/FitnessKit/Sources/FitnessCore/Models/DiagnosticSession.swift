import Foundation

public enum EvidenceSource: String, Codable, Sendable {
    case application, synthetic, hardware, userReported
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var text: String? {
        if case .string(let value) = self { value } else { nil }
    }
}

public struct DiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
    public let eventId: String
    public let sequence: Int
    public let timestamp: Date
    public let elapsedMilliseconds: Int
    public let kind: String
    public let source: EvidenceSource
    public let payload: [String: JSONValue]

    public var id: String { eventId }
    public var title: String {
        localizedTitle()
    }
    public func localizedTitle(locale: Locale? = nil) -> String {
        switch kind {
        case "session.created", "session.closed", "session.restored", "operator.note",
            "app.backgrounded", "app.activated", "ble.scan.started", "ble.scan.stopped",
            "ble.device.discovered", "ble.connection.requested", "ble.connected",
            "ble.connection.failed", "ble.disconnected", "ble.discovery.finished",
            "ble.operation.timeout", "ble.identity.read", "ftms.value.read",
            "ftms.subscription.requested", "ftms.subscription.updated",
            "ftms.treadmill.received", "ftms.control.subscription.requested",
            "ftms.control.subscription.updated", "ftms.control.requested",
            "ftms.control.written", "ftms.control.response", "ftms.control.timeout",
            "ftms.control.blocked", "ftms.control.superseded", "ftms.machine.status",
            "diagnostic.protocol.selected", "fitshow.subscription.requested",
            "fitshow.subscription.updated", "fitshow.notification.received",
            "fitshow.query.requested", "fitshow.query.timeout", "diagnostic.reception.silent":
            FitnessText.string("event.\(kind)", locale: locale)
        default: kind
        }
    }

    public var detail: String {
        payload["note"]?.text ?? payload["reason"]?.text ?? payload["name"]?.text
            ?? FitnessText.string("diagnostic.detail.default")
    }

    public init(
        eventId: String,
        sequence: Int,
        timestamp: Date,
        elapsedMilliseconds: Int,
        kind: String,
        source: EvidenceSource,
        payload: [String: JSONValue]
    ) {
        self.eventId = eventId
        self.sequence = sequence
        self.timestamp = timestamp
        self.elapsedMilliseconds = elapsedMilliseconds
        self.kind = kind
        self.source = source
        self.payload = payload
    }
}

public struct CaptureGap: Codable, Equatable, Sendable {
    public let from: Date
    public let to: Date
    public let reason: String

    public init(
        from: Date,
        to: Date,
        reason: String
    ) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

public struct DiagnosticSession: Codable, Identifiable, Equatable, Sendable {
    public let sessionId: String
    public let startedAt: Date
    public var endedAt: Date?
    public var events: [DiagnosticEvent]
    public var totalEventCount: Int
    public var droppedEventCount: Int
    public var gaps: [CaptureGap]
    public var device: GATTDevice?
    public var bleObserved: Bool?
    public var distanceProgress: FTMSDistanceProgress?

    public var id: String { sessionId }
    public var isOpen: Bool { endedAt == nil }
    public var lastElapsedMilliseconds: Int { events.last?.elapsedMilliseconds ?? 0 }

    public init(
        sessionId: String,
        startedAt: Date,
        endedAt: Date? = nil,
        events: [DiagnosticEvent],
        totalEventCount: Int,
        droppedEventCount: Int,
        gaps: [CaptureGap],
        device: GATTDevice? = nil,
        bleObserved: Bool? = nil,
        distanceProgress: FTMSDistanceProgress? = nil
    ) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.events = events
        self.totalEventCount = totalEventCount
        self.droppedEventCount = droppedEventCount
        self.gaps = gaps
        self.device = device
        self.bleObserved = bleObserved
        self.distanceProgress = distanceProgress
    }
}

public enum EvidenceJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Timestamp ISO 8601 inválido")
            }
            return date
        }
        return decoder
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
