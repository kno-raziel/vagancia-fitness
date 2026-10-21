import Foundation

public enum HealthSaveState: String, Codable, Sendable {
    case notRequested, pending, saving, saved, failed, uncertain, discarded
}

public struct HealthSaveResult: Codable, Equatable, Sendable {
    /// Stable identity for one terminal result, retained until the phone ACKs it.
    public var deliveryID: String?
    public var state: HealthSaveState
    public var workoutUUID: String?
    public var message: String?
    public var updatedAt: Date
    public var captureStartedAt: Date?
    public var captureEndedAt: Date?
    public var distanceMeters: Double?
    public var heartRateAverageBPM: Double?
    public var heartRateMaximumBPM: Double?
    public var activeEnergyKilocalories: Double?
    public init(
        state: HealthSaveState, workoutUUID: String? = nil, message: String? = nil,
        deliveryID: String? = nil,
        updatedAt: Date = Date(), captureStartedAt: Date? = nil, captureEndedAt: Date? = nil,
        distanceMeters: Double? = nil,
        heartRateAverageBPM: Double? = nil, heartRateMaximumBPM: Double? = nil,
        activeEnergyKilocalories: Double? = nil
    ) {
        self.state = state
        self.workoutUUID = workoutUUID
        self.message = message
        self.updatedAt = updatedAt
        self.deliveryID = deliveryID
        self.captureStartedAt = captureStartedAt
        self.captureEndedAt = captureEndedAt
        self.distanceMeters = distanceMeters
        self.heartRateAverageBPM = heartRateAverageBPM
        self.heartRateMaximumBPM = heartRateMaximumBPM
        self.activeEnergyKilocalories = activeEnergyKilocalories
    }
}

public enum WatchCaptureState: String, Codable, Sendable {
    case idle, accessNeeded, preparing, prepared, running, paused, ending, ended, conflict, failed,
        recovering
}

public struct WatchReadiness: Codable, Equatable, Sendable {
    public var state: WatchCaptureState
    public var accessReviewed: Bool
    public var canSaveWorkout: Bool
    public var message: String?
    public var updatedAt: Date
    public var captureRequestID: String?
    public var captureStartedAt: Date?
    public var blockingSessionID: String?
    public init(
        state: WatchCaptureState = .idle, accessReviewed: Bool = false, canSaveWorkout: Bool = false,
        message: String? = nil, updatedAt: Date = Date(), captureRequestID: String? = nil,
        captureStartedAt: Date? = nil,
        blockingSessionID: String? = nil
    ) {
        self.captureRequestID = captureRequestID
        self.captureStartedAt = captureStartedAt
        self.blockingSessionID = blockingSessionID
        self.state = state
        self.accessReviewed = accessReviewed
        self.canSaveWorkout = canSaveWorkout
        self.message = message
        self.updatedAt = updatedAt
    }
}

/// Device access is an observation in its own right, independent of a preparation.
public struct WatchAccessFacts: Codable, Equatable, Sendable {
    public var reviewed: Bool?
    public var canSaveWorkout: Bool?
    public var updatedAt: Date
    public init(reviewed: Bool? = nil, canSaveWorkout: Bool? = nil, updatedAt: Date = .distantPast) {
        self.reviewed = reviewed
        self.canSaveWorkout = canSaveWorkout
        self.updatedAt = updatedAt
    }
    public func isFresh(at date: Date = Date()) -> Bool {
        updatedAt != .distantPast && date.timeIntervalSince(updatedAt) >= 0
            && date.timeIntervalSince(updatedAt) < 30
    }
}

public struct WatchOrphanedPreparation: Equatable, Sendable {
    public let id: String
    public let state: WatchCaptureState
    public let message: String
    public init(id: String, state: WatchCaptureState, message: String) {
        self.id = id
        self.state = state
        self.message = message
    }
}

public struct WatchHealthSample: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let metric: String
    public let value: Double
    public let unit: String
    public let sampledAt: Date
    public let periodStart: Date
    public let device: String
    public let sourceIdentifier: String
    public let aggregation: String?
    public init(
        id: String = UUID().uuidString.lowercased(), metric: String, value: Double, unit: String,
        sampledAt: Date, periodStart: Date, device: String, sourceIdentifier: String,
        aggregation: String? = nil
    ) {
        self.id = id
        self.metric = metric
        self.value = value
        self.unit = unit
        self.sampledAt = sampledAt
        self.periodStart = periodStart
        self.device = device
        self.sourceIdentifier = sourceIdentifier
        self.aggregation = aggregation
    }
    public var isValid: Bool {
        value.isFinite && value >= 0 && periodStart <= sampledAt
            && ((metric == "heartRateBPM" && unit == "count/min" && value > 0 && value <= 300)
                || (metric == "energyKilocalories" && unit == "kcal"))
    }
}

/// Idempotent permission to start sensor capture, issued only after the iPhone
/// confirms its existing physical-start workflow. It carries no motor command.
public struct WatchCaptureRequest: Codable, Equatable, Sendable {
    public let id: String
    public let requestedAt: Date
    public init(id: String = UUID().uuidString.lowercased(), requestedAt: Date = Date()) {
        self.id = id
        self.requestedAt = requestedAt
    }
}

