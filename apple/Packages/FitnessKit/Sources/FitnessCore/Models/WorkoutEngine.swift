import Foundation

public enum WorkoutDeviationMetric: String, Codable, Sendable { case speed, inclination }
public enum WorkoutDeviationBasis: String, Codable, Sendable {
    case acceptedVersusPlan, measuredVersusAccepted
}

public struct WorkoutDeviation: Codable, Equatable, Sendable {
    public let metric: WorkoutDeviationMetric
    public let expected: Double
    public let observed: Double
    public let detectedAt: Date
    public let sampleCount: Int
    public let basis: WorkoutDeviationBasis

    public init(
        metric: WorkoutDeviationMetric, expected: Double, observed: Double,
        detectedAt: Date, sampleCount: Int, basis: WorkoutDeviationBasis = .acceptedVersusPlan
    ) {
        self.metric = metric
        self.expected = expected
        self.observed = observed
        self.detectedAt = detectedAt
        self.sampleCount = sampleCount
        self.basis = basis
    }

    private enum CodingKeys: String, CodingKey {
        case metric, expected, observed, detectedAt, sampleCount, basis
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metric = try values.decode(WorkoutDeviationMetric.self, forKey: .metric)
        expected = try values.decode(Double.self, forKey: .expected)
        observed = try values.decode(Double.self, forKey: .observed)
        detectedAt = try values.decode(Date.self, forKey: .detectedAt)
        sampleCount = try values.decode(Int.self, forKey: .sampleCount)
        basis =
            try values.decodeIfPresent(WorkoutDeviationBasis.self, forKey: .basis) ?? .acceptedVersusPlan
    }
}

public struct WorkoutSnapshot: Codable, Equatable, Sendable {
    public let state: WorkoutState
    public let phase: WorkoutPhase
    public let intervalIndex: Int
    public let phaseElapsedSeconds: TimeInterval
    public let program: WorkoutProgram
    public let effectiveSpeedKPH: Double?
    public let effectiveInclinationPercent: Double?
    public let measuredSpeed: WorkoutSample?
    public let measuredInclination: WorkoutSample?
    public let deviation: WorkoutDeviation?
    public let activeElapsedSeconds: TimeInterval?
    public let pausedElapsedSeconds: TimeInterval?

    public var currentInterval: WorkoutInterval {
        guard program.intervals.indices.contains(intervalIndex) else {
            return WorkoutInterval(id: "invalid-empty-program", durationSeconds: 15, targetSpeedKPH: 0.8)
        }
        return program.intervals[intervalIndex]
    }

    public init(
        state: WorkoutState, phase: WorkoutPhase, intervalIndex: Int,
        phaseElapsedSeconds: TimeInterval, program: WorkoutProgram,
        effectiveSpeedKPH: Double?, effectiveInclinationPercent: Double?,
        measuredSpeed: WorkoutSample?, measuredInclination: WorkoutSample?,
        deviation: WorkoutDeviation?, activeElapsedSeconds: TimeInterval? = nil,
        pausedElapsedSeconds: TimeInterval? = nil
    ) {
        self.state = state
        self.phase = phase
        self.intervalIndex = intervalIndex
        self.phaseElapsedSeconds = phaseElapsedSeconds
        self.program = program
        self.effectiveSpeedKPH = effectiveSpeedKPH
        self.effectiveInclinationPercent = effectiveInclinationPercent
        self.measuredSpeed = measuredSpeed
        self.measuredInclination = measuredInclination
        self.deviation = deviation
        self.activeElapsedSeconds = activeElapsedSeconds
        self.pausedElapsedSeconds = pausedElapsedSeconds
    }
}

/// A deterministic workout state machine. `clock` must supply monotonic seconds;
/// tests can inject a virtual clock and production can use systemUptime.
public struct WorkoutEngine {
    public private(set) var program: WorkoutProgram
    public private(set) var state: WorkoutState = .preparing
    public private(set) var intervalIndex = 0
    public private(set) var phaseElapsedSeconds: TimeInterval = 0
    public private(set) var measuredSpeed: WorkoutSample?
    public private(set) var measuredInclination: WorkoutSample?
    public private(set) var deviation: WorkoutDeviation?
    public private(set) var inclinationUnavailable = false
    public let isFreeWorkout: Bool

