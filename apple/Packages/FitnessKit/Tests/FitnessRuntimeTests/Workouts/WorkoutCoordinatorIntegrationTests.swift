import FitnessCore
import Foundation
import Testing

@testable import FitnessRuntime

struct WorkoutCoordinatorIntegrationTests {
    @MainActor @Test func acceptedSpeedThatFallsBackSuspendsAutomationWithoutMovementRetry()
        async throws
    {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .transientFallback)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        await #expect(throws: ControlError.self) { try await coordinator.confirmAndStart() }
        #expect(coordinator.snapshot?.state == .manual)
        #expect(coordinator.errorMessage?.contains("objetivo de velocidad") == true)
        #expect(transport.actions == [.requestControl, .stop, .start, .speed])
        let recordID = try #require(coordinator.currentRecord?.id)
        let events = try coordinator.loadEvents(for: recordID)
        #expect(events.contains { $0.kind == "workout.target.accepted" })
        #expect(events.contains { $0.kind == "workout.target.notReached" })
        #expect(!events.contains { $0.kind == "workout.target.observed" })
    }

    @MainActor @Test func speedLostAfterConfirmationSuspendsLaterProgramCommands() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        #expect(coordinator.snapshot?.state == .running)
        let base = ProcessInfo.processInfo.systemUptime
        for offset in [11.0, 12.0, 14.0] {
            transport.publishSpeed(0.8)
            await coordinator.schedulerStep(at: base + offset)
        }
        #expect(coordinator.snapshot?.state == .manual)
        #expect(coordinator.snapshot?.deviation?.basis == .measuredVersusAccepted)
        #expect(transport.actions.filter { $0 == .speed }.count == 1)
        let id = try #require(coordinator.currentRecord?.id)
        #expect(try coordinator.loadEvents(for: id).contains { $0.kind == "workout.target.lost" })
    }

    @MainActor @Test func schedulerCannotCountOneReusedFTMSSpeedEventThreeTimes() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        let base = ProcessInfo.processInfo.systemUptime
        transport.publishSpeed(0.8)
        for offset in [11.0, 12.0, 14.0] { await coordinator.schedulerStep(at: base + offset) }
        #expect(coordinator.snapshot?.state == .running)
        #expect(coordinator.snapshot?.deviation == nil)
        #expect(transport.actions.filter { $0 == .speed }.count == 1)
    }

    @MainActor @Test func observedZeroInclineDoesNotSendRedundantZeroCommand() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        let plan = WorkoutProgram(
            name: "Plano",
            intervals: [
                .init(durationSeconds: 30, targetSpeedKPH: 5, targetInclinationPercent: 0)
            ])
        try await coordinator.start(program: plan)
        try await coordinator.confirmAndStart()
        #expect(coordinator.snapshot?.state == .running)
        #expect(!transport.actions.contains(.inclination))
        let id = try #require(coordinator.currentRecord?.id)
        #expect(
            try coordinator.loadEvents(for: id).contains {
                $0.kind == "workout.inclination.alreadyObserved"
            })
    }

    @Test func audit081RawFTMSReplayDoesNotConfirmTargetAfterSingleEcho() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Audit081ProgramTrace", withExtension: "json"))
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(
            root["sourceType"] as? String
                == "CoreDevice app-container snapshot; events are app-recorded observations of real connected hardware"
        )
        let events = try #require(root["controlAndStageEvents"] as? [[String: Any]])
        let request = try #require(events.first { ($0["valueHex"] as? String) == "02F401" })
        let response = try #require(events.first { ($0["valueHex"] as? String) == "800201" })
        #expect(request["requestedSpeedKPH"] as? Double == 5)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let responseTimestamp = try #require(response["timestampUTC"] as? String)
        let acceptedAt = try #require(parser.date(from: responseTimestamp))
        let rows = try #require(root["selectedSpeedTelemetry"] as? [[String: Any]])
        var confirmation = TargetConfirmation(
            target: 5, acceptedAt: 0,
            requiredStableSeconds: 3, deadline: 20)
        for row in rows {
            let rowTimestamp = try #require(row["timestampUTC"] as? String)
            let timestamp = try #require(parser.date(from: rowTimestamp))
            let delta = timestamp.timeIntervalSince(acceptedAt)
            guard delta >= 0, delta <= 20 else { continue }
            let hex = try #require(row["valueHex"] as? String)
            let bytes = Data(
                stride(from: 0, to: hex.count, by: 2).compactMap { offset -> UInt8? in
                    let from = hex.index(hex.startIndex, offsetBy: offset)
                    let to = hex.index(from, offsetBy: 2)
                    return UInt8(hex[from..<to], radix: 16)
                })
            let decoded = try FTMSDecoder.treadmill(bytes)
            let speed = try #require(decoded.speedKilometersPerHour)
            #expect(speed == row["speedKPH"] as? Double)
            let reached = confirmation.observe(
                value: speed, eventID: try #require(row["eventId"] as? String), at: delta)
            #expect(!reached)
        }
        #expect(confirmation.observed == 0.8)
        #expect(confirmation.expired(at: 20))
    }
    @MainActor @Test func deniedBackgroundAdmissionSendsNoMovementCommand() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let background = FakeWorkoutBackgroundService(denyAdmission: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: background,
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())

        await #expect(throws: FakeWorkoutBackgroundError.self) {
            try await coordinator.confirmAndStart()
        }

        #expect(background.beginCount == 1)
        #expect(transport.actions.isEmpty)
        #expect(coordinator.snapshot?.state == .manual)
        #expect(coordinator.snapshot?.intervalIndex == 0)

        let workoutId = try #require(coordinator.currentRecord?.id)
        try await coordinator.saveInterruptedRecording()
        #expect(coordinator.currentRecord?.endedAt != nil)
        #expect(coordinator.currentRecord?.interrupted == true)
        #expect(coordinator.snapshot?.state == .interrupted)
        #expect(transport.actions.isEmpty)
        let exported = try coordinator.exportWorkoutJSON(id: workoutId)
        let trace = try String(contentsOf: exported, encoding: .utf8)
        #expect(trace.contains("workout.operatorSavedUnconfirmed"))
    }

    @MainActor @Test func rejectedInclineIsAttemptedOnceAndSpeedContinues() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge, rejectInclination: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()

        #expect(coordinator.snapshot?.state == .running)
        #expect(coordinator.snapshot?.effectiveSpeedKPH == 5)
        #expect(coordinator.snapshot?.effectiveInclinationPercent == nil)
        #expect(transport.actions.filter { $0 == .inclination }.count == 1)

        try await coordinator.skipSegment()
        #expect(coordinator.snapshot?.intervalIndex == 1)
        #expect(coordinator.snapshot?.state == .running)
        #expect(coordinator.snapshot?.effectiveSpeedKPH == 7)
        #expect(transport.actions.filter { $0 == .inclination }.count == 1)
        #expect(transport.actions.filter { $0 == .speed }.count == 2)
    }

    @MainActor @Test func failedTargetDoesNotCatchUpOrSendAnotherCommand() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge, failSpeedTarget: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())

        await #expect(throws: FakeWorkoutTransportError.self) {
            try await coordinator.confirmAndStart()
        }

        let commandsAtFailure = transport.actions
        #expect(coordinator.snapshot?.state == .manual)
        #expect(coordinator.snapshot?.intervalIndex == 0)
        #expect(commandsAtFailure == [.requestControl, .stop, .start, .speed])
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.actions == commandsAtFailure)
        #expect(transport.actions.filter { $0 == .stop }.count == 1)
    }

    @MainActor @Test func operatorSpeedOverrideLastsOnlyUntilNextInterval() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        try await coordinator.overrideSpeed(6.2)
        #expect(coordinator.snapshot?.effectiveSpeedKPH == 6.2)

        try await coordinator.skipSegment()

        #expect(coordinator.snapshot?.intervalIndex == 1)
        #expect(coordinator.snapshot?.effectiveSpeedKPH == 7)
    }

    @MainActor @Test func explicitStopHasPriorityAndRequiresFreshZeroConfirmation() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        let priorSpeedEvent = transport.snapshot?.telemetry?.speed?.eventId

        try await coordinator.stop()

        #expect(transport.actions.last == .stop)
        #expect(transport.snapshot?.telemetry?.speed?.value == 0)
        #expect(transport.snapshot?.telemetry?.speed?.eventId != priorSpeedEvent)
        #expect(coordinator.snapshot?.state == .completed)
        #expect(coordinator.currentRecord?.endedAt != nil)
        #expect(coordinator.currentRecord?.interrupted == false)
    }

    @MainActor @Test func mockWorkoutReusesAlreadyOpenDiagnosticCapture() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try coordinator.beginDeviceSetup()
        let openedSessionId = coordinator.store.session?.sessionId
        #expect(coordinator.store.session?.isOpen == true)
        coordinator.setMockMode(true)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()

        #expect(coordinator.currentRecord?.sessionId == openedSessionId)
        #expect(coordinator.store.session?.sessionId == openedSessionId)
        #expect(coordinator.store.session?.isOpen == true)
        #expect(coordinator.snapshot?.state == .running)
        #expect(transport.actions.isEmpty)
    }

    @MainActor @Test func mockFreeWorkoutLifecyclePersistsPauseResumeAndPostFinishNote() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let background = FakeWorkoutBackgroundService()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: background, controlTransport: transport,
            targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.setMockMode(true)
        try await coordinator.startFree()
        try await coordinator.confirmAndStart()
        #expect(coordinator.snapshot?.state == .running)
        #expect(coordinator.currentRecord?.mode == "free")

        try await coordinator.pause()
        #expect(coordinator.snapshot?.state == .paused)
        try await Task.sleep(for: .milliseconds(25))
        try await coordinator.resume()
        #expect(coordinator.snapshot?.state == .running)
        #expect((coordinator.snapshot?.pausedElapsedSeconds ?? 0) > 0)
        try await coordinator.finishAndSave()

        #expect(coordinator.snapshot?.state == .completed)
        #expect(coordinator.currentRecord?.endedAt != nil)
        #expect(coordinator.currentRecord?.interrupted == false)
        #expect(coordinator.store.session?.isOpen == false)
        #expect(background.beginCount == 0)

        try coordinator.addNote("Nota añadida tras cerrar el entrenamiento")
        #expect(
            coordinator.currentRecord?.notes.map(\.text) == ["Nota añadida tras cerrar el entrenamiento"])
        let workoutId = try #require(coordinator.currentRecord?.id)
        let exportURL = try coordinator.exportWorkoutJSON(id: workoutId)
        let export = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(export.contains("Nota añadida tras cerrar el entrenamiento"))
        #expect(export.contains("operator.note"))
        #expect(transport.actions.isEmpty)
    }

    @MainActor @Test func hardwareZeroTelemetryDuringPauseKeepsResumeTargetWithoutDeviation()
        async throws
    {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.startFree()
        try await coordinator.confirmAndStart()
        let acceptedTarget = try #require(coordinator.snapshot?.effectiveSpeedKPH)
        try await coordinator.pause()
        #expect(coordinator.snapshot?.state == .paused)
        for _ in 0..<4 {
            transport.publishSpeed(0)
            coordinator.captureTelemetryCallback(try #require(transport.snapshot?.telemetry))
        }
        #expect(coordinator.snapshot?.deviation == nil)
        #expect(coordinator.snapshot?.effectiveSpeedKPH == acceptedTarget)
        try await coordinator.resume()
        #expect(coordinator.snapshot?.state == .running)
        #expect(coordinator.snapshot?.effectiveSpeedKPH == acceptedTarget)
        #expect(coordinator.snapshot?.deviation == nil)
        try await coordinator.stop()
    }

    @MainActor @Test func capturedStopZeroBeforeAckStartsWithoutAnotherSpeedPacket() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge, stopZeroBeforeAck: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.startFree()
        try await coordinator.confirmAndStart()
        #expect(Array(transport.actions.prefix(3)) == [.requestControl, .stop, .start])
        #expect(coordinator.snapshot?.state == .running)
    }

    @MainActor @Test func lifecycleTransitionsAndWorkoutNotesKeepDiagnosticEventSequencesUnique()
        async throws
    {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.setMockMode(true)
        try await coordinator.startFree()
        try await coordinator.confirmAndStart()

        // Mirrors SwiftUI scenePhase callbacks while the capture is open.
        coordinator.backgrounded()
        coordinator.foregrounded()
        try coordinator.addNote("Nota durante el entrenamiento")
        coordinator.backgrounded()
        coordinator.foregrounded()
        try await coordinator.finishAndSave()
        try coordinator.addNote("Nota posterior al entrenamiento")

        #expect(coordinator.errorMessage == nil)
        let sessionId = try #require(coordinator.currentRecord?.sessionId)
        let artifact = try await coordinator.store.exportAsync(
            sessionId: sessionId,
            metadata: AppMetadata(
                version: "test", build: "1", osVersion: "test", deviceModel: "simulated"))
        let eventsURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.map(\.sequence) == Array(1...events.count))
        #expect(Set(events.map(\.eventId)).count == events.count)
        #expect(events.filter { $0.kind == "app.backgrounded" }.count == 2)
        #expect(events.filter { $0.kind == "app.activated" }.count == 2)
        #expect(
            events.contains {
                $0.kind == "operator.note" && $0.payload["note"]?.text == "Nota durante el entrenamiento"
            })
        #expect(events.contains { $0.kind == "session.closed" })
        #expect(
            coordinator.currentRecord?.notes.map(\.text) == [
                "Nota durante el entrenamiento", "Nota posterior al entrenamiento",
            ])
        #expect(transport.actions.isEmpty)
    }

    @MainActor @Test func backgroundExpirationSuspendsAutomationWithoutStopOrResume() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let background = FakeWorkoutBackgroundService()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: background, controlTransport: transport,
            targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        let commandsBeforeExpiration = transport.actions

        background.expire()

        #expect(coordinator.snapshot?.state == .manual)
        #expect(coordinator.currentRecord?.endedAt == nil)
        #expect(transport.actions == commandsBeforeExpiration)
        #expect(transport.actions.filter { $0 == .stop }.count == 1)
        await #expect(throws: ControlError.self) { try await coordinator.resume() }
    }

    @MainActor @Test func stopDuringPendingStartPreemptsTargetsAndIncline() async throws {
        let directory = temporaryDirectory()
        // Preparation exceeds the former 200 ms polling budget even on a fast runner.
        let transport = FakeWorkoutTransport(
            targetTelemetry: .converge, holdStartCommand: true,
            preparationDelay: .milliseconds(350))
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        let startTask = Task { try await coordinator.confirmAndStart() }
        try #require(await waitForCondition { transport.startCommandIsPending })

        try await coordinator.stop()
        transport.rejectPendingStartAsSuperseded()
        await #expect(throws: FakeWorkoutTransportError.self) { try await startTask.value }

        #expect(transport.actions == [.requestControl, .stop, .start, .stop])
        #expect(coordinator.snapshot?.state == .completed)
        #expect(coordinator.currentRecord?.endedAt != nil)
        #expect(!transport.actions.contains(.speed) && !transport.actions.contains(.inclination))
    }

    @MainActor @Test func expirationWhileWaitingForSpeedBlocksLateTargetCommands() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(
            targetTelemetry: .converge, startSpeedAfterAcknowledgement: nil,
            preparationDelay: .milliseconds(350))
        let background = FakeWorkoutBackgroundService()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: background, controlTransport: transport,
            targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        let startTask = Task { try await coordinator.confirmAndStart() }
        try #require(await waitForCondition { transport.actions.contains(.start) })

        // A late positive reading with a wall-clock timestamp older than the
        // Start request must not satisfy its fresh-speed confirmation.
        let startRequestedAt = try #require(transport.lastStartRequestAt)
        transport.publishSpeed(1, receivedAt: startRequestedAt.addingTimeInterval(-0.2))
        try await Task.sleep(for: .milliseconds(150))
        #expect(coordinator.snapshot?.state == .starting)
        #expect(!transport.actions.contains(.speed) && !transport.actions.contains(.inclination))

        background.expire()
        transport.publishSpeed(1)
        await #expect(throws: ControlError.self) { try await startTask.value }

        #expect(coordinator.snapshot?.state == .manual)
        #expect(coordinator.currentRecord?.endedAt == nil)
        #expect(transport.actions == [.requestControl, .stop, .start])
        #expect(!transport.actions.contains(.speed) && !transport.actions.contains(.inclination))
    }

    @MainActor @Test func expirationDuringSpeedTargetDoesNotContinueToInclination() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(
            targetTelemetry: .converge, holdSpeedTarget: true, preparationDelay: .milliseconds(350))
        let background = FakeWorkoutBackgroundService()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: background, controlTransport: transport,
            targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        let startTask = Task { try await coordinator.confirmAndStart() }
        try #require(await waitForCondition { transport.speedTargetIsPending })

        background.expire()
        transport.acceptHeldSpeedTarget()
        await #expect(throws: ControlError.self) { try await startTask.value }

        #expect(coordinator.snapshot?.state == .manual)
        #expect(transport.actions.filter { $0 == .speed }.count == 1)
        #expect(!transport.actions.contains(.inclination))
    }

    @MainActor @Test func stopDuringSkippedSegmentSpeedTargetPreventsFutureIncline() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(
            targetTelemetry: .converge, holdSpeedTarget: true, holdSpeedTargetAttempt: 2)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        let inclineCountBeforeSkip = transport.actions.filter { $0 == .inclination }.count
        let skipTask = Task { try await coordinator.skipSegment() }
        try #require(await waitForCondition { transport.speedTargetIsPending })

        try await coordinator.stop()
        transport.acceptHeldSpeedTarget()
        await #expect(throws: ControlError.self) { try await skipTask.value }

        #expect(coordinator.snapshot?.state == .completed)
        #expect(transport.actions.filter { $0 == .stop }.count == 2)
        #expect(transport.actions.filter { $0 == .inclination }.count == inclineCountBeforeSkip)
    }

    /// Wait for the interleaving under test instead of assuming a runner's scheduling latency.
    @MainActor private func waitForCondition(_ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // SessionStore/WorkoutCoordinator can still have SQLite writers and a scheduler
    // at test return. Keep these simulator-temp fixtures until xctest exits; removing
    // them in defer unlinks an open database and can corrupt unrelated checks.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkoutCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func twoIntervalProgram() -> WorkoutProgram {
        WorkoutProgram(
            id: "integration-two-intervals", name: "Prueba integrada",
            intervals: [
                WorkoutInterval(
                    id: "first", durationSeconds: 20, targetSpeedKPH: 5, targetInclinationPercent: 1),
                WorkoutInterval(
                    id: "second", durationSeconds: 20, targetSpeedKPH: 7, targetInclinationPercent: 2),
            ])
    }
}

