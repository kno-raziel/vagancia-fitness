import Foundation
import Testing

@testable import FitnessCore

struct WorkoutEngineTests {
    @Test func acceptedSpeedNeedsSustainedDistinctPostAcceptanceTelemetry() {
        var confirmation = TargetConfirmation(
            target: 5, acceptedAt: 10, requiredStableSeconds: 3, deadline: 12)
        let before = confirmation.observe(value: 5, eventID: "before", at: 9.9)
        let transient = confirmation.observe(value: 5, eventID: "one-target-echo", at: 10.5)
        let duplicate = confirmation.observe(value: 5, eventID: "one-target-echo", at: 11)
        let fallback = confirmation.observe(value: 0.8, eventID: "fallback", at: 11.5)
        let repeatedFallback = confirmation.observe(value: 0.8, eventID: "fallback-2", at: 20)
        #expect(!before && !transient && !duplicate && !fallback && !repeatedFallback)
        #expect(confirmation.expired(at: 22))
        #expect(confirmation.observed == 0.8)

        var converged = TargetConfirmation(target: 5, acceptedAt: 10, requiredStableSeconds: 3)
        let first = converged.observe(value: 5, eventID: "a", at: 11)
        let second = converged.observe(value: 5.1, eventID: "b", at: 12)
        let third = converged.observe(value: 4.9, eventID: "c", at: 14.1)
        #expect(!first && !second && third)
    }

    @Test func deviationLabelsMeasuredAndPlanEvidenceSeparately() {
        let plan = WorkoutProgram(
            name: "Una fase", intervals: [.init(durationSeconds: 60, targetSpeedKPH: 5)])
        var engine = WorkoutEngine(program: plan)
        _ = engine.start(at: 0)
        engine.updateEffectiveTargets(speedKPH: 5, inclinationPercent: 0, at: 0)
        _ = engine.markRunning(at: 0)
        for time in [11.0, 12.0, 14.0] {
            engine.updateMeasuredSpeed(
                WorkoutSample(
                    value: 0.8, source: .machineFTMS,
                    receivedAt: Date(), monotonicTime: time, eventId: "speed-\(time)"), at: time)
        }
        #expect(engine.deviation?.basis == .measuredVersusAccepted)
        #expect(engine.deviation?.observed == 0.8)
    }

    @Test func oneRepeatedTelemetryEventCannotCreateMeasuredDeviation() {
        let plan = WorkoutProgram(
            name: "Una fase", intervals: [.init(durationSeconds: 60, targetSpeedKPH: 5)])
        var engine = WorkoutEngine(program: plan)
        _ = engine.start(at: 0)
        engine.updateEffectiveTargets(speedKPH: 5, inclinationPercent: 0, at: 0)
        _ = engine.markRunning(at: 0)
        let repeated = WorkoutSample(
            value: 0.8, source: .machineFTMS, receivedAt: Date(),
            monotonicTime: 11, eventId: "one-event")
        engine.updateMeasuredSpeed(repeated, at: 11)
        engine.updateMeasuredSpeed(repeated, at: 12)
        engine.updateMeasuredSpeed(repeated, at: 14)
        #expect(engine.deviation == nil)
        engine.updateMeasuredSpeed(
            WorkoutSample(
                value: 0.8, source: .machineFTMS, receivedAt: Date(),
                monotonicTime: 12, eventId: "second-event"), at: 12)
        engine.updateMeasuredSpeed(
            WorkoutSample(
                value: 0.8, source: .machineFTMS, receivedAt: Date(),
                monotonicTime: 14, eventId: "third-event"), at: 14)
        #expect(engine.deviation?.basis == .measuredVersusAccepted)
    }
    @Test func physicalPauseAndFinishKeepAnUnconfirmedStateUntilRuntimeConfirms() {
        let plan = WorkoutProgram(
            name: "Una fase", intervals: [.init(durationSeconds: 15, targetSpeedKPH: 1)])
        var engine = WorkoutEngine(program: plan)
        _ = engine.start(at: 0)
        engine.updateEffectiveTargets(speedKPH: 1, inclinationPercent: 0, at: 0)
        _ = engine.markRunning(at: 0)
        #expect(engine.beginPausing(at: 3).state == .pausing)
        #expect(engine.snapshot(at: 10).activeElapsedSeconds == 3)
        #expect(engine.confirmPaused(at: 10).state == .paused)
        #expect(engine.resume(at: 12).state == .running)
        #expect(engine.beginFinishing(at: 14).state == .finishing)
        #expect(engine.suspendToManual(at: 15).state == .manual)
        #expect(engine.snapshot(at: 20).state != .completed)
        _ = engine.beginFinishing(at: 21)
        #expect(engine.complete(at: 22).state == .completed)
    }

