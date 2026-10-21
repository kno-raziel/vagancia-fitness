import XCTest

@MainActor
final class VaganciaFitnessUITests: XCTestCase {
    func testHomeKeepsNativeHeaderVisibleWhileScrolling() {
        let app = launchCleanApp()
        assertHomeBrandInsideNavigationBar(app)
        capture(app, named: "home-header-light-top")
        app.swipeUp()
        assertHomeBrandInsideNavigationBar(app)
        capture(app, named: "home-header-light-scrolled")
    }

    func testIntervalControlsUseMachineStepsAndPersistWithoutKeyboard() {
        let app = launchCleanApp()
        app.tabBars.buttons["Programas"].tap()
        app.buttons["create-program"].tap()
        app.buttons["add-workout-interval"].tap()
        XCTAssertTrue(app.navigationBars["Intervalo"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(
            app.textFields.allElementsBoundByIndex.contains(where: \.isHittable),
            "Numeric targets should use bounded controls.")

        let minutes = app.pickerWheels.element(boundBy: 0)
        let seconds = app.pickerWheels.element(boundBy: 1)
        minutes.adjust(toPickerWheelValue: "2 min")
        seconds.adjust(toPickerWheelValue: "15 s")
        let speed = app.sliders["interval-speed-slider"]
        let speedStepper = app.steppers.matching(identifier: "interval-speed-stepper").firstMatch
        speed.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(numericValue(speedStepper), 0.8, accuracy: 0.001)
        speedStepper.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(
            numericValue(speedStepper), 0.8, accuracy: 0.001,
            "Decrement must stay within the announced minimum.")
        speed.adjust(toNormalizedSliderPosition: 1)
        // XCTest's drag may stop a few points short of the native thumb's end.
        for _ in 0..<5 where numericValue(speedStepper) < 16 {
            speedStepper.buttons.element(boundBy: 1).tap()
        }
        XCTAssertEqual(numericValue(speedStepper), 16, accuracy: 0.001)
        speedStepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(
            numericValue(speedStepper), 16, accuracy: 0.001,
            "Increment must stay within the announced maximum.")
        speed.adjust(toNormalizedSliderPosition: 0.25)
        let before = numericValue(speedStepper)
        speedStepper.buttons.element(boundBy: 1).tap()
        let savedSpeed = numericValue(speedStepper)
        XCTAssertEqual(savedSpeed - before, 0.1, accuracy: 0.001)

        let incline = app.sliders["interval-incline-slider"]
        for _ in 0..<3 where !incline.isHittable { app.swipeUp() }
        let inclineStepper = app.steppers.matching(identifier: "interval-incline-stepper").firstMatch
        incline.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(numericValue(inclineStepper), 0, accuracy: 0.001)
        inclineStepper.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(numericValue(inclineStepper), 0, accuracy: 0.001)
        inclineStepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(numericValue(inclineStepper), 1, accuracy: 0.001)
        capture(app, named: "interval-native-controls-light")
        app.buttons["save-interval"].tap()
        app.buttons["save-program"].tap()
        app.staticTexts["Mi programa"].tap()
        app.buttons["Opciones del programa"].tap()
        app.buttons["Editar programa"].tap()
        app.buttons["Acciones de etapa 2"].tap()
        app.buttons["Editar"].tap()
        XCTAssertTrue(app.navigationBars["Intervalo"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            numericValue(app.steppers.matching(identifier: "interval-speed-stepper").firstMatch),
            savedSpeed, accuracy: 0.001)
        XCTAssertEqual(app.pickerWheels.element(boundBy: 0).value as? String, "2 min")
        XCTAssertEqual(app.pickerWheels.element(boundBy: 1).value as? String, "15 s")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testHeaderAndIntervalControlsWithDarkAccessibilityText() {
        let app = launchCleanApp(arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark",
        ])
        XCTAssertTrue(app.navigationBars["VAGANCIA FITNESS"].waitForExistence(timeout: 5))
        capture(app, named: "home-header-dark-accessibility-top")
        app.swipeUp()
        assertHomeBrandInsideNavigationBar(app)
        capture(app, named: "home-header-dark-accessibility-scrolled")
        app.tabBars.buttons["Programas"].tap()
        let create = app.buttons["create-program"]
        for _ in 0..<6 where !create.isHittable { app.swipeUp() }
        create.tap()
        app.buttons["add-workout-interval"].tap()
        XCTAssertTrue(app.navigationBars["Intervalo"].waitForExistence(timeout: 5))
        capture(app, named: "interval-native-controls-dark-accessibility-top")
        let incline = app.sliders["interval-incline-slider"]
        for _ in 0..<8 where !incline.isHittable {
            // A central swipe lands on the duration wheel at accessibility
            // sizes. Drag the form's gutter instead of spinning that picker.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(incline.isHittable)
        XCTAssertTrue(app.buttons["save-interval"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, named: "interval-native-controls-dark-accessibility-scrolled")
    }

    func testLandscapeHeaderAndManualSheetKeepStopAvailable() {
        let app = launchCleanApp()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["home-device-connection"].isHittable)
        assertHomeBrandInsideNavigationBar(app)
        capture(app, named: "product-home-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.tabBars.buttons["Ajustes"].tap()
        enableDemoMode(in: app)
        app.tabBars.buttons["Inicio"].tap()
        app.buttons["start-free-workout"].tap()
        app.buttons["confirm-workout-start"].tap()
        XCTAssertTrue(app.buttons["stop-workout"].waitForExistence(timeout: 8))
        app.buttons["Ajustar velocidad e inclinación"].tap()
        let stop = app.buttons["stop-workout-sheet"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isHittable)
        capture(app, named: "product-manual-sheet")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Sesión guardada"].waitForExistence(timeout: 8))
        app.swipeUp()
        app.buttons["Volver a Actividad"].tap()
        XCTAssertTrue(app.staticTexts["Historial"].waitForExistence(timeout: 5))
    }

    func testPrimaryTabsAndEmptyHistoryNavigate() {
        let app = launchCleanApp()

        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Programas"].tap()
        XCTAssertTrue(app.navigationBars["Programas"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Actividad"].tap()
        XCTAssertTrue(app.staticTexts["Tu historia empieza aquí"].waitForExistence(timeout: 3))
        app.buttons["Explorar programas"].tap()
        XCTAssertTrue(app.navigationBars["Programas"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Ajustes"].tap()
        XCTAssertTrue(app.navigationBars["Ajustes"].waitForExistence(timeout: 3))
        let mockMode = app.switches["settings-mock-mode"]
        let mockMetrics = app.switches["settings-mock-metrics"]
        XCTAssertTrue(mockMode.exists)
        XCTAssertTrue(mockMetrics.exists)
        XCTAssertEqual(mockMode.value as? String, "0")
        XCTAssertEqual(mockMetrics.value as? String, "1")
        mockMetrics.tap()
        XCTAssertEqual(
            mockMode.value as? String, "0", "Example metrics are independent from treadmill simulation.")
    }

    func testProgramFilterDetailAndExplicitStartPreview() {
        let app = launchCleanApp()
        app.tabBars.buttons["Programas"].tap()

        XCTAssertTrue(app.buttons["program-essential"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["program-steady"].exists)
        app.buttons["Hasta 20 min"].tap()
        XCTAssertTrue(app.buttons["program-essential"].exists)
        XCTAssertFalse(app.buttons["program-steady"].exists)
        app.buttons["program-essential"].tap()

        XCTAssertTrue(app.buttons["start-program"].waitForExistence(timeout: 3))
        app.buttons["start-program"].tap()
        XCTAssertTrue(app.buttons["prepare-workout-transport"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["confirm-workout-start"].exists)
        XCTAssertFalse(
            app.staticTexts["EN CURSO"].exists, "Opening the preview must not start or command movement.")
        app.buttons["prepare-workout-transport"].tap()
        XCTAssertTrue(app.navigationBars["Tu equipo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirm-workout-start"].exists)
    }

    func testProgramEditorOpensWithoutStartingWorkout() {
        let app = launchCleanApp()
        app.tabBars.buttons["Programas"].tap()
        app.buttons["create-program"].tap()

        XCTAssertTrue(app.navigationBars["Editar programa"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["program-name-field"].exists)
        XCTAssertTrue(app.buttons["add-workout-interval"].exists)
        XCTAssertTrue(app.buttons["save-program"].exists)
        XCTAssertFalse(app.buttons["confirm-workout-start"].exists)
    }

    func testProgramEditPersistsAcrossLaunches() {
        let app = launchCleanApp()
        app.tabBars.buttons["Programas"].tap()
        app.buttons["create-program"].tap()
        let name = app.textFields["program-name-field"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        replaceText(name, with: "Plan editado")
        app.buttons["save-program"].tap()
        XCTAssertTrue(app.staticTexts["Plan editado"].waitForExistence(timeout: 3))

        // Open the new program from its visible row, edit it, then relaunch to
        // exercise the repository-backed persistence path.
        app.staticTexts["Plan editado"].tap()
        app.buttons["Opciones del programa"].tap()
        app.buttons["Editar programa"].tap()
        let editedName = app.textFields["program-name-field"]
        replaceText(editedName, with: "Plan persistente")
        app.buttons["save-program"].tap()
        XCTAssertTrue(app.staticTexts["Plan persistente"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(es)", "-AppleLocale", "es_CR"]
        app.launch()
        app.tabBars.buttons["Programas"].tap()
        XCTAssertTrue(app.staticTexts["Plan persistente"].waitForExistence(timeout: 5))
    }

    func testMockWorkoutFinishAndExportNeverNeedsBluetooth() {
        let app = launchCleanApp()
        app.tabBars.buttons["Ajustes"].tap()
        enableDemoMode(in: app)
        app.tabBars.buttons["Inicio"].tap()
        app.buttons["start-free-workout"].tap()

        XCTAssertTrue(app.buttons["confirm-workout-start"].waitForExistence(timeout: 3))
        app.buttons["confirm-workout-start"].tap()
        XCTAssertTrue(app.buttons["finish-workout"].waitForExistence(timeout: 8))
        app.buttons["finish-workout"].tap()
        confirmFinish(in: app)

        XCTAssertTrue(app.staticTexts["Sesión guardada"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Distancia registrada"].exists)
        XCTAssertTrue(app.buttons["Compartir JSON"].exists)
        XCTAssertTrue(app.buttons["share-workout-image"].exists)
        let exportZIP = app.buttons["export-workout-zip"]
        for _ in 0..<4 where !exportZIP.isHittable { app.swipeUp() }
        exportZIP.tap()
        let completeExport = app.buttons.matching(identifier: "export-workout-complete").firstMatch
        XCTAssertTrue(completeExport.waitForExistence(timeout: 3))
        completeExport.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "workout-system-share-sheet").firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Compartir archivo"].exists)
    }

    func testCaptureProductScreensAcrossThePrimaryFlows() {
        let app = launchCleanApp(language: "en", region: "US")
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 5))
        capture(app, named: "product-home")

        app.tabBars.buttons["Settings"].tap()
        enableDemoMode(in: app)
        app.tabBars.buttons["Programs"].tap()
        capture(app, named: "product-programs")

        app.buttons["program-essential"].tap()
        capture(app, named: "product-program-detail")
        app.buttons["Program options"].tap()
        app.buttons["Edit program"].tap()
        XCTAssertTrue(app.navigationBars["Edit program"].waitForExistence(timeout: 3))
        capture(app, named: "product-program-editor")
        app.buttons["Cancel"].tap()
        app.buttons["Discard changes"].tap()

        app.buttons["start-program"].tap()
        XCTAssertTrue(app.buttons["confirm-workout-start"].waitForExistence(timeout: 3))
        capture(app, named: "product-workout-preview")
        app.buttons["confirm-workout-start"].tap()
        XCTAssertTrue(app.buttons["finish-workout"].waitForExistence(timeout: 8))
        sleep(2)
        capture(app, named: "product-active-workout")
        app.buttons["finish-workout"].tap()
        confirmFinish(in: app)
        XCTAssertTrue(app.staticTexts["Session saved"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "speed-source-legend-mock").firstMatch
                .exists)
        capture(app, named: "product-workout-summary")

        app.swipeUp()
        XCTAssertTrue(app.buttons["Back to Activity"].waitForExistence(timeout: 3))
        app.buttons["Back to Activity"].tap()
        XCTAssertTrue(app.tabBars.buttons["Activity"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
        capture(app, named: "product-activity")
        app.tabBars.buttons["Settings"].tap()
        capture(app, named: "product-settings")
    }

    func testDarkLargeTypeWorkoutControlsRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-AppleLanguages", "(es)", "-AppleLocale", "es_CR",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launchEnvironment["VAGANCIAFITNESS_DATA_DIRECTORY"] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("VaganciaFitnessUITests-Dark-\(UUID().uuidString)", isDirectory: true)
            .path
        app.launch()
        app.tabBars.buttons["Ajustes"].tap()
        enableDemoMode(in: app)
        app.tabBars.buttons["Inicio"].tap()
        app.buttons["start-free-workout"].tap()
        app.buttons["confirm-workout-start"].tap()
        let stop = app.buttons["stop-workout"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        XCTAssertTrue(stop.isHittable)
        XCTAssertTrue(app.buttons["add-workout-note"].isHittable)
        capture(app, named: "product-active-workout-dark-accessibility-xxxl")
        app.buttons["add-workout-note"].tap()
        let noteField = app.descendants(matching: .any).matching(identifier: "workout-note-field")
            .firstMatch
        XCTAssertTrue(noteField.waitForExistence(timeout: 3))
        noteField.tap()
        noteField.typeText("Nota de accesibilidad")
        app.buttons["Guardar"].tap()
        XCTAssertFalse(
            app.alerts["No se pudo completar el control"].waitForExistence(timeout: 1),
            "Saving a note should not raise a workout-control error.")
        app.buttons["finish-workout"].tap()
        confirmFinish(in: app)
        XCTAssertTrue(app.staticTexts["Sesión guardada"].waitForExistence(timeout: 8))
        let measured = app.staticTexts["Medido"]
        for _ in 0..<12 where !measured.isHittable { app.swipeUp() }
        capture(app, named: "product-summary-accessibility-provenance-values")
        app.swipeUp()
        capture(app, named: "product-summary-accessibility-provenance-sources")
        let note = app.staticTexts["Nota de accesibilidad"]
        XCTAssertTrue(
            note.waitForExistence(timeout: 3), "The saved note must survive workout finalization.")
        for _ in 0..<12 where !note.isHittable { app.swipeUp() }
        XCTAssertTrue(note.isHittable)
        capture(app, named: "product-workout-summary-dark-accessibility-xxxl")
        app.swipeUp()
        app.buttons["Volver a Actividad"].tap()
        app.tabBars.buttons["Ajustes"].tap()
        XCTAssertTrue(app.navigationBars["Ajustes"].waitForExistence(timeout: 5))
        capture(app, named: "product-settings-dark-accessibility-xxxl")
    }

    func testEnglishNavigationProgramWatchWorkoutAndImageShare() {
        let app = launchCleanApp(language: "en", region: "US")
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        capture(app, named: "localization-en-home")
        app.tabBars.buttons["Programs"].tap()
        XCTAssertTrue(app.buttons["program-essential"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Essential intervals"].exists)
        capture(app, named: "localization-en-programs")
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings-watch"].tap()
        XCTAssertTrue(app.navigationBars["Apple Watch"].waitForExistence(timeout: 5))
        capture(app, named: "localization-en-watch")
        app.navigationBars.buttons.firstMatch.tap()
        enableDemoMode(in: app)
        app.tabBars.buttons["Home"].tap()
        app.buttons["start-free-workout"].tap()
        app.buttons["confirm-workout-start"].tap()
        XCTAssertTrue(app.buttons["finish-workout"].waitForExistence(timeout: 8))
        sleep(2)
        XCTAssertTrue(app.staticTexts["elapsed"].exists)
        capture(app, named: "localization-en-workout")
        app.buttons["finish-workout"].tap()
        app.buttons.matching(identifier: "confirm-finish-workout").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Session saved"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "speed-source-legend-mock").firstMatch
                .exists)
        XCTAssertTrue(app.buttons["share-workout-image"].exists)
        capture(app, named: "localization-en-summary")
        app.buttons["share-workout-image"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "workout-system-share-sheet").firstMatch
                .waitForExistence(timeout: 5))
        capture(app, named: "localization-en-share-image")
    }

    func testWatchSetupIsActionableWithoutStartingAWorkout() {
        let app = launchCleanApp()
        app.tabBars.buttons["Ajustes"].tap()
        let link = app.buttons["settings-watch"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Apple Watch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["watch-review-health"].exists)
        XCTAssertFalse(app.buttons["confirm-workout-start"].exists)
        XCTAssertFalse(app.buttons["search-treadmill"].exists)
        XCTAssertTrue(app.staticTexts["Sin emparejar con iOS"].exists)
        XCTAssertTrue(app.staticTexts["App pendiente de instalar"].exists)
        capture(app, named: "watch-setup-native")
    }

    func testSettingsRowsKeepTheirGeometryDuringFourHertzDelayedWrites() {
        let app = launchCleanApp(arguments: ["--ui-test-settings-writes-4hz"])
        app.tabBars.buttons["Ajustes"].tap()
        let export = app.buttons["settings-export-diagnostic"]
        let clear = app.buttons["clear-app-data"]
        let toggle = app.buttons["settings-toggle-diagnostic-fixture"]
        let writeState = app.descendants(matching: .any).matching(identifier: "settings-write-state")
            .firstMatch
        XCTAssertTrue(writeState.waitForExistence(timeout: 5))
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for _ in 0..<5 where !clear.isHittable { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(writeState.value as? String, "Al día")
        let exportY = export.frame.minY
        let clearY = clear.frame.minY
        capture(app, named: "settings-4hz-before")
        toggle.tap()
        let writing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Guardando"), object: writeState)
        XCTAssertEqual(
            XCTWaiter.wait(for: [writing], timeout: 4), .completed,
            "The controlled fixture must exercise the delayed SQLite writer.")
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            XCTAssertTrue(writeState.exists, "The diagnostic row must remain in the Form.")
            XCTAssertEqual(
                writeState.value as? String, "Guardando",
                "The producer must still be active while measuring.")
            XCTAssertEqual(
                export.frame.minY, exportY, accuracy: 1,
                "Export moved while 4 Hz evidence entered the delayed writer.")
            XCTAssertEqual(
                clear.frame.minY, clearY, accuracy: 1,
                "Delete moved while pending writes rose or drained.")
        }
        capture(app, named: "settings-4hz-writing")
        toggle.tap()
        let drained = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Al día"), object: writeState)
        XCTAssertEqual(
            XCTWaiter.wait(for: [drained], timeout: 20), .completed,
            "The delayed writer should drain after the producer stops.")
        XCTAssertEqual(export.frame.minY, exportY, accuracy: 1)
        XCTAssertEqual(clear.frame.minY, clearY, accuracy: 1)
        capture(app, named: "settings-4hz-after")
    }

    func testWatchConflictResolutionKeepsIndependentAccessFacts() {
        let app = launchCleanApp(arguments: ["--ui-test-watch-conflict"])
        app.tabBars.buttons["Ajustes"].tap()
        app.buttons["settings-watch"].tap()
        let reviewed = app.descendants(matching: .any).matching(identifier: "watch-access-reviewed")
            .firstMatch
        let canSave = app.descendants(matching: .any).matching(identifier: "watch-can-save-workout")
            .firstMatch
        let conflict = app.descendants(matching: .any).matching(
            identifier: "watch-orphaned-preparation"
        ).firstMatch
        XCTAssertTrue(reviewed.waitForExistence(timeout: 5))
        XCTAssertTrue(canSave.waitForExistence(timeout: 5))
        XCTAssertTrue(reviewed.label.contains("Acceso a Salud revisado"))
        XCTAssertTrue(canSave.label.contains("Watch no puede guardar entrenamientos"))
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Escenario sintético de prueba"].exists)
        let resolve = app.buttons["watch-resolve-orphaned-preparation"]
        for _ in 0..<8 where !resolve.isHittable { app.swipeUp() }
        XCTAssertTrue(resolve.isHittable)
        capture(app, named: "watch-conflict-fixture-before")
        resolve.tap()
        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: conflict)
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 5), .completed)
        XCTAssertTrue(reviewed.label.contains("Acceso a Salud revisado"))
        XCTAssertTrue(canSave.label.contains("Watch no puede guardar entrenamientos"))
        XCTAssertFalse(app.buttons["confirm-workout-start"].exists)
        capture(app, named: "watch-conflict-fixture-after")
    }

    func testWatchAccessFactsBecomeVisiblyStaleWithoutChangingConflict() {
        let app = launchCleanApp(arguments: ["--ui-test-watch-conflict", "--ui-test-watch-stale"])
        app.tabBars.buttons["Ajustes"].tap()
        app.buttons["settings-watch"].tap()
        let reviewed = app.descendants(matching: .any).matching(identifier: "watch-access-reviewed")
            .firstMatch
        let canSave = app.descendants(matching: .any).matching(identifier: "watch-can-save-workout")
            .firstMatch
        XCTAssertTrue(reviewed.waitForExistence(timeout: 5))
        XCTAssertTrue(canSave.waitForExistence(timeout: 5))
        XCTAssertTrue(reviewed.label.contains("Revisión de acceso por actualizar"))
        XCTAssertTrue(canSave.label.contains("Guardado en Salud por actualizar"))
        XCTAssertTrue(reviewed.label.contains("desactualizado"))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "watch-orphaned-preparation").firstMatch
                .exists)
        capture(app, named: "watch-stale-access-fixture")
    }

    func testDiagnosticExportWorksBeforeWorkoutAndAfterClosingPreview() {
        let app = launchCleanApp()
        app.buttons["start-free-workout"].tap()
        XCTAssertTrue(app.buttons["prepare-workout-transport"].waitForExistence(timeout: 5))
        app.buttons["Cerrar vista previa"].tap()
        app.tabBars.buttons["Programas"].tap()
        app.buttons["program-essential"].tap()
        app.buttons["start-program"].tap()
        XCTAssertTrue(app.buttons["prepare-workout-transport"].waitForExistence(timeout: 5))
        app.buttons["Cerrar vista previa"].tap()
        app.tabBars.buttons["Ajustes"].tap()
        let export = app.buttons["settings-export-diagnostic"]
        for _ in 0..<6 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isEnabled)
        export.tap()
        let completeExport = app.buttons.matching(identifier: "export-diagnostic-complete").firstMatch
        XCTAssertTrue(completeExport.waitForExistence(timeout: 3))
        completeExport.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "share-diagnostic-zip").firstMatch
                .waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["VAGANCIA FITNESS"].exists)
        capture(app, named: "diagnostic-export-before-workout")
    }

    func testStopKeepsSummaryUntilExplicitReturnAndImageOpensShareSheet() {
        let app = launchCleanApp()
        app.tabBars.buttons["Ajustes"].tap()
        enableDemoMode(in: app)
        app.tabBars.buttons["Inicio"].tap()
        app.buttons["start-free-workout"].tap()
        app.buttons["confirm-workout-start"].tap()
        let stop = app.buttons["stop-workout"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Sesión guardada"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            app.staticTexts["Sesión guardada"].exists, "The summary must remain after Stop returns.")
        XCTAssertFalse(app.tabBars.buttons["Actividad"].isHittable)
        capture(app, named: "product-stop-summary-083")
        let back = app.buttons["Volver a Actividad"]
        for _ in 0..<8 where !back.isHittable { app.swipeUp() }
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["Historial"].waitForExistence(timeout: 5))
        app.staticTexts["Entrenamiento libre"].firstMatch.tap()
        let share = app.buttons["share-workout-image"]
        for _ in 0..<8 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable)
        share.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "workout-system-share-sheet").firstMatch
                .waitForExistence(timeout: 5))
        capture(app, named: "product-image-system-share-083")
    }

    func testNaturalProgramEndKeepsSummaryUntilReturn() {
        let app = launchCleanApp(arguments: ["--ui-test-natural-end"])
        XCTAssertTrue(app.staticTexts["Sesión guardada"].waitForExistence(timeout: 28))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.staticTexts["Sesión guardada"].exists)
        XCTAssertFalse(app.tabBars.buttons["Actividad"].isHittable)
        capture(app, named: "product-natural-end-summary-083")
        let back = app.buttons["Volver a Actividad"]
        for _ in 0..<8 where !back.isHittable { app.swipeUp() }
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["Historial"].waitForExistence(timeout: 5))
    }

    private func launchCleanApp(
        arguments: [String] = [], language: String = "es", region: String = "CR"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_\(region)"]
            + arguments
        app.launchEnvironment["VAGANCIAFITNESS_DATA_DIRECTORY"] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("VaganciaFitnessUITests-\(UUID().uuidString)", isDirectory: true).path
        app.launch()
        return app
    }

    private func numericValue(_ element: XCUIElement) -> Double {
        let value = (element.value as? String ?? "").replacingOccurrences(of: ",", with: ".")
        return Double(value.split(separator: " ").first ?? "") ?? .nan
    }

    private func assertHomeBrandInsideNavigationBar(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let brand = app.descendants(matching: .any).matching(identifier: "home-brand").firstMatch
        XCTAssertTrue(brand.waitForExistence(timeout: 5), file: file, line: line)
        let bar = app.navigationBars["VAGANCIA FITNESS"]
        XCTAssertGreaterThan(brand.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(brand.frame.minY, bar.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(brand.frame.maxY, bar.frame.maxY + 1, file: file, line: line)
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }

    private func enableDemoMode(in app: XCUIApplication) {
        let demoSwitch = app.switches["settings-mock-mode"]
        XCTAssertTrue(demoSwitch.waitForExistence(timeout: 5))
        for _ in 0..<5
        where !demoSwitch.isHittable || demoSwitch.frame.maxY > app.tabBars.firstMatch.frame.minY {
            app.swipeUp()
        }
        if demoSwitch.value as? String != "1" {
            demoSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let enabled = NSPredicate(format: "value == '1'")
        expectation(for: enabled, evaluatedWith: demoSwitch)
        waitForExpectations(timeout: 3)
    }

    private func confirmFinish(in app: XCUIApplication) {
        let finishButton = app.buttons.matching(identifier: "confirm-finish-workout").firstMatch
        XCTAssertTrue(
            finishButton.waitForExistence(timeout: 5),
            "Show the finish confirmation before ending the session.")
        let title = app.staticTexts["Finalizar y guardar esta sesión?"]
        if title.waitForExistence(timeout: 1) { XCTAssertTrue(title.exists) }
        finishButton.tap()
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