private enum FakeWorkoutBackgroundError: Error { case denied }

@MainActor
private final class FakeWorkoutBackgroundService: WorkoutBackgroundService {
    let denyAdmission: Bool
    private(set) var beginCount = 0
    private(set) var endResults: [Bool] = []
    private var expiration: (@MainActor () -> Void)?

    init(denyAdmission: Bool = false) { self.denyAdmission = denyAdmission }

    func begin(totalSeconds: Int, onExpiration: @escaping @MainActor () -> Void) async throws {
        beginCount += 1
        if denyAdmission { throw FakeWorkoutBackgroundError.denied }
        expiration = onExpiration
    }

    func update(completedSeconds: Int, totalSeconds: Int) {}
    func end(success: Bool) async { endResults.append(success) }
    func expire() { expiration?() }
}

@MainActor
private final class FakeWorkoutTransport: WorkoutControlTransport {
    enum TargetTelemetry { case none, converge, transientFallback }
    var phase: BluetoothPhase = .ready
    var selectedProtocol: DiagnosticProtocol = .ftms
    var control: FTMSControl
    var snapshot: GATTDevice?
    private(set) var actions: [FTMSAction] = []
    private var sequence = 0
    private let rejectInclination: Bool
    private let targetTelemetry: TargetTelemetry
    private let failSpeedTarget: Bool
    private let holdStartCommand: Bool
    private let holdSpeedTarget: Bool
    private let holdSpeedTargetAttempt: Int
    private let startSpeedAfterAcknowledgement: Double?
    private let preparationDelay: Duration
    private let failPreparation: Bool
    private let failStart: Bool
    private let disconnectAfterStop: Bool
    private let stopZeroBeforeAck: Bool
    private var heldStart: CheckedContinuation<FTMSProcedure, any Error>?
    private var heldSpeed: CheckedContinuation<FTMSProcedure, any Error>?
    private var heldSpeedProcedure: FTMSProcedure?
    private var heldSpeedTargetValue: Double?
    private(set) var startCommandIsPending = false
    private(set) var speedTargetIsPending = false
    private(set) var lastStartRequestAt: Date?
    private var speedTargetAttempts = 0

