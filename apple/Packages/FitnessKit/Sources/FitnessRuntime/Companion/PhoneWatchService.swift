import FitnessCore
import Foundation
@preconcurrency import HealthKit
import Observation
@preconcurrency import WatchConnectivity

@MainActor @Observable
public final class PhoneWatchService: NSObject, WorkoutCompanion {
    public private(set) var isPaired = false
    public private(set) var isInstalled = false
    public private(set) var isReachable = false
    public private(set) var readiness = WatchReadiness(updatedAt: .distantPast)
    public private(set) var readinessSessionID: String?
    public private(set) var accessFacts = WatchAccessFacts()
    public private(set) var orphanedPreparation: WatchOrphanedPreparation?
    public private(set) var preparedSessionID: String?
    public private(set) var errorMessage: String?
    public private(set) var mirrored = false
    public private(set) var mirroredSessionID: String?
    public private(set) var captureAwaitingConfirmation = false
    public private(set) var confirmedCaptureSessionID: String?
    public var readinessIsFresh: Bool { Date().timeIntervalSince(readiness.updatedAt) < 30 }
    @ObservationIgnored private var captureRequests: [String: WatchCaptureRequest] = [:]
    @ObservationIgnored private var awaitingRejectionSnapshots: Set<String> = []
    @ObservationIgnored private var rejectionSnapshotReceipts: [String: WatchRejectedEnvelopeSnapshotReceipt] = [:]
    @ObservationIgnored private var preparationAttempts: [String: String] = [:]
    @ObservationIgnored private var resolvingOrphanID: String?
    public var useWatch: Bool {
        didSet { UserDefaults.standard.set(useWatch, forKey: "fitness.useWatch") }
    }
    @ObservationIgnored public var onMessage: ((CompanionMessage) async throws -> Void)?
    @ObservationIgnored public var onEvent: ((String, String) -> Void)?
    @ObservationIgnored private var channel: WCSession?
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var remote: HKWorkoutSession?
    @ObservationIgnored private var sequence: UInt64 = UInt64(
        UserDefaults.standard.integer(forKey: "fitness.watchMessageSequence"))
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var lastState: [String: WorkoutState] = [:]
    @ObservationIgnored private var didActivate = false
    @ObservationIgnored private var preparingID: String?
    @ObservationIgnored private var preparationGeneration = 0
    @ObservationIgnored private var readinessGate = CompanionReadinessGate()
    @ObservationIgnored private var mirrorIdentity = CompanionMirrorIdentity()
    @ObservationIgnored private let inbox = CompanionInboundQueue()
    #if DEBUG
        @ObservationIgnored private var uiTestFixture = false
        public func configureUITestFixture() {
            uiTestFixture = true
            let fixtureDate =
                ProcessInfo.processInfo.arguments.contains("--ui-test-watch-stale")
                ? Date().addingTimeInterval(-31) : Date()
            accessFacts = WatchAccessFacts(reviewed: true, canSaveWorkout: false, updatedAt: fixtureDate)
            readiness = WatchReadiness(
                state: .conflict, accessReviewed: true, canSaveWorkout: false,
                message: "Ejemplo de preparación anterior en el Watch; no hay captura activa.",
                blockingSessionID: "fixture-orphaned-preparation")
            readinessSessionID = "fixture-new-session"
            orphanedPreparation = WatchOrphanedPreparation(
                id: "fixture-orphaned-preparation", state: .prepared,
                message: "Ejemplo sintético: preparación anterior sin captura.")
        }
    #endif

    public override init() {
        useWatch = UserDefaults.standard.bool(forKey: "fitness.useWatch")
        super.init()
    }

    /// WC activation is explicit and confined to the product app. Health
    /// authorization is requested only from the setup button, never here.
    public func activate() {
        guard !didActivate, WCSession.isSupported() else { return }
        didActivate = true
        healthStore.workoutSessionMirroringStartHandler = Self.makeMirroringStartHandler(for: self)
        channel = .default
        channel?.delegate = self
        channel?.activate()
    }

