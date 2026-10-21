import FitnessCore
import Foundation
import SQLite3

/// Serializes SQLite writes submitted by the session and workout background
/// writers. Both use session-log.sqlite and must not contend on MainActor.
actor SQLiteWriteGate {
    static let shared = SQLiteWriteGate()

    func run<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T { try body() }
}

/// SQLite is supplied by iOS. Each event and its latest device/session state are
/// committed together; the UI cache is never the source of exported evidence.
struct SessionJournal: Sendable {
    let url: URL

    struct StorageError: LocalizedError {
        let message: String
        var errorDescription: String? { FitnessText.format("error.journal.storage", message) }
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        url = directory.appendingPathComponent("session-log.sqlite")
        try database(create: true) { db in
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, snapshot BLOB NOT NULL, updated REAL NOT NULL)"
            )
            try execute(
                db,
                "CREATE TABLE IF NOT EXISTS events (session_id TEXT NOT NULL, sequence INTEGER NOT NULL, event BLOB NOT NULL, PRIMARY KEY(session_id, sequence))"
            )
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    func contains(_ id: String) throws -> Bool {
        try database { db in
            try statement(db, "SELECT 1 FROM sessions WHERE id = ?") { stmt in
                try bind(id, to: stmt, at: 1, db: db)
                let result = sqlite3_step(stmt)
                guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure(db) }
                return result == SQLITE_ROW
            }
        }
    }

    func latest(cacheLimit: Int) throws -> DiagnosticSession? {
        try database { db in
            try statement(db, "SELECT snapshot FROM sessions ORDER BY updated DESC, rowid DESC LIMIT 1") {
                stmt in
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw failure(db) }
                var session = try EvidenceJSON.decoder().decode(
                    DiagnosticSession.self, from: blob(stmt, column: 0))
                session.events = try events(db, sessionId: session.sessionId, limit: cacheLimit)
                return session
            }
        }
    }

    func session(id: String, cacheLimit: Int? = nil) throws -> DiagnosticSession? {
        try database { db in
            try statement(db, "SELECT snapshot FROM sessions WHERE id = ?") { stmt in
                try bind(id, to: stmt, at: 1, db: db)
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw failure(db) }
                var value = try EvidenceJSON.decoder().decode(
                    DiagnosticSession.self, from: blob(stmt, column: 0))
                value.events = try events(db, sessionId: id, limit: cacheLimit)
                return value
            }
        }
    }

    func allEvents(sessionId: String) throws -> [DiagnosticEvent] {
        try database { try events($0, sessionId: sessionId, limit: nil) }
    }

    /// Snapshot metadata and event rows from one SQLite read transaction so
    /// streaming telemetry cannot change the count between the two reads.
    func exportSnapshot(sessionId: String) throws -> DiagnosticSession? {
        try database { db in
            try execute(db, "BEGIN")
            do {
                let value = try statement(db, "SELECT snapshot FROM sessions WHERE id = ?") {
                    stmt -> DiagnosticSession? in
                    try bind(sessionId, to: stmt, at: 1, db: db)
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE { return nil }
                    guard result == SQLITE_ROW else { throw failure(db) }
                    return try EvidenceJSON.decoder().decode(
                        DiagnosticSession.self, from: blob(stmt, column: 0))
                }
                guard var value else {
                    try execute(db, "COMMIT")
                    return nil
                }
                value.events = try events(db, sessionId: sessionId, limit: nil)
                try execute(db, "COMMIT")
                return value
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func deleteSession(id: String) throws {
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                for table in ["events", "sessions"] {
                    let column = table == "events" ? "session_id" : "id"
                    try statement(db, "DELETE FROM \(table) WHERE \(column) = ?") { stmt in
                        try bind(id, to: stmt, at: 1, db: db)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
                    }
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// `events` contains only the new event during capture, or the retained legacy
    /// history during migration. A duplicate sequence is an error, never replaced.
    func save(_ session: DiagnosticSession, events: [DiagnosticEvent], updatedAt: Date = Date())
        throws
    {
        var snapshot = session
        snapshot.events = []
        let data = try EvidenceJSON.encoder().encode(snapshot)
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try statement(db, "INSERT INTO events(session_id, sequence, event) VALUES (?, ?, ?)") {
                    stmt in
                    for event in events {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        try bind(session.sessionId, to: stmt, at: 1, db: db)
                        guard sqlite3_bind_int64(stmt, 2, Int64(event.sequence)) == SQLITE_OK else {
                            throw failure(db)
                        }
                        try bind(try EvidenceJSON.encoder().encode(event), to: stmt, at: 3, db: db)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
                    }
                }
                try statement(
                    db,
                    "INSERT INTO sessions(id, snapshot, updated) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET snapshot = excluded.snapshot, updated = excluded.updated"
                ) { stmt in
                    try bind(session.sessionId, to: stmt, at: 1, db: db)
                    try bind(data, to: stmt, at: 2, db: db)
                    guard sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970) == SQLITE_OK,
                        sqlite3_step(stmt) == SQLITE_DONE
                    else { throw failure(db) }
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// Appends one live event using the committed database sequence as the
    /// source of truth. SessionStore is normally the sole writer, but lifecycle
    /// callbacks and a recreated coordinator can briefly hold stale snapshots.
    /// Reconcile inside the same transaction that inserts the event and updates
    /// the session snapshot so a retry cannot collide with an already committed
    /// sequence.
    func append(
        _ session: DiagnosticSession, event: DiagnosticEvent,
        prior: DiagnosticSession? = nil, updatedAt: Date = Date()
    ) throws -> DiagnosticEvent {
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let storedMaximum = try statement(
                    db, "SELECT COALESCE(MAX(sequence), 0) FROM events WHERE session_id = ?"
                ) { stmt in
                    try bind(session.sessionId, to: stmt, at: 1, db: db)
                    guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure(db) }
                    return Int(sqlite3_column_int64(stmt, 0))
                }
                let sequence = max(storedMaximum, session.totalEventCount - 1) + 1
                let committedEvent = DiagnosticEvent(
                    eventId: event.eventId, sequence: sequence,
                    timestamp: event.timestamp, elapsedMilliseconds: event.elapsedMilliseconds,
                    kind: event.kind, source: event.source, payload: event.payload)
                var committedSession = session
                if let prior, prior.totalEventCount != storedMaximum {
                    // Another writer advanced this session. Apply only fields
                    // changed by this event to the latest committed metadata.
                    // Reading the small snapshot here avoids rereading events.
                    let latest = try statement(db, "SELECT snapshot FROM sessions WHERE id = ?") {
                        stmt -> DiagnosticSession? in
                        try bind(session.sessionId, to: stmt, at: 1, db: db)
                        let result = sqlite3_step(stmt)
                        if result == SQLITE_DONE { return nil }
                        guard result == SQLITE_ROW else { throw failure(db) }
                        return try EvidenceJSON.decoder().decode(
                            DiagnosticSession.self, from: blob(stmt, column: 0))
                    }
                    guard let latest else {
                        throw StorageError(message: "La sesión cambió o fue eliminada durante la escritura.")
                    }
                    committedSession = reconcile(latest: latest, prior: prior, incoming: session)
                }
                committedSession.totalEventCount = sequence
                committedSession.events = [committedEvent]
                let snapshotData = try EvidenceJSON.encoder().encode(
                    {
                        var snapshot = committedSession
                        snapshot.events = []
                        return snapshot
                    }())
                let eventData = try EvidenceJSON.encoder().encode(committedEvent)
                try statement(db, "INSERT INTO events(session_id, sequence, event) VALUES (?, ?, ?)") {
                    stmt in
                    try bind(session.sessionId, to: stmt, at: 1, db: db)
                    guard sqlite3_bind_int64(stmt, 2, Int64(sequence)) == SQLITE_OK else { throw failure(db) }
                    try bind(eventData, to: stmt, at: 3, db: db)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
                }
                try statement(
                    db,
                    "INSERT INTO sessions(id, snapshot, updated) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET snapshot = excluded.snapshot, updated = excluded.updated"
                ) { stmt in
                    try bind(session.sessionId, to: stmt, at: 1, db: db)
                    try bind(snapshotData, to: stmt, at: 2, db: db)
                    guard sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970) == SQLITE_OK,
                        sqlite3_step(stmt) == SQLITE_DONE
                    else { throw failure(db) }
                }
                try execute(db, "COMMIT")
                return committedEvent
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    private func reconcile(
        latest: DiagnosticSession, prior: DiagnosticSession,
        incoming: DiagnosticSession
    ) -> DiagnosticSession {
        var result = latest
        if incoming.device != prior.device { result.device = incoming.device }
        if incoming.distanceProgress != prior.distanceProgress {
            result.distanceProgress = incoming.distanceProgress
        }
        if incoming.endedAt != prior.endedAt, let end = incoming.endedAt { result.endedAt = end }
        if incoming.bleObserved == true { result.bleObserved = true }
        result.droppedEventCount = max(latest.droppedEventCount, incoming.droppedEventCount)
        for gap in incoming.gaps where !prior.gaps.contains(gap) && !result.gaps.contains(gap) {
            result.gaps.append(gap)
        }
        return result
    }

    private func events(_ db: OpaquePointer, sessionId: String, limit: Int?) throws
        -> [DiagnosticEvent]
    {
        let sql =
            limit == nil
            ? "SELECT event FROM events WHERE session_id = ? ORDER BY sequence"
            : "SELECT event FROM (SELECT sequence, event FROM events WHERE session_id = ? ORDER BY sequence DESC LIMIT ?) ORDER BY sequence"
        return try statement(db, sql) { stmt in
            try bind(sessionId, to: stmt, at: 1, db: db)
            if let limit {
                guard sqlite3_bind_int64(stmt, 2, Int64(limit)) == SQLITE_OK else { throw failure(db) }
            }
            var result: [DiagnosticEvent] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw failure(db) }
                result.append(
                    try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: blob(stmt, column: 0)))
            }
        }
    }

    private func database<T>(create: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let db = handle else {
            let message =
                handle.map { String(cString: sqlite3_errmsg($0)) } ?? "No se pudo abrir el archivo."
            if let handle { sqlite3_close(handle) }
            throw StorageError(message: message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        // DELETE avoids WAL sidecar lifetime/protection surprises. FULL makes a
        // successful return mean both event and metadata passed durable COMMIT.
        try execute(db, "PRAGMA journal_mode = DELETE")
        try execute(db, "PRAGMA synchronous = FULL")
        return try body(db)
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T)
        throws -> T
    {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {
            throw failure(db)
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }

    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32, db: OpaquePointer)
        throws
    {
        let result = value.withCString {
            sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw failure(db) }
    }

    private func bind(_ value: Data, to stmt: OpaquePointer, at index: Int32, db: OpaquePointer)
        throws
    {
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(
                stmt, index, $0.baseAddress, Int32($0.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw failure(db) }
    }

    private func blob(_ stmt: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private func failure(_ db: OpaquePointer) -> StorageError {
        StorageError(message: String(cString: sqlite3_errmsg(db)))
    }
}
