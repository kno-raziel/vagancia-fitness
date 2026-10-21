import Foundation
import Testing

@testable import FitnessCore

// All packets in this suite are synthetic, derived from the published field layouts.
struct FTMSDecoderTests {
    @Test func featureMasksKeepUnknownBitsAndSeparateDeclarationFromVerification() throws {
        let features = try FTMSDecoder.features(Data([4, 0, 0, 128, 3, 0, 1, 128]))
        #expect(features.machineBits == 0x8000_0004)
        #expect(features.targetBits == 0x8001_0003)
        #expect(features.capabilities.first { $0.id == "totalDistance" }?.declaration == "advertised")
        #expect(features.capabilities.first { $0.id == "speedTarget" }?.declaration == "advertised")
        #expect(
            features.capabilities.first { $0.id == "inclinationTarget" }?.declaration == "advertised")
        #expect(features.capabilities.first { $0.id == "averageSpeed" }?.declaration == "notAdvertised")
        #expect(features.capabilities.allSatisfy { $0.verification == "notRun" })
        for size in 0..<8 {
            #expect(throws: FTMSDecodeError.self) {
                try FTMSDecoder.features(Data(repeating: 0, count: size))
            }
        }
    }

    @Test func supportedRangesUseCorrectWidthsSignednessAndUnits() throws {
        #expect(
            try FTMSDecoder.range(Data([100, 0, 176, 4, 10, 0]), uuid: "2AD4")
                == FTMSRange(minimum: 1, maximum: 12, increment: 0.1, unit: "km/h"))
        #expect(
            try FTMSDecoder.range(Data([206, 255, 150, 0, 10, 0]), uuid: "2AD5")
                == FTMSRange(minimum: -5, maximum: 15, increment: 1, unit: "%"))
        #expect(
            try FTMSDecoder.range(Data([60, 200, 1]), uuid: "2AD7")
                == FTMSRange(minimum: 60, maximum: 200, increment: 1, unit: "bpm"))
        #expect(
            try FTMSDecoder.range(Data([156, 255, 232, 3, 5, 0]), uuid: "2AD8")
                == FTMSRange(minimum: -100, maximum: 1000, increment: 5, unit: "W"))
    }

    @Test func invalidRangesAndUnexpectedLengthsAreRejected() {
        for (uuid, bytes) in [
            ("2AD4", [100, 0, 50, 0, 1, 0]), ("2AD5", [0, 0, 100, 0, 0, 0]), ("2AD7", [60, 200]),
            ("2AD8", [0, 0, 0, 1, 1, 0, 0]),
        ] {
            #expect(throws: FTMSDecodeError.self) {
                try FTMSDecoder.range(Data(bytes.map(UInt8.init)), uuid: uuid)
            }
        }
    }

    @Test func speedAndDistanceHaveIndependentPresenceAndUseLittleEndian24Bits() throws {
        let sample = try FTMSDecoder.treadmill(Data([6, 0, 244, 1, 144, 1, 57, 48, 0]))
        #expect(sample.speedKilometersPerHour == 5)
        #expect(sample.distanceMeters == 12_345)
        let more = try FTMSDecoder.treadmill(Data([5, 0, 3, 2, 1]))
        #expect(more.moreData)
        #expect(more.speedKilometersPerHour == nil)
        #expect(more.distanceMeters == 66_051)
        let zero = try FTMSDecoder.treadmill(Data([0, 0, 0, 0]))
        #expect(zero.speedKilometersPerHour == 0)
        #expect(zero.distanceMeters == nil)
    }

    @Test func inclinationAndRampAreSignedTenthsAndMalformedSuffixIsRejected() throws {
        // Speed=5 km/h, inclination=-1.2%, ramp=+3.4%.
        let sample = try FTMSDecoder.treadmill(Data([8, 0, 244, 1, 244, 255, 34, 0]))
        #expect(sample.inclinationPercent == -1.2)
        #expect(sample.rampAngleDegrees == 3.4)
        #expect(throws: FTMSDecodeError.self) {
            try FTMSDecoder.treadmill(Data([8, 0, 244, 1, 244, 255, 34]))
        }
    }

    @Test func telemetryPublishesInclinationAndRampWithTheirOriginalTimestamp() throws {
        let received = Date(timeIntervalSince1970: 1_700_000_000)
        var telemetry = FTMSTelemetry(
            serviceId: "service", characteristicId: "treadmill-data",
            startedAt: received, subscriptionOperationId: "subscription")
        _ = try telemetry.receive(
            Data([8, 0, 244, 1, 244, 255, 34, 0]), at: received, eventId: "incline")
        #expect(
            telemetry.inclination
                == FTMSMetric(value: -1.2, unit: "%", receivedAt: received, eventId: "incline"))
        #expect(
            telemetry.rampAngle
                == FTMSMetric(value: 3.4, unit: "°", receivedAt: received, eventId: "incline"))
        _ = try telemetry.receive(
            Data([0, 0, 0, 0]), at: received.addingTimeInterval(1), eventId: "speed-only")
        #expect(telemetry.inclination?.receivedAt == received)
        #expect(telemetry.inclination?.eventId == "incline")
    }

    @Test func optionalAngleFieldsPreserveNotAvailableSentinelsAsAbsent() throws {
        let sample = try FTMSDecoder.treadmill(Data([8, 0, 244, 1, 255, 127, 255, 127]))
        #expect(sample.inclinationPercent == nil)
        #expect(sample.rampAngleDegrees == nil)
    }

    @Test func fullPacketAndEveryTruncatedPrefixAreValidatedBeforePublishingMetrics() throws {
        // All optional fields. Pace fields follow GSS 2026-09-09: uint16 each.
        let packet = Data(
            [0xFE, 0x1F, 0xF4, 1, 0xE0, 1, 3, 2, 1] + Array(repeating: UInt8(0), count: 27))
        let sample = try FTMSDecoder.treadmill(packet)
        #expect(sample.speedKilometersPerHour == 5)
        #expect(sample.distanceMeters == 66_051)
        for length in 0..<packet.count {
            #expect(throws: FTMSDecodeError.self) {
                try FTMSDecoder.treadmill(Data(packet.prefix(length)))
            }
        }
        #expect(throws: FTMSDecodeError.self) { try FTMSDecoder.treadmill(packet + Data([0])) }
        #expect(throws: FTMSDecodeError.self) { try FTMSDecoder.treadmill(Data([0, 128, 0, 0])) }
    }

    @Test func splitPacketsDoNotRefreshAbsentMetricsAndInvalidPacketKeepsPreviousEvidence() throws {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        var telemetry = FTMSTelemetry(
            serviceId: "service", characteristicId: "char", startedAt: first,
            subscriptionOperationId: "subscription")
        _ = try telemetry.receive(Data([4, 0, 244, 1, 10, 0, 0]), at: first, eventId: "first")
        _ = try telemetry.receive(
            Data([5, 0, 20, 0, 0]), at: first.addingTimeInterval(2), eventId: "distance")
        #expect(telemetry.speed?.value == 5)
        #expect(telemetry.speed?.eventId == "first")
        #expect(telemetry.distance?.value == 20)
        #expect(telemetry.distance?.eventId == "distance")
        #expect(throws: FTMSDecodeError.self) {
            try telemetry.receive(Data([4, 0, 255]), at: first.addingTimeInterval(3), eventId: "broken")
        }
        #expect(telemetry.speed?.eventId == "first")
        #expect(telemetry.distance?.eventId == "distance")
        #expect(telemetry.lastPacketHex == "0400FF")
        #expect(telemetry.lastDecodeError != nil)
        #expect(telemetry.validSampleCount == 2 && telemetry.invalidSampleCount == 1)
        #expect(telemetry.speed?.isStale(at: first.addingTimeInterval(6)) == true)
        #expect(telemetry.distance?.isStale(at: first.addingTimeInterval(6)) == false)
        #expect(telemetry.speed?.isStale(at: first.addingTimeInterval(-1)) == true)
    }
}