    init(
        targetTelemetry: TargetTelemetry = .none, rejectInclination: Bool = false,
        failSpeedTarget: Bool = false,
        holdStartCommand: Bool = false, holdSpeedTarget: Bool = false,
        holdSpeedTargetAttempt: Int = 1,
        startSpeedAfterAcknowledgement: Double? = 1,
        preparationDelay: Duration = .zero, failPreparation: Bool = false, failStart: Bool = false,
        disconnectAfterStop: Bool = false, stopZeroBeforeAck: Bool = false
    ) {
        self.rejectInclination = rejectInclination
        self.targetTelemetry = targetTelemetry
        self.failSpeedTarget = failSpeedTarget
        self.holdStartCommand = holdStartCommand
        self.holdSpeedTarget = holdSpeedTarget
        self.holdSpeedTargetAttempt = holdSpeedTargetAttempt
        self.startSpeedAfterAcknowledgement = startSpeedAfterAcknowledgement
        self.preparationDelay = preparationDelay
        self.failPreparation = failPreparation
        self.failStart = failStart
        self.disconnectAfterStop = disconnectAfterStop
        self.stopZeroBeforeAck = stopZeroBeforeAck
        var initialControl = FTMSControl()
        initialControl.indicationReady = true
        initialControl.permission = true
        initialControl.stopAccepted = true
        control = initialControl
        let now = Date()
        let telemetry = FTMSTelemetry(
            serviceId: "ftms", characteristicId: "data", startedAt: now,
            subscriptionOperationId: "fake-subscription", subscriptionStatus: "subscribed",
            speed: FTMSMetric(value: 0, unit: "km/h", receivedAt: now, eventId: "initial-speed"),
            inclination: rejectInclination
                ? nil : FTMSMetric(value: 0, unit: "%", receivedAt: now, eventId: "initial-incline"))
        let features = GATTCharacteristic(
            id: "feature", uuid: "2ACC", properties: ["read"], rawProperties: 2,
            ftmsFeatures: FTMSFeatures(machineBits: 0, targetBits: (1 << 0) | (1 << 1)))
        let speedRange = GATTCharacteristic(
            id: "speed-range", uuid: "2AD4", properties: ["read"], rawProperties: 2,
            ftmsRange: FTMSRange(minimum: 0.8, maximum: 16, increment: 0.1, unit: "km/h"))
        let inclinationRange = GATTCharacteristic(
            id: "incline-range", uuid: "2AD5", properties: ["read"], rawProperties: 2,
            ftmsRange: FTMSRange(minimum: 0, maximum: 15, increment: 1, unit: "%"))
        let service = GATTService(
            id: "ftms", uuid: "1826", isPrimary: true,
            characteristicDiscovery: "complete",
            characteristics: [features, speedRange, inclinationRange])
        snapshot = GATTDevice(
            localPeripheralIdentifier: UUID().uuidString, inspectionId: "fake-inspection",
            advertisedName: "Fake treadmill", advertisement: [:], selectedAt: now, source: .synthetic,
            connectedAt: now, connectionState: "connected", serviceDiscovery: "complete",
            discoveryStatus: "complete", services: [service], telemetry: telemetry)
    }