    @Test func pauseZeroTelemetryDoesNotReportDeviationAndResumeChecksPreservedTarget() {
        let plan = WorkoutProgram(
            name: "Pausa", intervals: [.init(durationSeconds: 90, targetSpeedKPH: 5)])
        var engine = WorkoutEngine(program: plan)
        _ = engine.start(at: 0)
        engine.updateEffectiveTargets(speedKPH: 5, inclinationPercent: 0, at: 0)
        _ = engine.markRunning(at: 0)
        func sample(_ value: Double, _ time: TimeInterval) -> WorkoutSample {
            WorkoutSample(
                value: value, source: .machineFTMS, receivedAt: Date(),
                monotonicTime: time, eventId: "speed-\(time)")
        }
        for time in [11.0, 12.0, 14.0] { engine.updateMeasuredSpeed(sample(0, time), at: time) }
        #expect(engine.deviation?.basis == .measuredVersusAccepted)
        #expect(engine.beginPausing(at: 15).deviation == nil)
        for time in [16.0, 17.0, 18.0] { engine.updateMeasuredSpeed(sample(0, time), at: time) }
        #expect(engine.confirmPaused(at: 19).deviation == nil)
        for time in [20.0, 21.0, 22.0] { engine.updateMeasuredSpeed(sample(0, time), at: time) }
        #expect(engine.snapshot(at: 22).deviation == nil)
        let resumed = engine.resume(at: 30)
        #expect(resumed.effectiveSpeedKPH == 5 && resumed.deviation == nil)
        for time in [41.0, 42.0, 44.0] { engine.updateMeasuredSpeed(sample(0, time), at: time) }
        #expect(engine.snapshot(at: 44).deviation?.expected == 5)
        #expect(engine.beginFinishing(at: 45).deviation == nil)
        for time in [46.0, 47.0, 48.0] { engine.updateMeasuredSpeed(sample(0, time), at: time) }
        #expect(engine.snapshot(at: 48).deviation == nil)
    }