public struct CompanionWorkoutView: Codable, Equatable, Sendable {
    public let snapshot: WorkoutSnapshot
    public let metrics: [String: WorkoutSample]
    public let startedAt: Date?
    public let endedAt: Date?
    public let generatedAt: Date
    public let synthetic: Bool
    public var captureRequest: WatchCaptureRequest?
    public init(
        snapshot: WorkoutSnapshot, metrics: [String: WorkoutSample], startedAt: Date?, endedAt: Date?,
        generatedAt: Date = Date(), synthetic: Bool = false
    ) {
        self.snapshot = snapshot
        self.metrics = metrics
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.generatedAt = generatedAt
        self.synthetic = synthetic
    }
}

public enum CompanionPayload: Codable, Equatable, Sendable {
    case statusRequest
    case accessFacts(WatchAccessFacts)
    case readiness(WatchReadiness)
    case prepare(CompanionWorkoutView)
    case start(Date)
    case cancel
    case view(CompanionWorkoutView)
    case finish(CompanionWorkoutView)
    case samples([WatchHealthSample])
    case acknowledge([String])
    case healthResult(HealthSaveResult)
    case acknowledgeHealthResult(String)
    case rejectedEnvelopeChunk(WatchRejectedEnvelopeChunk)
    case acknowledgeRejectedEnvelopes([String])
    case requestRejectedEnvelopes
    case requestRejectedEnvelopeSnapshot(String)
    case rejectedEnvelopeSnapshot(WatchRejectedEnvelopeSnapshotReceipt)
    case resolvePreparation
    case reconcile
}

public struct CompanionMessage: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public let id: String
    public let sessionID: String
    /// New on 0.8.2; nil remains valid for 0.8.1 queued envelopes.
    public let attemptID: String?
    public let sender: String
    public let sequence: UInt64
    public let sentAt: Date
    public let payload: CompanionPayload
    public init(
        sessionID: String, sender: String, sequence: UInt64, payload: CompanionPayload,
        id: String = UUID().uuidString.lowercased(), sentAt: Date = Date(),
        version: Int = currentVersion,
        attemptID: String? = nil
    ) {
        self.version = version
        self.id = id
        self.sessionID = sessionID
        self.attemptID = attemptID
        self.sender = sender
        self.sequence = sequence
        self.sentAt = sentAt
        self.payload = payload
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512_000 else { throw CompanionError.invalidMessage }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == currentVersion, !value.id.isEmpty, value.id.count <= 128,
            value.sessionID.count <= 128, (value.attemptID?.count ?? 0) <= 128,
            ["iphone", "watch"].contains(value.sender)
        else { throw CompanionError.invalidMessage }
        return value
    }
}

public enum CompanionError: LocalizedError, Equatable {
    case invalidMessage, unavailable, notPrepared, timeout, conflict
    case remoteSessionUnknown(String)
    case sampleOutsideWorkoutWindow(String)
    case storage(String)
    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .invalidMessage: FitnessText.string("error.companion.invalidMessage", locale: locale)
        case .unavailable: FitnessText.string("error.companion.unavailable", locale: locale)
        case .notPrepared: FitnessText.string("error.companion.notPrepared", locale: locale)
        case .timeout: FitnessText.string("error.companion.timeout", locale: locale)
        case .conflict: FitnessText.string("error.companion.conflict", locale: locale)
        case .remoteSessionUnknown(let id):
            FitnessText.format("error.companion.remoteSessionUnknown", locale: locale, id)
        case .sampleOutsideWorkoutWindow(let id):
            FitnessText.format("error.companion.sampleOutsideWorkoutWindow", locale: locale, id)
        case .storage(let message):
            FitnessText.format("error.companion.storage", locale: locale, message)
        }
    }
}

/// State-only ordering. Sample batches are deduplicated by sample ID, not
/// sequence: late batches must never disappear behind a newer UI snapshot.
public struct CompanionViewGate: Codable, Equatable, Sendable {
    public private(set) var sessionID: String?
    public private(set) var sequence: UInt64 = 0
    public private(set) var terminal = false
    public init() {}
    public mutating func begin(_ id: String) {
        sessionID = id
        sequence = 0
        terminal = false
    }
    public mutating func accept(_ message: CompanionMessage, final: Bool = false) -> Bool {
        guard message.sessionID == sessionID, message.sequence > sequence, !terminal else {
            return false
        }
        sequence = message.sequence
        terminal = final
        return true
    }
}

/// Cumulative FTMS distance becomes one nonnegative increment per new sample.
/// A missing counter is not zero, and a restarted counter cannot subtract.
public struct HealthDistanceAccumulator: Codable, Equatable, Sendable {
    public private(set) var totalMeters: Double = 0
    public private(set) var lastSampleID: String?
    public private(set) var lastDate: Date?
    public init() {}
    public mutating func reconcileStoredTotal(_ meters: Double) {
        guard meters.isFinite, meters >= 0 else { return }
        totalMeters = max(totalMeters, meters)
    }
    public mutating func increment(for sample: WorkoutSample) -> Double? {
        guard sample.source == .derived || sample.source == .machineFTMS,
            sample.value.isFinite, sample.value >= totalMeters,
            sample.eventId != nil, sample.eventId != lastSampleID,
            lastDate == nil || sample.receivedAt > lastDate!
        else { return nil }
        let delta = sample.value - totalMeters
        totalMeters = sample.value
        lastSampleID = sample.eventId
        lastDate = sample.receivedAt
        return delta
    }
}
