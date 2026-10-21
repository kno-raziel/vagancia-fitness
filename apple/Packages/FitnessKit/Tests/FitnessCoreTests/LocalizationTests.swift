import Foundation
import XCTest

@testable import FitnessCore

final class LocalizationTests: XCTestCase {
    private let spanish = Locale(identifier: "es_ES")
    private let english = Locale(identifier: "en_US")

    func testSharedTitlesUseExplicitLanguageWithoutChangingCodes() throws {
        XCTAssertEqual(WorkoutPhase.warmup.localizedTitle(locale: spanish), "Calentamiento")
        XCTAssertEqual(WorkoutPhase.warmup.localizedTitle(locale: english), "Warm-up")
        XCTAssertEqual(WorkoutState.paused.localizedTitle(locale: english), "Paused")
        XCTAssertEqual(MetricSource.machineFTMS.localizedTitle(locale: english), "Treadmill · FTMS")
        XCTAssertEqual(FTMSAction.stop.localizedTitle(locale: english), "Stop treadmill")
        XCTAssertEqual(FTMSAction.stop.opcode, 8)
        let capability = FTMSCapability(
            id: "heartRate", label: "Frecuencia cardíaca", declaration: "advertised",
            verification: "notRun")
        XCTAssertEqual(capability.localizedLabel(locale: english), "Heart rate")
        XCTAssertEqual(capability.label, "Frecuencia cardíaca")
        XCTAssertEqual(WorkoutState.paused.rawValue, "paused")
        let json = try JSONEncoder().encode(WorkoutPhase.warmup)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "\"warmup\"")
    }

    func testSeedPresentationKeepsPersistedNameAndUserProgramsUntouched() throws {
        let seed = try XCTUnwrap(WorkoutProgram.seedPrograms.first { $0.id == "essential" })
        XCTAssertEqual(seed.name, "Intervalos esenciales")
        XCTAssertEqual(seed.localizedSeedName(locale: english), "Essential intervals")
        XCTAssertEqual(seed.localizedSeedName(locale: spanish), seed.name)
        let restored = try JSONDecoder().decode(WorkoutProgram.self, from: JSONEncoder().encode(seed))
        XCTAssertEqual(restored, seed)
        XCTAssertEqual(restored.name, seed.name)
        let custom = WorkoutProgram(id: "custom", name: "My own tempo", intervals: seed.intervals)
        XCTAssertEqual(custom.localizedSeedName(locale: spanish), "My own tempo")
        var renamedSeed = seed
        renamedSeed.name = "Mi plan personal"
        XCTAssertEqual(renamedSeed.localizedSeedName(locale: english), "Mi plan personal")
        let free = WorkoutProgram(
            id: "free-legacy-session", name: "Entrenamiento libre", intervals: seed.intervals)
        XCTAssertEqual(free.localizedSeedName(locale: english), "Free workout")
        XCTAssertEqual(free.name, "Entrenamiento libre")
        var renamedFree = free
        renamedFree.name = "Caminata personal"
        XCTAssertEqual(renamedFree.localizedSeedName(locale: english), "Caminata personal")
    }

    func testLocalizedErrorsAndFormats() {
        XCTAssertEqual(
            WorkoutProgramValidationError.invalidDuration(index: 1).localizedMessage(locale: english),
            "Interval 2 must last between 15 and 3,600 seconds.")
        XCTAssertEqual(
            FTMSDecodeError.length(expected: 4, actual: 2).localizedMessage(locale: spanish),
            "FTMS: se esperaban 4 bytes y llegaron 2.")
        XCTAssertEqual(FitnessText.number(5.5, locale: spanish), "5,5")
        XCTAssertEqual(FitnessText.number(5.5, locale: english), "5.5")
        XCTAssertEqual(FitnessText.intervalCount(0, locale: english), "0 intervals")
        XCTAssertEqual(FitnessText.intervalCount(1, locale: english), "1 interval")
        XCTAssertEqual(FitnessText.intervalCount(2, locale: spanish), "2 intervalos")
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertNotEqual(
            FitnessText.date(date, locale: spanish, dateStyle: .long, timeStyle: .none),
            FitnessText.date(date, locale: english, dateStyle: .long, timeStyle: .none))
    }

    func testDiagnosticEventTitleIsPresentationOnly() throws {
        let event = DiagnosticEvent(
            eventId: "e", sequence: 1, timestamp: .distantPast,
            elapsedMilliseconds: 0, kind: "ble.connected", source: .hardware, payload: [:])
        XCTAssertEqual(event.localizedTitle(locale: english), "Connection confirmed")
        XCTAssertEqual(event.kind, "ble.connected")
        let restored = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored.kind, event.kind)
        let raw = "Preparación cancelada; no se guardó entrenamiento."
        XCTAssertEqual(
            FitnessText.watchPreparationMessage(raw, locale: english),
            "Preparation cancelled; no workout was saved.")
        XCTAssertEqual(
            FitnessText.watchPreparationMessage("mensaje externo", locale: english), "mensaje externo")
    }

    func testControlPresentationDoesNotMutateStoredMessage() throws {
        let raw = "La parada Bluetooth no está preparada. Usa la consola física."
        XCTAssertEqual(
            FitnessText.controlMessage(raw, locale: english),
            "Bluetooth stop is not ready. Use the physical console.")
        XCTAssertEqual(
            FitnessText.controlMessage(
                "Parar banda: rechazado (código 3). No se reintenta.", locale: english),
            "Stop treadmill: rejected (code 3). It will not be retried.")
        XCTAssertEqual(
            FitnessText.controlMessage("mensaje del equipo", locale: english), "mensaje del equipo")
        var control = FTMSControl()
        XCTAssertEqual(
            control.localizedMessage(locale: english),
            "Prepare the control channel. No movement will be sent.")
        XCTAssertEqual(control.message, "Prepara el canal de control. No se enviará movimiento.")
        control.message = raw
        let stored = try JSONEncoder().encode(control)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains(raw))
    }
}