    private let clock: () -> TimeInterval
    private let speedTolerance: Double
    private let inclinationTolerance: Double
    private var lastTick: TimeInterval?
    private var overrideSpeed: Double?
    private var overrideInclination: Double?
    private var phaseBeganAt: TimeInterval?
    private var activeElapsed: TimeInterval = 0
    private var pausedElapsed: TimeInterval = 0
    private var pauseBeganAt: TimeInterval?
    private var effectiveSpeedSetAt: TimeInterval?
    private var effectiveInclinationSetAt: TimeInterval?
    private var speedMismatchSamples: [TimeInterval] = []
    private var inclinationMismatchSamples: [TimeInterval] = []
    private var measuredSpeedSamples: [TimeInterval] = []
    private var measuredInclinationSamples: [TimeInterval] = []
    private var measuredSpeedEventIDs: Set<String> = []
    private var measuredInclinationEventIDs: Set<String> = []
    private var effectiveSpeedOverride: Double?
    private var effectiveInclinationOverride: Double?

    public init(
        program: WorkoutProgram,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        speedStep: Double = 0.1, inclinationStep: Double = 1, isFreeWorkout: Bool = false
    ) {
        self.program = program
        self.clock = clock
        self.isFreeWorkout = isFreeWorkout
        self.speedTolerance = max(0.1, speedStep.isFinite ? speedStep : 0.1)
        self.inclinationTolerance = max(1, inclinationStep.isFinite ? inclinationStep : 1)
        if program.intervals.isEmpty { self.state = .interrupted }
    }

    public var currentInterval: WorkoutInterval {
        guard program.intervals.indices.contains(intervalIndex) else {
            return WorkoutInterval(id: "invalid-empty-program", durationSeconds: 15, targetSpeedKPH: 0.8)
        }
        return program.intervals[intervalIndex]
    }
    public var effectiveSpeedKPH: Double? { effectiveSpeedOverride ?? overrideSpeed }
    public var effectiveInclinationPercent: Double? {
        if inclinationUnavailable { return nil }
        return effectiveInclinationOverride ?? overrideInclination
    }

