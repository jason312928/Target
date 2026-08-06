import XCTest

final class ProfileWorkspacePresentationUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    private enum Scenario: String {
        case saveFailureThenSuccess = "save-failure-then-success"
        case persistedReadDiscardFailure = "persisted-read-discard-failure"
        case successfulDiscard = "successful-discard"
        case importCandidateReturn = "import-candidate-return"
        case subscriptionCandidateReturn = "subscription-candidate-return"
    }

    func testSaveFailureThenRecoveryAndSuccess() {
        let app = launch(.saveFailureThenSuccess)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        selectSecondProfile(in: app)
        assertUnsavedAlert(in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)

        clickButton("profile.unsaved.save-and-continue", in: app)
        assertUnsavedAlert(in: app)
        XCTAssertEqual(state("presentation.selected-profile", in: app), "First Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "fixture-dirty")
        XCTAssertEqual(state("presentation.dirty", in: app), "true")
        XCTAssertEqual(state("presentation.pending-operation", in: app), "select-second")
        let recoveredPresentationGeneration = initialPresentationGeneration + 1
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
        XCTAssertTrue(unsavedSheet(in: app).waitForNonExistence(timeout: timeout))
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
        selectSecondProfile(in: app)
        assertUnsavedAlert(in: app)
        let initialPresentationGeneration = integerState("presentation.generation", in: app)
        clickButton("profile.unsaved.discard", in: app)
        assertUnsavedAlert(in: app)
        XCTAssertEqual(state("presentation.selected-profile", in: app), "First Profile")
        XCTAssertEqual(state("presentation.editor-state", in: app), "fixture-dirty")
        XCTAssertEqual(state("presentation.dirty", in: app), "true")
        XCTAssertEqual(state("presentation.pending-operation", in: app), "select-second")
        XCTAssertEqual(integerState("presentation.generation", in: app), initialPresentationGeneration + 1)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)

        clickButton("profile.unsaved.cancel", in: app)
        XCTAssertTrue(unsavedSheet(in: app).waitForNonExistence(timeout: timeout))
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
        selectSecondProfile(in: app)
        assertUnsavedAlert(in: app)
        clickButton("profile.unsaved.discard", in: app)
        XCTAssertTrue(unsavedSheet(in: app).waitForNonExistence(timeout: timeout))
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
        XCTAssertTrue(element("profile.import.confirmation", in: app).waitForExistence(timeout: timeout))
        let candidateFingerprint = state("presentation.import-candidate-fingerprint", in: app)
        let initialRevision = state("presentation.selected-revision", in: app)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        XCTAssertEqual(state("presentation.import-candidate", in: app), "true")
        clickButton("profile.import.confirm", in: app)
        XCTAssertTrue(element("profile.import.confirmation", in: app).waitForNonExistence(timeout: timeout))
        assertUnsavedAlert(in: app)
        clickButton("profile.unsaved.save-and-continue", in: app)
        assertUnsavedAlert(in: app)
        clickButton("profile.unsaved.cancel", in: app)
        XCTAssertTrue(element("profile.import.confirmation", in: app).waitForExistence(timeout: timeout))
        XCTAssertEqual(state("presentation.import-candidate", in: app), "true")
        XCTAssertEqual(state("presentation.import-candidate-fingerprint", in: app), candidateFingerprint)
        XCTAssertEqual(state("presentation.selected-revision", in: app), initialRevision)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.profile-count", in: app), "2")
    }

    func testSubscriptionCandidateReturnsAfterFailedSaveAndCancel() {
        let app = launch(.subscriptionCandidateReturn)
        XCTAssertTrue(element("profile.subscription.preview", in: app).waitForExistence(timeout: timeout))
        let candidateFingerprint = state("presentation.subscription-candidate-fingerprint", in: app)
        let initialRevision = state("presentation.selected-revision", in: app)
        let initialReadinessGeneration = integerState("presentation.readiness-generation", in: app)
        XCTAssertEqual(state("presentation.subscription-candidate", in: app), "true")
        clickButton("profile.subscription.confirm", in: app)
        XCTAssertTrue(element("profile.subscription.preview", in: app).waitForNonExistence(timeout: timeout))
        assertUnsavedAlert(in: app)
        clickButton("profile.unsaved.save-and-continue", in: app)
        assertUnsavedAlert(in: app)
        clickButton("profile.unsaved.cancel", in: app)
        XCTAssertTrue(element("profile.subscription.preview", in: app).waitForExistence(timeout: timeout))
        XCTAssertEqual(state("presentation.subscription-candidate", in: app), "true")
        XCTAssertEqual(state("presentation.subscription-candidate-fingerprint", in: app), candidateFingerprint)
        XCTAssertEqual(state("presentation.selected-revision", in: app), initialRevision)
        XCTAssertEqual(integerState("presentation.readiness-generation", in: app), initialReadinessGeneration)
        XCTAssertEqual(state("presentation.pending-operation", in: app), "none")
        XCTAssertEqual(state("presentation.profile-count", in: app), "2")
    }

    private func launch(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.jason312928.TargetPresentationTestHost")
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "--presentation-scenario", scenario.rawValue
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        addTeardownBlock { app.terminate() }
        return app
    }

    private func selectSecondProfile(in app: XCUIApplication) {
        let id = state("presentation.second-profile-id", in: app)
        let second = app.outlines.firstMatch.cells.element(boundBy: 0)
            .descendants(matching: .any)["profile.row.\(id)"]
        XCTAssertTrue(second.waitForExistence(timeout: timeout))
        activateIfNeeded(app)
        second.click()
    }

    private func assertUnsavedAlert(in app: XCUIApplication) {
        let sheet = unsavedSheet(in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout))
        let title = sheet.staticTexts
            .matching(NSPredicate(format: "value == %@", "Keep unsaved changes?"))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
    }

    private func unsavedSheet(in app: XCUIApplication) -> XCUIElement {
        app.sheets
            .containing(.button, identifier: "profile.unsaved.save-and-continue")
            .firstMatch
    }

    private func state(_ identifier: String, in app: XCUIApplication) -> String {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing state probe \(identifier)")
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

    private func clickButton(_ identifier: String, in app: XCUIApplication) {
        activateIfNeeded(app)
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "Missing button \(identifier)")
        button.click()
    }

    private func activateIfNeeded(_ app: XCUIApplication) {
        if app.state != .runningForeground {
            app.activate()
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func assertStateRemains(
        _ identifier: String,
        value: String,
        for duration: TimeInterval,
        in app: XCUIApplication
    ) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing state probe \(identifier)")
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", value),
            object: element
        )
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: duration), .completed)
    }
}
