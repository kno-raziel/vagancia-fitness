import FitnessCore
import Foundation
@preconcurrency import HealthKit
import Observation
@preconcurrency import WatchConnectivity
import WatchKit
import os

@MainActor @Observable
final class WatchWorkoutService: NSObject {
    static let shared = WatchWorkoutService()
    private(set) var readiness = WatchReadiness()
    private(set) var current: WatchSessionRecord?
    private(set) var phoneReachable = false
    private(set) var errorMessage: String?
    var orphanedPreparation: WatchOrphanedPreparation? {
        guard orphanReviewNeeded, !blockedRecoveredSession, let current,
            current.canDiscardPreparation(for: current.id),
            workoutOwnerID == current.id || workout == nil
        else { return nil }
        return WatchOrphanedPreparation(
            id: current.id, state: current.captureState,
            message: WatchText.string(
                "Preparación anterior sin captura. Puedes descartarla para preparar otra sesión."))
    }
    var canFinishRecoveredCapture: Bool {
        guard let current, workoutOwnerID == current.id, let builder else { return false }
        let builderSessionID =
            builder.metadata["VaganciaSessionID"] as? String ?? builder.metadata[
                HKMetadataKeyExternalUUID] as? String
        return current.canFinishRecoveredCapture(
            builderSessionID: builderSessionID,
            collectionConfirmed: startedCollection)
    }
    private(set) var accessReviewed = UserDefaults.standard.bool(forKey: "watch.healthAccessReviewed")
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var ledger: WatchSessionLedger?
    @ObservationIgnored private var rejectionJournal: WatchRejectedEnvelopeJournal?
    @ObservationIgnored private let rejectionLogger = Logger(
        subsystem: "dev.vaganciafitness.kraziel.watch", category: "companion-rejection")
    @ObservationIgnored private var channel: WCSession?
    @ObservationIgnored private var workout: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var workoutOwnerID: String?
    @ObservationIgnored private var sequence: UInt64 = UInt64(
        UserDefaults.standard.integer(forKey: "watch.messageSequence"))
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var didActivate = false
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private var rejectedChunkCursor: [String: Int] = [:]
    @ObservationIgnored private var rejectedFlushTask: Task<Void, Never>?
    @ObservationIgnored private var startedCollection = false
    @ObservationIgnored private var launchConfiguration: HKWorkoutConfiguration?
    @ObservationIgnored private var preparationController: WatchPreparationController!
    private var orphanReviewNeeded = false
    private var blockedRecoveredSession = false
    @ObservationIgnored private var workoutLifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var heartAnchor: HKQueryAnchor?
    @ObservationIgnored private var heartQueryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0

