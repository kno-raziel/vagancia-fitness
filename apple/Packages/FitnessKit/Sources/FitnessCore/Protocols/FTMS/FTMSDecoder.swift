import Foundation

public struct FTMSCapability: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let declaration: String
    public let verification: String

    /// Display by stable capability ID; `label` remains original captured data.
    public func localizedLabel(locale: Locale? = nil) -> String {
        let key = "ftms.capability.\(id)"
        let value = FitnessText.string(key, locale: locale)
        return value == key ? label : value
    }

    public init(
        id: String,
        label: String,
        declaration: String,
        verification: String
    ) {
        self.id = id
        self.label = label
        self.declaration = declaration
        self.verification = verification
    }
}

public struct FTMSFeatures: Codable, Equatable, Sendable {
    public let machineBits: UInt32
    public let targetBits: UInt32

    public var capabilities: [FTMSCapability] {
        let machine: [(String, String)] = [
            ("averageSpeed", "Velocidad media"), ("cadence", "Cadencia"),
            ("totalDistance", "Distancia total"), ("inclination", "Inclinación"),
            ("elevationGain", "Desnivel"), ("pace", "Ritmo"), ("stepCount", "Pasos"),
            ("resistance", "Resistencia"), ("strideCount", "Zancadas"), ("energy", "Energía"),
            ("heartRate", "Frecuencia cardíaca"), ("metabolicEquivalent", "Equivalente metabólico"),
            ("elapsedTime", "Tiempo transcurrido"), ("remainingTime", "Tiempo restante"),
            ("power", "Potencia"), ("beltForceAndPower", "Fuerza y potencia de banda"),
            ("userDataRetention", "Retención de datos"),
        ]
        let target: [(String, String)] = [
            ("speedTarget", "Control de velocidad"), ("inclinationTarget", "Control de inclinación"),
            ("resistanceTarget", "Control de resistencia"), ("powerTarget", "Objetivo de potencia"),
            ("heartRateTarget", "Objetivo cardíaco"), ("energyTarget", "Objetivo de energía"),
            ("stepsTarget", "Objetivo de pasos"), ("stridesTarget", "Objetivo de zancadas"),
            ("distanceTarget", "Objetivo de distancia"), ("timeTarget", "Objetivo de tiempo"),
            ("twoHRZones", "Tiempo en dos zonas"), ("threeHRZones", "Tiempo en tres zonas"),
            ("fiveHRZones", "Tiempo en cinco zonas"), ("bikeSimulation", "Simulación de bicicleta"),
            ("wheelCircumference", "Circunferencia de rueda"), ("spinDown", "Spin down"),
            ("cadenceTarget", "Objetivo de cadencia"),
        ]
        return [(machine, machineBits), (target, targetBits)].flatMap { items, bits in
            items.enumerated().map { index, item in
                FTMSCapability(
                    id: item.0, label: item.1,
                    declaration: bits & (1 << index) != 0 ? "advertised" : "notAdvertised",
                    verification: "notRun")
            }
        }
    }

    public init(
        machineBits: UInt32,
        targetBits: UInt32
    ) {
        self.machineBits = machineBits
        self.targetBits = targetBits
    }
}

public struct FTMSRange: Codable, Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let increment: Double
    public let unit: String

    public init(
        minimum: Double,
        maximum: Double,
        increment: Double,
        unit: String
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.increment = increment
        self.unit = unit
    }
}

public struct TreadmillSample: Codable, Equatable, Sendable {
    public let flags: UInt16
    public let moreData: Bool
    public let speedKilometersPerHour: Double?
    public let distanceMeters: UInt32?
    public let inclinationPercent: Double?
    public let rampAngleDegrees: Double?

    public init(
        flags: UInt16,
        moreData: Bool,
        speedKilometersPerHour: Double?,
        distanceMeters: UInt32?,
        inclinationPercent: Double? = nil,
        rampAngleDegrees: Double? = nil
    ) {
        self.flags = flags
        self.moreData = moreData
        self.speedKilometersPerHour = speedKilometersPerHour
        self.distanceMeters = distanceMeters
        self.inclinationPercent = inclinationPercent
        self.rampAngleDegrees = rampAngleDegrees
    }
}

public enum FTMSDecodeError: LocalizedError, Equatable {
    case length(expected: Int, actual: Int)
    case truncated(offset: Int, required: Int, actual: Int)
    case reservedFlags(UInt16)
    case invalidRange
    case unsupportedCharacteristic

    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .length(let expected, let actual):
            FitnessText.format("error.ftms.length", locale: locale, expected, actual)
        case .truncated(let offset, let required, let actual):
            FitnessText.format("error.ftms.truncated", locale: locale, offset, required, actual)
        case .reservedFlags(let flags):
            FitnessText.format("error.ftms.reservedFlags", locale: locale, String(flags, radix: 16))
        case .invalidRange: FitnessText.string("error.ftms.invalidRange", locale: locale)
        case .unsupportedCharacteristic:
            FitnessText.string("error.ftms.unsupportedCharacteristic", locale: locale)
        }
    }
}

