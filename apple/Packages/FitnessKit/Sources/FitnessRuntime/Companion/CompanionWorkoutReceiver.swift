import FitnessCore
import Foundation

/// Persists incoming Watch data and terminal receipts before acknowledging
/// delivery. Control-plane status is routed before any workout-record guard.
@MainActor
final class CompanionWorkoutReceiver {
    struct Accepted {
        let record: WorkoutRecord
        let samples: [WorkoutRecordedSample]
        let shouldFinalize: Bool
        let statusRequested: Bool
    }

    private let repository: WorkoutRepository
    private let store: SessionStore
    private var terminalLedger: WatchTerminalResultLedger?
    private var rejectedAssembler: WatchRejectedEnvelopeAssembler?

    init(repository: WorkoutRepository, store: SessionStore, directory: URL) {
        self.repository = repository
        self.store = store
        terminalLedger = try? WatchTerminalResultLedger(directory: directory)
        rejectedAssembler = try? WatchRejectedEnvelopeAssembler(directory: directory)
    }

    func receive(
        _ message: CompanionMessage, pendingID: String?, cancelledIDs: Set<String>,
        companion: any WorkoutCompanion
    ) async throws -> Accepted? {
        guard message.sender == "watch" else { throw CompanionError.invalidMessage }
        if case .rejectedEnvelopeChunk(let chunk) = message.payload {
            guard let rejectedAssembler else {
                throw CompanionError.storage("Falta el registro de sobres rechazados.")
            }
            if let entryID = try await rejectedAssembler.accept(chunk) {
                companion.acknowledgeRejectedEnvelopes([entryID])
            }
            return nil
        }
        var route = CompanionInboundRoute(message, pendingID: pendingID, cancelledIDs: cancelledIDs)
        if case .terminalResult(var result) = route {
            guard result.state != .saved || UUID(uuidString: result.workoutUUID ?? "") != nil else {
                throw CompanionError.invalidMessage
            }
            if result.deliveryID == nil {
                result.deliveryID =
                    "legacy:\(message.sessionID):\(result.state.rawValue):\(Int(result.updatedAt.timeIntervalSince1970 * 1_000))"
            }
            route = .terminalResult(result)
        }
        if case .preparationReadiness = route, case .readiness(let status) = message.payload {
            if store.session?.isOpen == true {
                try await store.recordDurably(
                    kind: cancelledIDs.contains(message.sessionID)
                        ? "watch.readiness.stale" : "watch.preparation.readiness",
                    payload: [
                        "watchSessionID": .string(message.sessionID), "state": .string(status.state.rawValue),
                    ])
            }
            return nil
        }
        if case .terminalResult(let result) = route, let id = result.deliveryID,
            terminalLedger?.contains(sessionID: message.sessionID, deliveryID: id) == true
        {
            companion.acknowledgeHealthResult(sessionID: message.sessionID, resultID: id)
            return nil
        }
        let found = try await repository.recordAsync(id: message.sessionID)
        if found == nil, case .statusRequest = route {
            if store.session?.isOpen != true { try store.startSession() }
            try await store.recordDurably(
                kind: "watch.status.unknownSession",
                payload: [
                    "watchSessionID": .string(message.sessionID), "messageID": .string(message.id),
                    "classification": .string("remoteControlPlane"), "reason": .string("workoutRecordAbsent"),
                ])
            throw CompanionError.remoteSessionUnknown(message.sessionID)
        }
        if found == nil, case .terminalResult(let result) = route {
            guard let id = result.deliveryID else { throw CompanionError.invalidMessage }
            if store.session?.isOpen != true { try store.startSession() }
            let raw = try EvidenceJSON.decoder().decode(
                JSONValue.self, from: EvidenceJSON.encoder().encode(message))
            try await store.recordDurably(
                kind: "watch.terminal.orphaned",
                payload: [
                    "watchSessionID": .string(message.sessionID), "deliveryID": .string(id),
                    "message": raw, "classification": .string("terminalResultWithoutWorkout"),
                ], eventId: "watch-terminal:\(message.sessionID):\(id)")
            try acceptTerminal(result, sessionID: message.sessionID, companion: companion)
            return nil
        }
        guard var record = found, record.healthSave != nil else { throw CompanionError.invalidMessage }
        if case .terminalResult(let result) = route, let id = result.deliveryID,
            record.healthSave?.deliveryID == id
        {
            try acceptTerminal(result, sessionID: message.sessionID, companion: companion)
            return nil
        }
        let incomingID = "watch-message:\(message.id)"
        if try await repository.containsEventAsync(workoutID: record.id, eventID: incomingID) {
            if case .samples(let rows) = message.payload {
                companion.acknowledge(id: record.id, sampleIDs: rows.map(\.id))
            }
            if case .terminalResult(let result) = route {
                try acceptTerminal(result, sessionID: record.id, companion: companion)
            }
            return nil
        }
        var additions: [WorkoutRecordedSample] = []
        var healthResult: HealthSaveResult?
        if case .samples(let rows) = message.payload {
            guard rows.count <= 100, rows.allSatisfy(\.isValid) else {
                throw CompanionError.invalidMessage
            }
            let upperBound = Date().addingTimeInterval(30)
            let lowerBound = record.startedAt.addingTimeInterval(-5)
            if let outside = rows.first(where: { $0.sampledAt > upperBound || $0.sampledAt < lowerBound }) {
                throw CompanionError.sampleOutsideWorkoutWindow(outside.id)
            }
            let canonicalIDs = rows.map {
                WorkoutRecordedSample.canonicalID(metric: $0.metric, eventID: $0.id)
            }
            let existing = try await repository.existingSamplesAsync(
                workoutID: record.id, sampleIDs: canonicalIDs)
            for row in rows {
                let sample = WorkoutSample(
                    value: row.value, source: .watchHealthKit, receivedAt: Date(), eventId: row.id,
                    sampledAt: row.sampledAt, sourceDevice: row.device,
                    sourceIdentifier: row.sourceIdentifier,
                    aggregation: row.aggregation, periodStart: row.periodStart)
                let addition = WorkoutRecordedSample(metric: row.metric, sample: sample)
                if let previous = existing[addition.id] {
                    guard previous.sameIdentityContent(as: addition) else {
                        throw WorkoutRepositoryError.duplicateSample(addition.id)
                    }
                } else if let previous = additions.first(where: { $0.id == addition.id }) {
                    guard previous.sameIdentityContent(as: addition) else {
                        throw WorkoutRepositoryError.duplicateSample(addition.id)
                    }
                } else {
                    additions.append(addition)
                }
            }
        } else if case .terminalResult(let result) = route {
            healthResult = result
        } else if case .healthResult(let result) = message.payload {
            healthResult = result
        }
        record.schemaVersion = WorkoutRecord.currentSchemaVersion
        let raw = try EvidenceJSON.decoder().decode(
            JSONValue.self, from: EvidenceJSON.encoder().encode(message))
        let event = WorkoutRuntimeEvent(
            id: incomingID, sequence: record.eventCount + 1,
            kind: "watch.message.received", source: "watchHealthKit",
            payload: [
                "message": raw, "receivedAt": .string(Date().ISO8601Format()),
                "samplesStored": .number(Double(additions.count)),
            ])
        let committed = try await repository.appendSamplesAsync(
            workoutID: record.id,
            samples: additions, event: event, healthResult: healthResult)
        if store.session?.isOpen == true, store.session?.sessionId == record.sessionId {
            try await store.recordDurably(kind: event.kind, payload: event.payload)
        }
        if case .samples(let rows) = message.payload {
            companion.acknowledge(id: record.id, sampleIDs: rows.map(\.id))
        }
        if case .terminalResult(let result) = route {
            try acceptTerminal(result, sessionID: record.id, companion: companion)
        }
        let shouldFinalize: Bool = {
            if case .readiness(let status) = message.payload, committed.endedAt != nil {
                return [.running, .paused, .recovering, .prepared].contains(status.state)
            }
            return false
        }()
        let statusRequested: Bool = {
            if case .statusRequest = message.payload { true } else { false }
        }()
        return Accepted(
            record: committed, samples: additions,
            shouldFinalize: shouldFinalize, statusRequested: statusRequested)
    }

    private func acceptTerminal(
        _ result: HealthSaveResult, sessionID: String,
        companion: any WorkoutCompanion
    ) throws {
        guard let id = result.deliveryID, var terminalLedger else {
            throw CompanionError.storage("Falta el registro local de resultados terminales.")
        }
        try terminalLedger.accept(sessionID: sessionID, result: result)
        self.terminalLedger = terminalLedger
        companion.acknowledgeHealthResult(sessionID: sessionID, resultID: id)
    }
}
