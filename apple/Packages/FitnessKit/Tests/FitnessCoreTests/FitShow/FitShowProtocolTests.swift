import Foundation
import Testing

@testable import FitnessCore

struct FitShowProtocolTests {
    // Synthetic frames authored from documented wire fields, not real YK captures.
    let status: [UInt8] = [0x51, 3, 20, 0, 60, 0, 5, 0, 0, 0, 0, 0, 80]

    @Test func queriesHaveKnownFramingAndNeverEncodeMovement() throws {
        #expect(FitShowProtocol.speedRangeQuery().hex == "0250025203")
        #expect(FitShowProtocol.speedRangeQuery().hex != "02515103")
        let message = try FitShowProtocol.decode(Data([2, 0x50, 2, 160, 8, 0, 250, 3]))
        #expect(message.family == 0x50 && message.parameter == 2 && message.recognized)
        #expect(message.payload == [0x50, 2, 160, 8, 0])
        #expect(DiagnosticProtocol.fitShowFFF0.writeUUID == "FFF2")
        #expect(DiagnosticProtocol.fitShowFFE0.notifyUUID == "FFE4")
    }

    @Test func checksumDelimitersAndLengthAreValidated() throws {
        for bytes in [[UInt8](), [2, 0x50, 2, 0, 3], [0, 0x50, 2, 0x52, 3], [2, 0x50, 2, 0x52, 0]] {
            #expect(throws: FitShowError.self) { try FitShowProtocol.decode(Data(bytes)) }
        }
        let unknown = FitShowProtocol.frame([0x55, 0])
        #expect(try FitShowProtocol.decode(unknown).recognized == false)
    }

    @Test func fragmentedAndCoalescedFramesPreserveFooterBytesInsidePayload() throws {
        // Status parameter itself is 0x03, so splitting at every 0x03 is wrong.
        let packet = FitShowProtocol.frame(status)
        for split in 1..<packet.count {
            var decoder = FitShowAssembler()
            #expect(try decoder.receive(Data(packet.prefix(split))).isEmpty)
            let decoded = try decoder.receive(Data(packet.dropFirst(split)))
            #expect(decoded.count == 1 && decoded[0].payload == status)
            #expect(decoder.buffer.isEmpty)
        }
        var decoder = FitShowAssembler()
        let info = FitShowProtocol.frame([0x50, 2, 160, 8, 0])
        #expect(try decoder.receive(packet + info).count == 2)
        #expect(decoder.buffer.isEmpty)
    }

    @Test func corruptAndOversizedFragmentsCannotEnableControl() throws {
        var decoder = FitShowAssembler()
        #expect(throws: FitShowError.self) { try decoder.receive(Data(repeating: 2, count: 65)) }
        #expect(decoder.buffer.isEmpty)
        var frame = FitShowProtocol.frame(status)
        frame[frame.count - 2] ^= 1
        #expect(throws: FitShowError.self) { try decoder.receive(frame) }
        #expect(decoder.buffer.isEmpty)
    }

    @Test func recognizedMessagesKeepRawUnitsAndNeverPromoteToProprietaryControl() throws {
        var observation = FitShowObservation(
            channel: .fitShowFFF0, serviceId: "s", writeCharacteristicId: "tx",
            notifyCharacteristicId: "rx")
        observation.observe(
            try FitShowProtocol.decode(FitShowProtocol.frame([0x50, 2, 160, 8, 0])), eventId: "range",
            matchedRangeQuery: true)
        observation.observe(
            try FitShowProtocol.decode(FitShowProtocol.frame(status)), eventId: "status",
            matchedRangeQuery: false)
        #expect(observation.compatibility == "messagesRecognizedUnitsUnconfirmed")
        #expect(observation.minimumSpeedTenthsRaw == 8 && observation.maximumSpeedTenthsRaw == 160)
        #expect(observation.speedTenthsRaw == 20 && observation.distanceCounterRaw == 5)
        #expect(observation.rangeResponseEventId == "range" && observation.statusEventId == "status")
        #expect(!observation.controlEnabled)
        #expect(observation.unitByteRaw == 0)  // Preserved, not interpreted as km/h.
    }

    @Test func duplicateUUIDChannelsStaySeparateAndUnsolicitedInfoDoesNotMatchAQuery() throws {
        var first = FitShowObservation(
            channel: .fitShowFFF0, serviceId: "s1", writeCharacteristicId: "tx1",
            notifyCharacteristicId: "rx1")
        let second = FitShowObservation(
            channel: .fitShowFFE0, serviceId: "s2", writeCharacteristicId: "tx2",
            notifyCharacteristicId: "rx2")
        first.observe(
            try FitShowProtocol.decode(FitShowProtocol.frame([0x50, 2, 160, 8])), eventId: "unsolicited",
            matchedRangeQuery: false)
        #expect(first.recognizedFrameCount == 1 && first.rangeResponseEventId == nil)
        #expect(second.validFrameCount == 0 && second.rangeResponseEventId == nil)
    }

    @Test func shortIdleAndSafetyStatusesAreRecognizedWithoutFabricatingMetrics() throws {
        var observation = FitShowObservation(
            channel: .fitShowFFF0, serviceId: "s", writeCharacteristicId: "tx",
            notifyCharacteristicId: "rx")
        var assembler = FitShowAssembler()
        let payloads: [[UInt8]] = [[0x51, 0], [0x51, 2, 3], [0x51, 6]]
        for payload in payloads {
            let frames = try assembler.receive(FitShowProtocol.frame(payload))
            #expect(frames.count == 1 && frames[0].recognized)
            observation.observe(frames[0], eventId: "short", matchedRangeQuery: false)
            #expect(observation.speedTenthsRaw == nil && observation.distanceCounterRaw == nil)
            #expect(observation.metricReceivedAt == nil)
        }
        #expect(observation.machineStatusRaw == 6 && !observation.controlEnabled)
    }
}