    private nonisolated static func makeMirroringStartHandler(
        for service: PhoneWatchService
    ) -> @Sendable (HKWorkoutSession) -> Void {
        { [weak service] session in
            Task { @MainActor in
                guard let service else { return }
                service.remote = session
                service.mirrorIdentity.replace(with: session)
                service.mirroredSessionID = nil
                session.delegate = service
                service.mirrored = true
                service.onEvent?("watch.mirror.connected", "Sesión HealthKit reflejada recibida")
                service.refreshAvailability()
            }
        }
    }

    public func refreshAvailability() {
        guard let channel else { return }
        isPaired = channel.isPaired
        isInstalled = channel.isWatchAppInstalled
        isReachable = channel.isReachable
        if isReachable {
            send(payload: .statusRequest, id: preparedSessionID ?? preparingID ?? "setup")
        }
    }

    public func reviewPhoneHealthAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = FitnessText.string("watch.healthUnavailable")
            return
        }
        do {
            let types: Set<HKSampleType> = [
                HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
                HKQuantityType(.distanceWalkingRunning),
            ]
            try await healthStore.requestAuthorization(toShare: [], read: types)
            errorMessage = nil
            onEvent?(
                "health.phone.accessReviewed", "Diálogo completado; el permiso de lectura no se infiere")
            refreshAvailability()
        } catch { errorMessage = error.localizedDescription }
    }

    public func prepare(id: String, view: CompanionWorkoutView) async throws {
        guard !view.synthetic, useWatch else { throw CompanionError.notPrepared }
        guard isPaired, isInstalled else { throw CompanionError.unavailable }
        guard preparingID == nil else { throw CompanionError.notPrepared }
        preparingID = id
        preparedSessionID = nil
        confirmedCaptureSessionID = nil
        let attemptID = UUID().uuidString.lowercased()
        preparationAttempts[id] = attemptID
        orphanedPreparation = nil
        readinessGate.begin(id)
        preparationGeneration += 1
        let generation = preparationGeneration
        readiness = readinessGate.latest
        defer { if preparingID == id { preparingID = nil } }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .indoor
        do {
            // Activation is needed to enqueue background delivery, but live
            // reachability is not: the Watch may be opened behind another app.
            let activationDeadline = ProcessInfo.processInfo.systemUptime + 5
            while channel?.activationState != .activated,
                ProcessInfo.processInfo.systemUptime < activationDeadline
            {
                try await Task.sleep(for: .milliseconds(100))
                guard generation == preparationGeneration else { throw CancellationError() }
            }
            guard channel?.activationState == .activated else { throw CompanionError.unavailable }
            send(
                payload: .prepare(view), id: id, contextFallback: true, durable: true, attemptID: attemptID)
            try await healthStore.startWatchApp(toHandle: configuration)
            guard generation == preparationGeneration else { throw CancellationError() }
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            while preparedSessionID != id, ProcessInfo.processInfo.systemUptime < deadline {
                if readiness.state == .conflict { throw CompanionError.conflict }
                if readiness.state == .failed || readiness.state == .accessNeeded {
                    throw CompanionError.notPrepared
                }
                try await Task.sleep(for: .milliseconds(200))
                guard generation == preparationGeneration else { throw CancellationError() }
            }
            guard preparedSessionID == id else { throw CompanionError.timeout }
            errorMessage = nil
        } catch {
            let wasCurrent = preparingID == id || preparedSessionID == id
            cancelPreparation(id: id)
            if wasCurrent { errorMessage = error.localizedDescription }
            throw error
        }
    }

    public func publish(id: String, view: CompanionWorkoutView) {
        guard !view.synthetic, useWatch, preparedSessionID == id else { return }
        let state = view.snapshot.state
        let previous = lastState[id]
        if state == .running, captureRequests[id] == nil {
            captureRequests[id] = WatchCaptureRequest()
            readinessGate.requestCapture(captureRequests[id]!.id, for: id)
            captureAwaitingConfirmation = true
            confirmedCaptureSessionID = nil
            onEvent?("watch.capture.requested", "Esperando confirmación de captura; sin órdenes de motor")
        }
        guard state != previous || Date().timeIntervalSince(lastPublish) >= 1 else { return }
        lastState[id] = state
        lastPublish = Date()
        var delivery = view
        // The same request accompanies fresh views until end, including after
        // reconnection or a lost acknowledgement. Only HealthKit capture uses it.
        delivery.captureRequest = captureRequests[id]
        send(payload: .view(delivery), id: id, contextFallback: true)
    }

    public func cancelPreparation(id: String) {
        let wasCurrent = preparingID == id || preparedSessionID == id
        readinessGate.cancel(id)
        captureRequests.removeValue(forKey: id)
        if wasCurrent {
            captureAwaitingConfirmation = false
            confirmedCaptureSessionID = nil
            preparationGeneration += 1
        }
        send(payload: .cancel, id: id, durable: true, attemptID: preparationAttempts[id])
        if preparedSessionID == id { preparedSessionID = nil }
        if preparingID == id { preparingID = nil }
        if wasCurrent { readiness = readinessGate.latest }
    }

    public func finalize(id: String, view: CompanionWorkoutView) {
        guard !view.synthetic else { return }
        send(payload: .finish(view), id: id, durable: true)
        lastState[id] = view.snapshot.state
        captureRequests.removeValue(forKey: id)
        if preparedSessionID == id {
            captureAwaitingConfirmation = false
            readinessGate.cancel(id)
            readiness = readinessGate.latest
            preparedSessionID = nil
            confirmedCaptureSessionID = nil
        }
    }

    public func acknowledge(id: String, sampleIDs: [String]) {
        send(payload: .acknowledge(sampleIDs), id: id, durable: true)
    }
    public func reconcile(id: String) { send(payload: .reconcile, id: id, durable: true) }
    public func acknowledgeHealthResult(sessionID: String, resultID: String) {
        send(payload: .acknowledgeHealthResult(resultID), id: sessionID, durable: true)
    }
    public func acknowledgeRejectedEnvelopes(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        send(payload: .acknowledgeRejectedEnvelopes(ids), id: "diagnostics", durable: true)
    }
    public func requestRejectedEnvelopes() {
        send(payload: .requestRejectedEnvelopes, id: "diagnostics", durable: true)
    }
    public var rejectionSnapshotAvailable: Bool {
        channel?.isReachable == true || (remote != nil && mirrored && mirroredSessionID != nil)
    }
    public func collectRejectedEnvelopeSnapshot() async -> WatchRejectedEnvelopeSnapshotReceipt? {
        let requestID = UUID().uuidString.lowercased()
        let available = rejectionSnapshotAvailable
        if available { awaitingRejectionSnapshots.insert(requestID) }
        send(
            payload: .requestRejectedEnvelopeSnapshot(requestID), id: mirroredSessionID ?? "diagnostics",
            durable: true)
        guard available else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let receipt = rejectionSnapshotReceipts.removeValue(forKey: requestID) {
                awaitingRejectionSnapshots.remove(requestID)
                return receipt
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        awaitingRejectionSnapshots.remove(requestID)
        rejectionSnapshotReceipts.removeValue(forKey: requestID)
        return nil
    }
    public func resolveOrphanedPreparation() async throws {
        guard let orphanedPreparation else { throw CompanionError.notPrepared }
        #if DEBUG
            if uiTestFixture {
                self.orphanedPreparation = nil
                readiness = WatchReadiness(
                    state: .idle, accessReviewed: true, canSaveWorkout: false,
                    message: "Ejemplo sintético: preparación resuelta sin captura.")
                return
            }
        #endif
        resolvingOrphanID = orphanedPreparation.id
        send(payload: .resolvePreparation, id: orphanedPreparation.id, durable: true)
        onEvent?(
            "watch.preparation.resolveRequested",
            "Solicitada resolución explícita de preparación \(orphanedPreparation.id); sin comando de banda"
        )
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while resolvingOrphanID == orphanedPreparation.id
            && ProcessInfo.processInfo.systemUptime < deadline
        {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard resolvingOrphanID != orphanedPreparation.id else {
            resolvingOrphanID = nil
            throw CompanionError.timeout
        }
    }

    private func send(
        payload: CompanionPayload, id: String, contextFallback: Bool = false, durable: Bool = false,
        attemptID: String? = nil
    ) {
        sequence &+= 1
        UserDefaults.standard.set(Int(sequence), forKey: "fitness.watchMessageSequence")
        let message = CompanionMessage(
            sessionID: id, sender: "iphone", sequence: sequence, payload: payload, attemptID: attemptID)
        guard let data = try? message.encoded() else { return }
        let plan = CompanionDeliveryPlan(
            durable: durable, contextFallback: contextFallback,
            channelActivated: channel?.activationState == .activated,
            wcReachable: channel?.isReachable == true,
            mirrorConnected: remote != nil && mirrored && mirroredSessionID == id)
        if plan.queueBackground { channel?.transferUserInfo(["payload": data]) }
        if plan.livePath == .mirror, let remote {
            remote.sendToRemoteWorkoutSession(
                data: data, completion: mirrorSendHandler(for: remote, data: data))
        } else if plan.livePath == .watchConnectivity {
            channel?.sendMessageData(data, replyHandler: nil, errorHandler: channelErrorHandler())
        } else if !durable && !plan.updateContext {
            errorMessage = CompanionError.unavailable.localizedDescription
        }
        if plan.updateContext {
            do { try channel?.updateApplicationContext(["payload": data]) } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // These factories are also used by tests with callbacks invoked off the
    // main queue. WCSession and HealthKit do not promise a callback executor.
    func channelErrorHandler() -> @Sendable (Error) -> Void {
        CompanionCallbackBoundary.errorHandler { [weak self] text in
            self?.errorMessage = text
            self?.onEvent?("watch.channel.sendFailed", text)
        }
    }

    private func mirrorSendHandler(for remote: HKWorkoutSession, data: Data)
        -> @Sendable (Bool, Error?) -> Void
    {
        CompanionCallbackBoundary.mirrorSendHandler { [weak self] success, errorText in
            guard !success, let self, self.mirrorIdentity.isCurrent(remote) else { return }
            self.onEvent?("watch.mirror.sendFailed", errorText ?? "Sin enlace reflejado")
            // Same idempotent companion message; this path has no motor API.
            if self.channel?.isReachable == true {
                self.channel?.sendMessageData(data, replyHandler: nil)
            }
        }
    }

    private func receive(_ data: Data) async {
        var decoded: CompanionMessage?
        do {
            let message = try CompanionMessage.decode(data)
            decoded = message
            guard message.sender == "watch" else { throw CompanionError.invalidMessage }
            if case .rejectedEnvelopeSnapshot(let receipt) = message.payload {
                guard !receipt.requestID.isEmpty, receipt.requestID.count <= 128,
                    receipt.entryIDs.count <= 10_000,
                    receipt.entryIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 })
                else {
                    throw CompanionError.invalidMessage
                }
                if awaitingRejectionSnapshots.contains(receipt.requestID) {
                    rejectionSnapshotReceipts[receipt.requestID] = receipt
                }
                return
            }
            if case .accessFacts(let facts) = message.payload {
                if facts.updatedAt >= accessFacts.updatedAt { accessFacts = facts }
                return
            }
            if case .readiness(let value) = message.payload {
                if let expected = preparationAttempts[message.sessionID], message.attemptID != expected {
                    onEvent?("watch.readiness.stale", "Respuesta de otro intento: \(message.sessionID)")
                    return
                }
                let result = readinessGate.receive(value, sessionID: message.sessionID)
                if result == .staleCancelled {
                    onEvent?(
                        "watch.readiness.stale",
                        "Respuesta tardía de preparación cancelada: \(message.sessionID)")
                    return
                }
                guard result != .ignored else { return }
                if value.state == .conflict {
                    orphanedPreparation = WatchOrphanedPreparation(
                        id: value.blockingSessionID ?? message.sessionID, state: value.state,
                        message: value.message ?? CompanionError.conflict.localizedDescription)
                }
                readiness = readinessGate.latest
                readinessSessionID = message.sessionID
                if result == .captureConfirmed {
                    if captureAwaitingConfirmation {
                        onEvent?("watch.capture.confirmed", "Captura HealthKit confirmada por el Watch")
                    }
                    captureAwaitingConfirmation = false
                    confirmedCaptureSessionID = message.sessionID
                }
                if result == .prepared { preparedSessionID = message.sessionID }
                if [.failed, .conflict, .accessNeeded].contains(value.state) {
                    errorMessage = value.message
                }
            }
            if case .healthResult(let health) = message.payload,
                message.sessionID == resolvingOrphanID, health.state == .discarded
            {
                orphanedPreparation = nil
                resolvingOrphanID = nil
                onEvent?(
                    "watch.preparation.resolved",
                    "Preparación \(message.sessionID) descartada por el Watch; sin captura ni comando de banda"
                )
            }
            switch message.payload {
            case .acknowledgeHealthResult, .acknowledgeRejectedEnvelopes, .requestRejectedEnvelopes,
                .requestRejectedEnvelopeSnapshot, .resolvePreparation:
                // These are phone-origin commands and are invalid as Watch data.
                break
            default: try await onMessage?(message)
            }
        } catch {
            errorMessage = error.localizedDescription
            let type = decoded.map { String(describing: $0.payload) } ?? "decodeFailed"
            let id = decoded?.sessionID ?? "unknown"
            onEvent?(
                "watch.receive.failed",
                "reason=\(error.localizedDescription) sessionID=\(id) type=\(type) bytes=\(data.count) rawHex=\(data.map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

    private func enqueue(_ data: Data) {
        inbox.submit { [weak self] in await self?.receive(data) }
    }
}

extension PhoneWatchService: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let text = error?.localizedDescription
        Task { @MainActor in
            self.errorMessage = text
            self.refreshAvailability()
        }
    }
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshAvailability() }
    }
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshAvailability()
            self.onEvent?(
                "watch.reachability",
                self.isReachable ? "Disponible" : "Sin enlace inmediato; las muestras quedan pendientes")
        }
    }
    nonisolated public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in self.enqueue(messageData) }
    }
    nonisolated public func session(
        _ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo["payload"] as? Data else { return }
        Task { @MainActor in self.enqueue(data) }
    }
}

