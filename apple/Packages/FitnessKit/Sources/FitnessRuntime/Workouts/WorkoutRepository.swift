import FitnessCore
import Foundation
import SQLite3

/// Durable, versioned record of one workout. The full event and sample streams
/// live in child tables and are loaded explicitly for review/export.
public struct WorkoutRecord: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var id: String
    public var schemaVersion: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var mode: String
    public var sessionId: String?
    public var program: WorkoutProgram?
    public var latestSnapshot: WorkoutSnapshot
    public var notes: [WorkoutNote]
    public var interrupted: Bool
    public var sampleCount: Int
    public var eventCount: Int
    public var healthSave: HealthSaveResult?

    public init(
        id: String = UUID().uuidString.lowercased(), startedAt: Date = Date(), endedAt: Date? = nil,
        mode: String, program: WorkoutProgram? = nil, latestSnapshot: WorkoutSnapshot,
        sessionId: String? = nil,
        notes: [WorkoutNote] = [], interrupted: Bool = false, sampleCount: Int = 0, eventCount: Int = 0,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.sessionId = sessionId
        self.program = program
        self.latestSnapshot = latestSnapshot
        self.notes = notes
        self.interrupted = interrupted
        self.sampleCount = sampleCount
        self.eventCount = eventCount
        self.healthSave = nil
    }
}

public struct WorkoutNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: Date
    public var source: String

    public init(
        id: String = UUID().uuidString.lowercased(), text: String, createdAt: Date = Date(),
        source: String = "operatorReported"
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.source = source
    }
}

/// A complete sample value with provenance retained per metric.
public struct WorkoutRecordedSample: Codable, Identifiable, Equatable, Sendable {
    public static func canonicalID(metric: String, eventID: String) -> String {
        "\(metric):\(eventID)"
    }
    public var id: String {
        Self.canonicalID(
            metric: metric, eventID: sample.eventId ?? "\(sample.receivedAt.timeIntervalSince1970)")
    }
    public var metric: String
    public var sample: WorkoutSample
    public var intervalIndex: Int?
    public var plannedSpeedKPH: Double?
    public var plannedInclinationPercent: Double?
    public var effectiveSpeedKPH: Double?
    public var effectiveInclinationPercent: Double?

    public init(
        metric: String, sample: WorkoutSample, intervalIndex: Int? = nil,
        plannedSpeedKPH: Double? = nil, plannedInclinationPercent: Double? = nil,
        effectiveSpeedKPH: Double? = nil, effectiveInclinationPercent: Double? = nil
    ) {
        self.metric = metric
        self.sample = sample
        self.intervalIndex = intervalIndex
        self.plannedSpeedKPH = plannedSpeedKPH
        self.plannedInclinationPercent = plannedInclinationPercent
        self.effectiveSpeedKPH = effectiveSpeedKPH
        self.effectiveInclinationPercent = effectiveInclinationPercent
    }

    /// A retry can have a new reception time, but it cannot change the value
    /// or its original provenance under the same canonical identity.
    public func sameIdentityContent(as other: Self) -> Bool {
        func sameStoredDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (.some(let lhs), .some(let rhs)):
                return EvidenceJSON.timestamp(lhs) == EvidenceJSON.timestamp(rhs)
            default: return false
            }
        }
        return metric == other.metric && sample.eventId == other.sample.eventId
            && sample.value == other.sample.value && sample.source == other.sample.source
            && sameStoredDate(sample.sampledAt, other.sample.sampledAt)
            && sample.sourceDevice == other.sample.sourceDevice
            && sample.sourceIdentifier == other.sample.sourceIdentifier
            && sample.aggregation == other.sample.aggregation
            && sameStoredDate(sample.periodStart, other.sample.periodStart)
    }
}

/// Runtime event log preserves original fields, provenance, and wall-clock time.
public struct WorkoutRuntimeEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sequence: Int
    public var occurredAt: Date
    public var kind: String
    public var source: String
    public var payload: [String: JSONValue]

    public init(
        id: String = UUID().uuidString.lowercased(), sequence: Int, occurredAt: Date = Date(),
        kind: String, source: String = "application", payload: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.kind = kind
        self.source = source
        self.payload = payload
    }
}

