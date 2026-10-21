import XCTest

final class SessionFlowTests: XCTestCase {
    @MainActor
    func testNativeLiquidGlassTabsKeepHistoricalMetricsAndMotorGates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--start-on-live"]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = ftmsFixture()
        app.launchEnvironment["VAGANCIA_FITNESS_DISTANCE_REPLAY"] = "0,10,30,0"
        app.launchEnvironment["VAGANCIA_FITNESS_REMEMBERED_FIXTURE"] =
            #"{"identifier":"00000000-0000-0000-0000-000000000001","name":"YK-03K45","connectOnOpen":false}"#
        app.launch()
        XCTAssertTrue(app.staticTexts["dashboardSpeed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["dashboardSpeed"].label.contains("5"))
        XCTAssertTrue(app.staticTexts["dashboardSessionDistance"].label.contains("30"))
        XCTAssertTrue(app.staticTexts["dashboardCounter"].label.contains("123"))
        XCTAssertFalse(app.buttons["nativeStopBelt"].isEnabled)
        let dashboard = app.scrollViews["liveMetricScroll"]
        for _ in 0..<4 {
            if app.buttons["dashboardConnect"].isHittable
                && app.buttons["dashboardConnect"].frame.maxY < app.buttons["nativeStopBelt"].frame.minY - 8
            {
                break
            }
            dashboard.swipeUp()
        }
        XCTAssertTrue(app.buttons["dashboardConnect"].isHittable)
        XCTAssertLessThan(
            app.buttons["dashboardConnect"].frame.maxY, app.buttons["nativeStopBelt"].frame.minY - 8)
        dashboard.swipeDown()
        capture(app, name: "liquid-glass-session")
        app.buttons["openNativeControl"].tap()
        XCTAssertTrue(app.navigationBars["Control FTMS"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nativePrepareControl"].isEnabled)
        XCTAssertFalse(app.buttons["nativeStartBelt"].isEnabled)
        for _ in 0..<4 {
            if app.buttons["nativeApplySpeed"].exists
                && app.buttons["nativeApplySpeed"].frame.maxY < app.buttons["nativeSheetStopBelt"].frame
                    .minY - 8
            {
                break
            }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(app.buttons["nativeApplySpeed"].exists)
        XCTAssertLessThan(
            app.buttons["nativeApplySpeed"].frame.maxY, app.buttons["nativeSheetStopBelt"].frame.minY - 8)
        capture(app, name: "liquid-glass-control-sheet")
        app.buttons["Cerrar"].tap()
        app.tabBars.buttons["Equipo"].tap()
        XCTAssertTrue(app.switches["connectOnOpen"].waitForExistence(timeout: 5))
        capture(app, name: "liquid-glass-remembered-device")
        app.tabBars.buttons["Registro"].tap()
        XCTAssertTrue(app.buttons["exportDiagnostic"].waitForExistence(timeout: 5))
        capture(app, name: "liquid-glass-record")
    }

    @MainActor
    func testNativeLiquidGlassWithDarkModeAndLargeText() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--start-on-live", "--ui-testing-dark", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = ftmsFixture()
        app.launchEnvironment["VAGANCIA_FITNESS_DISTANCE_REPLAY"] = "0,10,30,0"
        app.launch()
        XCTAssertTrue(app.staticTexts["dashboardSpeed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nativeStopBelt"].isEnabled)
        capture(app, name: "liquid-glass-dark-large-text")
        let distance = app.staticTexts["dashboardSessionDistance"]
        let scroll = app.scrollViews["liveMetricScroll"]
        for _ in 0..<8 {
            if distance.exists && distance.isHittable
                && distance.frame.maxY < app.buttons["nativeStopBelt"].frame.minY - 8
            {
                break
            }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(
                forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(distance.exists && distance.isHittable)
        XCTAssertLessThan(distance.frame.maxY, app.buttons["nativeStopBelt"].frame.minY - 8)
        XCTAssertFalse(app.navigationBars["Control FTMS"].exists)
        capture(app, name: "liquid-glass-dark-large-distance")
    }

    @MainActor
    func testRememberedTreadmillCanBeConfiguredWithoutActivatingBluetooth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = ftmsFixture()
        app.launchEnvironment["VAGANCIA_FITNESS_REMEMBERED_FIXTURE"] =
            #"{"identifier":"00000000-0000-0000-0000-000000000001","name":"YK-03K45","connectOnOpen":false}"#
        app.launch()
        app.buttons["openBluetooth"].tap()
        let toggle = app.switches["connectOnOpen"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["Bluetooth se activará al buscar."].exists)
        capture(app, name: "phone-remembered-treadmill")
        app.buttons["Olvidar caminadora"].tap()
        XCTAssertFalse(app.switches["connectOnOpen"].exists)
        XCTAssertTrue(app.staticTexts["Bluetooth se activará al buscar."].exists)
    }
    @MainActor
    func testResetDistanceAndPassiveFitShowStatus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        var fixture = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ftmsFixture().utf8)) as? [String: Any])
        fixture["interactive"] = [
            "selectedProtocol": "fitShowFFF0",
            "control": [
                "indicationReady": false, "permission": false, "stopAccepted": false,
                "requiresReconnect": false, "movementUncertain": false, "movementOutstanding": false,
                "message": "Fixture sintética; sin hardware.",
            ],
            "fitShow": [
                [
                    "channel": "fitShowFFF0", "serviceId": "synthetic-s",
                    "writeCharacteristicId": "synthetic-tx", "notifyCharacteristicId": "synthetic-rx",
                    "subscriptionStatus": "interrupted", "notificationCount": 64, "validFrameCount": 64,
                    "recognizedFrameCount": 64, "rejectedCount": 0, "machineStatusRaw": 0,
                ]
            ],
        ]
        var telemetry = try XCTUnwrap(fixture["telemetry"] as? [String: Any])
        var distance = try XCTUnwrap(telemetry["distance"] as? [String: Any])
        distance["value"] = 0
        telemetry["distance"] = distance
        fixture["telemetry"] = telemetry
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = String(
            data: try JSONSerialization.data(withJSONObject: fixture), encoding: .utf8)
        app.launchEnvironment["VAGANCIA_FITNESS_DISTANCE_REPLAY"] = "0,10,30,0"
        app.launch()
        app.buttons["openLivePanel"].tap()
        let accumulated = app.descendants(matching: .any).matching(identifier: "sessionDistanceMetric")
            .firstMatch
        XCTAssertTrue(accumulated.waitForExistence(timeout: 5))
        XCTAssertTrue(accumulated.label.contains("30 m"))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "distanceMetric").firstMatch.label
                .contains("0 m"))
        capture(app, name: "phone-distance-reset")
        let passive = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "no se envía la consulta 51")
        ).firstMatch
        for _ in 0..<16 {
            if passive.exists && passive.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(passive.exists)
        XCTAssertFalse(app.buttons["Consultar estado una vez"].exists)
        XCTAssertFalse(app.buttons["stopBelt"].isEnabled)
        capture(app, name: "phone-fitshow-passive-status")
    }
    @MainActor
    func testLivePanelShowsMetricsAndKeepsMovementDisabledWithoutConnection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = ftmsFixture()
        app.launch()
        app.buttons["openLivePanel"].tap()
        XCTAssertTrue(app.staticTexts["Datos sintéticos · sin hardware"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "5 km/h")).firstMatch.exists
        )
        XCTAssertFalse(app.buttons["stopBelt"].isEnabled)
        capture(app, name: "phone-interactive-panel")
        let start = app.buttons["startBelt"]
        for _ in 0..<10 {
            if start.exists && start.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled)
        XCTAssertFalse(app.buttons["prepareControl"].isEnabled)
        app.collectionViews.firstMatch.swipeUp()
        capture(app, name: "phone-interactive-controls")
    }

    @MainActor
    func testFitShowComparisonKeepsRawUnitsAndBlockedControlVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        var fixture = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ftmsFixture().utf8)) as? [String: Any])
        fixture["interactive"] = [
            "selectedProtocol": "fitShowFFF0",
            "control": [
                "indicationReady": false, "permission": false, "stopAccepted": false,
                "requiresReconnect": false, "movementUncertain": false, "movementOutstanding": false,
                "message": "Fixture sintética; sin control de hardware.",
            ],
            "fitShow": [
                [
                    "channel": "fitShowFFF0", "serviceId": "synthetic-s",
                    "writeCharacteristicId": "synthetic-tx", "notifyCharacteristicId": "synthetic-rx",
                    "subscriptionStatus": "interrupted", "notificationCount": 5, "validFrameCount": 4,
                    "recognizedFrameCount": 4, "rejectedCount": 1, "rangeResponseEventId": "synthetic-range",
                    "statusEventId": "synthetic-status", "speedTenthsRaw": 20, "distanceCounterRaw": 5,
                    "lastHex": "02510314003C00050000000000502F03",
                ]
            ],
        ]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = String(
            data: try JSONSerialization.data(withJSONObject: fixture), encoding: .utf8)
        app.launch()
        app.buttons["openLivePanel"].tap()
        let blocked = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Control propietario bloqueado")
        ).firstMatch
        for _ in 0..<20 {
            if blocked.exists && blocked.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(blocked.exists)
        XCTAssertFalse(app.buttons["stopBelt"].isEnabled)
        capture(app, name: "phone-interactive-fitshow-accessibility")
        let raw = app.descendants(matching: .any).matching(identifier: "fitShowDistanceRaw").firstMatch
        for _ in 0..<20 {
            if raw.exists && raw.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(raw.exists)
        capture(app, name: "phone-interactive-comparison-accessibility")
    }
    @MainActor
    func testFTMSTelemetryAndCapabilitiesShowSyntheticEvidence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = ftmsFixture()
        app.launch()
        app.buttons["openBluetooth"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertTrue(app.staticTexts["Datos sintéticos · sin hardware"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "5 km/h")).firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "123 m")).firstMatch.exists)
        capture(app, name: "phone-ftms-telemetry-synthetic")
        let capabilities = app.buttons["openFTMSCapabilities"]
        for _ in 0..<4 {
            if capabilities.isHittable { break }
            app.swipeUp()
        }
        capabilities.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "12 km/h")).firstMatch
                .waitForExistence(timeout: 5))
        capture(app, name: "phone-ftms-ranges-synthetic")
        let speedControl = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Control de velocidad")
        ).firstMatch
        for _ in 0..<4 {
            if speedControl.exists && speedControl.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(speedControl.exists)
        capture(app, name: "phone-ftms-capabilities-synthetic")
    }

    @MainActor
    func testFTMSTelemetryWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] = ftmsFixture()
        app.launch()
        app.buttons["openBluetooth"].tap()
        let speed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "5 km/h"))
            .firstMatch
        for _ in 0..<10 {
            if speed.exists && speed.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(speed.exists)
        capture(app, name: "phone-ftms-accessibility-synthetic")
    }

    private func ftmsFixture() -> String {
        let timestamp = "2026-10-13T00:00:00.000Z"
        let fixture: [String: Any] = [
            "localPeripheralIdentifier": "synthetic", "inspectionId": "fixture",
            "advertisedName": "Caminadora sintética", "advertisement": [:], "selectedAt": timestamp,
            "source": "synthetic", "connectionState": "disconnected", "serviceDiscovery": "complete",
            "discoveryStatus": "complete",
            "telemetry": [
                "serviceId": "service", "characteristicId": "data", "startedAt": timestamp,
                "subscriptionOperationId": "subscription", "subscriptionStatus": "interrupted",
                "notificationCount": 1, "validSampleCount": 1, "invalidSampleCount": 0,
                "speed": ["value": 5, "unit": "km/h", "receivedAt": timestamp, "eventId": "sample"],
                "distance": ["value": 123, "unit": "m", "receivedAt": timestamp, "eventId": "sample"],
            ],
            "services": [
                [
                    "id": "service", "uuid": "1826", "isPrimary": true, "characteristicDiscovery": "complete",
                    "characteristics": [
                        [
                            "id": "features", "uuid": "2ACC", "properties": ["read"], "rawProperties": 2,
                            "descriptorDiscovery": "complete", "descriptors": [], "readStatus": "complete",
                            "valueHex": "0400000001000000", "ftmsFeatures": ["machineBits": 4, "targetBits": 1],
                        ],
                        [
                            "id": "range", "uuid": "2AD4", "properties": ["read"], "rawProperties": 2,
                            "descriptorDiscovery": "complete", "descriptors": [], "readStatus": "complete",
                            "ftmsRange": ["minimum": 1, "maximum": 12, "increment": 0.1, "unit": "km/h"],
                        ],
                        [
                            "id": "data", "uuid": "2ACD", "properties": ["notify"], "rawProperties": 16,
                            "descriptorDiscovery": "complete", "descriptors": [],
                        ],
                    ],
                ]
            ],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: fixture), encoding: .utf8)!
    }

    @MainActor
    func testSearchRemainsReachableWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        app.buttons["openBluetooth"].tap()
        let scan = app.buttons["scanDevices"]
        for _ in 0..<8 {
            if scan.exists && scan.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(scan.isHittable)
        capture(app, name: "phone-bluetooth-dark-large-controls")
    }

    @MainActor
    func testStoredInventoryShowsSourceServicesAndProperties() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"] =
            #"{"localPeripheralIdentifier":"synthetic","inspectionId":"fixture","advertisedName":"Caminadora de prueba","advertisement":{},"selectedAt":"2026-10-13T00:00:00.000Z","source":"synthetic","connectionState":"disconnected","serviceDiscovery":"complete","discoveryStatus":"complete","services":[{"id":"service","uuid":"1826","isPrimary":true,"characteristicDiscovery":"complete","characteristics":[{"id":"characteristic","uuid":"2ACD","properties":["notify"],"rawProperties":16,"descriptorDiscovery":"complete","descriptors":[{"id":"descriptor","uuid":"2902"}]}]}]}"#
        app.launch()
        app.buttons["openBluetooth"].tap()
        let syntheticLabel = app.staticTexts["Inventario sintético · sin hardware"]
        for _ in 0..<6 {
            if syntheticLabel.exists && syntheticLabel.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(
            app.staticTexts["Inventario sintético · sin hardware"].waitForExistence(timeout: 5))
        capture(app, name: "phone-bluetooth-inventory-synthetic")
        let service = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fitness Machine · FTMS")
        ).firstMatch
        for _ in 0..<8 {
            if service.exists && service.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(service.exists)
        service.tap()
        XCTAssertTrue(app.staticTexts["2ACD"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["notify"].exists)
        XCTAssertTrue(app.staticTexts["2902"].exists)
        capture(app, name: "phone-bluetooth-service-synthetic")
    }

    @MainActor
    func testBluetoothScreenStartsWithoutConnectingOrRequestingPermission() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["openBluetooth"].tap()
        XCTAssertTrue(app.buttons["scanDevices"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Listo para buscar"))
                .firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Bluetooth se activará al buscar."].exists)
        XCTAssertFalse(app.buttons["disconnectDevice"].exists)
        capture(app, name: "phone-bluetooth-empty")
    }

    @MainActor
    func testCreateNoteCloseAndPrepareExport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let start = app.buttons["startSession"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        capture(app, name: "phone-empty-light")
        start.tap()
        app.buttons["addNote"].tap()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Primera prueba de registro local.")
        app.buttons["saveNote"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Primera prueba de registro local."].waitForExistence(timeout: 5))
        capture(app, name: "phone-session-light")
        app.buttons["closeSession"].tap()
        let confirmClose = app.sheets.buttons["Finalizar sesión"]
        XCTAssertTrue(confirmClose.waitForExistence(timeout: 5))
        confirmClose.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Finalizada")).firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["exportDiagnostic"].tap()
        XCTAssertTrue(app.buttons["shareZIP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["manifest.json"].exists)
        capture(app, name: "phone-export-light")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
