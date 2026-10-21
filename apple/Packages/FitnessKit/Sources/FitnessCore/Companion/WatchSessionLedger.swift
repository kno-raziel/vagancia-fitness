import Foundation

public struct WatchSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var captureState: WatchCaptureState = .preparing
    public var view: CompanionWorkoutView
    public var viewGate = CompanionViewGate()
    public var receivedCommandIDs: Set<String> = []
    public var samples: [WatchHealthSample] = []
    public var acknowledgedSampleIDs: Set<String> = []
    public var distance = HealthDistanceAccumulator()
    public var health = HealthSaveResult(state: .notRequested)
    /// Optional so journals written by 0.8.1 remain decodable.
    public var acknowledgedHealthResultIDs: Set<String>?
    /// Attempt metadata is optional to decode 0.8.1 journals unchanged.
    public var lastPreparationAttemptID: String?
    public var lastPreparationSequence: UInt64?
    public var cancelledPreparationAttemptIDs: Set<String>?
    public var captureRequestID: String?
    /// Written before calling HealthKit. This is not proof of collection.
    public var captureIntentAt: Date?
    public var captureStartedAt: Date?
    public var captureEndedAt: Date?
    public init(id: String, view: CompanionWorkoutView) {
        self.id = id
        self.view = view
        self.viewGate.begin(id)
    }
    /// Repeated views recover a dropped capture request. Terminal, synthetic,
    /// stale, or already-started sessions can never create another capture.
    public func canBeginCapture(from view: CompanionWorkoutView, now: Date = Date()) -> Bool {
        guard let request = view.captureRequest else { return false }
        return captureState == .prepared && captureIntentAt == nil && captureStartedAt == nil
            && !viewGate.terminal && !view.synthetic && view.endedAt == nil
            && [.running, .paused].contains(view.snapshot.state) && !request.id.isEmpty
            && request.requestedAt <= now.addingTimeInterval(5)
            && abs(view.generatedAt.timeIntervalSince(now)) <= 15
    }
    public var pendingSamples: [WatchHealthSample] {
        samples.filter { !acknowledgedSampleIDs.contains($0.id) }
    }
    public mutating func terminalHealthResultForDelivery() -> HealthSaveResult? {
        guard [.saved, .failed, .uncertain, .discarded].contains(health.state) else { return nil }
        if health.deliveryID == nil { health.deliveryID = UUID().uuidString.lowercased() }
        guard let deliveryID = health.deliveryID,
            acknowledgedHealthResultIDs?.contains(deliveryID) != true
        else { return nil }
        return health
    }
    public mutating func acknowledgeHealthResult(_ deliveryID: String) -> Bool {
        guard health.deliveryID == deliveryID else { return false }
        acknowledgedHealthResultIDs = (acknowledgedHealthResultIDs ?? []).union([deliveryID])
        return true
    }
    /// Reconciliation may return the same saved HealthKit workout repeatedly.
    /// Preserve its receipt; a genuine transition gets a new delivery identity.
    public mutating func replaceHealthResult(_ result: HealthSaveResult) {
        let sameResult: Bool
        if health.state == .saved, result.state == .saved,
            let oldUUID = health.workoutUUID, let newUUID = result.workoutUUID
        {
            sameResult = oldUUID == newUUID
        } else {
            sameResult =
                health.state == result.state && health.message == result.message
                && health.captureStartedAt == result.captureStartedAt
                && health.captureEndedAt == result.captureEndedAt
        }
        if sameResult { return }
        health = result
        health.deliveryID = nil
    }
    public mutating func beginCaptureIntent(requestID: String, at date: Date) -> Bool {
        guard captureState == .prepared, captureIntentAt == nil, captureStartedAt == nil,
            !viewGate.terminal, !requestID.isEmpty
        else { return false }
        captureRequestID = requestID
        captureIntentAt = date
        return true
    }
    public mutating func confirmCollection(startedAt date: Date) -> Bool {
        guard captureIntentAt != nil, captureRequestID != nil, captureStartedAt == nil else {
            return false
        }
        captureStartedAt = date
        captureState = .running
        health = HealthSaveResult(state: .pending, captureStartedAt: date)
        return true
    }
    /// Inspect the recovered HealthKit builder. Journaled intent alone never
    /// confirms collection or produces an acknowledgement to iPhone.
    public mutating func reconcileRecoveredCollection(
        builderStartAt date: Date?, workoutActive: Bool, builderEnded: Bool
    ) -> Bool {
        guard workoutActive, !builderEnded, let date else {
            if captureIntentAt != nil || captureStartedAt != nil { captureState = .recovering }
            return false
        }
        if captureStartedAt != nil {
            captureStartedAt = date
            return true
        }
        return confirmCollection(startedAt: date)
    }
    public func canDiscardPreparation(for sessionID: String) -> Bool {
        id == sessionID && [.preparing, .prepared, .failed].contains(captureState)
            && captureIntentAt == nil && captureStartedAt == nil
    }
    public func canFinishRecoveredCapture(builderSessionID: String?, collectionConfirmed: Bool)
        -> Bool
    {
        id == builderSessionID && collectionConfirmed && captureStartedAt != nil
            && captureState == .recovering && health.state == .pending && !viewGate.terminal
    }
    public func canYieldToNewPreparation(hasLiveWorkout: Bool) -> Bool {
        !hasLiveWorkout && [.ended, .failed].contains(captureState)
    }
    public mutating func add(_ sample: WatchHealthSample) -> Bool {
        guard sample.isValid, !samples.contains(where: { $0.id == sample.id }) else { return false }
        samples.append(sample)
        return true
    }
    public mutating func acknowledge(_ ids: [String]) {
        let known = Set(samples.map(\.id))
        acknowledgedSampleIDs.formUnion(ids.filter { known.contains($0) })
    }
    public mutating func beginHealthSave() -> Bool {
        guard health.state == .pending else { return false }
        health = HealthSaveResult(
            state: .saving, captureStartedAt: captureStartedAt, captureEndedAt: captureEndedAt,
            distanceMeters: distance.totalMeters)
        return true
    }
    public mutating func markRecovered() {
        if health.state == .saving {
            health.state = .uncertain
            health.message = "Se interrumpió el guardado. Se conciliará con Salud antes de repetirlo."
            health.updatedAt = Date()
        }
    }
}

/// Small app-local journal. A corrupt journal is surfaced, never reset silently.
/// Writes are atomic and remain available after first unlock for active workouts.
public final class WatchSessionLedger {
    public let url: URL
    public private(set) var sessions: [String: WatchSessionRecord]
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = directory.appendingPathComponent("watch-sessions-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            sessions = try JSONDecoder().decode(
                [String: WatchSessionRecord].self, from: Data(contentsOf: url))
        } else {
            sessions = [:]
        }
    }
    public func save(_ record: WatchSessionRecord) throws {
        var next = sessions
        next[record.id] = record
        let data = try JSONEncoder().encode(next)
        try data.write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sessions = next
    }
}