public enum WorkoutRepositoryError: LocalizedError {
    case unsupportedSchema(Int)
    case storage(String)
    case duplicateSample(String)
    case missingWorkout(String)

    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .unsupportedSchema(let version):
            FitnessText.format("error.repository.unsupportedSchema", locale: locale, version)
        case .storage(let message):
            FitnessText.format("error.repository.storage", locale: locale, message)
        case .duplicateSample(let key):
            FitnessText.format("error.repository.duplicateSample", locale: locale, key)
        case .missingWorkout(let id):
            FitnessText.format("error.repository.missingWorkout", locale: locale, id)
        }
    }
}

/// One SQLite database for editable programs and workout records. Saving a
/// snapshot with its new events and samples is one durable transaction.
public final class WorkoutRepository: @unchecked Sendable {
    public let url: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let sessionsDirectory = directory.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = sessionsDirectory.appendingPathComponent("session-log.sqlite")
        try database(create: true) { db in
            let version = try statement(db, "PRAGMA user_version") { stmt -> Int in
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure(db) }
                return Int(sqlite3_column_int(stmt, 0))
            }
            guard version <= 1 else { throw WorkoutRepositoryError.unsupportedSchema(version) }
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS programs (id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, body BLOB NOT NULL, updated REAL NOT NULL)"
            )
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS workouts (id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, body BLOB NOT NULL, updated REAL NOT NULL)"
            )
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS workout_samples (workout_id TEXT NOT NULL, sequence INTEGER NOT NULL, sample_id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(workout_id, sequence), UNIQUE(workout_id, sample_id))"
            )
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS workout_events (workout_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(workout_id, sequence), UNIQUE(workout_id, event_id))"
            )
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS workout_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            if version == 0 { try execute(db, "PRAGMA user_version = 1") }
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    public func saveProgram(_ program: WorkoutProgram) throws {
        let data = try EvidenceJSON.encoder().encode(program)
        try database { db in
            try statement(
                db,
                "INSERT INTO programs(id, schema_version, body, updated) VALUES (?, 1, ?, ?) ON CONFLICT(id) DO UPDATE SET schema_version = 1, body = excluded.body, updated = excluded.updated"
            ) { stmt in
                try bind(program.id, to: stmt, at: 1, db: db)
                try bind(data, to: stmt, at: 2, db: db)
                try bind(program.updatedAt.timeIntervalSince1970, to: stmt, at: 3, db: db)
                try done(db, stmt)
            }
        }
    }

    public func programs() throws -> [WorkoutProgram] {
        try database { db in
            try statement(db, "SELECT schema_version, body FROM programs ORDER BY updated DESC, id") {
                stmt in
                var values: [WorkoutProgram] = []
                while true {
                    let status = sqlite3_step(stmt)
                    if status == SQLITE_DONE { return values }
                    guard status == SQLITE_ROW else { throw failure(db) }
                    let version = Int(sqlite3_column_int(stmt, 0))
                    guard version == 1 else { throw WorkoutRepositoryError.unsupportedSchema(version) }
                    values.append(try EvidenceJSON.decoder().decode(WorkoutProgram.self, from: blob(stmt, 1)))
                }
            }
        }
    }

    public func seedDefaultsIfNeeded(_ defaults: [WorkoutProgram]) throws {
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let seeded = try statement(
                    db, "SELECT value FROM workout_metadata WHERE key = 'defaultProgramsSeeded'"
                ) { stmt -> Bool in
                    let status = sqlite3_step(stmt)
                    if status == SQLITE_DONE { return false }
                    guard status == SQLITE_ROW else { throw failure(db) }
                    guard let text = sqlite3_column_text(stmt, 0) else { throw failure(db) }
                    return String(decodingCString: text, as: UTF8.self) == "1"
                }
                if !seeded {
                    for program in defaults {
                        let data = try EvidenceJSON.encoder().encode(program)
                        try statement(
                            db,
                            "INSERT OR IGNORE INTO programs(id, schema_version, body, updated) VALUES (?, 1, ?, ?)"
                        ) { stmt in
                            try bind(program.id, to: stmt, at: 1, db: db)
                            try bind(data, to: stmt, at: 2, db: db)
                            try bind(program.updatedAt.timeIntervalSince1970, to: stmt, at: 3, db: db)
                            try done(db, stmt)
                        }
                    }
                    try execute(
                        db,
                        "INSERT OR REPLACE INTO workout_metadata(key, value) VALUES ('defaultProgramsSeeded', '1')"
                    )
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    public func deleteProgram(id: String) throws {
        try database { db in
            try statement(db, "DELETE FROM programs WHERE id = ?") { stmt in
                try bind(id, to: stmt, at: 1, db: db)
                try done(db, stmt)
            }
        }
    }

    public func clearAll() throws {
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "DELETE FROM workout_samples")
                try execute(db, "DELETE FROM workout_events")
                try execute(db, "DELETE FROM workouts")
                try execute(db, "DELETE FROM programs")
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    public func clearHistory() throws {
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "DELETE FROM workout_samples")
                try execute(db, "DELETE FROM workout_events")
                try execute(db, "DELETE FROM workouts")
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult public func save(
        _ record: WorkoutRecord, samples: [WorkoutRecordedSample] = [],
        events: [WorkoutRuntimeEvent] = []
    ) throws -> WorkoutRecord {
        guard (1...WorkoutRecord.currentSchemaVersion).contains(record.schemaVersion) else {
            throw WorkoutRepositoryError.unsupportedSchema(record.schemaVersion)
        }
        var snapshot = record
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try insertChildren(
                    db, table: "workout_samples", workoutId: record.id, rows: samples.map { ($0.id, $0) })
                try insertChildren(
                    db, table: "workout_events", workoutId: record.id, rows: events.map { ($0.id, $0) })
                snapshot.sampleCount = try childCount(db, table: "workout_samples", workoutId: record.id)
                snapshot.eventCount = try childCount(db, table: "workout_events", workoutId: record.id)
                let data = try EvidenceJSON.encoder().encode(snapshot)
                try statement(
                    db,
                    "INSERT INTO workouts(id, schema_version, body, updated) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET schema_version = excluded.schema_version, body = excluded.body, updated = excluded.updated"
                ) { stmt in
                    try bind(record.id, to: stmt, at: 1, db: db)
                    guard sqlite3_bind_int(stmt, 2, Int32(snapshot.schemaVersion)) == SQLITE_OK else {
                        throw failure(db)
                    }
                    try bind(data, to: stmt, at: 3, db: db)
                    try bind(Date().timeIntervalSince1970, to: stmt, at: 4, db: db)
                    try done(db, stmt)
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
        return snapshot
    }

    /// Durable transaction off the UI actor, serialized with session evidence
    /// writes that target the same SQLite file.
    @discardableResult public func saveAsync(
        _ record: WorkoutRecord, samples: [WorkoutRecordedSample] = [],
        events: [WorkoutRuntimeEvent] = []
    ) async throws -> WorkoutRecord {
        try await SQLiteWriteGate.shared.run {
            try self.save(record, samples: samples, events: events)
        }
    }

    public func recordAsync(id: String) async throws -> WorkoutRecord? {
        try await Task.detached(priority: .utility) { try self.record(id: id) }.value
    }

    public func historyAsync(limit: Int = 100) async throws -> [WorkoutRecord] {
        try await Task.detached(priority: .utility) { try self.history(limit: limit) }.value
    }

    public func detailsAsync(id: String) async throws -> (
        record: WorkoutRecord, samples: [WorkoutRecordedSample], events: [WorkoutRuntimeEvent]
    )? {
        try await Task.detached(priority: .utility) {
            guard let record = try self.record(id: id) else { return nil }
            return (record: record, samples: try self.samples(for: id), events: try self.events(for: id))
        }.value
    }

    public func containsEventAsync(workoutID: String, eventID: String) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try self.database { db in
                try self.statement(
                    db, "SELECT 1 FROM workout_events WHERE workout_id = ? AND event_id = ? LIMIT 1"
                ) { stmt in
                    try self.bind(workoutID, to: stmt, at: 1, db: db)
                    try self.bind(eventID, to: stmt, at: 2, db: db)
                    let result = sqlite3_step(stmt)
                    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.failure(db) }
                    return result == SQLITE_ROW
                }
            }
        }.value
    }

    public func existingSampleIDsAsync(workoutID: String, sampleIDs: [String]) async throws -> Set<
        String
    > {
        guard !sampleIDs.isEmpty else { return [] }
        return try await Task.detached(priority: .utility) {
            try self.database { db in
                let placeholders = Array(repeating: "?", count: sampleIDs.count).joined(separator: ",")
                return try self.statement(
                    db,
                    "SELECT sample_id FROM workout_samples WHERE workout_id = ? AND sample_id IN (\(placeholders))"
                ) { stmt in
                    try self.bind(workoutID, to: stmt, at: 1, db: db)
                    for (index, id) in sampleIDs.enumerated() {
                        try self.bind(id, to: stmt, at: Int32(index + 2), db: db)
                    }
                    var existing: Set<String> = []
                    while true {
                        let result = sqlite3_step(stmt)
                        if result == SQLITE_DONE { return existing }
                        guard result == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else {
                            throw self.failure(db)
                        }
                        existing.insert(String(decodingCString: value, as: UTF8.self))
                    }
                }
            }
        }.value
    }

    public func existingSamplesAsync(workoutID: String, sampleIDs: [String]) async throws -> [String:
        WorkoutRecordedSample]
    {
        guard !sampleIDs.isEmpty else { return [:] }
        return try await Task.detached(priority: .utility) {
            try self.database { db in
                let placeholders = Array(repeating: "?", count: sampleIDs.count).joined(separator: ",")
                return try self.statement(
                    db,
                    "SELECT sample_id, body FROM workout_samples WHERE workout_id = ? AND sample_id IN (\(placeholders))"
                ) { stmt in
                    try self.bind(workoutID, to: stmt, at: 1, db: db)
                    for (index, id) in sampleIDs.enumerated() {
                        try self.bind(id, to: stmt, at: Int32(index + 2), db: db)
                    }
                    var existing: [String: WorkoutRecordedSample] = [:]
                    while true {
                        let result = sqlite3_step(stmt)
                        if result == SQLITE_DONE { return existing }
                        guard result == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else {
                            throw self.failure(db)
                        }
                        existing[String(decodingCString: value, as: UTF8.self)] = try EvidenceJSON.decoder()
                            .decode(WorkoutRecordedSample.self, from: self.blob(stmt, 1))
                    }
                }
            }
        }.value
    }

    /// Appends capture samples against the latest stored record within one
    /// transaction. A delayed telemetry callback cannot restore older workout
    /// state over a completed or interrupted record.
    @discardableResult public func appendSamplesAsync(
        workoutID: String,
        samples: [WorkoutRecordedSample],
        event: WorkoutRuntimeEvent? = nil,
        healthResult: HealthSaveResult? = nil,
        snapshot: WorkoutSnapshot? = nil
    ) async throws -> WorkoutRecord {
        try await SQLiteWriteGate.shared.run {
            try self.database { db in
                try self.execute(db, "BEGIN IMMEDIATE")
                do {
                    guard
                        var current = try self.statement(
                            db, "SELECT schema_version, body FROM workouts WHERE id = ?",
                            { stmt -> WorkoutRecord? in
                                try self.bind(workoutID, to: stmt, at: 1, db: db)
                                let status = sqlite3_step(stmt)
                                if status == SQLITE_DONE { return nil }
                                guard status == SQLITE_ROW else { throw self.failure(db) }
                                let version = Int(sqlite3_column_int(stmt, 0))
                                guard (1...WorkoutRecord.currentSchemaVersion).contains(version) else {
                                    throw WorkoutRepositoryError.unsupportedSchema(version)
                                }
                                return try EvidenceJSON.decoder().decode(
                                    WorkoutRecord.self, from: self.blob(stmt, 1))
                            })
                    else { throw WorkoutRepositoryError.missingWorkout(workoutID) }
                    if let snapshot, current.endedAt == nil { current.latestSnapshot = snapshot }
                    if let healthResult {
                        let old = current.healthSave
                        let rank: [HealthSaveState: Int] = [
                            .notRequested: 0, .pending: 1, .saving: 2,
                            .failed: 3, .uncertain: 3, .discarded: 4, .saved: 5,
                        ]
                        if (rank[healthResult.state] ?? 0) >= (rank[old?.state ?? .notRequested] ?? 0),
                            healthResult.updatedAt >= (old?.updatedAt ?? .distantPast)
                                || healthResult.state == .saved
                        {
                            current.healthSave = healthResult
                        }
                    }
                    var unseen: [WorkoutRecordedSample] = []
                    var batchSamples: [String: WorkoutRecordedSample] = [:]
                    for sample in samples {
                        if let previous = batchSamples[sample.id] {
                            guard previous.sameIdentityContent(as: sample) else {
                                throw WorkoutRepositoryError.duplicateSample(sample.id)
                            }
                            continue
                        }
                        batchSamples[sample.id] = sample
                        let previous: WorkoutRecordedSample? = try self.statement(
                            db, "SELECT body FROM workout_samples WHERE workout_id = ? AND sample_id = ? LIMIT 1"
                        ) { stmt in
                            try self.bind(workoutID, to: stmt, at: 1, db: db)
                            try self.bind(sample.id, to: stmt, at: 2, db: db)
                            let status = sqlite3_step(stmt)
                            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw self.failure(db) }
                            return status == SQLITE_ROW
                                ? try EvidenceJSON.decoder().decode(
                                    WorkoutRecordedSample.self, from: self.blob(stmt, 0)) : nil
                        }
                        if let previous {
                            guard previous.sameIdentityContent(as: sample) else {
                                throw WorkoutRepositoryError.duplicateSample(sample.id)
                            }
                        } else {
                            unseen.append(sample)
                        }
                    }
                    try self.insertChildren(
                        db, table: "workout_samples", workoutId: workoutID, rows: unseen.map { ($0.id, $0) })
                    if var event {
                        let exists = try self.statement(
                            db, "SELECT 1 FROM workout_events WHERE workout_id = ? AND event_id = ? LIMIT 1"
                        ) { stmt in
                            try self.bind(workoutID, to: stmt, at: 1, db: db)
                            try self.bind(event.id, to: stmt, at: 2, db: db)
                            let status = sqlite3_step(stmt)
                            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw self.failure(db) }
                            return status == SQLITE_ROW
                        }
                        if !exists {
                            event.sequence =
                                try self.childCount(db, table: "workout_events", workoutId: workoutID) + 1
                            try self.insertChildren(
                                db, table: "workout_events", workoutId: workoutID, rows: [(event.id, event)])
                        }
                    }
                    current.sampleCount = try self.childCount(
                        db, table: "workout_samples", workoutId: workoutID)
                    current.eventCount = try self.childCount(
                        db, table: "workout_events", workoutId: workoutID)
                    let data = try EvidenceJSON.encoder().encode(current)
                    try self.statement(db, "UPDATE workouts SET body = ?, updated = ? WHERE id = ?") { stmt in
                        try self.bind(data, to: stmt, at: 1, db: db)
                        try self.bind(Date().timeIntervalSince1970, to: stmt, at: 2, db: db)
                        try self.bind(workoutID, to: stmt, at: 3, db: db)
                        try self.done(db, stmt)
                    }
                    try self.execute(db, "COMMIT")
                    return current
                } catch {
                    try? self.execute(db, "ROLLBACK")
                    throw error
                }
            }
        }
    }

    public func history(limit: Int = 100) throws -> [WorkoutRecord] {
        try database { db in
            try statement(db, "SELECT schema_version, body FROM workouts ORDER BY updated DESC LIMIT ?") {
                stmt in
                guard sqlite3_bind_int64(stmt, 1, Int64(max(1, limit))) == SQLITE_OK else {
                    throw failure(db)
                }
                var values: [WorkoutRecord] = []
                while true {
                    let status = sqlite3_step(stmt)
                    if status == SQLITE_DONE { return values }
                    guard status == SQLITE_ROW else { throw failure(db) }
                    let version = Int(sqlite3_column_int(stmt, 0))
                    guard (1...WorkoutRecord.currentSchemaVersion).contains(version) else {
                        throw WorkoutRepositoryError.unsupportedSchema(version)
                    }
                    values.append(try EvidenceJSON.decoder().decode(WorkoutRecord.self, from: blob(stmt, 1)))
                }
            }
        }
    }

    public func record(id: String) throws -> WorkoutRecord? {
        try database { db in
            try statement(db, "SELECT schema_version, body FROM workouts WHERE id = ?") { stmt in
                try bind(id, to: stmt, at: 1, db: db)
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return nil }
                guard status == SQLITE_ROW else { throw failure(db) }
                let version = Int(sqlite3_column_int(stmt, 0))
                guard (1...WorkoutRecord.currentSchemaVersion).contains(version) else {
                    throw WorkoutRepositoryError.unsupportedSchema(version)
                }
                return try EvidenceJSON.decoder().decode(WorkoutRecord.self, from: blob(stmt, 1))
            }
        }
    }

    public func samples(for workoutId: String) throws -> [WorkoutRecordedSample] {
        try children("workout_samples", workoutId: workoutId)
    }
    public func events(for workoutId: String) throws -> [WorkoutRuntimeEvent] {
        try children("workout_events", workoutId: workoutId)
    }

    private func children<T: Decodable>(_ table: String, workoutId: String) throws -> [T] {
        guard table == "workout_samples" || table == "workout_events" else { return [] }
        return try database { db in
            try statement(db, "SELECT body FROM \(table) WHERE workout_id = ? ORDER BY sequence") {
                stmt in
                try bind(workoutId, to: stmt, at: 1, db: db)
                var values: [T] = []
                while true {
                    let status = sqlite3_step(stmt)
                    if status == SQLITE_DONE { return values }
                    guard status == SQLITE_ROW else { throw failure(db) }
                    values.append(try EvidenceJSON.decoder().decode(T.self, from: blob(stmt, 0)))
                }
            }
        }
    }

    private func insertChildren<T: Encodable>(
        _ db: OpaquePointer, table: String, workoutId: String, rows: [(String, T)]
    ) throws {
        guard table == "workout_samples" || table == "workout_events" else { return }
        let idColumn = table == "workout_samples" ? "sample_id" : "event_id"
        let firstSequence = try statement(
            db, "SELECT COALESCE(MAX(sequence), 0) FROM \(table) WHERE workout_id = ?"
        ) { stmt -> Int64 in
            try bind(workoutId, to: stmt, at: 1, db: db)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure(db) }
            return sqlite3_column_int64(stmt, 0)
        }
        try statement(
            db, "INSERT INTO \(table)(workout_id, sequence, \(idColumn), body) VALUES (?, ?, ?, ?)"
        ) { stmt in
            for (offset, row) in rows.enumerated() {
                let sequence = firstSequence + Int64(offset + 1)
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bind(workoutId, to: stmt, at: 1, db: db)
                guard sqlite3_bind_int64(stmt, 2, sequence) == SQLITE_OK else { throw failure(db) }
                try bind(row.0, to: stmt, at: 3, db: db)
                // The database assigns the authoritative sequence. Keep the
                // serialized event in sync when a stale coordinator/repository
                // instance appends after another writer.
                var value = row.1
                if table == "workout_events", var event = row.1 as? WorkoutRuntimeEvent {
                    event.sequence = Int(sequence)
                    if let normalized = event as? T { value = normalized }
                }
                try bind(try EvidenceJSON.encoder().encode(value), to: stmt, at: 4, db: db)
                try done(db, stmt)
            }
        }
    }

    private func childCount(_ db: OpaquePointer, table: String, workoutId: String) throws -> Int {
        guard table == "workout_samples" || table == "workout_events" else { return 0 }
        return try statement(db, "SELECT COUNT(*) FROM \(table) WHERE workout_id = ?") { stmt in
            try bind(workoutId, to: stmt, at: 1, db: db)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure(db) }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func database<T>(create: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "No se pudo abrir."
            if let handle { sqlite3_close(handle) }
            throw WorkoutRepositoryError.storage(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        try execute(db, "PRAGMA journal_mode = DELETE")
        try execute(db, "PRAGMA synchronous = FULL")
        return try body(db)
    }
    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T)
        throws -> T
    {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else {
            throw failure(db)
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    private func done(_ db: OpaquePointer, _ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
    }
    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32, db: OpaquePointer)
        throws
    {
        let rc = value.withCString {
            sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard rc == SQLITE_OK else { throw failure(db) }
    }
    private func bind(_ value: Data, to stmt: OpaquePointer, at index: Int32, db: OpaquePointer)
        throws
    {
        let rc = value.withUnsafeBytes {
            sqlite3_bind_blob(
                stmt, index, $0.baseAddress, Int32($0.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard rc == SQLITE_OK else { throw failure(db) }
    }
    private func bind(_ value: Double, to stmt: OpaquePointer, at index: Int32, db: OpaquePointer)
        throws
    {
        guard value.isFinite, sqlite3_bind_double(stmt, index, value) == SQLITE_OK else {
            throw failure(db)
        }
    }
    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }
    private func failure(_ db: OpaquePointer) -> WorkoutRepositoryError {
        .storage(String(cString: sqlite3_errmsg(db)))
    }
}
