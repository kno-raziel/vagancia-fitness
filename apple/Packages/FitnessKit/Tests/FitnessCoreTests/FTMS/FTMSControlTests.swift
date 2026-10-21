import Foundation
import Testing

@testable import FitnessCore

struct FTMSControlTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let range = FTMSRange(minimum: 0.8, maximum: 16, increment: 0.1, unit: "km/h")
    let inclinationRange = FTMSRange(minimum: -5, maximum: 15, increment: 1, unit: "%")
    func metric(_ value: Double, offset: Double = 1) -> FTMSMetric {
        FTMSMetric(
            value: value, unit: "km/h", receivedAt: now.addingTimeInterval(offset), eventId: "metric")
    }
    func prepared() throws -> FTMSControl {
        var control = FTMSControl()
        control.indicationReady = true
        #expect(try control.begin(.requestControl, authorized: true, at: now).valueHex == "00")
        // Transport ack alone must never grant authority.
        control.written(error: nil)
        #expect(!control.permission)
        #expect(try control.response(Data([0x80, 0, 1]), eventId: "permission"))
        #expect(try control.begin(.stop, authorized: true, at: now).valueHex == "0801")
        #expect(try control.response(Data([0x80, 8, 1]), eventId: "stop"))
        control.observed(metric(0), at: now.addingTimeInterval(1))
        return control
    }

    @Test func requiresAuthorizationIndicationsPermissionAndAcceptedStopBeforeStart() throws {
        var control = FTMSControl()
        #expect(throws: ControlError.self) { try control.begin(.requestControl, authorized: true) }
        control.indicationReady = true
        #expect(throws: ControlError.self) { try control.begin(.requestControl, authorized: false) }
        _ = try control.begin(.requestControl, authorized: true)
        control.written(error: nil)
        #expect(!control.canStop && !control.canStart)
        _ = try control.response(Data([0x80, 0, 1]), eventId: "permission")
        #expect(control.canStop && !control.canStart)
        #expect(throws: ControlError.self) {
            try control.begin(
                .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        }
        #expect(control.pending == nil)
    }

    @Test func startRequiresRecentZeroAndWaitsForActualRunningTelemetry() throws {
        var control = try prepared()
        #expect(control.canStart)
        #expect(throws: ControlError.self) {
            try control.begin(
                .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(10))
        }
        #expect(throws: ControlError.self) {
            try control.begin(
                .start, authorized: true, observedSpeed: metric(2), at: now.addingTimeInterval(1))
        }
        #expect(
            try control.begin(
                .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1)
            ).valueHex == "07")
        _ = try control.response(Data([0x80, 7, 1]), eventId: "start")
        #expect(control.movementUncertain && !control.canStart)
        control.observed(metric(0, offset: 2), at: now.addingTimeInterval(2))
        #expect(control.movementUncertain)  // Countdown/zero is not RUNNING.
        control.observed(metric(2, offset: 2), at: now.addingTimeInterval(2))
        #expect(!control.movementUncertain)
        #expect(control.last?.result == "acceptedByProtocol")
    }

    @Test func speedIsLittleEndianAndRejectsUnsafeValuesWithoutRounding() throws {
        var control = try prepared()
        #expect(
            try control.begin(
                .speed, authorized: true, speed: 2.5, range: range, speedAdvertised: true,
                observedSpeed: metric(2), at: now.addingTimeInterval(1)
            ).valueHex == "02FA00")
        #expect(throws: ControlError.self) {
            try control.begin(
                .speed, authorized: true, speed: 3, range: range, speedAdvertised: true,
                observedSpeed: metric(2))
        }
        _ = try control.response(Data([0x80, 2, 1]), eventId: "speed")
        for speed in [Double.nan, .infinity, -1, 0.7, 16.1, 1.05] {
            #expect(throws: ControlError.self) {
                try control.begin(
                    .speed, authorized: true, speed: speed, range: range,
                    speedAdvertised: true, observedSpeed: metric(2), at: now.addingTimeInterval(1))
            }
        }
        #expect(throws: ControlError.self) {
            try control.begin(
                .speed, authorized: true, speed: 2, range: range,
                speedAdvertised: false, observedSpeed: metric(2), at: now.addingTimeInterval(1))
        }
        #expect(throws: ControlError.self) {
            try control.begin(
                .speed, authorized: true, speed: 2, range: range,
                speedAdvertised: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        }
        #expect(control.pending == nil)
    }

    @Test func inclinationUsesSignedTenthsAndRequiresPermissionAdvertisementAndRange() throws {
        var control = try prepared()
        #expect(
            try control.begin(
                .inclination, authorized: true, inclination: -1,
                inclinationRange: inclinationRange, inclinationAdvertised: true,
                observedSpeed: metric(2), at: now.addingTimeInterval(1)
            ).valueHex == "03F6FF")
        _ = try control.response(Data([0x80, 3, 1]), eventId: "incline")
        #expect(throws: ControlError.self) {
            try control.begin(
                .inclination, authorized: true, inclination: 2,
                inclinationRange: inclinationRange, inclinationAdvertised: false, observedSpeed: metric(2))
        }
        #expect(throws: ControlError.self) {
            try control.begin(
                .inclination, authorized: true, inclination: 15.5,
                inclinationRange: inclinationRange, inclinationAdvertised: true, observedSpeed: metric(2))
        }
        #expect(throws: ControlError.self) {
            try control.begin(
                .inclination, authorized: true, inclination: 16,
                inclinationRange: inclinationRange, inclinationAdvertised: true, observedSpeed: metric(2))
        }
        let signedTenths = FTMSRange(minimum: -5, maximum: 15, increment: 0.1, unit: "%")
        #expect(
            try control.begin(
                .inclination, authorized: true, inclination: -0.5,
                inclinationRange: signedTenths, inclinationAdvertised: true,
                observedSpeed: metric(2), at: now.addingTimeInterval(1)
            ).valueHex == "03FBFF")
        _ = try control.response(Data([0x80, 3, 1]), eventId: "downhill")
        #expect(control.pending == nil)
    }

    @Test func explicitStopPreemptsPendingStartAndLateResponseCannotCompleteStop() throws {
        var control = try prepared()
        let start = try control.begin(
            .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        let stop = try control.begin(.stop, authorized: true, at: now.addingTimeInterval(2))
        #expect(control.last?.id == start.id)
        #expect(control.last?.result == "supersededByExplicitStop")
        #expect(!control.canSelectProtocol && control.requiresReconnect)
        #expect(try !control.response(Data([0x80, 7, 1]), eventId: "late-start"))
        #expect(control.pending?.id == stop.id)
        _ = try control.response(Data([0x80, 8, 1]), eventId: "stop")
        control.observed(metric(0, offset: 3), at: now.addingTimeInterval(3))
        #expect(!control.canSelectProtocol && !control.canStart)  // Switching must not bypass quarantine.
    }

    @Test func oldStartPersistenceCompletionCannotFailNewExplicitStop() throws {
        var control = try prepared()
        let start = try control.begin(
            .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        let stop = try control.begin(.stop, authorized: true, at: now.addingTimeInterval(2))
        let affectedCurrentProcedure = control.fail(
            procedureId: start.id, reason: "La solicitud antigua terminó tarde.")
        #expect(!affectedCurrentProcedure)
        #expect(control.pending?.id == stop.id)
        #expect(control.last?.id == start.id)
        #expect(control.last?.result == "supersededByExplicitStop")
        control.written(procedureId: stop.id, error: nil)
        #expect(try control.response(Data([0x80, 8, 1]), eventId: "explicit-stop"))
        #expect(control.last?.id == stop.id)
        #expect(control.last?.writeStatus == "acknowledgedByBLE")
        #expect(control.last?.result == "acceptedByProtocol")
    }

    @Test func timeoutQuarantinesFurtherMovementAndDoesNotRetry() throws {
        var control = try prepared()
        _ = try control.begin(
            .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        control.fail("timeout")
        #expect(control.pending == nil && control.requiresReconnect)
        #expect(control.last?.result == "indeterminate")
        #expect(try !control.response(Data([0x80, 7, 1]), eventId: "late"))
        #expect(throws: ControlError.self) {
            try control.begin(.start, authorized: true, observedSpeed: metric(0))
        }
        _ = try control.begin(.stop, authorized: true)
        control.fail("stop timeout")
        #expect(throws: ControlError.self) { try control.begin(.stop, authorized: true) }
    }

    @Test func rejectionMalformedResponseWriteFailureAndPermissionLossRemainDistinct() throws {
        var control = FTMSControl()
        control.indicationReady = true
        _ = try control.begin(.requestControl, authorized: true)
        _ = try control.response(Data([0x80, 0, 5]), eventId: "denied")
        #expect(
            !control.permission && control.last?.responseCode == 5
                && control.last?.result == "rejectedByProtocol")
        _ = try control.begin(.requestControl, authorized: true)
        #expect(throws: ControlError.self) {
            try control.response(Data([0x80, 0]), eventId: "malformed")
        }
        #expect(control.requiresReconnect && control.pending == nil)
        control = try prepared()
        control.permissionLost()
        #expect(!control.canStop && !control.canStart && control.requiresReconnect)
        control = try prepared()
        _ = try control.begin(
            .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        control.written(error: "CBError")
        #expect(control.last?.writeStatus == "failed" && control.last?.result == "indeterminate")
        control.disconnected()
        #expect(!control.indicationReady && !control.permission && !control.canStart)
    }

    @Test func writeCallbackAfterFastResponseUpdatesOnlyMatchingTerminalEvidence() throws {
        var control = try prepared()
        let procedure = try control.begin(
            .speed, authorized: true, speed: 3.2, range: range,
            speedAdvertised: true, observedSpeed: metric(2), at: now.addingTimeInterval(1))
        #expect(try control.response(Data([0x80, 2, 1]), eventId: "fast-response"))
        #expect(control.pending == nil)
        #expect(control.last?.result == "acceptedByProtocol")

        control.written(procedureId: procedure.id, error: nil)

        #expect(control.last?.id == procedure.id)
        #expect(control.last?.writeStatus == "acknowledgedByBLE")
        #expect(control.last?.result == "acceptedByProtocol")
        #expect(control.last?.responseEventId == "fast-response")
    }

    @Test func capturedStopZeroBeforeAckPermitsImmediateStartInSameConnection() throws {
        var control = try prepared()
        let stopAt = now.addingTimeInterval(100)
        _ = try control.begin(.stop, authorized: true, at: stopAt)
        let zero = metric(0, offset: 100.101)
        control.observed(zero, at: zero.receivedAt)
        #expect(control.movementUncertain && !control.canStart)
        #expect(try control.response(Data([0x80, 8, 1]), eventId: "stop-ack-100.228"))
        #expect(control.canStart && !control.movementUncertain)
        let start = try control.begin(
            .start, authorized: true, observedSpeed: zero,
            at: now.addingTimeInterval(100.462))
        #expect(start.action == .start)
    }

    @Test func stopAckBeforeZeroNeedsNewZeroAndOldOrLaterPositiveCannotSatisfyGate() throws {
        var control = try prepared()
        let stopAt = now.addingTimeInterval(100)
        _ = try control.begin(.stop, authorized: true, at: stopAt)
        control.observed(metric(0, offset: 99.9), at: stopAt)
        #expect(try control.response(Data([0x80, 8, 1]), eventId: "stop"))
        #expect(!control.canStart)
        #expect(throws: ControlError.self) {
            try control.begin(
                .start, authorized: true, observedSpeed: metric(0, offset: 99.9), at: stopAt)
        }
        let zero = metric(0, offset: 100.2)
        control.observed(zero, at: zero.receivedAt)
        #expect(control.canStart)
        let moving = metric(0.8, offset: 100.3)
        control.observed(moving, at: moving.receivedAt)
        #expect(!control.canStart)
        #expect(throws: ControlError.self) {
            try control.begin(.start, authorized: true, observedSpeed: zero, at: moving.receivedAt)
        }
    }

    @Test func rejectedStopDisconnectAndLateAckCannotReusePendingZero() throws {
        var control = try prepared()
        let stopAt = now.addingTimeInterval(100)
        _ = try control.begin(.stop, authorized: true, at: stopAt)
        let zero = metric(0, offset: 100.1)
        control.observed(zero, at: zero.receivedAt)
        #expect(try control.response(Data([0x80, 8, 2]), eventId: "rejected"))
        #expect(!control.canStart && control.stopZeroObservedAt == nil)

        _ = try control.begin(.stop, authorized: true, at: now.addingTimeInterval(101))
        control.observed(metric(0, offset: 101.1), at: now.addingTimeInterval(101.1))
        control.disconnected()
        #expect(try !control.response(Data([0x80, 8, 1]), eventId: "late-stop"))
        #expect(!control.canStart && control.stopZeroObservedAt == nil)
        #expect(control.connectionGeneration == 1)
    }

    @Test func positiveTelemetryAfterPendingZeroInvalidatesTheCandidate() throws {
        var control = try prepared()
        _ = try control.begin(.stop, authorized: true, at: now.addingTimeInterval(100))
        control.observed(metric(0, offset: 100.1), at: now.addingTimeInterval(100.1))
        control.observed(metric(1, offset: 100.2), at: now.addingTimeInterval(100.2))
        #expect(try control.response(Data([0x80, 8, 1]), eventId: "accepted"))
        #expect(!control.canStart && control.movementUncertain)
    }

    @Test func legacyControlJSONDecodesWithoutNewStopEpochFields() throws {
        let legacy = Data(
            """
            {"indicationReady":true,"permission":true,"stopAccepted":true,
             "requiresReconnect":false,"movementUncertain":false,"movementOutstanding":false,
             "pending":null,"last":null,"message":"Control FTMS preparado"}
            """.utf8)
        var restored = try JSONDecoder().decode(FTMSControl.self, from: legacy)
        #expect(restored.indicationReady && restored.permission && restored.stopAccepted)
        #expect(restored.connectionGeneration == 0)
        #expect(restored.stopZeroObservedAt == nil && restored.stopZeroGeneration == nil)
        #expect(throws: ControlError.self) {
            try restored.begin(
                .start, authorized: true, observedSpeed: metric(0), at: now.addingTimeInterval(1))
        }
        let roundtrip = try JSONDecoder().decode(FTMSControl.self, from: JSONEncoder().encode(restored))
        #expect(roundtrip == restored)
    }
}