    override init() {
        super.init()
        do {
            let directory = URL.applicationSupportDirectory.appendingPathComponent(
                "VaganciaWatch", isDirectory: true)
            let ledger = try WatchSessionLedger(directory: directory)
            self.ledger = ledger
            rejectionJournal = try WatchRejectedEnvelopeJournal(directory: directory)
            if let id = UserDefaults.standard.string(forKey: "watch.currentSession"),
                var restored = ledger.sessions[id]
            {
                restored.markRecovered()
                try ledger.save(restored)
                current = restored
                orphanReviewNeeded = restored.canDiscardPreparation(for: restored.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            readiness = WatchReadiness(state: .failed, message: error.localizedDescription)
        }
        let storedAttempts =
            UserDefaults.standard.dictionary(forKey: "watch.cancelledPreparationAttempts")
            as? [String: [String]] ?? [:]
        preparationController = WatchPreparationController(
            effects: self, restored: current,
            cancelledAttempts: storedAttempts.mapValues { Set($0) })
    }

    func activate() {
        guard !didActivate else { return }
        didActivate = true
        guard WCSession.isSupported() else { return }
        channel = .default
        channel?.delegate = self
        channel?.activate()
        flushRejectedEnvelopes()
        if WatchRecoveryPolicy.shouldInspectHealthKit(current) {
            scheduleRecovery()
        } else {
            updateReadiness(accessReviewed ? .idle : .accessNeeded)
        }
    }

    func scheduleRecovery() {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { await recover() }
    }

    /// HealthKit delivers this even while another app is on screen. Prepare the
    /// mirrored session immediately; the durable WC message later binds its ID.
    func handleLaunchConfiguration(_ configuration: HKWorkoutConfiguration) {
        launchConfiguration = configuration
        activate()
        guard accessReviewed else {
            updateReadiness(
                .accessNeeded,
                message: WatchText.string("Revisa el acceso a Salud en el Watch antes de preparar."))
            return
        }
        guard recoveryTask == nil else { return }
        Task {
            do { try await preparationController.launchArrived() } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func ensurePreparedWorkout(configuration: HKWorkoutConfiguration, ownerID: String?)
        async throws -> Bool
    {
        if workout != nil {
            if workoutOwnerID == nil, let ownerID {
                workoutOwnerID = ownerID
                workoutLifecycleGeneration = preparationController.generation
            }
            return workout?.state == .prepared
        }
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let liveBuilder = session.associatedWorkoutBuilder()
        sessionGeneration &+= 1
        workout = session
        builder = liveBuilder
        session.delegate = self
        liveBuilder.delegate = self
        workoutOwnerID = ownerID
        workoutLifecycleGeneration = preparationController.generation
        Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, let session, self.workout === session,
                self.workoutOwnerID == nil,
                self.current == nil || self.current?.captureState != .running
            else { return }
            session.end()
            self.builder?.discardWorkout()
            self.workout = nil
            self.builder = nil
            self.workoutOwnerID = nil
        }
        let source = HKLiveWorkoutDataSource(
            healthStore: healthStore, workoutConfiguration: configuration)
        source.disableCollection(for: HKQuantityType(.distanceWalkingRunning))
        source.disableCollection(for: HKQuantityType(.stepCount))
        liveBuilder.dataSource = source
        session.prepare()
        do { try await session.startMirroringToCompanionDevice() } catch {
            if workout === session {
                errorMessage = WatchText.format(
                    "Preparación HealthKit activa; enlace reflejado pendiente: %@", error.localizedDescription
                )
            }
        }
        return workout === session && session.state == .prepared
    }

    func requestHealthAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            fail(WatchText.string("Salud no está disponible."))
            return
        }
        do {
            let workoutType = HKObjectType.workoutType()
            let pulse = HKQuantityType(.heartRate)
            let energy = HKQuantityType(.activeEnergyBurned)
            let distance = HKQuantityType(.distanceWalkingRunning)
            try await healthStore.requestAuthorization(
                toShare: [workoutType, energy, distance], read: [workoutType, pulse, energy, distance])
            accessReviewed = true
            UserDefaults.standard.set(true, forKey: "watch.healthAccessReviewed")
            updateReadiness(
                .idle,
                message: WatchText.string("Acceso revisado. Las lecturas se confirmarán durante la sesión.")
            )
        } catch { fail(error.localizedDescription) }
    }

    func resolveOrphanedPreparation() async throws {
        await recoveryTask?.value
        guard let orphanedPreparation else { throw CompanionError.notPrepared }
        guard preparationController.resolveOrphan(id: orphanedPreparation.id) else {
            throw CompanionError.conflict
        }
        sessionGeneration &+= 1
        orphanReviewNeeded = false
        emitHealthResult(id: orphanedPreparation.id)
    }
    func finishRecoveredCapture() async throws {
        guard canFinishRecoveredCapture, let record = current else { throw CompanionError.conflict }
        let view = CompanionWorkoutView(
            snapshot: record.view.snapshot, metrics: record.view.metrics,
            startedAt: record.view.startedAt, endedAt: Date(), generatedAt: Date(), synthetic: false)
        let message = CompanionMessage(
            sessionID: record.id, sender: "iphone",
            sequence: record.viewGate.sequence &+ 1, payload: .finish(view))
        try await receive(message)
    }

    func refreshConnection() {
        phoneReachable = channel?.isReachable == true
        send(.accessFacts(accessFacts()), id: "setup")
        send(.readiness(readiness), id: current?.id ?? "setup")
        if phoneReachable { flushPending(force: true) }
    }
    func drainIncoming() async { await operation?.value }
    func handleBackgroundTasks(_ tasks: Set<WKRefreshBackgroundTask>) {
        activate()
        Task { @MainActor in
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while channel?.activationState != .activated || channel?.hasContentPending == true,
                ProcessInfo.processInfo.systemUptime < deadline
            {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await drainIncoming()
            for task in tasks { task.setTaskCompletedWithSnapshot(false) }
        }
    }

    #if DEBUG
        func loadPreview(_ scene: String) {
            let now = Date()
            let old = now.addingTimeInterval(-18)
            let program = WorkoutProgram.seedPrograms[0]
            let state: WorkoutState =
                scene == "paused"
                ? .paused : scene == "stopping" ? .pausing : scene == "summary" ? .completed : .running
            let snapshot = WorkoutSnapshot(
                state: state, phase: .work, intervalIndex: 2, phaseElapsedSeconds: 60, program: program,
                effectiveSpeedKPH: 3, effectiveInclinationPercent: 0, measuredSpeed: nil,
                measuredInclination: nil, deviation: nil, activeElapsedSeconds: 744)
            let metrics: [String: WorkoutSample] = [
                "speedKPH": .init(
                    value: state == .paused ? 0 : 3, source: .mock,
                    receivedAt: scene == "stale-phone" ? old : now),
                "sessionDistanceMeters": .init(
                    value: 620, source: .mock, receivedAt: scene == "stale-phone" ? old : now),
                "inclinationPercent": .init(value: 0, source: .mock, receivedAt: now),
            ]
            let view = CompanionWorkoutView(
                snapshot: snapshot, metrics: metrics, startedAt: now.addingTimeInterval(-744),
                endedAt: scene == "summary" ? now : nil,
                generatedAt: scene == "stale-phone" ? old : now, synthetic: true)
            var record = WatchSessionRecord(id: "preview-only", view: view)
            if scene == "conflict" {
                record.captureState = .failed
                record.health = HealthSaveResult(
                    state: .discarded,
                    message: WatchText.string("Ejemplo de preparación anterior sin captura."))
                current = record
                preparationController.restore(record)
                orphanReviewNeeded = true
                readiness = WatchReadiness(
                    state: .failed, message: WatchText.string("Ejemplo · preparación anterior pendiente."))
                phoneReachable = true
                return
            }
            record.captureState = scene == "summary" ? .ended : state == .paused ? .paused : .running
            record.captureStartedAt = now.addingTimeInterval(-744)
            _ = record.add(
                .init(
                    metric: "heartRateBPM", value: 124, unit: "count/min",
                    sampledAt: scene == "stale-pulse" ? old : now, periodStart: old,
                    device: "Simulated Watch", sourceIdentifier: "ui.fixture"))
            _ = record.add(
                .init(
                    metric: "energyKilocalories", value: 65, unit: "kcal", sampledAt: now, periodStart: old,
                    device: "Simulated Watch", sourceIdentifier: "ui.fixture"))
            record.health = HealthSaveResult(
                state: .pending, message: WatchText.string("Ejemplo · no se escribe en Salud"))
            current = scene == "setup" || scene == "ready" ? nil : record
            readiness = WatchReadiness(state: scene == "ready" ? .prepared : .idle)
            phoneReachable = true
        }
    #endif

    func recover() async {
        defer { recoveryTask = nil }
        guard workout == nil, let record = current else { return }
        let ticket = WatchRecoveryTicket(
            sessionID: record.id, generation: sessionGeneration, observedState: record.captureState)
        do {
            let recoveredSession = try await healthStore.recoverActiveWorkoutSession()
            guard
                ticket.matches(
                    currentID: current?.id, generation: sessionGeneration, hasWorkout: workout != nil,
                    currentState: current?.captureState)
            else { return }
            if let existing = recoveredSession {
                let recoveredBuilder = existing.associatedWorkoutBuilder()
                let builderSessionID =
                    recoveredBuilder.metadata["VaganciaSessionID"] as? String ?? recoveredBuilder.metadata[
                        HKMetadataKeyExternalUUID] as? String
                if record.captureState == .failed,
                    !(record.captureStartedAt == nil
                        ? WatchRecoveryPolicy.mayBindRecoveredFailedPreparation(
                            record,
                            healthSessionPrepared: existing.state == .prepared,
                            collectionStartedAt: recoveredBuilder.startDate,
                            collectionEndedAt: recoveredBuilder.endDate,
                            builderSessionID: builderSessionID)
                        : WatchRecoveryPolicy.mayBindRecoveredCapturedSession(
                            record,
                            builderSessionID: builderSessionID,
                            collectionStartedAt: recoveredBuilder.startDate,
                            healthSessionActive: [.running, .paused].contains(existing.state)))
                {
                    blockedRecoveredSession = true
                    errorMessage = WatchText.string(
                        "HealthKit conserva una sesión activa que no puede asociarse con seguridad a esta preparación fallida. Revísala en Salud; no se descartó ni se inició otra."
                    )
                    return
                }
                sessionGeneration &+= 1
                workout = existing
                builder = recoveredBuilder
                existing.delegate = self
                builder?.delegate = self
                workoutOwnerID = record.id
                preparationController.attachRecovered(ownerID: record.id)
                workoutLifecycleGeneration = preparationController.generation
                var recovered = record
                startedCollection = recovered.reconcileRecoveredCollection(
                    builderStartAt: builder?.startDate,
                    workoutActive: [.running, .paused].contains(existing.state),
                    builderEnded: builder?.endDate != nil)
                let storedDistance =
                    builder?.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?
                    .doubleValue(for: .meter()) ?? 0
                recovered.distance.reconcileStoredTotal(storedDistance)
                try persist(recovered)
                if !startedCollection, recovered.captureIntentAt == nil, existing.state == .prepared {
                    updateReadiness(
                        .prepared,
                        message: WatchText.string(
                            "Preparación recuperada sin captura. Puedes descartarla expresamente si ya no la necesitas."
                        ))
                    orphanReviewNeeded = true
                } else {
                    updateReadiness(
                        .recovering,
                        message: WatchText.string(
                            startedCollection
                                ? "Captura recuperada desde HealthKit."
                                : "Estado de colección por confirmar en HealthKit; no se inicia otra."))
                }
                do { try await existing.startMirroringToCompanionDevice() } catch {
                    if workout === existing {
                        errorMessage = WatchText.format(
                            "Sesión recuperada; enlace reflejado pendiente: %@", error.localizedDescription)
                    }
                }
                guard workout === existing, current?.id == record.id else { return }
                send(.statusRequest, id: record.id)
            } else if [.running, .paused, .preparing, .prepared].contains(record.captureState) {
                var next = record
                next.captureState = .failed
                if next.captureStartedAt != nil { next.health.state = .uncertain }
                try persist(next)
                updateReadiness(
                    .failed,
                    message: WatchText.string("La captura se interrumpió. Revisa la sesión en el iPhone."))
            }
            if let state = current?.health.state, [.saving, .uncertain, .saved].contains(state) {
                await reconcile()
            }
        } catch {
            if ticket.matches(
                currentID: current?.id, generation: sessionGeneration, hasWorkout: workout != nil,
                currentState: current?.captureState)
            {
                fail(error.localizedDescription)
            }
        }
    }

    func reconcile() async {
        guard var record = current else { return }
        do {
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [record.id])
            let found: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: .workoutType(), predicate: predicate, limit: 2,
                    sortDescriptors: nil, resultsHandler: WatchHealthQueryCallbacks.workouts(continuation))
                healthStore.execute(query)
            }
            guard let latest = current, latest.id == record.id else { return }
            record = latest  // Keep samples appended while the HealthKit query ran.
            if let saved = found.first {
                record.replaceHealthResult(
                    HealthSaveResult(
                        state: .saved, workoutUUID: saved.uuid.uuidString,
                        message: found.count > 1
                            ? WatchText.string("Se detectaron varias entradas; revisar en Salud.") : nil,
                        captureStartedAt: saved.startDate, captureEndedAt: saved.endDate,
                        distanceMeters: record.distance.totalMeters))
                record.captureState = .ended
                try persist(record)
            } else if record.health.state == .saving || record.health.state == .uncertain {
                var result = record.health
                result.state = .uncertain
                result.message = WatchText.string(
                    "No se confirmó una entrada existente. Revisa Salud y el permiso de lectura; no se repetirá el guardado incierto."
                )
                result.updatedAt = Date()
                record.replaceHealthResult(result)
                try persist(record)
            }
            emitHealthResult(id: record.id)
        } catch { fail(error.localizedDescription) }
    }

    private func enqueue(_ data: Data, channel: String) {
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await self.receive(CompanionMessage.decode(data)) } catch {
                let decoded = try? JSONDecoder().decode(CompanionMessage.self, from: data)
                let reason: String
                if data.count > 512_000 {
                    reason = "oversize"
                } else if let message = decoded {
                    if message.version != CompanionMessage.currentVersion {
                        reason = "unsupportedVersion"
                    } else if message.sender != "iphone" {
                        reason = "wrongSender"
                    } else if case .prepare = message.payload, abs(message.sentAt.timeIntervalSinceNow) > 30 {
                        reason = "stalePreparation"
                    } else {
                        reason = "invalidEnvelopeOrState"
                    }
                } else {
                    reason = "decodeFailure"
                }
                let before = self.readiness
                // A foreign or late envelope cannot change an owned preparation
                // or capture. Keep the current failure visible for a live attempt.
                if WatchRejectionPolicy.failsReadiness(
                    activeSessionID: self.current?.id, state: self.readiness.state,
                    messageSessionID: decoded?.sessionID, messageAttemptID: decoded?.attemptID,
                    activeAttemptID: self.current?.lastPreparationAttemptID, reason: reason)
                {
                    self.fail(error.localizedDescription)
                }
                let original = error as NSError
                let path: [String]?
                switch error {
                case DecodingError.typeMismatch(_, let context),
                    DecodingError.valueNotFound(_, let context),
                    DecodingError.keyNotFound(_, let context), DecodingError.dataCorrupted(let context):
                    path = context.codingPath.map(\.stringValue)
                default: path = nil
                }
                let entry = WatchRejectedEnvelope(
                    channel: channel, rawData: data, reason: reason,
                    readinessBefore: before, readinessAfter: self.readiness,
                    errorDescription: error.localizedDescription, errorDomain: original.domain,
                    errorCode: original.code,
                    decodingPath: path, currentSessionID: self.current?.id,
                    ownerSessionID: self.workoutOwnerID)
                do {
                    guard let rejectionJournal = self.rejectionJournal else {
                        throw CompanionError.storage(
                            WatchText.string("El registro de rechazos del Watch no está disponible."))
                    }
                    try rejectionJournal.record(entry)
                    self.flushRejectedEnvelopes()
                } catch {
                    self.errorMessage = WatchText.format(
                        "No se pudo guardar el sobre rechazado: %@", error.localizedDescription)
                }
                self.rejectionLogger.error(
                    "Rejected companion envelope id=\(entry.id, privacy: .public) reason=\(reason, privacy: .public) bytes=\(data.count)"
                )
            }
        }
    }

    private func receive(_ message: CompanionMessage) async throws {
        guard message.sender == "iphone" else { throw CompanionError.invalidMessage }
        switch message.payload {
        case .statusRequest:
            send(.accessFacts(accessFacts()), id: "setup")
            rejectedChunkCursor = [:]
            send(.readiness(readiness), id: current?.id ?? "setup")
            flushPending(force: true)
        case .requestRejectedEnvelopes:
            rejectedChunkCursor = [:]
            flushRejectedEnvelopes()
        case .requestRejectedEnvelopeSnapshot(let requestID):
            guard !requestID.isEmpty, requestID.count <= 128, let rejectionJournal else { return }
            let entries = rejectionJournal.entries
            send(
                .rejectedEnvelopeSnapshot(.init(requestID: requestID, entryIDs: entries.map(\.id))),
                id: "diagnostics", durable: true)
            rejectedChunkCursor = [:]
            flushRejectedEnvelopes()
        case .acknowledgeRejectedEnvelopes(let ids):
            try rejectionJournal?.acknowledge(ids)
            for id in ids { rejectedChunkCursor.removeValue(forKey: id) }
        case .prepare(let view):
            guard abs(message.sentAt.timeIntervalSinceNow) <= 30, !view.synthetic, ledger != nil else {
                throw CompanionError.invalidMessage
            }
            await recoveryTask?.value
            if blockedRecoveredSession {
                rejectPreparation(
                    id: message.sessionID, state: .conflict,
                    message: WatchText.string(
                        "HealthKit conserva una sesión sin identidad confirmada. Revísala antes de preparar otra."
                    ),
                    blockingSessionID: current?.id, attemptID: message.attemptID)
                return
            }
            heartAnchor = nil
            let attempt = message.attemptID ?? "legacy"
            let result = try await preparationController.prepare(
                id: message.sessionID, attempt: attempt, sequence: message.sequence, view: view,
                accessReviewed: accessReviewed, existing: ledger?.sessions[message.sessionID],
                hasLiveOwnedWorkout: workout != nil && workoutOwnerID == current?.id)
            switch result {
            case .accepted:
                orphanReviewNeeded = false
                errorMessage = nil
            case .duplicate: send(.readiness(readiness), id: message.sessionID)
            case .conflict:
                orphanReviewNeeded = true
                rejectPreparation(
                    id: message.sessionID, state: .conflict,
                    message: WatchText.string(
                        "Hay una preparación anterior en este Watch. Revísala o descártala expresamente antes de continuar."
                    ),
                    blockingSessionID: current?.id, attemptID: message.attemptID)
            case .accessNeeded:
                rejectPreparation(
                    id: message.sessionID, state: .accessNeeded,
                    message: WatchText.string("Revisa el acceso a Salud en el Watch antes de preparar."),
                    attemptID: message.attemptID)
            case .cancelledAttempt:
                rejectPreparation(
                    id: message.sessionID, state: .failed,
                    message: WatchText.string("Este intento se canceló; vuelve a intentar la preparación."),
                    attemptID: message.attemptID)
            }
        case .acknowledge(let ids):
            guard var record = ledger?.sessions[message.sessionID] else { return }
            record.acknowledge(ids)
            try ledger?.save(record)
            if current?.id == record.id { current = record }
            if !record.pendingSamples.isEmpty { flushPending(force: true) }
        case .reconcile:
            if current?.id == message.sessionID {
                await reconcile()
            } else if ledger?.sessions[message.sessionID] != nil {
                emitHealthResult(id: message.sessionID)
            }
        case .start(let date):
            // Compatibility with the original contract; the product now sends
            // the stable capture request with every fresh view instead.
            guard let record = current, record.id == message.sessionID,
                abs(message.sentAt.timeIntervalSinceNow) <= 15,
                Date().timeIntervalSince(date) >= -5, Date().timeIntervalSince(date) <= 30
            else { return }
            var view = record.view
            view.captureRequest = WatchCaptureRequest(id: message.id, requestedAt: date)
            if record.canBeginCapture(from: view) {
                try await beginCapture(requestID: message.id)
            } else if startedCollection {
                updateReadiness(record.captureState)
            }
        case .view(let view):
            guard var record = current, record.id == message.sessionID, record.viewGate.accept(message),
                !view.synthetic
            else { return }
            record.view = view
            try persist(record)
            if record.canBeginCapture(from: view), let request = view.captureRequest {
                // Use the actual sensor start time, never backdate a lost interval.
                try await beginCapture(requestID: request.id)
            } else if startedCollection, view.captureRequest?.id == record.captureRequestID {
                // A lost ACK is repaired without starting another HK session.
                updateReadiness(current?.captureState ?? record.captureState)
            }
            if let active = current, [.running, .paused, .recovering].contains(active.captureState) {
                if view.snapshot.state == .paused {
                    workout?.pause()
                    updateReadiness(.paused)
                } else if view.snapshot.state == .running, workout?.state == .paused {
                    workout?.resume()
                    updateReadiness(.running)
                }
                // Pausing/manual/finishing never claims a physical stop.
                try await addDistance(view.metrics["sessionDistanceMeters"])
            }
        case .cancel:
            if preparationController.cancel(id: message.sessionID, attempt: message.attemptID) {
                orphanReviewNeeded = false
                emitHealthResult(id: message.sessionID)
            }
        case .resolvePreparation:
            await recoveryTask?.value
            if preparationController.resolveOrphan(id: message.sessionID) {
                sessionGeneration &+= 1
                orphanReviewNeeded = false
                emitHealthResult(id: message.sessionID)
            } else {
                rejectPreparation(
                    id: message.sessionID, state: .conflict,
                    message: WatchText.string(
                        "La sesión ya capturó datos o no pertenece a esta preparación; no se descartó."))
            }
        case .acknowledgeHealthResult(let deliveryID):
            guard var record = ledger?.sessions[message.sessionID],
                record.acknowledgeHealthResult(deliveryID)
            else { return }
            try ledger?.save(record)
            if current?.id == record.id { current = record }
        case .finish(let view):
            guard var record = current, record.id == message.sessionID,
                !record.receivedCommandIDs.contains(message.id), !view.synthetic
            else { return }
            if record.viewGate.terminal {
                await reconcile()
                return
            }
            guard record.viewGate.accept(message, final: true) else { return }
            record.receivedCommandIDs.insert(message.id)
            record.view = view
            record.captureEndedAt = view.endedAt ?? Date()
            try persist(record)
            if !startedCollection {
                workout?.end()
                builder?.discardWorkout()
                workout = nil
                builder = nil
                workoutOwnerID = nil
                record.captureState = .ended
                record.health = HealthSaveResult(
                    state: record.captureIntentAt == nil ? .discarded : .uncertain,
                    message: WatchText.string(
                        record.captureIntentAt == nil
                            ? "No hubo captura activa; preparación descartada."
                            : "La colección no pudo confirmarse al recuperar HealthKit; no se guardó otra sesión."
                    ))
                try persist(record)
                emitHealthResult(id: record.id)
                return
            }
            guard record.health.state == .pending, let builder, let workout else {
                await reconcile()
                return
            }
            defer {
                workout.end()
                self.workout = nil
                self.builder = nil
                self.workoutOwnerID = nil
                startedCollection = false
                updateReadiness(.ended)
                flushPending(force: true)
                emitHealthResult(id: record.id)
            }
            updateReadiness(.ending)
            var distanceError: String?
            do { try await addDistance(view.metrics["sessionDistanceMeters"]) } catch {
                distanceError = error.localizedDescription
                errorMessage = WatchText.format(
                    "Distancia incompleta en Salud: %@", error.localizedDescription)
            }
            let end = max(record.captureStartedAt!, view.endedAt ?? Date())
            workout.stopActivity(with: end)
            do { try await builder.endCollection(at: end) } catch {
                builder.discardWorkout()
                if var failed = current {
                    failed.health = HealthSaveResult(
                        state: .failed,
                        message: WatchText.format(
                            "No se pudo cerrar la captura de Salud: %@", error.localizedDescription),
                        captureStartedAt: failed.captureStartedAt, captureEndedAt: end)
                    failed.captureState = .ended
                    try persist(failed)
                }
                return
            }
            await heartQueryTask?.value
            do { try await collectHeartSamples() } catch {
                errorMessage = WatchText.format("Pulso final incompleto: %@", error.localizedDescription)
            }
            guard var saving = current, saving.beginHealthSave() else { return }
            try persist(saving)  // Durable intent before the uncertain HealthKit write.
            send(.healthResult(saving.health), id: saving.id, durable: true)
            do {
                if healthStore.authorizationStatus(for: .workoutType()) != .sharingAuthorized {
                    builder.discardWorkout()
                    saving.health = HealthSaveResult(
                        state: .failed,
                        message: WatchText.string("Salud no autorizó guardar este entrenamiento."),
                        captureStartedAt: saving.captureStartedAt, captureEndedAt: end)
                } else if let result = try await builder.finishWorkout() {
                    // Samples committed by finishWorkout may become queryable
                    // only now. Recover their UUID/source/device before export.
                    await heartQueryTask?.value
                    do { try await collectHeartSamples() } catch {
                        errorMessage = WatchText.format(
                            "Muestras originales de pulso pendientes: %@", error.localizedDescription)
                    }
                    saving.health = HealthSaveResult(
                        state: .saved, workoutUUID: result.uuid.uuidString,
                        message: distanceError.map { WatchText.format("Distancia incompleta: %@", $0) },
                        captureStartedAt: result.startDate, captureEndedAt: result.endDate,
                        distanceMeters: saving.distance.totalMeters,
                        heartRateAverageBPM: builder.statistics(for: HKQuantityType(.heartRate))?
                            .averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                        heartRateMaximumBPM: builder.statistics(for: HKQuantityType(.heartRate))?
                            .maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                        activeEnergyKilocalories: builder.statistics(for: HKQuantityType(.activeEnergyBurned))?
                            .sumQuantity()?.doubleValue(for: .kilocalorie()))
                } else {
                    saving.health = HealthSaveResult(
                        state: .uncertain,
                        message: WatchText.string(
                            "Salud no devolvió el resultado. Se conciliará sin duplicar escrituras."))
                }
            } catch {
                saving.health = HealthSaveResult(
                    state: .uncertain, message: error.localizedDescription,
                    captureStartedAt: saving.captureStartedAt, captureEndedAt: end,
                    distanceMeters: saving.distance.totalMeters)
            }
            // Reload samples collected during the async save before updating result.
            if var latest = current {
                latest.health = saving.health
                latest.captureEndedAt = end
                latest.captureState = .ended
                try persist(latest)
            }
        default: break
        }
    }

    private func addDistance(_ sample: WorkoutSample?) async throws {
        guard var record = current, let sample, let builder, startedCollection,
            sample.receivedAt >= (record.captureStartedAt ?? .distantFuture)
        else { return }
        var accumulator = record.distance
        guard let delta = accumulator.increment(for: sample) else { return }
        if delta > 0 {
            let start = max(
                record.distance.lastDate ?? record.captureStartedAt!, record.captureStartedAt!)
            let end = max(start, sample.receivedAt)
            let quantity = HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: delta), start: start, end: end,
                metadata: [
                    HKMetadataKeyExternalUUID: record.id + ":distance:" + (sample.eventId ?? ""),
                    "VaganciaDistanceSource": "FTMS",
                ])
            try await builder.addSamples([quantity])
        }
        // Async callbacks may have appended pulse samples; do not overwrite them.
        record = current ?? record
        record.distance = accumulator
        try persist(record)
    }

    private func beginCapture(requestID: String) async throws {
        guard var record = current, record.captureState == .prepared,
            record.captureIntentAt == nil, record.captureStartedAt == nil, !record.viewGate.terminal,
            let workout, let builder
        else { return }
        let date = Date()
        guard record.beginCaptureIntent(requestID: requestID, at: date) else { return }
        // Persist intent before Apple API calls. Only successful collection
        // confirms capture; recovery inspects the actual HealthKit builder.
        try persist(record)
        try await builder.addMetadata([
            HKMetadataKeyExternalUUID: record.id, HKMetadataKeyIndoorWorkout: true,
            "VaganciaSessionID": record.id, "VaganciaDistanceSource": "FTMS",
        ])
        workout.startActivity(with: date)
        try await builder.beginCollection(at: date)
        guard var confirmed = current, confirmed.id == record.id,
            confirmed.captureRequestID == requestID,
            confirmed.confirmCollection(startedAt: builder.startDate ?? date)
        else { return }
        try persist(confirmed)
        startedCollection = true
        updateReadiness(.running)
    }

    private func persist(_ record: WatchSessionRecord) throws {
        guard let ledger else {
            throw CompanionError.storage(WatchText.string("El registro del reloj no está disponible."))
        }
        try ledger.save(record)
        current = record
        preparationController?.observePersisted(record)
        UserDefaults.standard.set(record.id, forKey: "watch.currentSession")
    }
    private func updateReadiness(
        _ state: WatchCaptureState, message: String? = nil, sessionID: String? = nil
    ) {
        let id = sessionID ?? current?.id ?? "setup"
        readiness = WatchReadiness(
            state: state, accessReviewed: accessReviewed,
            canSaveWorkout: healthStore.authorizationStatus(for: .workoutType()) == .sharingAuthorized,
            message: message,
            captureRequestID: startedCollection ? current?.captureRequestID : nil,
            captureStartedAt: startedCollection ? current?.captureStartedAt : nil)
        if var record = current, record.id == id, workoutOwnerID == id,
            !(record.captureState == .ended && [.idle, .accessNeeded].contains(state))
        {
            record.captureState = state
            do { try persist(record) } catch { errorMessage = error.localizedDescription }
        }
        send(
            .readiness(readiness), id: id,
            attemptID: id == preparationController.ownerID ? preparationController.attemptID : nil)
        send(.accessFacts(accessFacts()), id: "setup")
    }
    private func accessFacts() -> WatchAccessFacts {
        WatchAccessFacts(
            reviewed: accessReviewed,
            canSaveWorkout: healthStore.authorizationStatus(for: .workoutType()) == .sharingAuthorized,
            updatedAt: Date())
    }
    private func rejectPreparation(
        id: String, state: WatchCaptureState, message: String,
        blockingSessionID: String? = nil, attemptID: String? = nil
    ) {
        let response = WatchReadiness(
            state: state, accessReviewed: accessReviewed,
            canSaveWorkout: healthStore.authorizationStatus(for: .workoutType()) == .sharingAuthorized,
            message: message, blockingSessionID: blockingSessionID)
        send(.readiness(response), id: id, attemptID: attemptID)
    }
    private func fail(_ message: String) {
        errorMessage = message
        updateReadiness(.failed, message: message)
    }
    private func flushPending(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFlush) >= 2, let ledger else { return }
        lastFlush = Date()
        for record in ledger.sessions.values {
            let samples = record.pendingSamples
            if !samples.isEmpty {
                send(.samples(Array(samples.prefix(10))), id: record.id, durable: true)
            }
            if [.saved, .failed, .uncertain, .discarded].contains(record.health.state) {
                emitHealthResult(id: record.id)
            }
        }
        flushRejectedEnvelopes()
    }
    private func flushRejectedEnvelopes() {
        guard channel?.activationState == .activated, let rejectionJournal else { return }
        var sent = 0
        var hasMore = false
        for entry in rejectionJournal.pending {
            do {
                let chunks = try WatchRejectedEnvelopeChunk.split(entry)
                var index = rejectedChunkCursor[entry.id] ?? 0
                while index < chunks.count, sent < 16 {
                    send(.rejectedEnvelopeChunk(chunks[index]), id: "diagnostics", durable: true)
                    index += 1
                    sent += 1
                }
                rejectedChunkCursor[entry.id] = index
                if index < chunks.count { hasMore = true }
            } catch {
                errorMessage = WatchText.format(
                    "No se pudo enviar el rechazo guardado: %@", error.localizedDescription)
            }
            if sent >= 16 {
                hasMore = true
                break
            }
        }
        if hasMore, rejectedFlushTask == nil {
            rejectedFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.rejectedFlushTask = nil
                self?.flushRejectedEnvelopes()
            }
        }
    }
    private func emitHealthResult(id: String) {
        guard var record = ledger?.sessions[id], let result = record.terminalHealthResultForDelivery()
        else { return }
        do {
            try ledger?.save(record)
            if current?.id == id { current = record }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        send(.healthResult(result), id: id, durable: true)
    }
    private func send(
        _ payload: CompanionPayload, id: String, durable: Bool = false, attemptID: String? = nil
    ) {
        sequence &+= 1
        UserDefaults.standard.set(Int(sequence), forKey: "watch.messageSequence")
        let message = CompanionMessage(
            sessionID: id, sender: "watch", sequence: sequence, payload: payload,
            attemptID: attemptID
                ?? (id == preparationController?.ownerID ? preparationController?.attemptID : nil))
        guard let data = try? message.encoded() else { return }
        if durable, channel?.activationState == .activated {
            channel?.transferUserInfo(["payload": data])
        }
        if let workout, workoutOwnerID == id, workout.state != .ended {
            workout.sendToRemoteWorkoutSession(
                data: data,
                completion: CompanionCallbackBoundary.mirrorSendHandler { [weak self] success, _ in
                    guard !success, let self, self.workout === workout,
                        self.workoutOwnerID == id, self.channel?.isReachable == true
                    else { return }
                    self.channel?.sendMessageData(data, replyHandler: nil)
                })
        } else if channel?.isReachable == true {
            channel?.sendMessageData(data, replyHandler: nil)
        }
    }

    private func collected(_ types: Set<HKSampleType>) {
        guard var record = current, record.captureStartedAt != nil, let builder else { return }
        for type in types {
            guard let quantityType = type as? HKQuantityType,
                let stats = builder.statistics(for: quantityType)
            else { continue }
            let pulse = quantityType == HKQuantityType(.heartRate)
            let energy = quantityType == HKQuantityType(.activeEnergyBurned)
            guard pulse || energy else { continue }
            let unit: HKUnit = pulse ? HKUnit.count().unitDivided(by: .minute()) : .kilocalorie()
            let quantity = pulse ? stats.mostRecentQuantity() : stats.sumQuantity()
            let interval = stats.mostRecentQuantityDateInterval()
            let date = interval?.end ?? stats.endDate
            guard let value = quantity?.doubleValue(for: unit) else { continue }
            let sample = WatchHealthSample(
                id: "\(record.id):\(quantityType.identifier):\(date.timeIntervalSince1970):\(value)",
                metric: pulse ? "heartRateBPM" : "energyKilocalories", value: value,
                unit: pulse ? "count/min" : "kcal",
                sampledAt: date, periodStart: pulse ? (interval?.start ?? date) : record.captureStartedAt!,
                device: HKDevice.local().name ?? "Apple Watch",
                sourceIdentifier: stats.sources?.first?.bundleIdentifier
                    ?? HKSource.default().bundleIdentifier,
                aggregation: pulse ? "latestFromBuilder" : "cumulative")
            _ = record.add(sample)
        }
        do {
            try persist(record)
            flushPending()
        } catch { fail(error.localizedDescription) }
        if types.contains(HKQuantityType(.heartRate)), heartQueryTask == nil {
            heartQueryTask = Task { [weak self] in
                guard let self else { return }
                defer { self.heartQueryTask = nil }
                do { try await self.collectHeartSamples() } catch {
                    self.errorMessage = WatchText.format(
                        "No se pudieron leer todas las muestras de pulso: %@", error.localizedDescription)
                }
            }
        }
    }

    private func collectHeartSamples() async throws {
        guard let record = current, let start = record.captureStartedAt, !record.view.synthetic else {
            return
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: record.captureEndedAt, options: .strictStartDate)
        let anchor = heartAnchor
        let result: ([HKQuantitySample], HKQueryAnchor?) = try await withCheckedThrowingContinuation {
            continuation in
            let query = HKAnchoredObjectQuery(
                type: HKQuantityType(.heartRate), predicate: predicate,
                anchor: anchor, limit: HKObjectQueryNoLimit,
                resultsHandler: WatchHealthQueryCallbacks.heartSamples(continuation))
            healthStore.execute(query)
        }
        guard var latest = current, latest.id == record.id else { return }
        for sample in result.0 {
            _ = latest.add(
                WatchHealthSample(
                    id: sample.uuid.uuidString, metric: "heartRateBPM",
                    value: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    unit: "count/min",
                    sampledAt: sample.endDate, periodStart: sample.startDate,
                    device: sample.device?.name ?? "HealthKit · Watch",
                    sourceIdentifier: sample.sourceRevision.source.bundleIdentifier,
                    aggregation: "rawHealthKit"))
        }
        try persist(latest)
        heartAnchor = result.1  // Advance only after the samples are durably retained.
        flushPending()
    }
}