// FTMS 1.0 §§4.3–4.4; GATT Specification Supplement 2026-09-09
// §§3.227–3.232 and 3.258. Little-endian; no aligned memory loads.
public enum FTMSDecoder {
    public static let identifier = "ftms-1.0-v1"
    public static let readableUUIDs: Set<String> = ["2ACC", "2AD4", "2AD5", "2AD7", "2AD8"]

    public static func features(_ data: Data) throws -> FTMSFeatures {
        try requireLength(data, 8)
        var reader = Reader(data)
        return FTMSFeatures(machineBits: try reader.unsigned(4), targetBits: try reader.unsigned(4))
    }

    public static func range(_ data: Data, uuid: String) throws -> FTMSRange {
        let size = uuid == "2AD7" ? 3 : 6
        guard readableUUIDs.contains(uuid), uuid != "2ACC" else {
            throw FTMSDecodeError.unsupportedCharacteristic
        }
        try requireLength(data, size)
        var reader = Reader(data)
        let minimum: Double
        let maximum: Double
        let increment: Double
        let unit: String
        switch uuid {
        case "2AD4":
            minimum = Double(try reader.unsigned(2)) / 100
            maximum = Double(try reader.unsigned(2)) / 100
            increment = Double(try reader.unsigned(2)) / 100
            unit = "km/h"
        case "2AD5":
            minimum = Double(try reader.signed16()) / 10
            maximum = Double(try reader.signed16()) / 10
            increment = Double(try reader.unsigned(2)) / 10
            unit = "%"
        case "2AD8":
            minimum = Double(try reader.signed16())
            maximum = Double(try reader.signed16())
            increment = Double(try reader.unsigned(2))
            unit = "W"
        default:
            minimum = Double(try reader.unsigned(1))
            maximum = Double(try reader.unsigned(1))
            increment = Double(try reader.unsigned(1))
            unit = "bpm"
        }
        guard minimum <= maximum, increment > 0 else { throw FTMSDecodeError.invalidRange }
        return FTMSRange(minimum: minimum, maximum: maximum, increment: increment, unit: unit)
    }

    public static func treadmill(_ data: Data) throws -> TreadmillSample {
        var reader = Reader(data)
        let flags = UInt16(try reader.unsigned(2))
        guard flags & 0xE000 == 0 else { throw FTMSDecodeError.reservedFlags(flags) }
        let moreData = flags & 1 != 0
        let speed = moreData ? nil : Double(try reader.unsigned(2)) / 100
        if flags & (1 << 1) != 0 { try reader.skip(2) }  // Average speed precedes distance.
        let distance = flags & (1 << 2) != 0 ? try reader.unsigned(3) : nil
        // Validate the entire known packet before publishing either metric.
        // Optional values outside this delivery remain available as original bytes.
        let inclination: Double?
        let rampAngle: Double?
        if flags & (1 << 3) != 0 {
            let rawInclination = try reader.signed16()
            let rawRampAngle = try reader.signed16()
            // FTMS reserves 0x7FFF for "value not available" in these fields.
            inclination = rawInclination == Int16.max ? nil : Double(rawInclination) / 10
            rampAngle = rawRampAngle == Int16.max ? nil : Double(rawRampAngle) / 10
        } else {
            inclination = nil
            rampAngle = nil
        }
        for (bit, width) in [(4, 4), (5, 2), (6, 2), (7, 5), (8, 1), (9, 1), (10, 2), (11, 2), (12, 4)] {
            if flags & (1 << bit) != 0 { try reader.skip(width) }
        }
        guard reader.offset == data.count else {
            throw FTMSDecodeError.length(expected: reader.offset, actual: data.count)
        }
        return TreadmillSample(
            flags: flags, moreData: moreData, speedKilometersPerHour: speed,
            distanceMeters: distance, inclinationPercent: inclination, rampAngleDegrees: rampAngle)
    }

    private static func requireLength(_ data: Data, _ count: Int) throws {
        guard data.count == count else {
            throw FTMSDecodeError.length(expected: count, actual: data.count)
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        mutating func unsigned(_ width: Int) throws -> UInt32 {
            guard offset + width <= bytes.count else {
                throw FTMSDecodeError.truncated(offset: offset, required: width, actual: bytes.count)
            }
            var value: UInt32 = 0
            for i in 0..<width { value |= UInt32(bytes[offset + i]) << (8 * i) }
            offset += width
            return value
        }
        mutating func signed16() throws -> Int16 { Int16(bitPattern: UInt16(try unsigned(2))) }
        mutating func skip(_ width: Int) throws {
            _ = try unsigned(width > 4 ? 4 : width)
            if width > 4 { _ = try unsigned(width - 4) }
        }
    }
}