    func prepareControlAndWait(timeout: Duration) async throws {
        control.indicationReady = false
        if preparationDelay > .zero { try await Task.sleep(for: preparationDelay) }
        if failPreparation { throw FakeWorkoutTransportError.subscriptionsTimedOut }
        control.indicationReady = true
        phase = .ready
    }

    func executeAndWait(
        _ action: FTMSAction, speed: Double?, inclination: Double?,
        allowProgramBackground: Bool, timeout: Duration
    ) async throws -> FTMSProcedure {
        actions.append(action)
        if action == .start { lastStartRequestAt = Date() }
        if action == .speed { speedTargetAttempts += 1 }
        sequence += 1
        var procedure = FTMSProcedure(
            id: "fake-\(sequence)", action: action, requestedAt: Date(), valueHex: "",
            writeStatus: "complete", result: "accepted")
        if action == .inclination && rejectInclination {
            procedure.result = "rejectedByProtocol"
            control.last = procedure
            throw FakeWorkoutTransportError.inclinationRejected
        }
        if action == .speed && failSpeedTarget {
            procedure.result = "timeout"
            control.last = procedure
            throw FakeWorkoutTransportError.targetTimedOut
        }
        if action == .start && failStart {
            procedure.result = "timeout"
            control.last = procedure
            throw FakeWorkoutTransportError.startTimedOut
        }
        control.last = procedure
        if action == .speed && holdSpeedTarget && speedTargetAttempts == holdSpeedTargetAttempt {
            speedTargetIsPending = true
            heldSpeedProcedure = procedure
            heldSpeedTargetValue = speed
            let accepted = try await withCheckedThrowingContinuation { continuation in
                heldSpeed = continuation
            }
            speedTargetIsPending = false
            return accepted
        }
        switch action {
        case .requestControl:
            control.permission = true
        case .stop:
            if stopZeroBeforeAck {
                _ = try control.begin(.stop, authorized: true, at: procedure.requestedAt)
                try await Task.sleep(for: .milliseconds(2))
                setSpeed(0)
                control.observed(snapshot?.telemetry?.speed)
                _ = try control.response(Data([0x80, 8, 1]), eventId: "fake-stop-ack")
            } else {
                try await Task.sleep(for: .milliseconds(2))
                control.stopAccepted = true
                setSpeed(0)
            }
            if disconnectAfterStop { phase = .disconnected }
        case .start:
            if stopZeroBeforeAck {
                _ = try control.begin(.start, authorized: true, observedSpeed: snapshot?.telemetry?.speed)
                _ = try control.response(Data([0x80, 7, 1]), eventId: "fake-start-ack")
            }
            if holdStartCommand {
                startCommandIsPending = true
                return try await withCheckedThrowingContinuation { continuation in heldStart = continuation
                }
            }
            if let startSpeedAfterAcknowledgement {
                try await Task.sleep(for: .milliseconds(2))
                setSpeed(startSpeedAfterAcknowledgement)
            }
        case .speed:
            if let speed { scheduleTargetTelemetry(speed) }
        case .inclination:
            break
        }
        return procedure
    }