extension WatchWorkoutService: WatchPreparationEffects {
    func prepareHealthSession(ownerID: String?) async throws -> Bool {
        let configuration =
            launchConfiguration
            ?? {
                let fallback = HKWorkoutConfiguration()
                fallback.activityType = .walking
                fallback.locationType = .indoor
                return fallback
            }()
        return try await ensurePreparedWorkout(configuration: configuration, ownerID: ownerID)
    }
    func discardOwnedPreparation(ownerID: String) {
        guard workoutOwnerID == ownerID else { return }
        workout?.end()
        builder?.discardWorkout()
        workout = nil
        builder = nil
        workoutOwnerID = nil
        startedCollection = false
    }
    func persistPreparation(_ record: WatchSessionRecord) throws { try persist(record) }
    func persistCancelledAttempt(sessionID: String, attemptID: String) {
        var stored =
            UserDefaults.standard.dictionary(forKey: "watch.cancelledPreparationAttempts")
            as? [String: [String]] ?? [:]
        if !stored[sessionID, default: []].contains(attemptID) {
            stored[sessionID, default: []].append(attemptID)
        }
        UserDefaults.standard.set(stored, forKey: "watch.cancelledPreparationAttempts")
    }
    func publishPreparation(_ state: WatchCaptureState, sessionID: String, message: String?) {
        updateReadiness(state, message: message, sessionID: sessionID)
    }
}

