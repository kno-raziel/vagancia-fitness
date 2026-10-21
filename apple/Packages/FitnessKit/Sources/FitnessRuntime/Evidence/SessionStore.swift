import FitnessCore
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

public enum SessionError: LocalizedError {
    case storageUnavailable, alreadyOpen, noOpenSession, emptyNote, noteTooLong, noSession,
        pendingWrites

    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .storageUnavailable: FitnessText.string("error.session.storageUnavailable", locale: locale)
        case .alreadyOpen: FitnessText.string("error.session.alreadyOpen", locale: locale)
        case .noOpenSession: FitnessText.string("error.session.noOpenSession", locale: locale)
        case .emptyNote: FitnessText.string("error.session.emptyNote", locale: locale)
        case .noteTooLong: FitnessText.string("error.session.noteTooLong", locale: locale)
        case .noSession: FitnessText.string("error.session.noSession", locale: locale)
        case .pendingWrites: FitnessText.string("error.session.pendingWrites", locale: locale)
        }
    }
}

@MainActor @Observable
public final class SessionStore {
    public private(set) var session: DiagnosticSession?
    public private(set) var storageReady = false
    public private(set) var startupError: String?
    public private(set) var pendingEventCount = 0
    public private(set) var persistenceError: String?
    /// Latest accepted telemetry state, including events awaiting the UI's
    /// bounded publication. Consumers that calculate samples need this value.
    public var currentDistanceProgress: FTMSDistanceProgress? { workingSession?.distanceProgress }
    @ObservationIgnored public var onPersistenceFailure: (@MainActor (String) -> Void)?

