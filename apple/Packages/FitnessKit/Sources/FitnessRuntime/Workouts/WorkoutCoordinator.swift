import FitnessCore
import Foundation
import Observation

/// One owner for a workout, its evidence store, and its Bluetooth connection.
/// Construction is inert: it opens SQLite and never creates CBCentralManager.
@MainActor @Observable
public final class WorkoutCoordinator {
    public let store: SessionStore
    public let bluetooth: BluetoothExplorer
    public private(set) var programs: [WorkoutProgram] = []
    public private(set) var history: [WorkoutRecord] = []
    public private(set) var latestMetrics: [String: WorkoutSample] = [:]
    public private(set) var currentRecord: WorkoutRecord?
    public private(set) var snapshot: WorkoutSnapshot?
    public private(set) var errorMessage: String?
    public private(set) var isCommandPending = false
    public private(set) var mockMode = false
    public private(set) var mockMetricsEnabled = true
    public private(set) var targetLimits: WorkoutTargetLimits = .cachedDefault
    public private(set) var watchPrepared = false
    public private(set) var isPreparingWatch = false
    public private(set) var isPreparingSelection = false
    public private(set) var continueWithoutWatch = false

    @ObservationIgnored private let repository: WorkoutRepository?
    @ObservationIgnored private let backgroundService: any WorkoutBackgroundService
    @ObservationIgnored private let controlTransport: any WorkoutControlTransport
    @ObservationIgnored private let targetVerifier: TargetObservationVerifier
    @ObservationIgnored private var engine: WorkoutEngine?
    @ObservationIgnored private var pendingProgram: WorkoutProgram?
    @ObservationIgnored private var pendingMode: String?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var lastDispatchUptime: TimeInterval?
    @ObservationIgnored private var lastSpeedEventId: String?
    @ObservationIgnored private var lastInclinationEventId: String?
    @ObservationIgnored private var lastDistanceEventId: String?
    @ObservationIgnored private var mockDistanceMeters = 0.0
    @ObservationIgnored private var distanceBaselineMeters = 0.0
    @ObservationIgnored private var inclinationDisabledForWorkout = false
    @ObservationIgnored private var targetLimitsURL: URL
    @ObservationIgnored private var mockMetricsURL: URL
    @ObservationIgnored private var backgroundTaskActive = false
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var companion: (any WorkoutCompanion)?
    @ObservationIgnored private var companionReceiver: CompanionWorkoutReceiver?
    @ObservationIgnored private var pendingWorkoutID: String?
    @ObservationIgnored private var watchMetricsSuppressed = false
    @ObservationIgnored private var cancelledWatchPreparations: Set<String> = []
    @ObservationIgnored private var telemetryWriteTail: Task<Void, Never>?
    @ObservationIgnored private var telemetryWriteError: String?
    @ObservationIgnored private var companionReceiveTail: Task<Void, any Error>?
    @ObservationIgnored private var failedStartStage: String?
    @ObservationIgnored private var hardwareSampleCaptureClosed = false
    @ObservationIgnored var beforeScheduledTarget: (@MainActor () async -> Void)?

    public convenience init(
        directory: URL = ApplicationDataDirectory.resolve(),
        backgroundService: (any WorkoutBackgroundService)? = nil,
        diagnosticWriterDelay: Duration? = nil
    ) {
        self.init(
            directory: directory, backgroundService: backgroundService, controlTransport: nil,
            diagnosticWriterDelay: diagnosticWriterDelay)
    }

    init(
        directory: URL, backgroundService: (any WorkoutBackgroundService)? = nil,
        controlTransport injectedTransport: (any WorkoutControlTransport)?,
        diagnosticWriterDelay: Duration? = nil,
        targetClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        targetSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        targetStableSeconds: TimeInterval = 3, targetDeadlineScale: Double = 1
    ) {
        store = SessionStore(directory: directory, writerDelay: diagnosticWriterDelay)
        bluetooth = BluetoothExplorer(store: store)
        targetLimitsURL = directory.appendingPathComponent("workout-target-limits.json")
        mockMetricsURL = directory.appendingPathComponent("workout-mock-metrics.json")
        self.backgroundService = backgroundService ?? SystemWorkoutBackgroundService()
        controlTransport = injectedTransport ?? bluetooth
        targetVerifier = TargetObservationVerifier(
            transport: controlTransport, clock: targetClock,
            sleep: targetSleep, stableSeconds: targetStableSeconds, deadlineScale: targetDeadlineScale)
        repository = try? WorkoutRepository(directory: directory)
        companionReceiver = repository.map {
            CompanionWorkoutReceiver(repository: $0, store: store, directory: directory)
        }
        bluetooth.onTelemetry = { [weak self] telemetry in self?.captureTelemetryCallback(telemetry) }
        do {
            guard let repository else { throw SessionError.storageUnavailable }
            if let data = try? Data(contentsOf: targetLimitsURL),
                let saved = try? EvidenceJSON.decoder().decode(WorkoutTargetLimits.self, from: data)
            {
                targetLimits = WorkoutTargetLimits(
                    speed: saved.speed, inclination: saved.inclination, source: .cachedDefault)
            }
            if let data = try? Data(contentsOf: mockMetricsURL),
                let enabled = try? EvidenceJSON.decoder().decode(Bool.self, from: data)
            {
                mockMetricsEnabled = enabled
            }
            try repository.seedDefaultsIfNeeded(WorkoutProgram.seedPrograms)
            let saved = try repository.programs()
            programs = saved
            history = try repository.history()
            if let latest = history.first(where: { $0.endedAt == nil }) {
                latestMetrics = Dictionary(
                    try repository.samples(for: latest.id).map { ($0.metric, $0.sample) },
                    uniquingKeysWith: { _, newer in newer })
            }
            restoreInterruptedWorkoutIfNeeded()
        } catch { errorMessage = error.localizedDescription }
    }

    public var isRunning: Bool { snapshot?.state == .running || snapshot?.state == .manual }
    public var hasOpenWorkout: Bool { currentRecord?.endedAt == nil && currentRecord != nil }
    public var currentInterval: WorkoutInterval? { snapshot?.currentInterval }
    public var rememberedTreadmill: RememberedTreadmill? { bluetooth.rememberedTreadmill }
    public var recordUsesWatch: Bool { currentRecord?.healthSave != nil }

    private func companionView(_ record: WorkoutRecord) -> CompanionWorkoutView {
        CompanionWorkoutView(
            snapshot: record.latestSnapshot, metrics: latestMetrics, startedAt: record.startedAt,
            endedAt: record.endedAt, synthetic: mockMode || record.mode == "mock")
    }

    private func receiveCompanion(_ message: CompanionMessage) async throws {
        guard let companionReceiver, let companion, let repository else {
            throw CompanionError.unavailable
        }
        guard
            let accepted = try await companionReceiver.receive(
                message,
                pendingID: pendingWorkoutID, cancelledIDs: cancelledWatchPreparations,
                companion: companion)
        else { return }
        let committed = accepted.record
        if var current = currentRecord, current.id == committed.id {
            current.sampleCount = max(current.sampleCount, committed.sampleCount)
            current.eventCount = max(current.eventCount, committed.eventCount)
            current.healthSave = committed.healthSave
            if committed.endedAt != nil { current.endedAt = committed.endedAt }
            currentRecord = current
            for item in accepted.samples {
                let prior = latestMetrics[item.metric]
                if (item.sample.sampledAt ?? item.sample.receivedAt)
                    >= (prior?.sampledAt ?? prior?.receivedAt ?? .distantPast)
                {
                    latestMetrics[item.metric] = item.sample
                }
            }
        }
        history = try await repository.historyAsync()
        if accepted.shouldFinalize {
            companion.finalize(id: committed.id, view: companionView(committed))
        }
        if accepted.statusRequested {
            if committed.endedAt != nil {
                companion.finalize(id: committed.id, view: companionView(committed))
            } else {
                companion.publish(id: committed.id, view: companionView(committed))
            }
        }
    }

    public func attachCompanion(_ companion: any WorkoutCompanion) {
        self.companion = companion
        companion.onMessage = { [weak self] message in
            guard let self else { return }
            let previous = self.companionReceiveTail
            let task = Task {
                try? await previous?.value
                try await self.receiveCompanion(message)
            }
            self.companionReceiveTail = task
            try await task.value
        }
    }
    public func recordCompanionEvent(_ kind: String, message: String) {
        do {
            if hasOpenWorkout {
                try persistEvent(kind, source: "watchHealthKit", payload: ["message": .string(message)])
            } else {
                if store.session?.isOpen != true { try store.startSession() }
                try store.record(kind: kind, payload: ["message": .string(message)])
            }
        } catch { errorMessage = error.localizedDescription }
    }

    public func prepareWatch() async throws {
        guard !mockMode, let companion, companion.useWatch, let id = pendingWorkoutID, let snapshot
        else { throw CompanionError.notPrepared }
        isPreparingWatch = true
        defer { isPreparingWatch = false }
        let started = ProcessInfo.processInfo.systemUptime
        try await store.recordDurably(
            kind: "watch.preparation.requested", payload: ["watchSessionID": .string(id)])
        do {
            try await companion.prepare(
                id: id,
                view: CompanionWorkoutView(snapshot: snapshot, metrics: [:], startedAt: nil, endedAt: nil))
            guard pendingWorkoutID == id else {
                companion.cancelPreparation(id: id)
                throw CancellationError()
            }
            watchPrepared = true
            continueWithoutWatch = false
            try await store.recordDurably(
                kind: "watch.preparation.ready",
                payload: [
                    "watchSessionID": .string(id),
                    "durationMilliseconds": .number((ProcessInfo.processInfo.systemUptime - started) * 1_000),
                ])
        } catch {
            try? await store.recordDurably(
                kind: "watch.preparation.failed",
                payload: [
                    "watchSessionID": .string(id),
                    "durationMilliseconds": .number((ProcessInfo.processInfo.systemUptime - started) * 1_000),
                    "error": .string(String(reflecting: error)),
                ])
            throw error
        }
    }