extension WatchWorkoutService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext["payload"] as? Data
        let text = error?.localizedDescription
        Task { @MainActor in
            self.errorMessage = text
            self.refreshConnection()
            self.flushRejectedEnvelopes()
            if let context { self.enqueue(context, channel: "applicationContext") }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshConnection() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in self.enqueue(messageData, channel: "watchConnectivityLive") }
    }
    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext["payload"] as? Data else { return }
        Task { @MainActor in self.enqueue(data, channel: "applicationContext") }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["payload"] as? Data else { return }
        Task { @MainActor in self.enqueue(data, channel: "watchConnectivityBackground") }
    }
}

extension WatchWorkoutService: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        Task { @MainActor in
            guard self.workout === workoutSession, workoutSession.state == toState else { return }
            if toState == .prepared {
                self.preparationController.markPrepared(
                    ownerID: self.workoutOwnerID,
                    generation: self.workoutLifecycleGeneration)
            } else if toState == .ended, self.current?.captureState != .ended,
                self.current?.captureState != .ending
            {
                guard self.workoutOwnerID == self.current?.id else { return }
                self.updateReadiness(
                    .failed,
                    message: WatchText.string(
                        "La captura terminó fuera del iPhone. Esto no confirma que la banda haya parado."))
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in
            guard self.workout === workoutSession else { return }
            guard self.workoutOwnerID == self.current?.id else {
                self.errorMessage = text
                return
            }
            self.fail(text)
        }
    }
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            guard self.workout === workoutSession else { return }
            self.phoneReachable = true
            for value in data { self.enqueue(value, channel: "healthKitMirror") }
        }
    }
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in if self.workout === workoutSession { self.phoneReachable = false } }
    }
}

extension WatchWorkoutService: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.collected(collectedTypes)
        }
    }
}
