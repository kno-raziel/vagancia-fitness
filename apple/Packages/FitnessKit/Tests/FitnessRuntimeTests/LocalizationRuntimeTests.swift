import FitnessCore
import Foundation
import XCTest

final class LocalizationRuntimeTests: XCTestCase {
    func testOperationalControlFailureKeepsRawReasonAndPresentsEnglish() {
        let raw = "Conecta la caminadora y prepara FTMS antes de iniciar."
        let error = ControlError.blocked(raw)
        XCTAssertEqual(
            error.errorDescription,
            FitnessText.controlMessage(raw))
        XCTAssertEqual(
            FitnessText.controlMessage(raw, locale: Locale(identifier: "en_US")),
            "Connect the treadmill and prepare FTMS before starting.")
        if case .blocked(let stored) = error {
            XCTAssertEqual(stored, raw)
        } else {
            XCTFail("The original control reason was lost")
        }
    }
}