    public let directory: URL
    // Only limits the recent in-memory/UI window. Disk evidence is not pruned.
    private let maxEvents: Int
    @ObservationIgnored private var journal: SessionJournal?
    @ObservationIgnored private var workingSession: DiagnosticSession?
    private struct PendingWrite: Sendable {
        let generation: Int
        let snapshot: DiagnosticSession
        let event: DiagnosticEvent
        let base: DiagnosticSession?
        let journal: SessionJournal
    }
    @ObservationIgnored private var writeQueue: [PendingWrite] = []
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var writeWaiters:
        [(generation: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    @ObservationIgnored private var committedGeneration = 0
    @ObservationIgnored private var reconciledGeneration = 0
    @ObservationIgnored private var writerFailure: (any Error)?
    @ObservationIgnored private var enqueueGeneration = 0
    @ObservationIgnored private var lastPublishedUptime = 0.0
    @ObservationIgnored private var publicationTask: Task<Void, Never>?
    @ObservationIgnored private let writerDelay: Duration?
    #if canImport(UIKit)
        @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var originUptime = ProcessInfo.processInfo.systemUptime
    private var elapsedOffset = 0

    public init(directory: URL, maxEvents: Int = 1_000, writerDelay: Duration? = nil) {
        self.directory = directory
        self.maxEvents = max(2, maxEvents)
        self.writerDelay = writerDelay
        do { try reload() } catch { startupError = error.localizedDescription }
    }

    public func reload() throws {
        guard pendingEventCount == 0 else { throw SessionError.pendingWrites }
        storageReady = false
        let sessionsDirectory = directory.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        .filter { $0.pathExtension == "json" }
        let legacyFiles = try files.map { url in
            (
                url,
                try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    ?? .distantPast
            )
        }.sorted { $0.1 < $1.1 }
        let journal = try SessionJournal(directory: sessionsDirectory)
        // Keep original JSON files. Import each once, including the old loss
        // counter: migration cannot recover evidence discarded by older builds.
        for (url, modified) in legacyFiles {
            let legacy = try EvidenceJSON.decoder().decode(
                DiagnosticSession.self, from: Data(contentsOf: url))
            if try !journal.contains(legacy.sessionId) {
                try journal.save(legacy, events: legacy.events, updatedAt: modified)
            }
        }
        self.journal = journal
        var recovered = try journal.latest(cacheLimit: maxEvents)
        originUptime = ProcessInfo.processInfo.systemUptime
        elapsedOffset = recovered?.lastElapsedMilliseconds ?? 0
        if var current = recovered, current.isOpen {
            if current.device != nil {
                current.device?.connectionState = "notConnectedAfterRestore"
                current.device?.endPendingDiscovery(as: "interrupted")
                current.device?.interruptTelemetry()
            }
            let now = Date()
            if let previous = current.events.last?.timestamp {
                current.gaps.append(
                    CaptureGap(from: previous, to: now, reason: "appNotRunningOrCaptureUnobserved"))
            }
            append(
                to: &current, kind: "session.restored",
                payload: [
                    "reason": .string(
                        "Registro recuperado. No hubo captura mientras la app no estaba ejecutándose.")
                ], at: now)
            recovered = try persist(current, prior: recovered)
        }
        session = recovered
        workingSession = recovered
        reconciledGeneration = enqueueGeneration
        storageReady = true
        startupError = nil
    }

    public func startSession() throws {
        guard storageReady else { throw SessionError.storageUnavailable }
        guard pendingEventCount == 0 else { throw SessionError.pendingWrites }
        guard workingSession?.isOpen != true else { throw SessionError.alreadyOpen }
        let now = Date()
        originUptime = ProcessInfo.processInfo.systemUptime
        elapsedOffset = 0
        var next = DiagnosticSession(
            sessionId: UUID().uuidString.lowercased(), startedAt: now, endedAt: nil, events: [],
            totalEventCount: 0, droppedEventCount: 0, gaps: [])
        append(
            to: &next, kind: "session.created",
            payload: ["hardwareConnected": .bool(false), "captureMode": .string("sessionOnly")], at: now)
        session = try persist(next)
        workingSession = session
    }

    public func addNote(_ text: String) throws {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw SessionError.emptyNote }
        guard note.count <= 2_000 else { throw SessionError.noteTooLong }
        try record(kind: "operator.note", source: .userReported, payload: ["note": .string(note)])
    }

    public func closeSession() throws {
        guard var next = workingSession, next.isOpen else { throw SessionError.noOpenSession }
        let now = Date()
        append(
            to: &next, kind: "session.closed",
            payload: ["reason": .string("Finalizada por el operador.")], at: now)
        next.endedAt = now
        try enqueue(next, prior: workingSession)
    }

    public func recordLifecycle(_ state: String) throws {
        guard workingSession?.isOpen == true else { return }
        try record(
            kind: state == "background" ? "app.backgrounded" : "app.activated",
            payload: ["appState": .string(state)])
    }

    public func export(
        metadata: AppMetadata, watchDiagnostics: WatchDiagnosticExportSnapshot? = nil,
        profile: DiagnosticExportProfile = .complete
    ) throws -> DiagnosticExport {
        guard pendingEventCount == 0 else { throw SessionError.pendingWrites }
        guard let session else { throw SessionError.noSession }
        return try export(
            sessionId: session.sessionId, metadata: metadata, watchDiagnostics: watchDiagnostics,
            profile: profile)
    }

    public func export(
        sessionId: String, metadata: AppMetadata, workout: JSONValue? = nil,
        watchDiagnostics: WatchDiagnosticExportSnapshot? = nil,
        profile: DiagnosticExportProfile = .complete
    ) throws -> DiagnosticExport {
        guard pendingEventCount == 0 else { throw SessionError.pendingWrites }
        guard let journal else { throw SessionError.storageUnavailable }
        guard let snapshot = try journal.exportSnapshot(sessionId: sessionId) else {
            throw SessionError.noSession
        }
        guard snapshot.events.count + snapshot.droppedEventCount == snapshot.totalEventCount else {
            throw SessionJournal.StorageError(
                message:
                    "El número de eventos no coincide con la sesión; se conserva el registro para revisarlo.")
        }
        return try DiagnosticExporter.export(
            session: snapshot, metadata: metadata,
            directory: directory.appendingPathComponent("Exports", isDirectory: true), workout: workout,
            watchDiagnostics: watchDiagnostics, profile: profile)
    }

    public func exportAsync(
        metadata: AppMetadata, watchDiagnostics: WatchDiagnosticExportSnapshot? = nil,
        profile: DiagnosticExportProfile = .complete
    ) async throws -> DiagnosticExport {
        guard let id = workingSession?.sessionId else { throw SessionError.noSession }
        return try await exportAsync(
            sessionId: id, metadata: metadata, watchDiagnostics: watchDiagnostics, profile: profile)
    }

    public func exportAsync(
        sessionId: String, metadata: AppMetadata, workout: JSONValue? = nil,
        watchDiagnostics: WatchDiagnosticExportSnapshot? = nil,
        profile: DiagnosticExportProfile = .complete
    ) async throws -> DiagnosticExport {
        try await flush()
        guard let journal else { throw SessionError.storageUnavailable }
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        return try await Task.detached(priority: .utility) {
            guard let snapshot = try journal.exportSnapshot(sessionId: sessionId) else {
                throw SessionError.noSession
            }
            guard snapshot.events.count + snapshot.droppedEventCount == snapshot.totalEventCount else {
                throw SessionJournal.StorageError(
                    message:
                        "El número de eventos no coincide con la sesión; se conserva el registro para revisarlo."
                )
            }
            return try DiagnosticExporter.export(
                session: snapshot, metadata: metadata, directory: exports, workout: workout,
                watchDiagnostics: watchDiagnostics, profile: profile)
        }.value
    }

    public func deleteSession(id: String) throws {
        guard pendingEventCount == 0 else { throw SessionError.pendingWrites }
        guard let journal else { throw SessionError.storageUnavailable }
        guard !(session?.sessionId == id && session?.isOpen == true) else {
            throw SessionError.alreadyOpen
        }
        // Delete legacy imports too, so a subsequent reload cannot resurrect them.
        let sessionsDirectory = directory.appendingPathComponent("Sessions", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
                let legacy = try? EvidenceJSON.decoder().decode(DiagnosticSession.self, from: data),
                legacy.sessionId == id
            {
                try FileManager.default.removeItem(at: file)
            }
        }
        try journal.deleteSession(id: id)
        if session?.sessionId == id { session = nil }
    }

    public func record(
        kind: String, source: EvidenceSource = .application, payload: [String: JSONValue],
        device: GATTDevice? = nil, eventId: String = UUID().uuidString.lowercased()
    ) throws {
        guard var next = workingSession, next.isOpen else { throw SessionError.noOpenSession }
        guard persistenceError == nil else { throw SessionError.storageUnavailable }
        let now = Date()
        var payload = payload
        if let device { next.device = device }
        if kind == "ftms.treadmill.received", source == .hardware || source == .synthetic,
            case .object(let sample) = payload["sample"],
            case .number(let counter) = sample["distanceMeters"],
            counter.isFinite, counter >= 0, counter <= 0xFFFFFF, counter.rounded() == counter,
            let inspection = payload["inspectionId"]?.text
        {
            var progress = next.distanceProgress ?? FTMSDistanceProgress()
            progress.observe(UInt32(counter), inspectionId: inspection, at: now, eventId: eventId)
            next.distanceProgress = progress
            payload["distanceProgress"] = .object([
                "accumulatedMeters": .number(Double(progress.accumulatedMeters)),
                "zeroResetCount": .number(Double(progress.zeroResetCount)),
                "discontinuityCount": .number(Double(progress.discontinuityCount)),
                "lastCounterMeters": progress.lastCounterMeters.map { .number(Double($0)) } ?? .null,
                "lastInspectionId": progress.lastInspectionId.map(JSONValue.string) ?? .null,
                "lastReceivedAt": progress.lastReceivedAt.map { .string(EvidenceJSON.timestamp($0)) }
                    ?? .null,
                "lastEventId": progress.lastEventId.map(JSONValue.string) ?? .null,
                "lastTransition": .string(progress.lastTransition),
            ])
        }
        if kind.hasPrefix("ble.") { next.bleObserved = true }
        append(to: &next, kind: kind, source: source, payload: payload, at: now, eventId: eventId)
        try enqueue(next, prior: workingSession, publishImmediately: kind != "ftms.treadmill.received")
    }

    /// Completes every write accepted before the barrier, then reconciles the
    /// in-memory window with the committed SQLite sequence. A failed writer is
    /// never silently retried or presented as durable evidence.
    public func flush() async throws {
        if let writerFailure { throw writerFailure }
        guard enqueueGeneration > reconciledGeneration else {
            if let persistenceError { throw SessionJournal.StorageError(message: persistenceError) }
            return
        }
        let generation = enqueueGeneration
        if committedGeneration < generation {
            try await withCheckedThrowingContinuation { continuation in
                writeWaiters.append((generation, continuation))
            }
        }
        // Writes accepted after this barrier must remain in the live cache.
        guard generation == enqueueGeneration else { return }
        guard let journal else { throw SessionError.storageUnavailable }
        guard let sessionId = workingSession?.sessionId else { throw SessionError.noSession }
        let limit = maxEvents
        let committed = try await Task.detached(priority: .utility) {
            try journal.session(id: sessionId, cacheLimit: limit)
        }.value
        guard generation == enqueueGeneration else { return }
        session = committed
        workingSession = committed
        reconciledGeneration = generation
        if let persistenceError { throw SessionJournal.StorageError(message: persistenceError) }
    }

    public func recordDurably(
        kind: String, source: EvidenceSource = .application,
        payload: [String: JSONValue], device: GATTDevice? = nil,
        eventId: String = UUID().uuidString.lowercased()
    ) async throws {
        try record(kind: kind, source: source, payload: payload, device: device, eventId: eventId)
        try await flush()
    }

    private func enqueue(
        _ next: DiagnosticSession, prior: DiagnosticSession?, publishImmediately: Bool = true
    ) throws {
        guard let journal, let event = next.events.last else { throw SessionError.storageUnavailable }
        let snapshot: DiagnosticSession = {
            var value = next
            value.events = [event]
            return value
        }()
        let base: DiagnosticSession? = {
            var value = prior
            value?.events = []
            return value
        }()
        pendingEventCount += 1
        beginBackgroundLeaseIfNeeded()
        enqueueGeneration += 1
        workingSession = next
        let now = ProcessInfo.processInfo.systemUptime
        if publishImmediately || now - lastPublishedUptime >= 0.1 {
            publicationTask?.cancel()
            publicationTask = nil
            session = next
            lastPublishedUptime = now
        } else if publicationTask == nil {
            publicationTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.session = self.workingSession
                self.lastPublishedUptime = ProcessInfo.processInfo.systemUptime
                self.publicationTask = nil
            }
        }
        writeQueue.append(
            PendingWrite(
                generation: enqueueGeneration, snapshot: snapshot,
                event: event, base: base, journal: journal))
        if writerTask == nil {
            writerTask = Task.detached(priority: .utility) { [self] in
                await drainWrites()
            }
        }
    }

