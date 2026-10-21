import Foundation

/// Local watchdog only. Never sends BLE reads, writes, retries or motor orders.
public struct ReceptionStream: Codable, Equatable, Sendable {
    public let channel: String
    public let subscribedAt: Date
    public var lastReceivedAt: Date?
    public var lastEventId: String?
    public var silent = false
    public var lastGapFrom: Date?
    public var lastGapTo: Date?

    public init(
        channel: String,
        subscribedAt: Date,
        lastReceivedAt: Date? = nil,
        lastEventId: String? = nil,
        silent: Bool = false,
        lastGapFrom: Date? = nil,
        lastGapTo: Date? = nil
    ) {
        self.channel = channel
        self.subscribedAt = subscribedAt
        self.lastReceivedAt = lastReceivedAt
        self.lastEventId = lastEventId
        self.silent = silent
        self.lastGapFrom = lastGapFrom
        self.lastGapTo = lastGapTo
    }
}

public struct ReceptionHealth: Codable, Equatable, Sendable {
    public var streams: [ReceptionStream] = []
    public var lastQueryId: String?
    public var lastQueryAt: Date?
    public var lastQueryHex: String?
    public var lastQueryChannel: String?

    public mutating func subscribe(_ channel: String, at date: Date) {
        guard !streams.contains(where: { $0.channel == channel }) else { return }
        streams.append(ReceptionStream(channel: channel, subscribedAt: date))
    }

    /// Returns true only when a previously silent stream resumes.
    public mutating func received(_ channel: String, at date: Date, eventId: String) -> Bool {
        guard let i = streams.firstIndex(where: { $0.channel == channel }) else { return false }
        let previous = streams[i].lastReceivedAt ?? streams[i].subscribedAt
        // A suspended app may receive a new BLE callback before its local
        // timer runs. Preserve that observed gap even without an earlier alarm.
        let gap = date.timeIntervalSince(previous) > 5
        let resumed = streams[i].silent || gap
        if gap {
            streams[i].lastGapFrom = previous
            streams[i].lastGapTo = date
        }
        streams[i].lastReceivedAt = date
        streams[i].lastEventId = eventId
        streams[i].silent = false
        return resumed
    }

    public mutating func check(at date: Date) -> [String] {
        var changed: [String] = []
        for i in streams.indices where !streams[i].silent {
            if date.timeIntervalSince(streams[i].lastReceivedAt ?? streams[i].subscribedAt) > 5 {
                streams[i].silent = true
                changed.append(streams[i].channel)
            }
        }
        return changed
    }

    public init(
        streams: [ReceptionStream] = [],
        lastQueryId: String? = nil,
        lastQueryAt: Date? = nil,
        lastQueryHex: String? = nil,
        lastQueryChannel: String? = nil
    ) {
        self.streams = streams
        self.lastQueryId = lastQueryId
        self.lastQueryAt = lastQueryAt
        self.lastQueryHex = lastQueryHex
        self.lastQueryChannel = lastQueryChannel
    }
}