    @discardableResult
    public mutating func start(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        guard state == .preparing else { return snapshot(at: suppliedTime) }
        let now = resolve(suppliedTime)
        state = .starting
        lastTick = now
        phaseBeganAt = now
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func markRunning(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .starting else { return snapshot(at: now) }
        guard effectiveSpeedKPH != nil else { return snapshot(at: now) }
        state = .running
        lastTick = now
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func pause(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .running else { return snapshot(at: now) }
        advanceClock(to: now)
        state = .paused
        clearDeviationWindow()
        pauseBeganAt = now
        lastTick = nil
        return snapshot(at: now)
    }

    /// Begins a logical pause while a runtime action is still being confirmed.
    /// This changes only workout scheduling; it does not stop the treadmill.
    @discardableResult
    public mutating func beginPausing(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .running else { return snapshot(at: now) }
        advanceClock(to: now)
        state = .pausing
        clearDeviationWindow()
        pauseBeganAt = now
        lastTick = nil
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func confirmPaused(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .pausing else { return snapshot(at: now) }
        state = .paused
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func resume(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .paused else { return snapshot(at: now) }
        accumulatePause(until: now)
        state = .running
        clearDeviationWindow()
        if effectiveSpeedOverride != nil { effectiveSpeedSetAt = now }
        if effectiveInclinationOverride != nil { effectiveInclinationSetAt = now }
        lastTick = now
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func resumeFromManual(reprepared: Bool, at suppliedTime: TimeInterval? = nil)
        -> WorkoutSnapshot
    {
        let now = resolve(suppliedTime)
        guard state == .manual, reprepared else { return snapshot(at: now) }
        state = .running
        lastTick = now
        return snapshot(at: now)
    }

    /// Suspends automation without issuing a machine command. The operator
    /// explicitly resumes or finishes after an uncertain target/result.
    @discardableResult
    public mutating func suspendToManual(reason: String? = nil, at suppliedTime: TimeInterval? = nil)
        -> WorkoutSnapshot
    {
        let now = resolve(suppliedTime)
        guard
            state == .running || state == .starting || state == .paused || state == .pausing
                || state == .finishing
        else { return snapshot(at: now) }
        if state == .running { advanceClock(to: now) }
        if state == .paused || state == .pausing { accumulatePause(until: now) }
        state = .manual
        lastTick = nil
        _ = reason  // Runtime retains the evidence detail; core carries the state.
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func skipInterval(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .running || state == .manual || state == .paused else {
            return snapshot(at: now)
        }
        if state == .running { advanceClock(to: now) }
        advanceInterval(at: now)
        if state == .completed { return snapshot(at: now) }
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func finish(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state != .completed && state != .interrupted else { return snapshot(at: now) }
        if state == .running { advanceClock(to: now) }
        if state == .paused || state == .pausing { accumulatePause(until: now) }
        state = .finishing
        clearDeviationWindow()
        overrideSpeed = nil
        overrideInclination = nil
        effectiveSpeedOverride = nil
        effectiveInclinationOverride = nil
        state = .completed
        lastTick = nil
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func beginFinishing(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state != .interrupted else { return snapshot(at: now) }
        if state == .running { advanceClock(to: now) }
        if state == .paused || state == .pausing { accumulatePause(until: now) }
        state = .finishing
        clearDeviationWindow()
        lastTick = nil
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func complete(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .finishing else { return snapshot(at: now) }
        state = .completed
        overrideSpeed = nil
        overrideInclination = nil
        effectiveSpeedOverride = nil
        effectiveInclinationOverride = nil
        lastTick = nil
        return snapshot(at: now)
    }

    @discardableResult
    public mutating func interrupt(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state != .completed && state != .interrupted else { return snapshot(at: now) }
        if state == .running { advanceClock(to: now) }
        if state == .paused || state == .pausing { accumulatePause(until: now) }
        state = .interrupted
        lastTick = nil
        return snapshot(at: now)
    }

    /// Manual changes remain active through the current interval, then the next
    /// planned interval restores its own targets.
    @discardableResult
    public mutating func manualOverride(
        speedKPH: Double? = nil, inclinationPercent: Double? = nil,
        at suppliedTime: TimeInterval? = nil
    ) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .running || state == .manual else { return snapshot(at: now) }
        if let speedKPH, speedKPH.isFinite {
            overrideSpeed = speedKPH
            effectiveSpeedOverride = speedKPH
            effectiveSpeedSetAt = now
        }
        if let inclinationPercent, inclinationPercent.isFinite {
            overrideInclination = inclinationPercent
            effectiveInclinationOverride = inclinationPercent
            inclinationUnavailable = false
            effectiveInclinationSetAt = now
        }
        guard speedKPH != nil || inclinationPercent != nil else { return snapshot(at: now) }
        return snapshot(at: now)
    }

    /// Supplies what the runtime believes the machine's active target to be.
    /// A rejected inclination is represented as unavailable while speed keeps running.
    public mutating func updateEffectiveTargets(
        speedKPH: Double?, inclinationPercent: Double?,
        inclinationAccepted: Bool = true,
        at suppliedTime: TimeInterval? = nil
    ) {
        let now = resolve(suppliedTime)
        effectiveSpeedOverride = speedKPH
        effectiveInclinationOverride = inclinationAccepted ? inclinationPercent : nil
        inclinationUnavailable = !inclinationAccepted
        effectiveSpeedSetAt = speedKPH == nil ? nil : now
        effectiveInclinationSetAt = inclinationAccepted && inclinationPercent != nil ? now : nil
        evaluatePlanDeviation(now: now)
    }

    public mutating func updateMeasuredSpeed(
        _ sample: WorkoutSample, at suppliedTime: TimeInterval? = nil
    ) {
        if let id = sample.eventId {
            guard !measuredSpeedEventIDs.contains(id) else { return }
            measuredSpeedEventIDs.insert(id)
            if measuredSpeedEventIDs.count > 256 { measuredSpeedEventIDs = [id] }
        }
        let now = resolve(suppliedTime)
        measuredSpeed = sample
        guard state == .running else { return }
        evaluateMeasured(
            sample, metric: .speed, tolerance: speedTolerance, grace: 10, setAt: effectiveSpeedSetAt,
            now: now)
    }

    public mutating func updateMeasuredInclination(
        _ sample: WorkoutSample, at suppliedTime: TimeInterval? = nil
    ) {
        if let id = sample.eventId {
            guard !measuredInclinationEventIDs.contains(id) else { return }
            measuredInclinationEventIDs.insert(id)
            if measuredInclinationEventIDs.count > 256 { measuredInclinationEventIDs = [id] }
        }
        let now = resolve(suppliedTime)
        measuredInclination = sample
        guard state == .running else { return }
        evaluateMeasured(
            sample, metric: .inclination, tolerance: inclinationTolerance, grace: 30,
            setAt: effectiveInclinationSetAt, now: now)
    }

    @discardableResult
    public mutating func tick(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = resolve(suppliedTime)
        guard state == .running else { return snapshot(at: now) }
        guard !program.intervals.isEmpty else {
            state = .interrupted
            return snapshot(at: now)
        }
        if isFreeWorkout {
            advanceClock(to: now)
            evaluatePlanDeviation(now: now)
            return snapshot(at: now)
        }
        if let lastTick {
            let delta = max(0, now - lastTick)
            let remaining = max(0, Double(currentInterval.durationSeconds) - phaseElapsedSeconds)
            if delta > remaining + 2 {
                activeElapsed += delta
                state = .manual
                self.lastTick = nil
                return snapshot(at: now)
            }
        }
        advanceClock(to: now)
        evaluatePlanDeviation(now: now)
        while phaseElapsedSeconds >= Double(currentInterval.durationSeconds)
            && (state == .running || state == .manual)
        {
            phaseElapsedSeconds -= Double(currentInterval.durationSeconds)
            advanceInterval(at: now, preserveElapsed: true, completedByElapsed: true)
        }
        return snapshot(at: now)
    }

    public func snapshot(at suppliedTime: TimeInterval? = nil) -> WorkoutSnapshot {
        let now = suppliedTime ?? clock()
        let elapsed =
            (state == .running || state == .manual)
            ? phaseElapsedSeconds + max(0, now - (lastTick ?? now)) : phaseElapsedSeconds
        let activeAtSnapshot = activeElapsed + (state == .running ? max(0, now - (lastTick ?? now)) : 0)
        let pausedAtSnapshot =
            pausedElapsed
            + ((state == .paused || state == .pausing) ? max(0, now - (pauseBeganAt ?? now)) : 0)
        return WorkoutSnapshot(
            state: state, phase: currentInterval.phase, intervalIndex: intervalIndex,
            phaseElapsedSeconds: isFreeWorkout
                ? elapsed : min(Double(currentInterval.durationSeconds), elapsed), program: program,
            effectiveSpeedKPH: effectiveSpeedKPH,
            effectiveInclinationPercent: effectiveInclinationPercent,
            measuredSpeed: fresh(measuredSpeed, now: now),
            measuredInclination: fresh(measuredInclination, now: now),
            deviation: deviation, activeElapsedSeconds: activeAtSnapshot,
            pausedElapsedSeconds: pausedAtSnapshot)
    }

    private func resolve(_ suppliedTime: TimeInterval?) -> TimeInterval { suppliedTime ?? clock() }

    private mutating func advanceClock(to now: TimeInterval) {
        guard let lastTick else {
            self.lastTick = now
            return
        }
        let delta = max(0, now - lastTick)
        phaseElapsedSeconds += delta
        activeElapsed += delta
        self.lastTick = now
    }

    private mutating func accumulatePause(until now: TimeInterval) {
        if let pauseBeganAt { pausedElapsed += max(0, now - pauseBeganAt) }
        pauseBeganAt = nil
    }

    private mutating func advanceInterval(
        at now: TimeInterval, preserveElapsed: Bool = false,
        completedByElapsed: Bool = false
    ) {
        clearDeviationWindow()
        if intervalIndex + 1 >= program.intervals.count {
            if completedByElapsed { phaseElapsedSeconds = Double(currentInterval.durationSeconds) }
            state = .completed
            lastTick = nil
            overrideSpeed = nil
            overrideInclination = nil
            effectiveSpeedOverride = nil
            effectiveInclinationOverride = nil
            inclinationUnavailable = false
            effectiveSpeedSetAt = nil
            effectiveInclinationSetAt = nil
            return
        }
        intervalIndex += 1
        if !preserveElapsed { phaseElapsedSeconds = 0 }
        phaseBeganAt = now
        effectiveSpeedSetAt = nil
        effectiveInclinationSetAt = nil
        lastTick = now
        overrideSpeed = nil
        overrideInclination = nil
        effectiveSpeedOverride = nil
        effectiveInclinationOverride = nil
        inclinationUnavailable = false
        if state == .manual { state = .running }
    }

    private mutating func clearDeviationWindow() {
        deviation = nil
        speedMismatchSamples = []
        inclinationMismatchSamples = []
        measuredSpeedSamples = []
        measuredInclinationSamples = []
    }

    private mutating func evaluatePlanDeviation(now: TimeInterval) {
        guard state == .running else { return }
        if let effectiveSpeedKPH {
            let elapsedInPhase = max(0, now - (effectiveSpeedSetAt ?? phaseBeganAt ?? now))
            let result = Self.evaluateDifference(
                planned: currentInterval.targetSpeedKPH, effective: effectiveSpeedKPH,
                metric: .speed, tolerance: speedTolerance, grace: 10, now: now,
                elapsedInPhase: elapsedInPhase,
                samples: speedMismatchSamples)
            speedMismatchSamples = result.samples
            if let deviation = result.deviation, self.deviation?.basis != .measuredVersusAccepted {
                self.deviation = deviation
            } else if result.samples.isEmpty {
                clearDeviation(.speed, basis: .acceptedVersusPlan)
            }
        } else {
            speedMismatchSamples = []
            clearDeviation(.speed, basis: .acceptedVersusPlan)
        }
        if let effective = effectiveInclinationPercent {
            let elapsedInPhase = max(0, now - (effectiveInclinationSetAt ?? phaseBeganAt ?? now))
            let plannedIncline = currentInterval.targetInclinationPercent
            let result = Self.evaluateDifference(
                planned: plannedIncline, effective: effective, metric: .inclination,
                tolerance: inclinationTolerance, grace: 10, now: now, elapsedInPhase: elapsedInPhase,
                samples: inclinationMismatchSamples)
            inclinationMismatchSamples = result.samples
            if let deviation = result.deviation, self.deviation?.basis != .measuredVersusAccepted {
                self.deviation = deviation
            } else if result.samples.isEmpty {
                clearDeviation(.inclination, basis: .acceptedVersusPlan)
            }
        } else {
            inclinationMismatchSamples = []
            clearDeviation(.inclination, basis: .acceptedVersusPlan)
        }
    }

    private static func evaluateDifference(
        planned: Double, effective: Double, metric: WorkoutDeviationMetric,
        tolerance: Double, grace: TimeInterval, now: TimeInterval,
        elapsedInPhase: TimeInterval, samples existing: [TimeInterval]
    )
        -> (samples: [TimeInterval], deviation: WorkoutDeviation?)
    {
        guard abs(planned - effective) > tolerance else { return ([], nil) }
        let samples = (existing + [now]).filter { now - $0 <= 5 }
        guard elapsedInPhase >= grace, samples.count >= 3, let first = samples.first, now - first >= 2
        else {
            return (samples, nil)
        }
        return (
            samples,
            WorkoutDeviation(
                metric: metric, expected: planned, observed: effective,
                detectedAt: Date(), sampleCount: samples.count, basis: .acceptedVersusPlan)
        )
    }

    private mutating func evaluateMeasured(
        _ sample: WorkoutSample, metric: WorkoutDeviationMetric,
        tolerance: Double, grace: TimeInterval, setAt: TimeInterval?, now: TimeInterval
    ) {
        // Stale, future, or duplicate evidence is retained as the latest sample,
        // but cannot establish a deviation.
        let age = sample.monotonicTime.map { now - $0 } ?? Date().timeIntervalSince(sample.receivedAt)
        guard sample.value.isFinite, age >= 0, age <= 5 else { return }
        let expected = metric == .speed ? effectiveSpeedKPH : effectiveInclinationPercent
        guard let expected, abs(sample.value - expected) > tolerance else {
            if metric == .speed { measuredSpeedSamples = [] } else { measuredInclinationSamples = [] }
            clearDeviation(metric, basis: .measuredVersusAccepted)
            return
        }
        let sinceTarget = max(0, now - (setAt ?? phaseBeganAt ?? now))
        guard sinceTarget >= grace else { return }
        var times = metric == .speed ? measuredSpeedSamples : measuredInclinationSamples
        let received = sample.monotonicTime ?? sample.receivedAt.timeIntervalSince1970
        times.append(received)
        times = times.filter { received - $0 <= 5 }
        if metric == .speed { measuredSpeedSamples = times } else { measuredInclinationSamples = times }
        guard times.count >= 3, let first = times.first, received - first >= 2 else { return }
        deviation = WorkoutDeviation(
            metric: metric, expected: expected, observed: sample.value,
            detectedAt: sample.receivedAt, sampleCount: times.count, basis: .measuredVersusAccepted)
    }

    private mutating func clearDeviation(
        _ metric: WorkoutDeviationMetric, basis: WorkoutDeviationBasis
    ) {
        if deviation?.metric == metric && deviation?.basis == basis { deviation = nil }
    }

    private func fresh(_ sample: WorkoutSample?, now: TimeInterval) -> WorkoutSample? {
        guard let sample else { return nil }
        let age = sample.monotonicTime.map { now - $0 } ?? Date().timeIntervalSince(sample.receivedAt)
        guard age >= 0, age <= 5 else { return nil }
        return sample
    }
}