    func setProgramBackgroundLease(_ enabled: Bool) {}

    func rejectPendingStartAsSuperseded() {
        startCommandIsPending = false
        heldStart?.resume(throwing: FakeWorkoutTransportError.startSuperseded)
        heldStart = nil
    }

    func acceptHeldSpeedTarget() {
        guard let heldSpeedProcedure else { return }
        if let heldSpeedTargetValue { scheduleTargetTelemetry(heldSpeedTargetValue) }
        heldSpeed?.resume(returning: heldSpeedProcedure)
        heldSpeed = nil
        self.heldSpeedProcedure = nil
        heldSpeedTargetValue = nil
    }

    func publishSpeed(_ speed: Double, receivedAt: Date = Date()) {
        setSpeed(speed, receivedAt: receivedAt)
    }

    private func scheduleTargetTelemetry(_ target: Double) {
        switch targetTelemetry {
        case .none: break
        case .converge:
            Task { @MainActor in
                for _ in 0..<5 {
                    try? await Task.sleep(for: .milliseconds(75))
                    self.setSpeed(target)
                }
            }
        case .transientFallback:
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(75))
                self.setSpeed(target)
                try? await Task.sleep(for: .milliseconds(75))
                self.setSpeed(0.8)
            }
        }
    }

    func publishDistance(_ meters: Double, eventID: String, receivedAt: Date = Date()) {
        guard var device = snapshot, var telemetry = device.telemetry else { return }
        telemetry.distance = FTMSMetric(
            value: meters, unit: "m", receivedAt: receivedAt, eventId: eventID)
        device.telemetry = telemetry
        snapshot = device
    }

    private func setSpeed(_ speed: Double, receivedAt: Date = Date()) {
        guard var device = snapshot, var telemetry = device.telemetry else { return }
        telemetry.speed = FTMSMetric(
            value: speed, unit: "km/h", receivedAt: receivedAt,
            eventId: "fake-speed-\(sequence)-\(UUID().uuidString)")
        device.telemetry = telemetry
        snapshot = device
    }
}

private enum FakeWorkoutTransportError: Error {
    case inclinationRejected
    case targetTimedOut
    case startSuperseded
    case subscriptionsTimedOut
    case startTimedOut
}

@MainActor
private final class FakeWorkoutCompanion: WorkoutCompanion {
    var useWatch = true
    var readiness = WatchReadiness(state: .prepared, accessReviewed: true, canSaveWorkout: true)
    var preparedSessionID: String?
    var onMessage: ((CompanionMessage) async throws -> Void)?
    var rejectPreparation = false
    var acknowledgements: [String] = []
    var healthAcknowledgements: [String] = []
    var finalizations = 0
    var publishedStates: [WorkoutState] = []
    func prepare(id: String, view: CompanionWorkoutView) async throws {
        if rejectPreparation { throw CompanionError.unavailable }
        preparedSessionID = id
    }
    func publish(id: String, view: CompanionWorkoutView) {
        publishedStates.append(view.snapshot.state)
    }
    func cancelPreparation(id: String) { if preparedSessionID == id { preparedSessionID = nil } }
    func finalize(id: String, view: CompanionWorkoutView) { finalizations += 1 }
    func acknowledge(id: String, sampleIDs: [String]) { acknowledgements += sampleIDs }
    func acknowledgeHealthResult(sessionID: String, resultID: String) {
        healthAcknowledgements.append("\(sessionID):\(resultID)")
    }
}