extension PhoneWatchService: HKWorkoutSessionDelegate {
    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        let ended = toState == .ended
        Task { @MainActor in
            if ended, self.mirrorIdentity.isCurrent(workoutSession) {
                self.mirrored = false
                self.mirroredSessionID = nil
                self.onEvent?("watch.mirror.ended", "La captura terminó; esto no confirma parada física")
            }
        }
    }
    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession, didFailWithError error: Error
    ) {
        let text = error.localizedDescription
        Task { @MainActor in
            if self.mirrorIdentity.isCurrent(workoutSession) {
                self.errorMessage = text
                self.mirrored = false
                self.mirroredSessionID = nil
                self.onEvent?("watch.mirror.failed", text)
            }
        }
    }
    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            guard self.mirrorIdentity.isCurrent(workoutSession) else { return }
            self.mirrored = true
            for value in data {
                if let decoded = try? CompanionMessage.decode(value), decoded.sender == "watch" {
                    self.mirroredSessionID = decoded.sessionID
                }
                self.enqueue(value)
            }
        }
    }
    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        let text = error?.localizedDescription ?? "Sesión reflejada desconectada"
        Task { @MainActor in
            if self.mirrorIdentity.isCurrent(workoutSession) {
                self.mirrored = false
                self.mirroredSessionID = nil
                self.onEvent?("watch.mirror.disconnected", text)
            }
        }
    }
}
