import Foundation

public enum WorkoutPhase: String, Codable, CaseIterable, Sendable {
    case warmup, work, recovery, cooldown, steady
}

public enum WorkoutState: String, Codable, CaseIterable, Sendable {
    case preparing, starting, running, pausing, paused, manual, finishing, completed, interrupted
}

/// Provenance of a value. Its role (planned/effective/measured) is carried by
/// the containing snapshot field, so provenance is never mistaken for a role.
public enum MetricSource: String, Codable, CaseIterable, Sendable {
    case machineFTMS, watchHealthKit, mock, derived, unknown
}

public struct WorkoutSample: Codable, Equatable, Sendable {
    public let value: Double
    public let source: MetricSource
    public let receivedAt: Date
    public let monotonicTime: TimeInterval?
    public let eventId: String?
    public let sampledAt: Date?
    public let sourceDevice: String?
    public let sourceIdentifier: String?
    public let aggregation: String?
    public let periodStart: Date?

    public init(
        value: Double, source: MetricSource, receivedAt: Date, monotonicTime: TimeInterval? = nil,
        eventId: String? = nil,
        sampledAt: Date? = nil, sourceDevice: String? = nil, sourceIdentifier: String? = nil,
        aggregation: String? = nil, periodStart: Date? = nil
    ) {
        self.value = value
        self.source = source
        self.receivedAt = receivedAt
        self.monotonicTime = monotonicTime
        self.eventId = eventId
        self.sampledAt = sampledAt
        self.sourceDevice = sourceDevice
        self.sourceIdentifier = sourceIdentifier
        self.aggregation = aggregation
        self.periodStart = periodStart
    }
}

public struct WorkoutInterval: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var durationSeconds: Int
    public var targetSpeedKPH: Double
    public var targetInclinationPercent: Double
    public var phase: WorkoutPhase

    public init(
        id: String = UUID().uuidString.lowercased(), durationSeconds: Int,
        targetSpeedKPH: Double, targetInclinationPercent: Double = 0,
        phase: WorkoutPhase = .work
    ) {
        self.id = id
        self.durationSeconds = durationSeconds
        self.targetSpeedKPH = targetSpeedKPH
        self.targetInclinationPercent = targetInclinationPercent
        self.phase = phase
    }
}

public struct WorkoutTargetLimits: Codable, Equatable, Sendable {
    public let speed: FTMSRange
    public let inclination: FTMSRange
    public let source: Source

    public enum Source: String, Codable, Sendable { case announced, cachedDefault }

    public init(speed: FTMSRange, inclination: FTMSRange, source: Source) {
        self.speed = speed
        self.inclination = inclination
        self.source = source
    }

    /// Product defaults used only to seed and edit a program until a machine
    /// advertises its own ranges. These are not evidence about connected hardware.
    public static let cachedDefault = WorkoutTargetLimits(
        speed: FTMSRange(minimum: 0.8, maximum: 16, increment: 0.1, unit: "km/h"),
        inclination: FTMSRange(minimum: 0, maximum: 15, increment: 1, unit: "%"),
        source: .cachedDefault
    )
}

public enum WorkoutProgramValidationError: LocalizedError, Equatable, Sendable {
    case invalidName
    case noIntervals
    case invalidDuration(index: Int)
    case invalidSpeed(index: Int)
    case invalidInclination(index: Int)
    case invalidLimits

    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .invalidName: FitnessText.string("error.program.invalidName", locale: locale)
        case .noIntervals: FitnessText.string("error.program.noIntervals", locale: locale)
        case .invalidDuration(let index):
            FitnessText.format("error.program.invalidDuration", locale: locale, index + 1)
        case .invalidSpeed(let index):
            FitnessText.format("error.program.invalidSpeed", locale: locale, index + 1)
        case .invalidInclination(let index):
            FitnessText.format("error.program.invalidInclination", locale: locale, index + 1)
        case .invalidLimits: FitnessText.string("error.program.invalidLimits", locale: locale)
        }
    }
}

public struct WorkoutProgram: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var intervals: [WorkoutInterval]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(), name: String,
        intervals: [WorkoutInterval], createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.intervals = intervals
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public static func validate(
        name: String, intervals: [WorkoutInterval],
        limits: WorkoutTargetLimits = .cachedDefault
    ) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(normalized.count) else {
            throw WorkoutProgramValidationError.invalidName
        }
        guard !intervals.isEmpty else { throw WorkoutProgramValidationError.noIntervals }
        guard valid(limits.speed), limits.speed.unit == "km/h", valid(limits.inclination),
            limits.inclination.unit == "%"
        else {
            throw WorkoutProgramValidationError.invalidLimits
        }
        for (index, interval) in intervals.enumerated() {
            guard (15...3600).contains(interval.durationSeconds) else {
                throw WorkoutProgramValidationError.invalidDuration(index: index)
            }
            guard target(interval.targetSpeedKPH, range: limits.speed) else {
                throw WorkoutProgramValidationError.invalidSpeed(index: index)
            }
            guard target(interval.targetInclinationPercent, range: limits.inclination) else {
                throw WorkoutProgramValidationError.invalidInclination(index: index)
            }
        }
    }

    private static func valid(_ range: FTMSRange) -> Bool {
        range.minimum.isFinite && range.maximum.isFinite && range.increment.isFinite
            && range.minimum <= range.maximum && range.increment > 0
    }

    private static func target(_ value: Double, range: FTMSRange) -> Bool {
        guard value.isFinite, value >= range.minimum, value <= range.maximum else { return false }
        let steps = (value - range.minimum) / range.increment
        return abs(steps - steps.rounded()) < 0.000_01
    }

    /// Two seed plans from prototype/app.js, expressed as product data only.
    public static let seedPrograms: [WorkoutProgram] = [
        WorkoutProgram(
            id: "essential", name: "Intervalos esenciales",
            intervals: [
                .init(id: "essential-warmup", durationSeconds: 120, targetSpeedKPH: 5, phase: .warmup),
                .init(id: "essential-work-1", durationSeconds: 90, targetSpeedKPH: 9),
                .init(
                    id: "essential-recovery-1", durationSeconds: 150, targetSpeedKPH: 5, phase: .recovery),
                .init(id: "essential-work-2", durationSeconds: 90, targetSpeedKPH: 10),
                .init(
                    id: "essential-recovery-2", durationSeconds: 150, targetSpeedKPH: 5, phase: .recovery),
                .init(id: "essential-work-3", durationSeconds: 90, targetSpeedKPH: 10),
                .init(
                    id: "essential-recovery-3", durationSeconds: 150, targetSpeedKPH: 5, phase: .recovery),
                .init(id: "essential-work-4", durationSeconds: 90, targetSpeedKPH: 10),
                .init(id: "essential-cooldown", durationSeconds: 150, targetSpeedKPH: 4, phase: .cooldown),
            ], createdAt: Date(timeIntervalSince1970: 0)),
        WorkoutProgram(
            id: "steady", name: "A tu ritmo",
            intervals: [
                .init(id: "steady-warmup", durationSeconds: 180, targetSpeedKPH: 4, phase: .warmup),
                .init(
                    id: "steady-main", durationSeconds: 1200, targetSpeedKPH: 5.5,
                    targetInclinationPercent: 1, phase: .steady),
                .init(id: "steady-cooldown", durationSeconds: 120, targetSpeedKPH: 4, phase: .cooldown),
            ], createdAt: Date(timeIntervalSince1970: 0)),
    ]
}