    public func chooseWithoutWatch() {
        if let id = pendingWorkoutID {
            cancelledWatchPreparations.insert(id)
            companion?.cancelPreparation(id: id)
            if store.session?.isOpen == true {
                try? store.record(
                    kind: "watch.preparation.skipped",
                    payload: ["watchSessionID": .string(id), "operatorChoice": .bool(true)])
            }
        }
        watchPrepared = false
        continueWithoutWatch = true
    }

    public func cancelWatchPreparation() {
        guard currentRecord == nil else { return }
        if let id = pendingWorkoutID {
            cancelledWatchPreparations.insert(id)
            companion?.cancelPreparation(id: id)
            if store.session?.isOpen == true {
                try? store.record(
                    kind: "watch.preparation.cancelled", payload: ["watchSessionID": .string(id)])
            }
        }
        pendingWorkoutID = nil
        pendingProgram = nil
        pendingMode = nil
        engine = nil
        snapshot = nil
        watchPrepared = false
    }

    public func refresh() {
        do {
            guard let repository else { throw SessionError.storageUnavailable }
            programs = try repository.programs()
            history = try repository.history()
            if let latest = history.first, latest.endedAt == nil, currentRecord?.id != latest.id {
                currentRecord = latest
                snapshot = latest.latestSnapshot
                latestMetrics = Dictionary(
                    try repository.samples(for: latest.id).map { ($0.metric, $0.sample) },
                    uniquingKeysWith: { _, newer in newer })
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func saveProgram(_ program: WorkoutProgram) throws {
        guard let repository else { throw SessionError.storageUnavailable }
        try WorkoutProgram.validate(
            name: program.name, intervals: program.intervals, limits: targetLimits)
        try repository.saveProgram(program)
        programs = try repository.programs()
    }

    public func deleteProgram(id: String) throws {
        guard let repository else { throw SessionError.storageUnavailable }
        try repository.deleteProgram(id: id)
        programs = try repository.programs()
    }

    public func loadSamples(for id: String) throws -> [WorkoutRecordedSample] {
        guard let repository else { throw SessionError.storageUnavailable }
        return try repository.samples(for: id)
    }
    public func loadEvents(for id: String) throws -> [WorkoutRuntimeEvent] {
        guard let repository else { throw SessionError.storageUnavailable }
        return try repository.events(for: id)
    }

    public func exportWorkoutJSON(id: String) throws -> URL {
        guard let repository else { throw SessionError.storageUnavailable }
        guard let record = try repository.record(id: id) else {
            throw WorkoutRepositoryError.missingWorkout(id)
        }
        let payload = WorkoutExportPayload(
            record: record, samples: try repository.samples(for: id),
            events: try repository.events(for: id))
        return try WorkoutExporter.exportJSON(
            payload, directory: store.directory.appendingPathComponent("Exports", isDirectory: true))
    }

    public func exportWorkoutJSONAsync(id: String) async throws -> URL {
        try await flushHardwareSamples()
        guard let repository else { throw SessionError.storageUnavailable }
        guard let details = try await repository.detailsAsync(id: id) else {
            throw WorkoutRepositoryError.missingWorkout(id)
        }
        let payload = WorkoutExportPayload(
            record: details.record, samples: details.samples, events: details.events)
        let exports = store.directory.appendingPathComponent("Exports", isDirectory: true)
        return try await Task.detached(priority: .utility) {
            try WorkoutExporter.exportJSON(payload, directory: exports)
        }.value
    }

    public func exportCurrent(metadata: AppMetadata) throws -> DiagnosticExport {
        guard let currentRecord else { throw WorkoutRepositoryError.missingWorkout("current") }
        return try exportZIP(record: currentRecord, metadata: metadata)
    }

    public func exportCurrentAsync(
        metadata: AppMetadata, profile: DiagnosticExportProfile = .complete
    ) async throws -> DiagnosticExport {
        try await flushHardwareSamples()
        guard let currentRecord else { throw WorkoutRepositoryError.missingWorkout("current") }
        return try await exportZIPAsync(record: currentRecord, metadata: metadata, profile: profile)
    }

    /// Exports the current diagnostic capture even when no workout record exists.
    public func exportDiagnostic(metadata: AppMetadata, profile: DiagnosticExportProfile = .complete)
        async throws -> DiagnosticExport
    {
        try await flushHardwareSamples()
        let watchDiagnostics = try await watchDiagnosticSnapshot()
        if let currentRecord, let sessionID = currentRecord.sessionId,
            sessionID == store.session?.sessionId
        {
            guard let repository else { throw SessionError.storageUnavailable }
            guard let details = try await repository.detailsAsync(id: currentRecord.id) else {
                throw WorkoutRepositoryError.missingWorkout(currentRecord.id)
            }
            let payload = WorkoutExportPayload(
                record: details.record, samples: details.samples, events: details.events)
            let workout = try await Task.detached(priority: .utility) {
                try WorkoutExporter.jsonValue(payload)
            }.value
            return try await store.exportAsync(
                sessionId: sessionID, metadata: metadata,
                workout: workout, watchDiagnostics: watchDiagnostics, profile: profile)
        }
        return try await store.exportAsync(
            metadata: metadata, watchDiagnostics: watchDiagnostics, profile: profile)
    }

    public func exportZIP(
        record: WorkoutRecord, metadata: AppMetadata, profile: DiagnosticExportProfile = .complete
    ) throws -> DiagnosticExport {
        guard let repository else { throw SessionError.storageUnavailable }
        let current = try repository.record(id: record.id) ?? record
        let payload = WorkoutExportPayload(
            record: current, samples: try repository.samples(for: record.id),
            events: try repository.events(for: record.id))
        let workout = try WorkoutExporter.jsonValue(payload)
        guard let sessionId = record.sessionId else {
            throw SessionError.noSession
        }
        let watchDiagnostics = WatchDiagnosticExportSnapshot(
            entries: try WatchRejectedEnvelopeJournal(directory: store.directory).entries)
        return try store.export(
            sessionId: sessionId, metadata: metadata, workout: workout,
            watchDiagnostics: watchDiagnostics, profile: profile)
    }

    public func exportZIPAsync(
        record: WorkoutRecord, metadata: AppMetadata, profile: DiagnosticExportProfile = .complete
    ) async throws -> DiagnosticExport {
        try await flushHardwareSamples()
        let watchDiagnostics = try await watchDiagnosticSnapshot()
        guard let repository else { throw SessionError.storageUnavailable }
        guard let details = try await repository.detailsAsync(id: record.id) else {
            throw WorkoutRepositoryError.missingWorkout(record.id)
        }
        let payload = WorkoutExportPayload(
            record: details.record, samples: details.samples, events: details.events)
        guard let sessionID = record.sessionId else { throw SessionError.noSession }
        let workout = try await Task.detached(priority: .utility) {
            try WorkoutExporter.jsonValue(payload)
        }.value
        return try await store.exportAsync(
            sessionId: sessionID, metadata: metadata,
            workout: workout, watchDiagnostics: watchDiagnostics, profile: profile)
    }

    private func watchDiagnosticSnapshot() async throws -> WatchDiagnosticExportSnapshot {
        let available = companion?.rejectionSnapshotAvailable == true
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let receipt = await companion?.collectRejectedEnvelopeSnapshot()
        let directory = store.directory
        let expected = Set(receipt?.entryIDs ?? [])
        while true {
            let entries = try await Task.detached(priority: .utility) {
                try WatchRejectedEnvelopeJournal(directory: directory).entries
            }.value
            if let receipt, expected.isSubset(of: Set(entries.map(\.id))) {
                return WatchDiagnosticExportSnapshot(
                    entries: entries, syncStatus: .snapshotConfirmed,
                    collectionRequestID: receipt.requestID, watchSnapshotAt: receipt.capturedAt)
            }
            if receipt == nil || ProcessInfo.processInfo.systemUptime >= deadline {
                return WatchDiagnosticExportSnapshot(
                    entries: entries,
                    syncStatus: available ? .timedOut : .unavailable,
                    collectionRequestID: receipt?.requestID, watchSnapshotAt: receipt?.capturedAt)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func setMockMode(_ enabled: Bool) {
        guard !isCommandPending, currentRecord?.endedAt != nil || currentRecord == nil else {
            errorMessage = FitnessText.string("workout.finishBeforeMock")
            return
        }
        mockMode = enabled
        errorMessage = nil
    }

    public func setMockMetricsEnabled(_ enabled: Bool) {
        do {
            try EvidenceJSON.encoder().encode(enabled).write(to: mockMetricsURL, options: .atomic)
            mockMetricsEnabled = enabled
            errorMessage = nil
        } catch {
            errorMessage = FitnessText.format(
                "workout.syntheticPreferenceError", error.localizedDescription)
        }
    }

    public var canClearHistory: Bool { !isCommandPending && !hasOpenWorkout }

    public func clearHistory() throws {
        guard canClearHistory else { throw SessionError.alreadyOpen }
        guard let repository else { throw SessionError.storageUnavailable }
        let sessionIDs = Set(try repository.history(limit: Int.max).compactMap(\.sessionId))
        for id in sessionIDs { try store.deleteSession(id: id) }
        try repository.clearHistory()
        history = []
        currentRecord = nil
        snapshot = nil
        latestMetrics = [:]
    }

    public func foregrounded() {
        do { try store.recordLifecycle("active") } catch { errorMessage = error.localizedDescription }
        guard !mockMode else { return }
        bluetooth.autoConnectIfEnabled()
    }

    public func backgrounded() {
        do { try store.recordLifecycle("background") } catch {
            errorMessage = error.localizedDescription
        }
        bluetooth.backgrounded()
    }

    public func beginDeviceSetup() throws {
        guard !mockMode else {
            throw ControlError.blocked("Desactiva el modo de demostración para buscar Bluetooth.")
        }
        if store.session?.isOpen != true { try store.startSession() }
    }

    public func searchDevices(allDevices: Bool = false) {
        do {
            try beginDeviceSetup()
            bluetooth.search(allDevices: allDevices)
        } catch { errorMessage = error.localizedDescription }
    }

    public func connect(_ device: DiscoveredDevice) {
        do {
            try beginDeviceSetup()
            bluetooth.connect(device)
        } catch { errorMessage = error.localizedDescription }
    }

    public func connect(_ device: DiscoveredDevice, remember: Bool) {
        setRememberOnConnect(remember)
        connect(device)
    }

    public func setRememberOnConnect(_ enabled: Bool) { bluetooth.setRememberOnConnect(enabled) }

    public func setConnectOnOpen(_ enabled: Bool) { bluetooth.setConnectOnOpen(enabled) }
    public func connectRemembered() {
        guard !mockMode else {
            errorMessage = FitnessText.string("workout.disableMockConnect")
            return
        }
        bluetooth.connectRemembered()
    }
    public func forgetTreadmill() { bluetooth.forgetTreadmill() }

    public func setCachedTargetLimits(speed: FTMSRange, inclination: FTMSRange) throws {
        let limits = WorkoutTargetLimits(speed: speed, inclination: inclination, source: .cachedDefault)
        try WorkoutProgram.validate(
            name: "Validación",
            intervals: [
                .init(
                    durationSeconds: 15, targetSpeedKPH: speed.minimum,
                    targetInclinationPercent: inclination.minimum)
            ], limits: limits)
        let data = try EvidenceJSON.encoder().encode(limits)
        try data.write(to: targetLimitsURL, options: .atomic)
        targetLimits = limits
    }

    public func startFree() async throws {
        let program = WorkoutProgram(
            id: "free-\(UUID().uuidString.lowercased())", name: "Entrenamiento libre",
            intervals: [
                .init(
                    durationSeconds: 3_600, targetSpeedKPH: targetLimits.speed.minimum,
                    targetInclinationPercent: 0, phase: .steady)
            ])
        try await prepare(program, mode: "free")
    }

    public func start(program: WorkoutProgram) async throws {
        try await prepare(program, mode: "program")
    }

    private func prepare(_ program: WorkoutProgram, mode: String) async throws {
        guard !isPreparingSelection else {
            throw ControlError.blocked("Ya se está preparando una sesión.")
        }
        guard pendingProgram == nil || snapshot?.state != .preparing else {
            throw ControlError.blocked("Ya hay una sesión preparada.")
        }
        guard currentRecord?.endedAt != nil || currentRecord == nil else {
            throw SessionError.alreadyOpen
        }
        isPreparingSelection = true
        defer { isPreparingSelection = false }
        if store.session?.isOpen != true { try store.startSession() }
        let selectedID = UUID().uuidString.lowercased()
        try await store.recordDurably(
            kind: "workout.preparation.selected",
            payload: [
                "workoutID": .string(selectedID), "programID": .string(program.id),
                "mode": .string(mode), "mockMode": .bool(mockMode), "movementAuthorized": .bool(false),
            ])
        do {
            let limits =
                controlTransport.snapshot?.speedRange.map { speed in
                    WorkoutTargetLimits(
                        speed: speed,
                        inclination: controlTransport.snapshot?.inclinationRange ?? targetLimits.inclination,
                        source: .announced)
                } ?? targetLimits
            try WorkoutProgram.validate(name: program.name, intervals: program.intervals, limits: limits)
            if limits.source == .announced {
                let cached = WorkoutTargetLimits(
                    speed: limits.speed, inclination: limits.inclination, source: .cachedDefault)
                let data = try EvidenceJSON.encoder().encode(cached)
                try data.write(to: targetLimitsURL, options: .atomic)
                targetLimits = cached
            }
            pendingProgram = program
            pendingWorkoutID = selectedID
            watchPrepared = false
            continueWithoutWatch = false
            watchMetricsSuppressed = companion?.useWatch == true && !mockMode
            pendingMode = mode
            lastSpeedEventId = nil
            lastInclinationEventId = nil
            lastDistanceEventId = nil
            mockDistanceMeters = 0
            inclinationDisabledForWorkout = false
            latestMetrics = [:]
            engine = WorkoutEngine(
                program: program, speedStep: limits.speed.increment,
                inclinationStep: limits.inclination.increment, isFreeWorkout: mode == "free")
            snapshot = engine?.snapshot()
            currentRecord = nil
            hardwareSampleCaptureClosed = false
            errorMessage = nil
            try await store.recordDurably(
                kind: "workout.preparation.ready",
                payload: [
                    "workoutID": .string(selectedID), "programID": .string(program.id),
                    "limitsSource": .string(limits.source.rawValue), "movementAuthorized": .bool(false),
                ])
        } catch {
            try? await store.recordDurably(
                kind: "workout.preparation.failed",
                payload: [
                    "workoutID": .string(selectedID), "programID": .string(program.id),
                    "error": .string(String(reflecting: error)),
                    "errorDescription": .string(error.localizedDescription),
                ])
            throw error
        }
    }

    /// The only entry point that authorizes a workout to send movement commands.
    public func confirmAndStart() async throws {
        guard let program = pendingProgram, var engine, snapshot?.state == .preparing else {
            throw SessionError.noOpenSession
        }
        guard !isCommandPending else { throw ControlError.blocked("Ya hay un procedimiento en curso.") }
        isCommandPending = true
        defer { isCommandPending = false }
        failedStartStage = nil
        try await store.recordDurably(
            kind: "workout.start.confirmed",
            payload: [
                "workoutID": .string(pendingWorkoutID ?? "unknown"), "programID": .string(program.id),
                "operatorAuthorizedMovement": .bool(!mockMode),
            ])
        do {
            if !mockMode, controlTransport.phase != .ready || controlTransport.selectedProtocol != .ftms {
                throw ControlError.blocked("Conecta la caminadora y prepara FTMS antes de iniciar.")
            }
            if !mockMode {
                guard let device = controlTransport.snapshot, device.speedControlAdvertised,
                    let speedRange = device.speedRange, speedRange.unit == "km/h"
                else {
                    throw ControlError.blocked(
                        "El equipo conectado no anuncia control y rango de velocidad FTMS; no se iniciará el entrenamiento."
                    )
                }
                let inclinationRange =
                    device.inclinationControlAdvertised
                    ? (device.inclinationRange ?? targetLimits.inclination) : targetLimits.inclination
                let runtimeLimits = WorkoutTargetLimits(
                    speed: speedRange, inclination: inclinationRange, source: .announced)
                try WorkoutProgram.validate(
                    name: program.name, intervals: program.intervals, limits: runtimeLimits)
            }
            if !mockMode, companion?.useWatch == true, !continueWithoutWatch {
                guard watchPrepared, companion?.preparedSessionID == pendingWorkoutID else {
                    throw CompanionError.notPrepared
                }
            }
            try await recordStartStage("preflight", status: "completed", durationMilliseconds: 0)
        } catch {
            try? await recordStartStage(
                "preflight", status: "failed", durationMilliseconds: 0, error: error)
            throw error
        }
        operationGeneration += 1
        let generation = operationGeneration
        if store.session?.isOpen != true { try store.startSession() }
        var record = WorkoutRecord(
            id: pendingWorkoutID ?? UUID().uuidString.lowercased(), mode: pendingMode ?? "program",
            program: program,
            latestSnapshot: engine.snapshot(), sessionId: store.session?.sessionId)
        if watchPrepared, !mockMode {
            record.healthSave = HealthSaveResult(
                state: .pending, message: "Watch preparado; esperando captura y cierre.")
        }
        distanceBaselineMeters = Double(store.currentDistanceProgress?.accumulatedMeters ?? 0)
        _ = engine.start()
        self.engine = engine
        snapshot = engine.snapshot()
        let confirmationPayload: [String: JSONValue] = [
            "programId": .string(program.id), "mode": .string(record.mode),
            "operatorAuthorizedMovement": .bool(!mockMode),
        ]
        guard let repository else { throw SessionError.storageUnavailable }
        try await runStartStage("recordCreated") {
            let event = WorkoutRuntimeEvent(
                sequence: 1, kind: "workout.operatorConfirmed", payload: confirmationPayload)
            let committed = try await repository.saveAsync(record, events: [event])
            self.currentRecord = committed
            try await self.store.recordDurably(
                kind: "workout.operatorConfirmed", payload: confirmationPayload)
        }
        if mockMode {
            let first = program.intervals[0]
            engine.updateEffectiveTargets(
                speedKPH: first.targetSpeedKPH, inclinationPercent: first.targetInclinationPercent)
            _ = engine.markRunning()
            self.engine = engine
            snapshot = engine.snapshot()
            try persistEvent(
                "workout.mock.started", source: "synthetic",
                payload: ["source": .string("mock"), "bluetoothInitialized": .bool(false)])
            pendingProgram = nil
            pendingMode = nil
            beginScheduler()
            return
        }
        controlTransport.setProgramBackgroundLease(false)
        do {
            if record.mode == "program" {
                try await runStartStage("backgroundTask") { try await self.submitBackgroundTask() }
            }
            try ensureCurrentOperation(generation)
            try await runStartStage("ftmsSubscriptions") {
                try await self.controlTransport.prepareControlAndWait()
            }
            try ensureCurrentOperation(generation)
            _ = try await runStartStage("requestControl") {
                try await self.controlTransport.executeAndWait(.requestControl)
            }
            try ensureCurrentOperation(generation)
            let stopTime = Date()
            _ = try await runStartStage("stopBeforeStart") {
                try await self.controlTransport.executeAndWait(.stop)
            }
            try ensureCurrentOperation(generation)
            try await runStartStage("observeZeroSpeed") {
                try await self.waitForSpeed(after: stopTime, zero: true, generation: generation)
            }
            try ensureCurrentOperation(generation)
            let startTime = Date()
            _ = try await runStartStage("start") {
                try await self.controlTransport.executeAndWait(.start)
            }
            try ensureCurrentOperation(generation)
            try await runStartStage("observePositiveSpeed") {
                try await self.waitForSpeed(after: startTime, zero: false, generation: generation)
            }
            try ensureCurrentOperation(generation)
            try await runStartStage("initialTargets") {
                try await self.applyGoals(
                    speed: program.intervals[0].targetSpeedKPH,
                    inclination: program.intervals[0].targetInclinationPercent,
                    inclinationMayFail: true)
            }
            try ensureCurrentOperation(generation)
            engine = self.engine ?? engine
            _ = engine.markRunning()
            self.engine = engine
            snapshot = engine.snapshot()
            try await persistEventAsync(
                "workout.running",
                payload: ["startAcceptedByFTMS": .bool(true), "freshPositiveSpeedObserved": .bool(true)])
            try await recordStartStage("running", status: "completed", durationMilliseconds: 0)
            pendingProgram = nil
            pendingMode = nil
            controlTransport.setProgramBackgroundLease(record.mode == "program" && backgroundTaskActive)
            beginScheduler()
        } catch {
            try? await store.flush()
            if watchPrepared { companion?.cancelPreparation(id: record.id) }
            controlTransport.setProgramBackgroundLease(false)
            await cancelBackgroundTask(success: false)
            pendingProgram = nil
            pendingMode = nil
            if generation == operationGeneration, currentRecord?.endedAt == nil {
                enterManual(
                    "Inicio incompleto en \(failedStartStage ?? "coordinación"): \(error.localizedDescription). Se requiere control manual; no se reintentó ninguna orden."
                )
            }
            throw error
        }
    }

    public func pause() async throws {
        guard let record = currentRecord, record.endedAt == nil, isRunning else {
            throw ControlError.blocked("No hay un entrenamiento activo para pausar.")
        }
        if mockMode {
            guard var engine else { return }
            _ = engine.pause()
            self.engine = engine
            snapshot = engine.snapshot()
            schedulerTask?.cancel()
            schedulerTask = nil
            try persistEvent("workout.paused", source: "synthetic", payload: ["source": .string("mock")])
            return
        }
        operationGeneration += 1
        let generation = operationGeneration
        guard var engine else { return }
        _ = engine.beginPausing()
        self.engine = engine
        snapshot = engine.snapshot()
        try await sendStopAndConfirmZero(reason: "pause")
        try ensureCurrentOperation(generation)
        engine = self.engine ?? engine
        _ = engine.confirmPaused()
        self.engine = engine
        snapshot = engine.snapshot()
        controlTransport.setProgramBackgroundLease(false)
        await cancelBackgroundTask(success: true)
        try persistEvent(
            "workout.paused",
            payload: [
                "reason": .string(
                    "La pausa Bluetooth se confirmó y se observó velocidad FTMS reciente de 0 km/h.")
            ])
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    public func resume() async throws {
        guard currentRecord?.endedAt == nil, snapshot?.state == .paused, var engine else {
            throw ControlError.blocked("El entrenamiento no está pausado.")
        }
        guard !isCommandPending else { throw ControlError.blocked("Ya hay un procedimiento en curso.") }
        operationGeneration += 1
        let generation = operationGeneration
        if mockMode {
            _ = engine.resume()
            self.engine = engine
            snapshot = engine.snapshot()
            try persistEvent(
                "workout.resumed", source: "synthetic",
                payload: ["source": .string("mock"), "userInitiated": .bool(true)])
            beginScheduler()
            return
        }
        isCommandPending = true
        defer { isCommandPending = false }
        do {
            if currentRecord?.mode == "program" { try await submitBackgroundTask() }
            try ensureCurrentOperation(generation)
            try await controlTransport.prepareControlAndWait()
            try ensureCurrentOperation(generation)
            _ = try await controlTransport.executeAndWait(.requestControl)
            try ensureCurrentOperation(generation)
            let stopTime = Date()
            _ = try await controlTransport.executeAndWait(.stop)
            try ensureCurrentOperation(generation)
            try await waitForSpeed(after: stopTime, zero: true, generation: generation)
            try ensureCurrentOperation(generation)
            let startTime = Date()
            _ = try await controlTransport.executeAndWait(.start)
            try ensureCurrentOperation(generation)
            try await waitForSpeed(after: startTime, zero: false, generation: generation)
            try ensureCurrentOperation(generation)
            let interval = engine.currentInterval
            try await applyGoals(
                speed: engine.effectiveSpeedKPH ?? interval.targetSpeedKPH,
                inclination: engine.effectiveInclinationPercent ?? interval.targetInclinationPercent,
                inclinationMayFail: true)
            try ensureCurrentOperation(generation)
            engine = self.engine ?? engine
            _ = engine.resume()
            self.engine = engine
            snapshot = engine.snapshot()
            controlTransport.setProgramBackgroundLease(
                currentRecord?.mode == "program" && backgroundTaskActive)
            try persistEvent(
                "workout.resumed",
                payload: ["userInitiated": .bool(true), "freshPositiveSpeedObserved": .bool(true)])
            beginScheduler()
        } catch {
            if generation == operationGeneration, currentRecord?.endedAt == nil {
                enterManual("La continuación no se completó. El estado requiere control manual.")
            }
            controlTransport.setProgramBackgroundLease(false)
            await cancelBackgroundTask(success: false)
            throw error
        }
    }

    public func skipSegment() async throws {
        guard var engine, snapshot?.state == .running else {
            throw ControlError.blocked("No hay un segmento automático activo para saltar.")
        }
        let nextIndex =
            engine.currentInterval == engine.program.intervals.last
            ? nil : engine.program.intervals.firstIndex(of: engine.currentInterval).map { $0 + 1 }
        guard let nextIndex, engine.program.intervals.indices.contains(nextIndex) else {
            try await stop()
            return
        }
        let target = engine.program.intervals[nextIndex]
        if mockMode {
            _ = engine.skipInterval()
            engine.updateEffectiveTargets(
                speedKPH: target.targetSpeedKPH, inclinationPercent: target.targetInclinationPercent)
            self.engine = engine
            snapshot = engine.snapshot()
            try persistEvent(
                "workout.segment.skipped", source: "synthetic",
                payload: ["intervalIndex": .number(Double(nextIndex))])
            return
        }
        guard !isCommandPending else { throw ControlError.blocked("Ya hay un procedimiento en curso.") }
        isCommandPending = true
        defer { isCommandPending = false }
        operationGeneration += 1
        let generation = operationGeneration
        do {
            schedulerTask?.cancel()
            schedulerTask = nil
            _ = engine.skipInterval()
            self.engine = engine
            snapshot = engine.snapshot()
            try await applyGoals(
                speed: target.targetSpeedKPH, inclination: target.targetInclinationPercent,
                inclinationMayFail: true)
            try ensureCurrentOperation(generation)
            try persistEvent(
                "workout.segment.skipped", payload: ["intervalIndex": .number(Double(nextIndex))])
            beginScheduler()
        } catch {
            if generation == operationGeneration, currentRecord?.endedAt == nil {
                enterManual(
                    "No se pudo aplicar el siguiente segmento; el entrenamiento pasa a control manual.")
            }
            throw error
        }
    }

    public func overrideSpeed(_ speed: Double) async throws {
        guard snapshot?.state == .running || snapshot?.state == .manual, var engine else {
            throw ControlError.blocked("El objetivo manual requiere un entrenamiento en marcha.")
        }
        guard !isCommandPending else { throw ControlError.blocked("Ya hay un procedimiento en curso.") }
        isCommandPending = true
        defer { isCommandPending = false }
        operationGeneration += 1
        let generation = operationGeneration
        guard speed >= targetLimits.speed.minimum, speed <= targetLimits.speed.maximum else {
            throw ControlError.blocked("La velocidad está fuera del rango permitido.")
        }
        if !mockMode {
            do {
                let priorSpeed = controlTransport.snapshot?.telemetry?.speed?.value ?? 0
                let accepted = try await controlTransport.executeAndWait(
                    .speed, speed: speed, allowProgramBackground: currentRecord?.mode == "program")
                let acceptedAt = Date()
                try ensureCurrentOperation(generation)
                engine.updateEffectiveTargets(
                    speedKPH: speed, inclinationPercent: engine.effectiveInclinationPercent)
                self.engine = engine
                snapshot = engine.snapshot()
                try await persistEventAsync(
                    "workout.target.accepted",
                    payload: [
                        "metric": .string("speedKPH"), "requested": .number(speed),
                        "source": .string("operator"), "procedureID": .string(accepted.id),
                        "requestValueHex": .string(accepted.valueHex),
                        "responseEventID": accepted.responseEventId.map(JSONValue.string) ?? .null,
                        "interpretation": .string("acceptedByProtocol; awaiting sustained FTMS telemetry"),
                    ])
                try await confirmSpeedTarget(
                    speed, priorSpeed: priorSpeed, after: acceptedAt, generation: generation)
            } catch {
                if generation == operationGeneration, currentRecord?.endedAt == nil {
                    enterManual(
                        "El objetivo manual de velocidad no quedó confirmado: \(error.localizedDescription)")
                }
                throw error
            }
            engine = self.engine ?? engine
        }
        _ = engine.manualOverride(speedKPH: speed)
        engine.updateEffectiveTargets(
            speedKPH: speed, inclinationPercent: engine.effectiveInclinationPercent)
        self.engine = engine
        snapshot = engine.snapshot()
        try persistEvent(
            "workout.speed.override", source: mockMode ? "synthetic" : "application",
            payload: ["targetKPH": .number(speed), "source": .string(mockMode ? "mock" : "operator")])
    }

    public func overrideIncline(_ inclination: Double) async throws {
        guard snapshot?.state == .running || snapshot?.state == .manual, var engine else {
            throw ControlError.blocked("El objetivo manual requiere un entrenamiento en marcha.")
        }
        guard !isCommandPending else { throw ControlError.blocked("Ya hay un procedimiento en curso.") }
        isCommandPending = true
        defer { isCommandPending = false }
        operationGeneration += 1
        let generation = operationGeneration
        guard inclination >= targetLimits.inclination.minimum,
            inclination <= targetLimits.inclination.maximum
        else { throw ControlError.blocked("La inclinación está fuera del rango permitido.") }
        if !mockMode
            && (inclinationDisabledForWorkout
                || controlTransport.snapshot?.inclinationControlAdvertised != true)
        {
            inclinationDisabledForWorkout = true
            try persistEvent(
                "workout.inclination.unavailable",
                payload: [
                    "requestedPercent": .number(inclination),
                    "reason": .string("El equipo no ofrece control de inclinación para esta sesión."),
                    "speedContinues": .bool(true),
                ])
            throw ControlError.blocked(
                "La inclinación no está disponible en esta sesión; la velocidad continúa.")
        }
        if !mockMode {
            do {
                _ = try await controlTransport.executeAndWait(
                    .inclination, inclination: inclination,
                    allowProgramBackground: currentRecord?.mode == "program")
                try ensureCurrentOperation(generation)
            } catch {
                if generation == operationGeneration, let last = controlTransport.control.last,
                    last.action == .inclination, last.result == "rejectedByProtocol",
                    controlTransport.control.permission
                {
                    inclinationDisabledForWorkout = true
                    engine = self.engine ?? engine
                    engine.updateEffectiveTargets(
                        speedKPH: engine.effectiveSpeedKPH, inclinationPercent: nil, inclinationAccepted: false)
                    self.engine = engine
                    snapshot = engine.snapshot()
                    try persistEvent(
                        "workout.inclination.unavailable",
                        payload: [
                            "requestedPercent": .number(inclination),
                            "reason": .string(error.localizedDescription), "speedContinues": .bool(true),
                        ])
                    throw error
                }
                if generation == operationGeneration, currentRecord?.endedAt == nil {
                    enterManual(
                        "El resultado de la inclinación manual es incierto; se requiere control manual.")
                }
                throw error
            }
            engine = self.engine ?? engine
        }
        _ = engine.manualOverride(inclinationPercent: inclination)
        engine.updateEffectiveTargets(
            speedKPH: engine.effectiveSpeedKPH, inclinationPercent: inclination)
        self.engine = engine
        snapshot = engine.snapshot()
        try persistEvent(
            "workout.inclination.override", source: mockMode ? "synthetic" : "application",
            payload: [
                "targetPercent": .number(inclination), "source": .string(mockMode ? "mock" : "operator"),
            ])
    }

    public func stop() async throws { try await finishAndSave() }

    /// Explicitly closes the recording when Bluetooth cannot confirm a stop.
    /// This never claims the belt stopped and never sends another movement command.
    public func saveInterruptedRecording() async throws {
        guard let record = currentRecord, record.endedAt == nil, var engine else {
            throw ControlError.blocked("No hay un registro abierto para guardar.")
        }
        operationGeneration += 1
        schedulerTask?.cancel()
        schedulerTask = nil
        controlTransport.setProgramBackgroundLease(false)
        await cancelBackgroundTask(success: false)
        _ = engine.interrupt()
        self.engine = engine
        snapshot = engine.snapshot()
        try await closeRecord(
            snapshot: engine.snapshot(), interrupted: true,
            event: "workout.operatorSavedUnconfirmed",
            reason: "operatorClosedRecordingWithoutConfirmedStop")
    }

    public func finishAndSave() async throws {
        guard let record = currentRecord, record.endedAt == nil, var engine else {
            throw ControlError.blocked("No hay un entrenamiento abierto para finalizar.")
        }
        if mockMode {
            schedulerTask?.cancel()
            schedulerTask = nil
            _ = engine.finish()
            self.engine = engine
            snapshot = engine.snapshot()
            try await closeRecord(
                snapshot: snapshot!, interrupted: false, event: "workout.completed",
                reason: "mockOperatorFinish")
            return
        }
        operationGeneration += 1
        schedulerTask?.cancel()
        schedulerTask = nil
        _ = engine.beginFinishing()
        self.engine = engine
        snapshot = engine.snapshot()
        try await sendStopAndConfirmZero(reason: "operatorFinish")
        engine = self.engine ?? engine
        _ = engine.complete()
        self.engine = engine
        snapshot = engine.snapshot()
        controlTransport.setProgramBackgroundLease(false)
        await cancelBackgroundTask(success: true)
        try await closeRecord(
            snapshot: snapshot!, interrupted: false, event: "workout.completed", reason: "operatorFinish")
    }

    public func addNote(_ text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SessionError.emptyNote }
        guard clean.count <= 2_000 else { throw SessionError.noteTooLong }
        guard var record = currentRecord else { throw WorkoutRepositoryError.missingWorkout("current") }
        record.notes.append(WorkoutNote(text: clean))
        try saveRecord(
            record,
            event: WorkoutRuntimeEvent(
                sequence: 0, kind: "operator.note", source: "operatorReported",
                payload: ["note": .string(clean)]))
    }

    private func applyGoals(
        speed: Double, inclination: Double, inclinationMayFail: Bool,
        expectedGeneration: Int? = nil
    ) async throws {
        let ownsPendingFlag = !isCommandPending
        if ownsPendingFlag { isCommandPending = true }
        defer { if ownsPendingFlag { isCommandPending = false } }
        let generation = operationGeneration
        try Task.checkCancellation()
        if let expectedGeneration { try ensureCurrentOperation(expectedGeneration) }
        guard controlTransport.phase == .ready, controlTransport.control.indicationReady,
            controlTransport.control.permission, controlTransport.control.stopAccepted,
            !controlTransport.control.requiresReconnect, controlTransport.control.pending == nil
        else {
            throw ControlError.blocked(
                "El canal FTMS perdió permiso o quedó incierto; no se envían objetivos automáticos.")
        }
        let observedBefore = controlTransport.snapshot?.telemetry?.speed?.value ?? 0
        let accepted = try await controlTransport.executeAndWait(
            .speed, speed: speed, allowProgramBackground: currentRecord?.mode == "program")
        let speedAcceptedAt = Date()
        try ensureCurrentOperation(generation)
        if var acceptedEngine = engine {
            acceptedEngine.updateEffectiveTargets(
                speedKPH: speed, inclinationPercent: acceptedEngine.effectiveInclinationPercent)
            engine = acceptedEngine
            snapshot = acceptedEngine.snapshot()
        }
        try await persistEventAsync(
            "workout.target.accepted",
            payload: [
                "metric": .string("speedKPH"), "requested": .number(speed),
                "procedureID": .string(accepted.id), "requestValueHex": .string(accepted.valueHex),
                "responseEventID": accepted.responseEventId.map(JSONValue.string) ?? .null,
                "interpretation": .string("acceptedByProtocol; awaiting sustained FTMS telemetry"),
            ])
        try await confirmSpeedTarget(
            speed, priorSpeed: observedBefore, after: speedAcceptedAt, generation: generation)
        try ensureCurrentOperation(generation)
        guard var engine else { return }
        if inclinationDisabledForWorkout
            || controlTransport.snapshot?.inclinationControlAdvertised != true
        {
            inclinationDisabledForWorkout = true
            engine.updateEffectiveTargets(
                speedKPH: speed, inclinationPercent: nil, inclinationAccepted: false)
            self.engine = engine
            snapshot = engine.snapshot()
            try await persistEventAsync(
                "workout.inclination.unavailable",
                payload: [
                    "requestedPercent": .number(inclination),
                    "reason": .string("Control de inclinación FTMS no anunciado para esta sesión."),
                    "speedContinues": .bool(true),
                ])
            return
        }
        if let measured = controlTransport.snapshot?.telemetry?.inclination,
            !measured.isStale(at: Date()), abs(measured.value - inclination) <= 0.5
        {
            engine.updateEffectiveTargets(speedKPH: speed, inclinationPercent: inclination)
            self.engine = engine
            snapshot = engine.snapshot()
            try await persistEventAsync(
                "workout.inclination.alreadyObserved",
                payload: [
                    "targetPercent": .number(inclination), "measuredPercent": .number(measured.value),
                    "eventID": .string(measured.eventId),
                ])
            return
        }
        let previousInclineProcedureId = controlTransport.control.last?.id
        do {
            _ = try await controlTransport.executeAndWait(
                .inclination, inclination: inclination,
                allowProgramBackground: currentRecord?.mode == "program")
            try ensureCurrentOperation(generation)
            engine.updateEffectiveTargets(speedKPH: speed, inclinationPercent: inclination)
        } catch {
            try ensureCurrentOperation(generation)
            guard let last = controlTransport.control.last, last.id != previousInclineProcedureId,
                last.action == .inclination,
                last.result == "rejectedByProtocol", controlTransport.control.permission
            else { throw error }
            engine.updateEffectiveTargets(
                speedKPH: speed, inclinationPercent: nil, inclinationAccepted: false)
            inclinationDisabledForWorkout = true
            self.engine = engine
            snapshot = engine.snapshot()
            try await persistEventAsync(
                "workout.inclination.unavailable",
                payload: [
                    "requestedPercent": .number(inclination), "reason": .string(error.localizedDescription),
                    "speedContinues": .bool(true),
                ])
            if !inclinationMayFail { throw error }
        }
        self.engine = engine
        snapshot = engine.snapshot()
    }

    private func confirmSpeedTarget(
        _ target: Double, priorSpeed: Double, after acceptedAt: Date,
        generation: Int
    ) async throws {
        do {
            let observed = try await targetVerifier.confirmSpeed(
                target, priorSpeed: priorSpeed,
                acceptedAt: acceptedAt
            ) { try self.ensureCurrentOperation(generation) }
            try await persistEventAsync(
                "workout.target.observed",
                payload: [
                    "metric": .string("speedKPH"), "requested": .number(target),
                    "observed": .number(observed.value), "eventID": .string(observed.eventID),
                    "stableSeconds": .number(targetVerifier.stableSeconds),
                    "sampleCount": .number(Double(observed.sampleCount)),
                ])
        } catch let error as TargetObservationError {
            if case .notReached(_, let observed, let deadline) = error {
                try await persistEventAsync(
                    "workout.target.notReached",
                    payload: [
                        "metric": .string("speedKPH"), "requested": .number(target),
                        "lastObserved": observed.map(JSONValue.number) ?? .null,
                        "deadlineSeconds": .number(deadline), "automaticCommandsDisabled": .bool(true),
                    ])
            }
            throw ControlError.blocked(error.localizedDescription)
        }
    }

    private func sendStopAndConfirmZero(reason: String) async throws {
        let ownedPendingFlag = !isCommandPending
        if ownedPendingFlag { isCommandPending = true }
        defer { if ownedPendingFlag { isCommandPending = false } }
        schedulerTask?.cancel()
        schedulerTask = nil
        do {
            guard controlTransport.control.canStop else {
                throw ControlError.blocked("Stop Bluetooth no está listo. Usa la consola física.")
            }
            let sentAt = Date()
            _ = try await controlTransport.executeAndWait(
                .stop, allowProgramBackground: currentRecord?.mode == "program")
            try await waitForSpeed(after: sentAt, zero: true)
            try persistEvent(
                "workout.stop.confirmed",
                payload: ["reason": .string(reason), "freshZeroObserved": .bool(true)])
        } catch {
            enterManual(
                "La parada Bluetooth no quedó confirmada con velocidad reciente de 0 km/h; el movimiento físico puede continuar. Usa los controles físicos."
            )
            controlTransport.setProgramBackgroundLease(false)
            await cancelBackgroundTask(success: false)
            throw error
        }
    }

    private func waitForSpeed(after date: Date, zero: Bool, generation: Int? = nil) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let generation { try ensureCurrentOperation(generation) }
            guard controlTransport.phase == .ready, controlTransport.control.indicationReady,
                controlTransport.control.permission, !controlTransport.control.requiresReconnect
            else {
                throw ControlError.blocked(
                    "Se perdió la conexión o el permiso FTMS mientras se verificaba la velocidad.")
            }
            guard let metric = controlTransport.snapshot?.telemetry?.speed, !metric.isStale(at: Date()),
                metric.receivedAt > date
            else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if zero && metric.value == 0 { return }
            if !zero && metric.value > 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlError.blocked(
            zero
                ? "No se observó velocidad FTMS fresca de 0 km/h después de Stop."
                : "No se observó velocidad FTMS positiva y fresca después de Start.")
    }

    private func beginScheduler() {
        schedulerTask?.cancel()
        lastDispatchUptime = ProcessInfo.processInfo.systemUptime
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await self.schedulerStep()
            }
        }
    }

    func schedulerStep(at suppliedNow: TimeInterval? = nil) async {
        guard var engine, currentRecord?.endedAt == nil else { return }
        let generation = operationGeneration
        let now = suppliedNow ?? ProcessInfo.processInfo.systemUptime
        if isCommandPending {
            lastDispatchUptime = now
            return
        }
        let delta = now - (lastDispatchUptime ?? now)
        lastDispatchUptime = now
        if mockMode {
            let prior = engine.snapshot(at: now)
            _ = engine.tick(at: now)
            if engine.state == .manual {
                self.engine = engine
                snapshot = engine.snapshot(at: now)
                enterManual(
                    "El cronograma detectó una demora que cruzó el límite de una fase; se requiere control manual."
                )
                schedulerTask?.cancel()
                schedulerTask = nil
                return
            }
            let intervalChanged = prior.intervalIndex != engine.intervalIndex
            self.engine = engine
            snapshot = engine.snapshot(at: now)
            do {
                try appendMockSample(elapsed: delta)
                try await appendSyntheticFitnessSamples(activeSeconds: activeElapsed(engine), uptime: now)
                try persistEvent(
                    "workout.tick", source: "synthetic",
                    payload: ["clock": .string("monotonic"), "deltaSeconds": .number(delta)])
                if intervalChanged {
                    try persistEvent(
                        "workout.segment.changed", source: "synthetic",
                        payload: ["intervalIndex": .number(Double(engine.intervalIndex))])
                }
            } catch { errorMessage = error.localizedDescription }
            updateBackgroundProgress()
            if engine.state == .completed {
                do {
                    try await closeRecord(
                        snapshot: engine.snapshot(at: now), interrupted: false, event: "workout.completed",
                        reason: "programEnded")
                } catch { errorMessage = error.localizedDescription }
            }
            return
        }
        guard controlTransport.phase == .ready, controlTransport.control.indicationReady,
            controlTransport.control.permission, controlTransport.control.stopAccepted,
            !controlTransport.control.requiresReconnect, controlTransport.control.pending == nil,
            let speed = controlTransport.snapshot?.telemetry?.speed, !speed.isStale(at: Date())
        else {
            enterManual(
                "La velocidad FTMS está ausente o lleva más de cinco segundos sin actualizar; el cronograma requiere control manual."
            )
            schedulerTask?.cancel()
            schedulerTask = nil
            controlTransport.setProgramBackgroundLease(false)
            await cancelBackgroundTask(success: false)
            return
        }
        let source = MetricSource.machineFTMS
        let speedSample = WorkoutSample(
            value: speed.value, source: source, receivedAt: speed.receivedAt, monotonicTime: now,
            eventId: speed.eventId)
        engine.updateMeasuredSpeed(speedSample, at: now)
        if let inclination = controlTransport.snapshot?.telemetry?.inclination,
            !inclination.isStale(at: Date())
        {
            engine.updateMeasuredInclination(
                WorkoutSample(
                    value: inclination.value, source: source, receivedAt: inclination.receivedAt,
                    monotonicTime: now, eventId: inclination.eventId), at: now)
        }
        if let deviation = engine.deviation, deviation.metric == .speed,
            deviation.basis == .measuredVersusAccepted
        {
            self.engine = engine
            snapshot = engine.snapshot(at: now)
            try? persistEvent(
                "workout.target.lost",
                payload: [
                    "metric": .string("speedKPH"), "accepted": .number(deviation.expected),
                    "observed": .number(deviation.observed),
                    "sampleCount": .number(Double(deviation.sampleCount)),
                    "automaticCommandsDisabled": .bool(true),
                ])
            enterManual(
                "La velocidad medida dejó de coincidir con el objetivo aceptado. Automatización suspendida; revisa la consola física."
            )
            return
        }
        let oldIndex = engine.intervalIndex
        _ = engine.tick(at: now)
        if engine.state == .completed { _ = engine.beginFinishing(at: now) }
        self.engine = engine
        snapshot = engine.snapshot(at: now)
        if engine.state == .manual {
            enterManual(
                "El cronograma detectó una demora que cruzó el límite de una fase; no se aplicó un segmento atrasado."
            )
            schedulerTask?.cancel()
            schedulerTask = nil
            controlTransport.setProgramBackgroundLease(false)
            await cancelBackgroundTask(success: false)
            return
        }
        updateBackgroundProgress()
        do {
            try await persistEventAsync(
                "workout.tick", payload: ["clock": .string("monotonic"), "deltaSeconds": .number(delta)])
            try await appendSyntheticFitnessSamples(activeSeconds: activeElapsed(engine), uptime: now)
            if engine.intervalIndex != oldIndex {
                try await persistEventAsync(
                    "workout.segment.change.requested",
                    payload: ["intervalIndex": .number(Double(engine.intervalIndex))])
                try await store.flush()
                await beforeScheduledTarget?()
                try Task.checkCancellation()
                guard generation == operationGeneration, currentRecord?.endedAt == nil,
                    snapshot?.state == .running
                else { return }
                try await applyGoals(
                    speed: engine.currentInterval.targetSpeedKPH,
                    inclination: engine.currentInterval.targetInclinationPercent,
                    inclinationMayFail: true, expectedGeneration: generation)
                try await persistEventAsync(
                    "workout.segment.changed",
                    payload: ["intervalIndex": .number(Double(engine.intervalIndex))])
            }
        } catch {
            if Task.isCancelled || generation != operationGeneration || currentRecord?.endedAt != nil {
                return
            }
            enterManual("No se pudo aplicar o guardar el siguiente objetivo. Control manual requerido.")
            errorMessage = error.localizedDescription
            schedulerTask?.cancel()
            schedulerTask = nil
            controlTransport.setProgramBackgroundLease(false)
            await cancelBackgroundTask(success: false)
            return
        }
        if generation == operationGeneration, currentRecord?.endedAt == nil, engine.state == .finishing {
            do {
                try await sendStopAndConfirmZero(reason: "programCompleted")
                engine = self.engine ?? engine
                _ = engine.complete()
                self.engine = engine
                snapshot = engine.snapshot()
                await cancelBackgroundTask(success: true)
                controlTransport.setProgramBackgroundLease(false)
                try await closeRecord(
                    snapshot: engine.snapshot(), interrupted: false, event: "workout.completed",
                    reason: "programEnded")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func captureHardwareSamples() throws {
        if let telemetryWriteError {
            throw ControlError.blocked("Falló el guardado de muestras FTMS: \(telemetryWriteError)")
        }
        guard let telemetry = controlTransport.snapshot?.telemetry else { return }
        enqueueHardwareSamples(telemetry)
    }

    func captureTelemetryCallback(_ telemetry: FTMSTelemetry) {
        guard !mockMode, hasOpenWorkout, !hardwareSampleCaptureClosed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let speed = telemetry.speed, !speed.isStale(at: Date()) {
            let sample = WorkoutSample(
                value: speed.value, source: .machineFTMS, receivedAt: speed.receivedAt,
                monotonicTime: now, eventId: speed.eventId)
            engine?.updateMeasuredSpeed(sample, at: now)
        }
        if let incline = telemetry.inclination, !incline.isStale(at: Date()) {
            let sample = WorkoutSample(
                value: incline.value, source: .machineFTMS, receivedAt: incline.receivedAt,
                monotonicTime: now, eventId: incline.eventId)
            engine?.updateMeasuredInclination(sample, at: now)
        }
        if let engine { snapshot = engine.snapshot(at: now) }
        enqueueHardwareSamples(telemetry)
    }

    private func enqueueHardwareSamples(_ telemetry: FTMSTelemetry) {
        guard !hardwareSampleCaptureClosed, let record = currentRecord, record.endedAt == nil,
            let engine, let repository
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = engine.currentInterval
        func recorded(_ metric: String, _ sample: WorkoutSample) -> WorkoutRecordedSample {
            WorkoutRecordedSample(
                metric: metric, sample: sample, intervalIndex: engine.intervalIndex,
                plannedSpeedKPH: interval.targetSpeedKPH,
                plannedInclinationPercent: interval.targetInclinationPercent,
                effectiveSpeedKPH: engine.effectiveSpeedKPH,
                effectiveInclinationPercent: engine.effectiveInclinationPercent)
        }
        var samples: [WorkoutRecordedSample] = []
        if let speed = telemetry.speed, speed.eventId != lastSpeedEventId {
            lastSpeedEventId = speed.eventId
            samples.append(
                recorded(
                    "speedKPH",
                    WorkoutSample(
                        value: speed.value, source: .machineFTMS, receivedAt: speed.receivedAt,
                        monotonicTime: now, eventId: speed.eventId)))
        }
        if let incline = telemetry.inclination, incline.eventId != lastInclinationEventId {
            lastInclinationEventId = incline.eventId
            samples.append(
                recorded(
                    "inclinationPercent",
                    WorkoutSample(
                        value: incline.value, source: .machineFTMS, receivedAt: incline.receivedAt,
                        monotonicTime: now, eventId: incline.eventId)))
        }
        if let progress = store.currentDistanceProgress,
            telemetry.distance?.eventId != lastDistanceEventId, let id = telemetry.distance?.eventId
        {
            lastDistanceEventId = id
            let distance = max(0, Double(progress.accumulatedMeters) - distanceBaselineMeters)
            samples.append(
                recorded(
                    "sessionDistanceMeters",
                    WorkoutSample(
                        value: distance, source: .derived, receivedAt: telemetry.distance!.receivedAt,
                        monotonicTime: now, eventId: id)))
        }
        guard !samples.isEmpty else { return }
        let event = WorkoutRuntimeEvent(
            sequence: record.eventCount + 1, kind: "workout.samples.captured", source: "hardware",
            payload: ["sampleCount": .number(Double(samples.count))])
        let previous = telemetryWriteTail
        telemetryWriteTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let committed = try await repository.appendSamplesAsync(
                    workoutID: record.id, samples: samples, event: event)
                if var current = self.currentRecord, current.id == record.id {
                    current.sampleCount = max(current.sampleCount, committed.sampleCount)
                    current.eventCount = max(current.eventCount, committed.eventCount)
                    self.currentRecord = current
                    self.updateLatestMetrics(samples)
                }
                if self.store.session?.isOpen == true {
                    try self.store.record(kind: event.kind, source: .hardware, payload: event.payload)
                }
                self.publishCompanionView()
            } catch {
                self.telemetryWriteError = error.localizedDescription
                self.errorMessage = FitnessText.format(
                    "workout.telemetrySaveFailed", error.localizedDescription)
                self.schedulerTask?.cancel()
                self.schedulerTask = nil
                self.controlTransport.setProgramBackgroundLease(false)
                await self.cancelBackgroundTask(success: false)
                self.enterManual("Falló el guardado de la evidencia; el cronograma pasa a control manual.")
            }
        }
    }

    private func flushHardwareSamples() async throws {
        await telemetryWriteTail?.value
        if let telemetryWriteError {
            throw ControlError.blocked("Falló el guardado de muestras FTMS: \(telemetryWriteError)")
        }
    }

    private func appendMockSample(elapsed: TimeInterval) throws {
        guard let repository else { throw SessionError.storageUnavailable }
        guard var record = currentRecord, let engine else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let speed = engine.effectiveSpeedKPH ?? 0
        mockDistanceMeters += max(0, speed) / 3.6 * max(0, elapsed)
        let date = Date()
        var samples = [
            WorkoutRecordedSample(
                metric: "speedKPH",
                sample: WorkoutSample(value: speed, source: .mock, receivedAt: date, monotonicTime: now)),
            WorkoutRecordedSample(
                metric: "sessionDistanceMeters",
                sample: WorkoutSample(
                    value: mockDistanceMeters, source: .mock, receivedAt: date, monotonicTime: now)),
        ]
        if let incline = engine.effectiveInclinationPercent {
            samples.append(
                WorkoutRecordedSample(
                    metric: "inclinationPercent",
                    sample: WorkoutSample(value: incline, source: .mock, receivedAt: date, monotonicTime: now)
                ))
        }
        record.latestSnapshot = engine.snapshot(at: now)
        try repository.save(
            record, samples: samples,
            events: [
                WorkoutRuntimeEvent(
                    sequence: record.eventCount + 1, occurredAt: date, kind: "workout.mock.samples",
                    source: "synthetic", payload: ["source": .string("mock")])
            ])
        currentRecord = try repository.record(id: record.id)
        updateLatestMetrics(samples)
    }

    private func activeElapsed(_ engine: WorkoutEngine) -> Int {
        Int(max(0, engine.snapshot().activeElapsedSeconds ?? 0))
    }

    private func appendSyntheticFitnessSamples(activeSeconds: Int, uptime: TimeInterval) async throws {
        guard mockMetricsEnabled, !watchMetricsSuppressed, recordUsesWatch != true, let repository,
            var record = currentRecord, record.endedAt == nil,
            let engine
        else { return }
        let speed = engine.effectiveSpeedKPH ?? engine.currentInterval.targetSpeedKPH
        let distance =
            mockMode
            ? mockDistanceMeters
            : max(
                0, Double(store.currentDistanceProgress?.accumulatedMeters ?? 0) - distanceBaselineMeters)
        let date = Date()
        let interval = engine.currentInterval
        var samples = WorkoutMockMetrics.samples(
            speedKPH: speed, distanceMeters: distance,
            activeSeconds: TimeInterval(activeSeconds), at: date, uptime: uptime)
        samples = samples.map { row in
            var enriched = row
            enriched.intervalIndex = engine.intervalIndex
            enriched.plannedSpeedKPH = interval.targetSpeedKPH
            enriched.plannedInclinationPercent = interval.targetInclinationPercent
            enriched.effectiveSpeedKPH = engine.effectiveSpeedKPH
            enriched.effectiveInclinationPercent = engine.effectiveInclinationPercent
            return enriched
        }
        record.latestSnapshot = engine.snapshot(at: uptime)
        let event = WorkoutRuntimeEvent(
            sequence: record.eventCount + 1, occurredAt: date, kind: "workout.synthetic.metrics",
            source: "synthetic",
            payload: [
                "source": .string("mock"),
                "reason": .string("No se expone una señal real para frecuencia cardíaca, pasos o energía."),
            ])
        let committed = try await repository.appendSamplesAsync(
            workoutID: record.id, samples: samples,
            event: event, snapshot: record.latestSnapshot)
        if var current = currentRecord, current.id == record.id {
            current.sampleCount = max(current.sampleCount, committed.sampleCount)
            current.eventCount = max(current.eventCount, committed.eventCount)
            currentRecord = current
            updateLatestMetrics(samples)
        }
    }

    private func updateLatestMetrics(_ samples: [WorkoutRecordedSample]) {
        for item in samples { latestMetrics[item.metric] = item.sample }
    }

    private func markManual(_ reason: String) throws {
        operationGeneration += 1
        schedulerTask?.cancel()
        schedulerTask = nil
        controlTransport.setProgramBackgroundLease(false)
        Task { [weak self] in await self?.cancelBackgroundTask(success: false) }
        guard var engine else { return }
        engine.suspendToManual(reason: reason)
        self.engine = engine
        snapshot = engine.snapshot()
        try persistEvent(
            "workout.manualRequired",
            payload: ["reason": .string(reason), "automaticCommandsDisabled": .bool(true)])
        errorMessage = reason
    }

    private func enterManual(_ reason: String) {
        do { try markManual(reason) } catch {
            errorMessage = "\(reason) No se pudo guardar este estado: \(error.localizedDescription)"
        }
    }

    private func closeRecord(
        snapshot: WorkoutSnapshot, interrupted: Bool, event: String, reason: String
    ) async throws {
        schedulerTask?.cancel()
        schedulerTask = nil
        hardwareSampleCaptureClosed = true
        try await flushHardwareSamples()
        guard var record = currentRecord else { return }
        record.latestSnapshot = snapshot
        record.endedAt = Date()
        record.interrupted = interrupted
        try saveRecord(
            record,
            event: WorkoutRuntimeEvent(sequence: 0, kind: event, payload: ["reason": .string(reason)]))
        if record.healthSave != nil { companion?.finalize(id: record.id, view: companionView(record)) }
        self.snapshot = snapshot
        if let repository { history = try repository.history() }
        if bluetooth.hasConnection {
            bluetooth.disconnect(reason: "workoutFinished")
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while bluetooth.phase == .disconnecting && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        if store.session?.isOpen == true, bluetooth.phase != .disconnecting { try store.closeSession() }
        pendingProgram = nil
        pendingMode = nil
    }

    private func persistEvent(
        _ kind: String, source: String = "application", payload: [String: JSONValue]
    ) throws {
        guard var record = currentRecord, record.endedAt == nil else { return }
        record.latestSnapshot = engine?.snapshot() ?? snapshot ?? record.latestSnapshot
        let event = WorkoutRuntimeEvent(
            sequence: (currentRecord?.eventCount ?? record.eventCount) + 1, kind: kind, source: source,
            payload: payload)
        try saveRecord(record, event: event)
    }

    private func persistEventAsync(
        _ kind: String, source: String = "application", payload: [String: JSONValue]
    ) async throws {
        guard let record = currentRecord, record.endedAt == nil, let repository else { return }
        let event = WorkoutRuntimeEvent(
            sequence: record.eventCount + 1, kind: kind, source: source, payload: payload)
        let committed = try await repository.appendSamplesAsync(
            workoutID: record.id, samples: [], event: event,
            snapshot: engine?.snapshot() ?? snapshot)
        if var current = currentRecord, current.id == record.id {
            current.sampleCount = max(current.sampleCount, committed.sampleCount)
            current.eventCount = max(current.eventCount, committed.eventCount)
            currentRecord = current
        }
        if store.session?.isOpen == true {
            let evidenceSource: EvidenceSource =
                source == "synthetic"
                ? .synthetic : source == "operatorReported" ? .userReported : .application
            try store.record(kind: kind, source: evidenceSource, payload: payload)
        }
        publishCompanionView()
    }

    private func runStartStage<T>(_ stage: String, operation: () async throws -> T) async throws -> T {
        let started = ProcessInfo.processInfo.systemUptime
        try await recordStartStage(stage, status: "began", durationMilliseconds: 0)
        do {
            let result = try await operation()
            try await recordStartStage(
                stage, status: "completed",
                durationMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
            return result
        } catch {
            failedStartStage = stage
            try? await recordStartStage(
                stage, status: "failed",
                durationMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                error: error)
            throw error
        }
    }

    private func recordStartStage(
        _ stage: String, status: String, durationMilliseconds: Double,
        error: (any Error)? = nil
    ) async throws {
        let control = controlTransport.control
        var payload: [String: JSONValue] = [
            "workoutID": .string(pendingWorkoutID ?? currentRecord?.id ?? "unknown"),
            "stage": .string(stage), "status": .string(status),
            "durationMilliseconds": .number(durationMilliseconds),
            "bluetoothPhase": .string(controlTransport.phase.rawValue),
            "selectedProtocol": .string(controlTransport.selectedProtocol.rawValue),
            "ftmsIndicationReady": .bool(control.indicationReady),
            "ftmsPermission": .bool(control.permission),
            "ftmsStopAccepted": .bool(control.stopAccepted),
            "ftmsCanStart": .bool(control.canStart),
            "ftmsConnectionPresent": .bool(controlTransport.snapshot?.connectionState == "connected"),
            "ftmsSubscriptionStatus": .string(
                controlTransport.snapshot?.telemetry?.subscriptionStatus ?? "unknown"),
            "ftmsSubscriptionOperationID": .string(
                controlTransport.snapshot?.telemetry?.subscriptionOperationId ?? "unknown"),
        ]
        if let error {
            let original = error as NSError
            payload["errorType"] = .string(String(reflecting: type(of: error)))
            payload["error"] = .string(String(reflecting: error))
            payload["errorDescription"] = .string(error.localizedDescription)
            payload["errorDomain"] = .string(original.domain)
            payload["errorCode"] = .number(Double(original.code))
        }
        try await store.recordDurably(kind: "workout.start.stage", payload: payload)
    }

    private func ensureCurrentOperation(_ generation: Int) throws {
        guard generation == operationGeneration, currentRecord?.endedAt == nil else {
            throw ControlError.blocked(
                "La orden fue interrumpida por una acción prioritaria del operador.")
        }
    }

    private func saveRecord(
        _ record: WorkoutRecord, samples: [WorkoutRecordedSample] = [],
        event: WorkoutRuntimeEvent? = nil
    ) throws {
        guard let repository else { throw SessionError.storageUnavailable }
        var event = event
        if event != nil { event!.sequence = (currentRecord?.eventCount ?? record.eventCount) + 1 }
        let events = event.map { [$0] } ?? []
        try repository.save(record, samples: samples, events: events)
        currentRecord = try repository.record(id: record.id) ?? record
        publishCompanionView()
        if let event, store.session?.isOpen == true {
            let evidenceSource: EvidenceSource =
                event.source == "synthetic"
                ? .synthetic : event.source == "operatorReported" ? .userReported : .application
            try store.record(kind: event.kind, source: evidenceSource, payload: event.payload)
        }
    }

    /// One bounded live publication route for both synchronous and async
    /// persistence. PhoneWatchService throttles unchanged state to one view/s.
    private func publishCompanionView() {
        guard let record = currentRecord, record.endedAt == nil, record.healthSave != nil else {
            return
        }
        // Async repository commits can finish after a newer UI transition.
        // Publish the current engine state, while retaining the durable record
        // identity and the latest live metrics.
        let liveSnapshot = engine?.snapshot() ?? snapshot ?? record.latestSnapshot
        companion?.publish(
            id: record.id,
            view: CompanionWorkoutView(
                snapshot: liveSnapshot,
                metrics: latestMetrics, startedAt: record.startedAt, endedAt: record.endedAt,
                synthetic: mockMode || record.mode == "mock"))
    }

    private func restoreInterruptedWorkoutIfNeeded() {
        guard let record = history.first(where: { $0.endedAt == nil }) else { return }
        guard let repository else {
            errorMessage = SessionError.storageUnavailable.localizedDescription
            return
        }
        var recovered = record
        let old = record.latestSnapshot
        recovered.latestSnapshot = WorkoutSnapshot(
            state: .interrupted, phase: old.phase, intervalIndex: old.intervalIndex,
            phaseElapsedSeconds: old.phaseElapsedSeconds, program: old.program,
            effectiveSpeedKPH: old.effectiveSpeedKPH,
            effectiveInclinationPercent: old.effectiveInclinationPercent,
            measuredSpeed: old.measuredSpeed,
            measuredInclination: old.measuredInclination, deviation: old.deviation,
            activeElapsedSeconds: old.activeElapsedSeconds, pausedElapsedSeconds: old.pausedElapsedSeconds
        )
        recovered.endedAt = Date()
        recovered.interrupted = true
        do {
            let event = WorkoutRuntimeEvent(
                sequence: record.eventCount + 1, kind: "workout.interruptedAfterRelaunch",
                payload: [
                    "reason": .string(
                        "La aplicación se cerró con el entrenamiento abierto; no se reanuda automáticamente."),
                    "automaticStart": .bool(false),
                ])
            try repository.save(recovered, samples: [], events: [event])
            currentRecord = try repository.record(id: record.id)
            snapshot = recovered.latestSnapshot
            history = try repository.history()
            if store.session?.isOpen == true {
                try store.record(
                    kind: "workout.restored",
                    payload: [
                        "workoutId": .string(record.id),
                        "reason": .string("No se reanuda automáticamente tras restaurar."),
                        "automaticStart": .bool(false),
                    ])
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func submitBackgroundTask() async throws {
        let total = max(1, pendingProgram?.intervals.reduce(0) { $0 + $1.durationSeconds } ?? 1)
        try await backgroundService.begin(
            totalSeconds: total,
            onExpiration: { [weak self] in
                self?.backgroundExpired()
            })
        backgroundTaskActive = true
    }

    fileprivate func backgroundExpired() {
        guard backgroundTaskActive else { return }
        backgroundTaskActive = false
        schedulerTask?.cancel()
        schedulerTask = nil
        controlTransport.setProgramBackgroundLease(false)
        enterManual(
            "iOS terminó la concesión de continuidad. El cronograma pasa a control manual; no se envía Stop automático."
        )
    }

    private func cancelBackgroundTask(success: Bool = true) async {
        guard backgroundTaskActive else { return }
        backgroundTaskActive = false
        await backgroundService.end(success: success)
    }

    private func updateBackgroundProgress() {
        guard backgroundTaskActive, let engine else { return }
        let completed =
            engine.program.intervals.prefix(engine.intervalIndex).reduce(0) { $0 + $1.durationSeconds }
            + Int(engine.phaseElapsedSeconds)
        let total = max(1, engine.program.intervals.reduce(0) { $0 + $1.durationSeconds })
        backgroundService.update(completedSeconds: completed, totalSeconds: total)
    }
}

private struct WorkoutExportPayload: Codable, Sendable {
    var record: WorkoutRecord
    var samples: [WorkoutRecordedSample]
    var events: [WorkoutRuntimeEvent]
}