    /// One worker drains the FIFO. A task per event creates an arbitrarily deep
    /// task-dependency chain when BLE notifications arrive faster than SQLite.
    private func drainWrites() async {
        while !writeQueue.isEmpty {
            let job = writeQueue.removeFirst()
            do {
                if let writerDelay { try await Task.sleep(for: writerDelay) }
                _ = try await SQLiteWriteGate.shared.run {
                    try job.journal.append(job.snapshot, event: job.event, prior: job.base)
                }
                writeCompleted(generation: job.generation)
            } catch {
                writeFailed(error)
                writerTask = nil
                return
            }
        }
        writerTask = nil
    }

    private func writeCompleted(generation: Int) {
        pendingEventCount -= 1
        committedGeneration = generation
        let ready = writeWaiters.filter { $0.generation <= generation }
        writeWaiters.removeAll { $0.generation <= generation }
        for waiter in ready { waiter.continuation.resume() }
        endBackgroundLeaseIfIdle()
    }

    private func writeFailed(_ error: any Error) {
        writerFailure = error
        persistenceError = error.localizedDescription
        writeQueue.removeAll()
        for waiter in writeWaiters { waiter.continuation.resume(throwing: error) }
        writeWaiters.removeAll()
        onPersistenceFailure?(error.localizedDescription)
        endBackgroundLease()
    }

