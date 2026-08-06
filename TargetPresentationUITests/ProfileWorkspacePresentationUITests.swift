import XCTest

final class ProfileWorkspacePresentationUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 60
    }

    private enum Scenario: String {
        case saveFailureThenSuccess = "save-failure-then-success"
        case persistedReadDiscardFailure = "persisted-read-discard-failure"
        case successfulDiscard = "successful-discard"
        case importCandidateReturn = "import-candidate-return"
        case subscriptionCandidateReturn = "subscription-candidate-return"
        case emptyWorkspace = "empty-workspace"
        case localProfile = "local-profile"
        case remoteProfile = "remote-profile"
        case dirtyEditor = "dirty-editor"
        case invalidDiagnostic = "invalid-diagnostic"
        case subscriptionBusy = "subscription-busy"
    }

    func testSaveFailureThenRecoveryAndSuccess() {
        let app = launch(.saveFailureThenSuccess)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)
        selectSecondProfile(in: app)
        assertUnsavedAlert(
            pendingOperation: "select-second",
            generation: initialPresentationGeneration + 1,
            in: app
        )

        clickButton("profile.unsaved.save-and-continue", in: app)
        let recoveredPresentationGeneration = initialPresentationGeneration + 2
        assertUnsavedAlert(
            pendingOperation: "select-second",
            generation: recoveredPresentationGeneration,
            in: app
        )
        XCTAssertEqual(state("presentation.selected-profile", in: app), "First Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "fixture-dirty")
        XCTAssertEqual(state("presentation.dirty", in: app), "true")
        XCTAssertEqual(state("presentation.pending-operation", in: app), "select-second")
        XCTAssertEqual(integerState("presentation.generation", in: app), recoveredPresentationGeneration)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)
        XCTAssertEqual(state("presentation.active-presentation", in: app), "active")
        assertStateRemains(
            "presentation.generation",
            value: "\(recoveredPresentationGeneration)",
            for: 1,
            in: app
        )

        clickButton("profile.unsaved.save-and-continue", in: app)
        waitForUnsavedAlertToDisappear(in: app)
        XCTAssertEqual(state("presentation.selected-profile", in: app), "Second Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "second-persisted")
        XCTAssertEqual(state("presentation.dirty", in: app), "false")
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.active-presentation", in: app), "inactive")
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration + 2)
        XCTAssertEqual(state("presentation.profile-count", in: app), "2")
    }

    func testPersistedReadDiscardFailureThenCancel() {
        let app = launch(.persistedReadDiscardFailure)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)
        selectSecondProfile(in: app)
        assertUnsavedAlert(
            pendingOperation: "select-second",
            generation: initialPresentationGeneration + 1,
            in: app
        )
        clickButton("profile.unsaved.discard", in: app)
        assertUnsavedAlert(
            pendingOperation: "select-second",
            generation: initialPresentationGeneration + 2,
            in: app
        )
        XCTAssertEqual(state("presentation.selected-profile", in: app), "First Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "fixture-dirty")
        XCTAssertEqual(state("presentation.dirty", in: app), "true")
        XCTAssertEqual(state("presentation.pending-operation", in: app), "select-second")
        XCTAssertEqual(integerState("presentation.generation", in: app), initialPresentationGeneration + 2)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)

        clickButton("profile.unsaved.cancel", in: app)
        waitForUnsavedAlertToDisappear(in: app)
        activateIfNeeded(app)
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.selected-profile", in: app), "First Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "fixture-dirty")
        XCTAssertEqual(state("presentation.dirty", in: app), "true")
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)
    }

    func testSuccessfulDiscardExecutesSelectionOnce() {
        let app = launch(.successfulDiscard)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)
        selectSecondProfile(in: app)
        assertUnsavedAlert(
            pendingOperation: "select-second",
            generation: initialPresentationGeneration + 1,
            in: app
        )
        clickButton("profile.unsaved.discard", in: app)
        waitForUnsavedAlertToDisappear(in: app)
        XCTAssertEqual(state("presentation.selected-profile", in: app), "Second Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "second-persisted")
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.dirty", in: app), "false")
        XCTAssertEqual(state("presentation.active-presentation", in: app), "inactive")
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration + 1)
        XCTAssertEqual(state("presentation.profile-count", in: app), "2")
    }

    func testImportCandidateReturnsAfterFailedSaveAndCancel() {
        let app = launch(.importCandidateReturn)
        assertExists(element("profile.import.confirmation", in: app), message: "Missing import confirmation")
        let candidateFingerprint = state("presentation.import-candidate-fingerprint", in: app)
        let initialRevision = state("presentation.selected-revision", in: app)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)
        XCTAssertEqual(state("presentation.import-candidate", in: app), "true")
        clickButton("profile.import.confirm", in: app)
        assertDoesNotExist(element("profile.import.confirmation", in: app), message: "Import confirmation did not dismiss")
        waitForState("presentation.import-confirmation-presented", toEqual: "false", in: app)
        assertUnsavedAlert(
            pendingOperation: "import-candidate",
            generation: initialPresentationGeneration + 1,
            in: app
        )
        clickButton("profile.unsaved.save-and-continue", in: app)
        assertUnsavedAlert(
            pendingOperation: "import-candidate",
            generation: initialPresentationGeneration + 2,
            in: app
        )
        clickButton("profile.unsaved.cancel", in: app)
        waitForUnsavedAlertToDisappear(in: app)
        waitForState("presentation.pending-operation", toEqual: "none", in: app)
        waitForState("presentation.import-confirmation-presented", toEqual: "true", in: app)
        assertExists(element("profile.import.confirmation", in: app), message: "Import confirmation did not return")
        XCTAssertEqual(state("presentation.import-candidate", in: app), "true")
        XCTAssertEqual(state("presentation.import-candidate-fingerprint", in: app), candidateFingerprint)
        XCTAssertEqual(state("presentation.selected-revision", in: app), initialRevision)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.profile-count", in: app), "2")
    }

    func testSubscriptionCandidateReturnsAfterFailedSaveAndCancel() {
        let app = launch(.subscriptionCandidateReturn)
        assertExists(element("profile.subscription.preview", in: app), message: "Missing subscription preview")
        let candidateFingerprint = state("presentation.subscription-candidate-fingerprint", in: app)
        let initialRevision = state("presentation.selected-revision", in: app)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)
        XCTAssertEqual(state("presentation.subscription-candidate", in: app), "true")
        clickButton("profile.subscription.confirm", in: app)
        assertDoesNotExist(element("profile.subscription.preview", in: app), message: "Subscription preview did not dismiss")
        waitForState("presentation.subscription-preview-presented", toEqual: "false", in: app)
        assertUnsavedAlert(
            pendingOperation: "apply-subscription",
            generation: initialPresentationGeneration + 1,
            in: app
        )
        clickButton("profile.unsaved.save-and-continue", in: app)
        assertUnsavedAlert(
            pendingOperation: "apply-subscription",
            generation: initialPresentationGeneration + 2,
            in: app
        )
        clickButton("profile.unsaved.cancel", in: app)
        waitForUnsavedAlertToDisappear(in: app)
        waitForState("presentation.pending-operation", toEqual: "none", in: app)
        waitForState("presentation.subscription-preview-presented", toEqual: "true", in: app)
        assertExists(element("profile.subscription.preview", in: app), message: "Subscription preview did not return")
        XCTAssertEqual(state("presentation.subscription-candidate", in: app), "true")
        XCTAssertEqual(state("presentation.subscription-candidate-fingerprint", in: app), candidateFingerprint)
        XCTAssertEqual(state("presentation.selected-revision", in: app), initialRevision)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.profile-count", in: app), "2")
    }

    func testVisualWorkspaceStatesRemainReachableAtMinimumAndRegularWidths() {
        assertVisualState(.emptyWorkspace, size: "740x511", expectsEditor: false)
        assertVisualState(.localProfile, size: "740x511", expectsEditor: true)
        assertVisualState(.remoteProfile, size: "740x511", expectsEditor: true)
        assertVisualState(.dirtyEditor, size: "740x511", expectsEditor: true)
        assertVisualState(.invalidDiagnostic, size: "740x511", expectsEditor: true)
        assertVisualState(.subscriptionBusy, size: "740x511", expectsEditor: true)
        assertVisualState(.localProfile, size: "950x670", expectsEditor: true)
        assertVisualState(.remoteProfile, size: "950x670", expectsEditor: true)
    }

    private func launch(_ scenario: Scenario) -> XCUIApplication {
        launch(scenario, windowSize: nil, activates: true)
    }

    private func launch(_ scenario: Scenario, windowSize: String?, activates: Bool) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.jason312928.TargetPresentationTestHost")
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSAutomaticTextCompletionEnabled", "NO",
            "--presentation-scenario", scenario.rawValue
        ]
        if let windowSize {
            app.launchArguments += ["--presentation-window-size", windowSize]
        }
        app.launch()
        assertExists(app.windows.firstMatch, message: "Presentation host window did not appear")
        if activates { activateIfNeeded(app) }
        waitForState("presentation.scenario", toEqual: scenario.rawValue, in: app)
        addTeardownBlock {
            if app.state != .notRunning {
                let sheet = app.sheets.firstMatch
                if sheet.exists {
                    app.typeKey(.escape, modifierFlags: [])
                    _ = sheet.waitForNonExistence(timeout: 2)
                }
                app.typeKey("q", modifierFlags: .command)
                if !app.wait(for: .notRunning, timeout: 5) {
                    app.terminate()
                }
            }
            self.cleanUpPresentationFixtures()
        }
        return app
    }

    private func assertVisualState(_ scenario: Scenario, size: String, expectsEditor: Bool) {
        let app = launch(scenario, windowSize: size, activates: false)
        XCTAssertFalse(app.sheets.firstMatch.exists, "\(scenario) unexpectedly opened a sheet")
        XCTAssertFalse(app.alerts.firstMatch.exists, "\(scenario) unexpectedly opened an alert")

        if expectsEditor {
            assertVisibleInsideWindow(app.staticTexts["profile.summary.name"], in: app, message: "Missing summary for \(scenario)")
            let editor = app.scrollViews["profile.json-editor.scroll"]
            assertVisibleInsideWindow(editor, in: app, message: "Missing JSON editor for \(scenario)")
            assertVisibleInsideWindow(button("Format", in: app), in: app, message: "Format is inaccessible for \(scenario)")
            assertVisibleInsideWindow(button("Validate & Save", in: app), in: app, message: "Save is inaccessible for \(scenario)")
            assertVisibleInsideWindow(app.menuButtons["More Actions"], in: app, message: "Secondary actions are inaccessible for \(scenario)")
        } else {
            assertVisibleInsideWindow(app.staticTexts["profile.workspace.empty"], in: app, message: "Missing empty workspace state")
        }

        if scenario == .subscriptionBusy {
            assertVisibleInsideWindow(button("Cancel Update", in: app), in: app, message: "Missing subscription cancellation")
        }
    }

    private func selectSecondProfile(in app: XCUIApplication) {
        let id = state("presentation.second-profile-id", in: app)
        let second = app.descendants(matching: .any)["profile.row.\(id)"]
        assertExists(second, message: "Missing second Profile row")
        activateIfNeeded(app)
        second.click()
    }

    private func assertUnsavedAlert(
        pendingOperation: String,
        generation: Int,
        in app: XCUIApplication
    ) {
        waitForState("presentation.pending-operation", toEqual: pendingOperation, in: app)
        waitForState("presentation.active-presentation", toEqual: "active", in: app)
        waitForState("presentation.generation", toEqual: "\(generation)", in: app)
        activateIfNeeded(app)
        _ = requireButton("profile.unsaved.save-and-continue", in: app)
        let title = app.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value == %@", "Keep unsaved changes?"))
            .firstMatch
        assertExists(title, message: "Missing unsaved Alert title")
    }

    private func waitForUnsavedAlertToDisappear(in app: XCUIApplication) {
        assertDoesNotExist(
            button("profile.unsaved.save-and-continue", in: app),
            message: "Unsaved Alert did not disappear"
        )
    }

    private func state(_ identifier: String, in app: XCUIApplication) -> String {
        let element = app.staticTexts[identifier]
        assertExists(element, message: "Missing state probe \(identifier)")
        return element.value as? String ?? ""
    }

    private func integerState(_ identifier: String, in app: XCUIApplication) -> Int {
        let value = state(identifier, in: app)
        guard let integer = Int(value) else {
            XCTFail("State probe \(identifier) is not an integer: \(value)")
            return 0
        }
        return integer
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForState(_ identifier: String, toEqual expectedValue: String, in app: XCUIApplication) {
        let stateElement = app.staticTexts[identifier]
        assertExists(stateElement, message: "Missing state probe \(identifier)")
        guard (stateElement.value as? String) != expectedValue else { return }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: stateElement
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "State probe \(identifier) did not become \(expectedValue); current value: \(String(describing: stateElement.value))"
        )
    }

    private func clickButton(_ identifier: String, in app: XCUIApplication) {
        activateIfNeeded(app)
        if identifier == "profile.import.confirm" {
            app.typeKey(.tab, modifierFlags: [])
        }
        dismissTextCompletionIfPresent(in: app)
        let result = requireButton(identifier, in: app)
        switch identifier {
        case "profile.import.confirm", "profile.subscription.confirm", "profile.unsaved.save-and-continue":
            app.typeKey(.return, modifierFlags: [])
        case "profile.unsaved.cancel":
            app.typeKey(.escape, modifierFlags: [])
        default:
            guard result.isHittable || waitUntilHittable(result) else {
                attachAccessibilityDiagnostics(for: app, missingIdentifier: "hittable \(identifier)")
                XCTFail("Button \(identifier) did not become hittable within \(timeout) seconds")
                return
            }
            result.click()
        }
    }

    private func dismissTextCompletionIfPresent(in app: XCUIApplication) {
        let completionWindow = app.windows["SafariPlatformSupportAutoCompleteWindow"]
        guard completionWindow.exists else { return }
        app.typeKey(.escape, modifierFlags: [])
        assertDoesNotExist(completionWindow, message: "System text-completion window did not dismiss")
    }

    private func button(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .button)[identifier]
    }

    private func requireButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let result = button(identifier, in: app)
        guard result.exists || result.waitForExistence(timeout: timeout) else {
            attachAccessibilityDiagnostics(for: app, missingIdentifier: identifier)
            XCTFail("Missing button \(identifier) while presentation state was active")
            return result
        }
        return result
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachAccessibilityDiagnostics(for app: XCUIApplication, missingIdentifier: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "AX hierarchy missing \(missingIdentifier)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let identifiers = [
            ("Sheets", app.sheets),
            ("Dialogs", app.dialogs),
            ("Buttons", app.descendants(matching: .button))
        ].map { label, query in
            let values = query.allElementsBoundByIndex.map { element in
                element.identifier.isEmpty ? "<empty>" : element.identifier
            }
            return "\(label): \(values)"
        }.joined(separator: "\n")
        let inventory = XCTAttachment(string: identifiers)
        inventory.name = "AX Sheet Dialog Button identifiers"
        inventory.lifetime = .keepAlways
        add(inventory)
    }

    private func activateIfNeeded(_ app: XCUIApplication) {
        guard !app.wait(for: .runningForeground, timeout: timeout) else { return }

        app.activate()
        guard app.wait(for: .runningForeground, timeout: timeout) else {
            attachAccessibilityDiagnostics(for: app, missingIdentifier: "runningForeground")
            XCTFail("Application did not enter the foreground within \(timeout) seconds")
            return
        }
    }

    private func assertStateRemains(
        _ identifier: String,
        value: String,
        for duration: TimeInterval,
        in app: XCUIApplication
    ) {
        let element = app.staticTexts[identifier]
        assertExists(element, message: "Missing state probe \(identifier)")
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", value),
            object: element
        )
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: duration), .completed)
    }

    private func assertExists(_ element: XCUIElement, message: String) {
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: timeout), message)
    }

    private func assertDoesNotExist(_ element: XCUIElement, message: String) {
        XCTAssertTrue(!element.exists || element.waitForNonExistence(timeout: timeout), message)
    }

    private func assertVisibleInsideWindow(_ element: XCUIElement, in app: XCUIApplication, message: String) {
        let visibleElement = element.firstMatch
        assertExists(visibleElement, message: message)
        let frame = visibleElement.frame
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.width, 0, message)
        XCTAssertGreaterThan(frame.height, 0, message)
        XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX, message)
        XCTAssertGreaterThanOrEqual(frame.minY, windowFrame.minY, message)
        XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX, message)
        XCTAssertLessThanOrEqual(frame.maxY, windowFrame.maxY, message)
    }

    private func cleanUpPresentationFixtures() {
        let fileManager = FileManager.default
        var directory = fileManager.temporaryDirectory.resolvingSymlinksInPath()

        for _ in 0..<4 {
            if let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in contents where url.lastPathComponent.hasPrefix("TargetPresentationFixture-") {
                    do {
                        try fileManager.removeItem(at: url)
                    } catch {
                        XCTFail("Unable to remove presentation fixture \(url.lastPathComponent)")
                    }
                }
            }

            if directory.lastPathComponent == "T" { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != "/", parent != directory else { break }
            directory = parent
        }
    }
}