    private func program(_ durations: [Int] = [15, 15, 15]) -> WorkoutProgram {
        WorkoutProgram(
            id: "test", name: "Test",
            intervals: durations.enumerated().map { index, duration in
                WorkoutInterval(
                    id: "i\(index)", durationSeconds: duration, targetSpeedKPH: 4 + Double(index),
                    targetInclinationPercent: Double(index), phase: index == 0 ? .warmup : .work)
            }, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func prepareAndRun(_ engine: inout WorkoutEngine, at time: TimeInterval = 0) {
        _ = engine.start(at: time)
        engine.updateEffectiveTargets(
            speedKPH: engine.currentInterval.targetSpeedKPH,
            inclinationPercent: engine.currentInterval.targetInclinationPercent, at: time)
        _ = engine.markRunning(at: time)
    }

    @Test func seedsMirrorPrototypeAndEditorValidatesCachedLimits() throws {
        #expect(WorkoutProgram.seedPrograms.map(\.id) == ["essential", "steady"])
        #expect(
            WorkoutProgram.seedPrograms[0].intervals.map(\.durationSeconds) == [
                120, 90, 150, 90, 150, 90, 150, 90, 150,
            ])
        #expect(WorkoutTargetLimits.cachedDefault.source == .cachedDefault)
        try WorkoutProgram.validate(
            name: "  A plan ", intervals: [WorkoutInterval(durationSeconds: 15, targetSpeedKPH: 0.8)])
        #expect(throws: WorkoutProgramValidationError.self) {
            try WorkoutProgram.validate(
                name: " ", intervals: [WorkoutInterval(durationSeconds: 15, targetSpeedKPH: 1)])
        }
        #expect(throws: WorkoutProgramValidationError.self) {
            try WorkoutProgram.validate(
                name: "A", intervals: [WorkoutInterval(durationSeconds: 14, targetSpeedKPH: 1)])
        }
        #expect(throws: WorkoutProgramValidationError.self) {
            try WorkoutProgram.validate(
                name: "A", intervals: [WorkoutInterval(durationSeconds: 15, targetSpeedKPH: 1.05)])
        }
        #expect(throws: WorkoutProgramValidationError.self) {
            try WorkoutProgram.validate(
                name: "A",
                intervals: [
                    WorkoutInterval(durationSeconds: 15, targetSpeedKPH: 1, targetInclinationPercent: 16)
                ])
        }
    }

    @Test func virtualClockAdvancesPhasesAndPauseFreezesUntilExplicitResume() {
        var now: TimeInterval = 0
        var engine = WorkoutEngine(program: program(), clock: { now })
        #expect(engine.start().state == .starting)
        engine.updateEffectiveTargets(
            speedKPH: engine.currentInterval.targetSpeedKPH,
            inclinationPercent: engine.currentInterval.targetInclinationPercent)
        #expect(engine.markRunning().state == .running)
        for second in 1...10 {
            now = TimeInterval(second)
            _ = engine.tick()
        }
        #expect(engine.phaseElapsedSeconds == 10)
        #expect(engine.snapshot().activeElapsedSeconds == 10)
        #expect(engine.pause().state == .paused)
        now = 100
        let frozen = engine.tick()
        #expect(frozen.phaseElapsedSeconds == 10)
        #expect(frozen.activeElapsedSeconds == 10)
        #expect(frozen.pausedElapsedSeconds == 90)
        #expect(engine.resume().state == .running)
        for second in 101...105 {
            now = TimeInterval(second)
            _ = engine.tick()
        }
        let next = engine.snapshot()
        #expect(next.intervalIndex == 1)
        #expect(next.phaseElapsedSeconds == 0)
        #expect(next.activeElapsedSeconds == 15)
        #expect(next.pausedElapsedSeconds == 90)
    }

    @Test func initialPhaseCannotRunBeforeAnEffectiveSpeedTargetAndEmptyProgramsStaySafe() {
        var engine = WorkoutEngine(program: program())
        _ = engine.start(at: 0)
        #expect(engine.markRunning(at: 0).state == .starting)
        engine.updateEffectiveTargets(
            speedKPH: 4, inclinationPercent: nil, inclinationAccepted: false, at: 0)
        #expect(engine.markRunning(at: 0).state == .running)

        let empty = WorkoutProgram(id: "empty", name: "Empty", intervals: [])
        let invalidEngine = WorkoutEngine(program: empty, clock: { 0 })
        #expect(invalidEngine.snapshot().state == .interrupted)
        #expect(invalidEngine.snapshot().currentInterval.id == "invalid-empty-program")
    }

    @Test func manualOverrideLastsUntilIntervalBoundaryAndRejectedInclinationKeepsSpeed() {
        var engine = WorkoutEngine(program: program([15, 15]))
        prepareAndRun(&engine)
        let manual = engine.manualOverride(speedKPH: 6.5, inclinationPercent: 5, at: 1)
        #expect(
            manual.state == .running && manual.effectiveSpeedKPH == 6.5
                && manual.effectiveInclinationPercent == 5)
        _ = engine.tick(at: 1)
        engine.updateEffectiveTargets(
            speedKPH: 6.5, inclinationPercent: nil, inclinationAccepted: false, at: 2)
        let rejected = engine.snapshot(at: 2)
        #expect(rejected.effectiveSpeedKPH == 6.5)
        #expect(rejected.effectiveInclinationPercent == nil)
        _ = engine.tick(at: 2)
        for second in 3...15 { _ = engine.tick(at: TimeInterval(second)) }
        let next = engine.snapshot(at: 15)
        #expect(next.intervalIndex == 1 && next.state == .running)
        #expect(next.effectiveSpeedKPH == nil && next.effectiveInclinationPercent == nil)
    }

    @Test func deviationNeedsGraceAndThreeSamplesAcrossTwoSecondsAndStaleDataIsIgnored() {
        var engine = WorkoutEngine(program: program([60]))
        prepareAndRun(&engine)
        engine.updateEffectiveTargets(speedKPH: 6, inclinationPercent: 0, at: 0)
        for t in [10.0, 11, 12] { _ = engine.tick(at: t) }
        #expect(engine.snapshot(at: 12).deviation?.metric == .speed)
        engine.updateEffectiveTargets(speedKPH: 4, inclinationPercent: 0, at: 13)
        #expect(engine.snapshot(at: 13).deviation == nil)

        var measured = WorkoutEngine(program: program([60]))
        _ = measured.start(at: 0)
        measured.updateEffectiveTargets(speedKPH: 4, inclinationPercent: 0, at: 0)
        _ = measured.markRunning(at: 0)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, monotonic) in [(0.0, 10.0), (1, 11), (2, 12)] {
            measured.updateMeasuredSpeed(
                WorkoutSample(
                    value: 8, source: .machineFTMS,
                    receivedAt: base.addingTimeInterval(offset), monotonicTime: monotonic), at: monotonic)
        }
        #expect(measured.snapshot(at: 12).deviation?.metric == .speed)

        var stale = WorkoutEngine(program: program([60]))
        _ = stale.start(at: 0)
        stale.updateEffectiveTargets(speedKPH: 4, inclinationPercent: 0, at: 0)
        _ = stale.markRunning(at: 0)
        stale.updateMeasuredSpeed(
            WorkoutSample(
                value: 8, source: .machineFTMS,
                receivedAt: base, monotonicTime: 1), at: 10)
        #expect(stale.snapshot(at: 10).deviation == nil)
        #expect(stale.snapshot(at: 10).measuredSpeed == nil)
    }

    @Test func suspensionAndLongTickGapNeverCatchUpAcrossIntervals() {
        var engine = WorkoutEngine(program: program([15, 15]))
        prepareAndRun(&engine)
        let delayed = engine.tick(at: 20)
        #expect(delayed.state == .manual)
        #expect(delayed.intervalIndex == 0 && delayed.phaseElapsedSeconds == 0)
        let resumed = engine.resumeFromManual(reprepared: true, at: 21)
        #expect(resumed.state == .running)
        let suspended = engine.suspendToManual(reason: "uncertain target", at: 22)
        #expect(suspended.state == .manual)
        #expect(engine.tick(at: 80).phaseElapsedSeconds == 1)
    }

    @Test func ordinaryTickGapAtMidIntervalAdvancesWithoutSuspending() {
        var engine = WorkoutEngine(program: program())
        prepareAndRun(&engine)
        let snapshot = engine.tick(at: 5)
        #expect(snapshot.state == .running)
        #expect(snapshot.intervalIndex == 0 && snapshot.phaseElapsedSeconds == 5)
    }

    @Test func freeWorkoutElapsedTimeIsUncappedAndOnlyExplicitFinishEndsIt() {
        var engine = WorkoutEngine(program: program([3_600]), clock: { 0 }, isFreeWorkout: true)
        prepareAndRun(&engine)
        let snapshot = engine.tick(at: 7_205)
        #expect(snapshot.state == .running)
        #expect(snapshot.intervalIndex == 0)
        #expect(snapshot.phaseElapsedSeconds == 7_205)
        #expect(engine.finish(at: 7_206).state == .completed)
    }

    @Test func skippedIntervalsDoNotInflateActiveTimeAndNaturalFinishKeepsFinalPhaseProgress() {
        var skipped = WorkoutEngine(program: program([15, 15]), clock: { 0 })
        prepareAndRun(&skipped)
        _ = skipped.tick(at: 5)
        _ = skipped.skipInterval(at: 5)
        #expect(skipped.snapshot(at: 5).activeElapsedSeconds == 5)
        _ = skipped.tick(at: 10)
        let explicitlyFinished = skipped.finish(at: 12)
        #expect(explicitlyFinished.state == .completed)
        #expect(explicitlyFinished.activeElapsedSeconds == 12)

        var completed = WorkoutEngine(program: program([15, 15]), clock: { 0 })
        prepareAndRun(&completed)
        _ = completed.tick(at: 15)
        let final = completed.tick(at: 30)
        #expect(final.state == .completed)
        #expect(final.intervalIndex == 1)
        #expect(final.phaseElapsedSeconds == 15)
        #expect(final.activeElapsedSeconds == 30)
    }

    @Test func skipFinishAndDisconnectHaveExplicitTerminalStates() {
        var engine = WorkoutEngine(program: program([15, 15]))
        prepareAndRun(&engine)
        #expect(engine.skipInterval(at: 1).intervalIndex == 1)
        #expect(engine.skipInterval(at: 2).state == .completed)
        var interrupted = WorkoutEngine(program: program())
        _ = interrupted.start(at: 0)
        #expect(interrupted.interrupt(at: 1).state == .interrupted)
        #expect(interrupted.finish(at: 2).state == .interrupted)
    }
}