extension WorkoutCoordinatorIntegrationTests {
    @MainActor @Test func oldSessionStatusGetsDomainErrorBeforeWorkoutDataGuard() async throws {
        let directory = temporaryDirectory()
        let companion = FakeWorkoutCompanion()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: FakeWorkoutTransport(targetTelemetry: .converge), targetStableSeconds: 0.15,
            targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        let oldID = UUID().uuidString.lowercased()
        do {
            try await companion.onMessage?(
                .init(sessionID: oldID, sender: "watch", sequence: 1, payload: .statusRequest))
            Issue.record("Se esperaba error de sesión remota desconocida")
        } catch let error as CompanionError { #expect(error == .remoteSessionUnknown(oldID)) }
        try await coordinator.store.flush()
        #expect(
            coordinator.store.session?.events.contains { $0.kind == "watch.status.unknownSession" }
                == true)
    }

    @MainActor @Test func orphanedTerminalResultIsDurablyDeduplicatedAndAcknowledged() async throws {
        let directory = temporaryDirectory()
        let oldID = UUID().uuidString.lowercased()
        let deliveryID = UUID().uuidString.lowercased()
        let result = HealthSaveResult(
            state: .discarded, message: "cancelled old preparation", deliveryID: deliveryID)
        let first = FakeWorkoutCompanion()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: FakeWorkoutTransport(targetTelemetry: .converge), targetStableSeconds: 0.15,
            targetDeadlineScale: 0.07)
        coordinator.attachCompanion(first)
        try await first.onMessage?(
            .init(sessionID: oldID, sender: "watch", sequence: 1, payload: .healthResult(result)))
        #expect(first.healthAcknowledgements == ["\(oldID):\(deliveryID)"])
        let second = FakeWorkoutCompanion()
        let restored = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: FakeWorkoutTransport(targetTelemetry: .converge), targetStableSeconds: 0.15,
            targetDeadlineScale: 0.07)
        restored.attachCompanion(second)
        try await second.onMessage?(
            .init(sessionID: oldID, sender: "watch", sequence: 2, payload: .healthResult(result)))
        #expect(second.healthAcknowledgements == ["\(oldID):\(deliveryID)"])
        let ledger = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("watch-terminal-results.json")))
                as? [String: Any])
        #expect(ledger.count == 1)
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let eventsURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let evidence = try String(contentsOf: eventsURL, encoding: .utf8)
        #expect(evidence.contains("watch.terminal.orphaned"))
        #expect(evidence.contains(deliveryID))
    }
    @MainActor @Test func selectionIsDurableAndExportsWithoutWorkoutRecord() async throws {
        let directory = temporaryDirectory()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: FakeWorkoutTransport(targetTelemetry: .converge), targetStableSeconds: 0.15,
            targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        #expect(coordinator.currentRecord == nil)
        let id = try #require(coordinator.store.session?.sessionId)
        let reopened = SessionStore(directory: directory)
        #expect(reopened.session?.sessionId == id)
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let eventsURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let text = try String(contentsOf: eventsURL, encoding: .utf8)
        #expect(text.contains("workout.preparation.selected"))
        #expect(text.contains("workout.preparation.ready"))
        #expect(!text.contains("workout.operatorConfirmed"))
    }

    @MainActor @Test func cancelledPreviewAllowsNewSelectionAndStandaloneExport() async throws {
        let directory = temporaryDirectory()
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: FakeWorkoutTransport(targetTelemetry: .converge), targetStableSeconds: 0.15,
            targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        coordinator.cancelWatchPreparation()
        let second = WorkoutProgram(
            id: "second-selection", name: "Segunda selección",
            intervals: [
                WorkoutInterval(
                    id: "next", durationSeconds: 20, targetSpeedKPH: 4, targetInclinationPercent: 0)
            ])
        try await coordinator.start(program: second)
        #expect(coordinator.currentRecord == nil)
        #expect(coordinator.snapshot?.state == .preparing)
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.filter { $0.kind == "workout.preparation.selected" }.count == 2)
        #expect(events.contains { $0.kind == "watch.preparation.cancelled" })
    }

    @MainActor @Test func startWaitsForSubscriptionsWhileJournalReceivesConcurrentTelemetry()
        async throws
    {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(
            targetTelemetry: .converge, preparationDelay: .milliseconds(250))
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        let startTask = Task { try await coordinator.confirmAndStart() }
        try #require(await waitForCondition { coordinator.currentRecord != nil })
        #expect(transport.actions.isEmpty)
        for index in 0..<300 {
            let eventID = "stream-distance-\(index)"
            var payload: [String: JSONValue] = [
                "streamIndex": .number(Double(index)), "rawHex": .string("01020304"),
            ]
            if index < 60 {
                payload["inspectionId"] = .string("fake-inspection")
                payload["sample"] = .object(["distanceMeters": .number(Double(index + 1))])
            }
            try coordinator.store.record(
                kind: "ftms.treadmill.received", source: .synthetic,
                payload: payload, eventId: eventID)
            if index < 60 {
                transport.publishSpeed(Double(index % 2))
                transport.publishDistance(Double(index + 1), eventID: eventID)
                if let telemetry = transport.snapshot?.telemetry {
                    coordinator.captureTelemetryCallback(telemetry)
                }
            }
        }
        try await startTask.value
        #expect(coordinator.snapshot?.state == .running)
        #expect(transport.actions.prefix(3) == [.requestControl, .stop, .start])
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let events = try lines.map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.filter { $0.kind == "ftms.treadmill.received" }.count == 300)
        #expect((coordinator.currentRecord?.sampleCount ?? 0) >= 60)
        let workoutID = try #require(coordinator.currentRecord?.id)
        let distances = try coordinator.loadSamples(for: workoutID).filter {
            $0.metric == "sessionDistanceMeters"
        }
        #expect(distances.count == 60)
        #expect(distances.last?.sample.value == 59)
        #expect(
            events.contains {
                $0.kind == "workout.start.stage" && $0.payload["stage"]?.text == "ftmsSubscriptions"
                    && $0.payload["status"]?.text == "completed"
            })
    }

    @MainActor @Test func subscriptionFailureExportsOriginalErrorAndNoControlRequest() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(
            targetTelemetry: .converge, preparationDelay: .milliseconds(40), failPreparation: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        await #expect(throws: FakeWorkoutTransportError.self) {
            try await coordinator.confirmAndStart()
        }
        #expect(transport.actions.isEmpty)
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        let failure = try #require(
            events.last { $0.kind == "workout.start.stage" && $0.payload["status"]?.text == "failed" })
        #expect(failure.payload["stage"]?.text == "ftmsSubscriptions")
        #expect(failure.payload["error"]?.text?.contains("subscriptionsTimedOut") == true)
        #expect(
            {
                if case .some(.number(_)) = failure.payload["durationMilliseconds"] { true } else { false }
            }())
        #expect(failure.payload["ftmsIndicationReady"] == .bool(false))
        #expect(
            !events.contains {
                $0.kind == "workout.start.stage" && $0.payload["stage"]?.text == "requestControl"
            })
    }

    @MainActor @Test func startTimeoutIsRecordedAtStartAndNeverRetried() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge, failStart: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        await #expect(throws: FakeWorkoutTransportError.self) {
            try await coordinator.confirmAndStart()
        }
        #expect(transport.actions == [.requestControl, .stop, .start])
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(
            events.contains {
                $0.kind == "workout.start.stage" && $0.payload["stage"]?.text == "start"
                    && $0.payload["status"]?.text == "failed"
                    && $0.payload["error"]?.text?.contains("startTimedOut") == true
            })
        #expect(
            !events.contains {
                $0.kind == "workout.start.stage" && $0.payload["stage"]?.text == "initialTargets"
            })
    }

    @MainActor @Test func connectionLossDuringZeroGateBlocksStartAndRecordsGate() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge, disconnectAfterStop: true)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        await #expect(throws: ControlError.self) { try await coordinator.confirmAndStart() }
        #expect(transport.actions == [.requestControl, .stop])
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(
            events.contains {
                $0.kind == "workout.start.stage" && $0.payload["stage"]?.text == "observeZeroSpeed"
                    && $0.payload["status"]?.text == "failed"
                    && $0.payload["bluetoothPhase"]?.text == "disconnected"
            })
    }

    @MainActor @Test func stopDuringSuspendedSchedulerCannotSendLateTarget() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.confirmAndStart()
        var releaseTarget: CheckedContinuation<Void, Never>?
        coordinator.beforeScheduledTarget = {
            await withCheckedContinuation { releaseTarget = $0 }
        }
        let tick = Task {
            await coordinator.schedulerStep(at: ProcessInfo.processInfo.systemUptime + 20.05)
        }
        try #require(await waitForCondition { releaseTarget != nil })
        try await coordinator.finishAndSave()
        let actionsAtStop = transport.actions
        releaseTarget?.resume()
        await tick.value
        #expect(transport.actions == actionsAtStop)
        #expect(transport.actions.filter { $0 == .speed }.count == 1)
        #expect(coordinator.currentRecord?.endedAt != nil)
    }

    @MainActor @Test func watchPreparationFailureSendsNoMotorCommands() async throws {
        let directory = temporaryDirectory()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let companion = FakeWorkoutCompanion()
        companion.rejectPreparation = true
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        try await coordinator.start(program: twoIntervalProgram())
        await #expect(throws: CompanionError.self) { try await coordinator.prepareWatch() }
        await #expect(throws: CompanionError.self) { try await coordinator.confirmAndStart() }
        #expect(transport.actions.isEmpty)
        #expect(coordinator.currentRecord == nil)
    }

    @MainActor @Test func cancelledWatchReadinessIsBenignAndExportable() async throws {
        let directory = temporaryDirectory()
        let companion = FakeWorkoutCompanion()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.prepareWatch()
        let id = try #require(companion.preparedSessionID)
        coordinator.cancelWatchPreparation()
        try await companion.onMessage?(
            .init(
                sessionID: id, sender: "watch", sequence: 3,
                payload: .readiness(.init(state: .prepared, accessReviewed: true, canSaveWorkout: true))))
        #expect(coordinator.currentRecord == nil)
        #expect(transport.actions.isEmpty)
        let artifact = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("watch.preparation.cancelled"))
        #expect(text.contains("watch.readiness.stale"))
    }

    @MainActor @Test func duplicateConcurrentWatchBatchesAckAfterSingleDurableSave() async throws {
        let directory = temporaryDirectory()
        let companion = FakeWorkoutCompanion()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.prepareWatch()
        try await coordinator.confirmAndStart()
        let id = try #require(coordinator.currentRecord?.id)
        let now = Date()
        let row = WatchHealthSample(
            id: "simultaneous-pulse", metric: "heartRateBPM", value: 121,
            unit: "count/min", sampledAt: now, periodStart: now, device: "Watch test",
            sourceIdentifier: "healthkit.test")
        let message = CompanionMessage(
            sessionID: id, sender: "watch", sequence: 100, payload: .samples([row]))
        let first = Task { try await companion.onMessage?(message) }
        let second = Task { try await companion.onMessage?(message) }
        try await first.value
        try await second.value
        #expect(try coordinator.loadSamples(for: id).filter { $0.sample.eventId == row.id }.count == 1)
        #expect(companion.acknowledgements == [row.id, row.id])
        let exported = try await coordinator.exportDiagnostic(
            metadata: .init(version: "test", build: "1", osVersion: "test", deviceModel: "synthetic"))
        let url = try #require(exported.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        #expect(try String(contentsOf: url, encoding: .utf8).contains(row.id))
    }

    @MainActor @Test func failedWatchCaptureStillReceivesFinalizationOnWorkoutClose() async throws {
        let directory = temporaryDirectory()
        let companion = FakeWorkoutCompanion()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.prepareWatch()
        try await coordinator.confirmAndStart()
        let id = try #require(coordinator.currentRecord?.id)
        try await companion.onMessage?(
            .init(
                sessionID: id, sender: "watch", sequence: 15,
                payload: .healthResult(.init(state: .failed, message: "beginCollection failed"))))
        #expect(coordinator.currentRecord?.healthSave?.state == .failed)
        try await coordinator.stop()
        #expect(companion.finalizations == 1)
        #expect(coordinator.currentRecord?.endedAt != nil)
    }

    @MainActor @Test func lateWatchResultCannotReopenClosedWorkout() async throws {
        let directory = temporaryDirectory()
        let repository = try WorkoutRepository(directory: directory)
        var record = WorkoutRecord(
            mode: "program", program: twoIntervalProgram(),
            latestSnapshot: WorkoutEngine(program: twoIntervalProgram()).snapshot())
        record.healthSave = HealthSaveResult(state: .pending)
        try repository.save(record)
        record.endedAt = Date()
        record.interrupted = true
        try repository.save(record)
        let closedDate = try #require(repository.record(id: record.id)?.endedAt)
        let savedResult = HealthSaveResult(state: .saved, workoutUUID: UUID().uuidString)
        let committed = try await repository.appendSamplesAsync(
            workoutID: record.id, samples: [],
            event: WorkoutRuntimeEvent(
                sequence: 0, kind: "watch.message.received", source: "watchHealthKit"),
            healthResult: savedResult)
        #expect(committed.endedAt == closedDate)
        #expect(committed.interrupted)
        #expect(committed.healthSave?.state == .saved)
        #expect(try repository.record(id: record.id)?.endedAt == closedDate)
    }

    @MainActor @Test func watchSamplesPersistOnceAndLateDataDoesNotReplaceFreshMetrics() async throws {
        let directory = temporaryDirectory()
        let companion = FakeWorkoutCompanion()
        let transport = FakeWorkoutTransport(targetTelemetry: .converge)
        let coordinator = WorkoutCoordinator(
            directory: directory, backgroundService: FakeWorkoutBackgroundService(),
            controlTransport: transport, targetStableSeconds: 0.15, targetDeadlineScale: 0.07)
        coordinator.attachCompanion(companion)
        try await coordinator.start(program: twoIntervalProgram())
        try await coordinator.prepareWatch()
        try await coordinator.confirmAndStart()
        let id = try #require(coordinator.currentRecord?.id)
        let now = Date()
        let fresh = WatchHealthSample(
            id: "pulse-new", metric: "heartRateBPM", value: 124, unit: "count/min", sampledAt: now,
            periodStart: now, device: "Ultra 2", sourceIdentifier: "healthkit.test")
        let first = CompanionMessage(
            sessionID: id, sender: "watch", sequence: 3, payload: .samples([fresh]))
        try await companion.onMessage?(first)
        try await companion.onMessage?(first)
        let old = WatchHealthSample(
            id: "pulse-old", metric: "heartRateBPM", value: 118, unit: "count/min",
            sampledAt: now.addingTimeInterval(-1), periodStart: now.addingTimeInterval(-1),
            device: "Ultra 2", sourceIdentifier: "healthkit.test")
        try await companion.onMessage?(
            .init(sessionID: id, sender: "watch", sequence: 2, payload: .samples([old])))
        let saved = try coordinator.loadSamples(for: id).filter { $0.sample.source == .watchHealthKit }
        #expect(saved.count == 2)
        #expect(coordinator.latestMetrics["heartRateBPM"]?.value == 124)
        #expect(abs((saved.first?.sample.sampledAt ?? .distantPast).timeIntervalSince(now)) < 0.001)
        #expect(saved.first?.sample.sourceDevice == "Ultra 2")
        #expect(companion.acknowledgements.contains("pulse-new"))
        #expect(!coordinator.latestMetrics.values.contains { $0.source == .mock })
        let beforeUnknown = companion.acknowledgements.count
        await #expect(throws: CompanionError.self) {
            try await companion.onMessage?(
                .init(sessionID: "wrong", sender: "watch", sequence: 9, payload: .samples([fresh])))
        }
        #expect(companion.acknowledgements.count == beforeUnknown)
        try await coordinator.stop()
        #expect(companion.finalizations == 1)
        let late = WatchHealthSample(
            id: "energy-last", metric: "energyKilocalories", value: 65, unit: "kcal", sampledAt: now,
            periodStart: now, device: "Ultra 2", sourceIdentifier: "healthkit.test")
        try await companion.onMessage?(
            .init(sessionID: id, sender: "watch", sequence: 10, payload: .samples([late])))
        #expect(try coordinator.loadSamples(for: id).contains { $0.sample.eventId == "energy-last" })
        let result = HealthSaveResult(state: .saved, workoutUUID: UUID().uuidString)
        try await companion.onMessage?(
            .init(sessionID: id, sender: "watch", sequence: 11, payload: .healthResult(result)))
        try await companion.onMessage?(
            .init(
                sessionID: id, sender: "watch", sequence: 12, payload: .healthResult(.init(state: .pending))
            ))
        #expect(coordinator.currentRecord?.healthSave?.state == .saved)
        let exported = try String(contentsOf: coordinator.exportWorkoutJSON(id: id), encoding: .utf8)
        #expect(exported.contains("healthkit.test"))
        #expect(exported.contains("sampledAt"))
        #expect(exported.contains("energy-last"))
        #expect(exported.contains(result.workoutUUID!))
        let archive = try await coordinator.exportZIPAsync(
            record: #require(coordinator.currentRecord),
            metadata: .init(version: "test", build: "13", osVersion: "26", deviceModel: "test double"))
        #expect(
            Set(archive.fileURLs.map(\.lastPathComponent)) == [
                "manifest.json", "device.json", "results.json", "events.jsonl", "summary.txt",
                "watch-rejected-envelopes.json", "watch-rejected-envelopes.jsonl",
            ])
        let jsonl = try String(
            contentsOf: #require(archive.fileURLs.first { $0.lastPathComponent == "events.jsonl" }),
            encoding: .utf8)
        #expect(jsonl.contains("energy-last"))
        #expect(jsonl.contains(result.workoutUUID!))
    }

    @MainActor @Test func oldWorkoutRecordStillLoadsWithOptionalHealthFields() throws {
        let directory = temporaryDirectory()
        let repository = try WorkoutRepository(directory: directory)
        let snapshot = WorkoutEngine(program: twoIntervalProgram()).snapshot()
        let record = WorkoutRecord(mode: "program", latestSnapshot: snapshot, schemaVersion: 1)
        let data = try EvidenceJSON.encoder().encode(record)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "healthSave")
        let legacy = try EvidenceJSON.decoder().decode(
            WorkoutRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try repository.save(legacy)
        #expect(try repository.record(id: legacy.id)?.healthSave == nil)
        #expect(try repository.history().count == 1)
    }
}