    private func beginBackgroundLeaseIfNeeded() {
        #if canImport(UIKit)
            guard backgroundTaskID == .invalid else { return }
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(
                withName: "VaganciaFitness evidence writer"
            ) { [weak self] in
                Task { @MainActor in self?.endBackgroundLease() }
            }
        #endif
    }

    private func endBackgroundLeaseIfIdle() {
        if pendingEventCount == 0 { endBackgroundLease() }
    }

    private func endBackgroundLease() {
        #if canImport(UIKit)
            guard backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        #endif
    }

    private func append(
        to session: inout DiagnosticSession, kind: String, source: EvidenceSource = .application,
        payload: [String: JSONValue], at date: Date, eventId: String = UUID().uuidString.lowercased()
    ) {
        session.totalEventCount += 1
        let elapsed = max(
            session.lastElapsedMilliseconds,
            elapsedOffset + Int(max(0, ProcessInfo.processInfo.systemUptime - originUptime) * 1_000))
        session.events.append(
            DiagnosticEvent(
                eventId: eventId, sequence: session.totalEventCount, timestamp: date,
                elapsedMilliseconds: elapsed, kind: kind, source: source, payload: payload))
        if session.events.count > maxEvents {
            let excess = session.events.count - maxEvents
            session.events.removeFirst(excess)
        }
    }

    @discardableResult
    private func persist(_ session: DiagnosticSession, prior: DiagnosticSession? = nil) throws
        -> DiagnosticSession
    {
        guard let journal, let event = session.events.last else {
            throw SessionError.storageUnavailable
        }
        let committed = try journal.append(session, event: event, prior: prior)
        var updated = session
        updated.totalEventCount = committed.sequence
        updated.events[updated.events.count - 1] = committed
        return updated
    }
}
