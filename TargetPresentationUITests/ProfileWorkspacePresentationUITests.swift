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
        case policyCatalogPopulated = "policy-catalog-populated"
        case policyCatalogEmpty = "policy-catalog-empty"
        case policyCatalogUnavailable = "policy-catalog-unavailable"
        case policyCatalogWarnings = "policy-catalog-warnings"
        case policyCatalogSecrets = "policy-catalog-secrets"
    }

    func testPolicyCatalogPopulatedPresentationUsesPersistedOrderDefaultAndType() {
        let app = launch(.policyCatalogPopulated)
        assertExists(element("policy.catalog", in: app), message: "Missing Policy Catalog")
        assertCatalogText("group", identifier: "policy.catalog.selector.0.tag", in: app)
        assertCatalogText("Configured default: second", identifier: "policy.catalog.selector.0.configured-default", in: app)
        assertCatalogText("first", identifier: "policy.catalog.selector.0.member.0.tag", in: app)
        assertCatalogText("vmess", identifier: "policy.catalog.selector.0.member.0.type", in: app)
        assertCatalogText("second", identifier: "policy.catalog.selector.0.member.1.tag", in: app)
        XCTAssertLessThan(
            element("policy.catalog.selector.0.member.0", in: app).frame.minY,
            element("policy.catalog.selector.0.member.1", in: app).frame.minY,
            "Persisted member order must be rendered"
        )
    }

    func testPolicyCatalogEmptyPresentationUsesLocalizedEmptyState() {
        let app = launch(.policyCatalogEmpty)
        assertExists(element("policy.catalog.empty", in: app), message: "Missing localized Policy Catalog empty state")
        assertDoesNotExist(element("policy.catalog.unavailable", in: app), message: "Empty catalog rendered as unavailable")
    }

    func testPolicyCatalogUnavailablePresentationClearsStaleRows() {
        let app = launch(.policyCatalogUnavailable)
        assertExists(element("policy.catalog.unavailable", in: app), message: "Missing Policy Catalog unavailable state")
        assertDoesNotExist(element("policy.catalog.selector.0", in: app), message: "Unavailable state retained a stale selector row")
    }

    func testPolicyCatalogWarningsAndDuplicateRowsAreRenderedWithoutCollapse() {
        let app = launch(.policyCatalogWarnings)
        assertCatalogText("Missing reference", identifier: "policy.catalog.selector.0.member.0.status", in: app)
        assertCatalogText("Ambiguous tag", identifier: "policy.catalog.selector.0.member.1.status", in: app)
        assertCatalogText("Ambiguous tag", identifier: "policy.catalog.selector.0.member.2.status", in: app)
        assertCatalogText("Unavailable", identifier: "policy.catalog.selector.0.member.3.status", in: app)
        assertCatalogText("Invalid selector tag", identifier: "policy.catalog.selector.4.tag", in: app)
        assertCatalogText("Invalid tag", identifier: "policy.catalog.selector.4.status", in: app)
        assertCatalogText("Invalid members", identifier: "policy.catalog.selector.5.status", in: app)
        assertExists(element("policy.catalog.selector.0.member.1", in: app), message: "First duplicate member row collapsed")
        assertExists(element("policy.catalog.selector.0.member.2", in: app), message: "Second duplicate member row collapsed")
        assertExists(element("policy.catalog.selector.4", in: app), message: "Invalid selector row collapsed")
        assertExists(element("policy.catalog.selector.5", in: app), message: "Malformed selector row collapsed")
    }

    func testPolicyCatalogPresentationIsReadOnlyAndCredentialSafe() {
        let app = launch(.policyCatalogSecrets)
        let catalog = element("policy.catalog", in: app)
        assertExists(catalog, message: "Missing Policy Catalog")
        assertCatalogText("safe-group", identifier: "policy.catalog.selector.0.tag", in: app)
        assertCatalogText("safe-member", identifier: "policy.catalog.selector.0.member.0.tag", in: app)
        assertCatalogText("vmess", identifier: "policy.catalog.selector.0.member.0.type", in: app)
        for type in [XCUIElement.ElementType.button, .switch, .popUpButton, .comboBox, .slider] {
            XCTAssertEqual(catalog.descendants(matching: type).count, 0, "Policy Catalog must not expose mutation controls")
        }
        let sentinel = "POLICY-PRESENTATION-SECRET"
        let catalogElements = catalog.descendants(matching: .any).allElementsBoundByIndex + [catalog]
        for element in catalogElements {
            XCTAssertFalse(element.label.contains(sentinel), "Credential sentinel leaked through Policy Catalog label")
            XCTAssertFalse((element.value as? String ?? "").contains(sentinel), "Credential sentinel leaked through Policy Catalog value")
            XCTAssertFalse(element.identifier.contains(sentinel), "Credential sentinel leaked through Policy Catalog identifier")
            XCTAssertFalse(element.debugDescription.contains(sentinel), "Credential sentinel leaked through Policy Catalog accessibility description")
        }
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

    func testFullShellEmptyWorkspaceAtMinimumSize() {
        assertFullShellEmptyWorkspace(size: "740x511", sidebarToggleLabel: "Toggle Main Sidebar")
    }

    func testFullShellEmptyWorkspaceAtRegularSize() {
        assertFullShellEmptyWorkspace(
            size: "950x670",
            sidebarToggleLabel: "切换主侧边栏",
            language: "zh-Hans",
            locale: "zh_CN"
        )
    }

    func testFullShellSelectedProfileAtMinimumSize() {
        assertFullShellSelectedProfile(.localProfile, size: "740x511")
    }

    func testFullShellSelectedProfileAtRegularSize() {
        assertFullShellSelectedProfile(.localProfile, size: "950x670")
    }

    func testFullShellRemoteProfileAtMinimumSize() {
        assertFullShellSelectedProfile(.remoteProfile, size: "740x511")
    }

    func testFullShellRemoteProfileAtRegularSize() {
        assertFullShellSelectedProfile(.remoteProfile, size: "950x670")
    }

    func testFullShellRestoresProfilesDestinationAfterRestartAtBothSizes() {
        assertRestoredShellWorkspace(size: "740x511")
        assertRestoredShellWorkspace(size: "950x670")
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

    private func assertFullShellEmptyWorkspace(
        size: String,
        sidebarToggleLabel: String,
        language: String = "en",
        locale: String = "en_US"
    ) {
        let app = launchFullShell(
            .emptyWorkspace,
            windowSize: size,
            resetDestination: true,
            language: language,
            locale: locale
        )
        assertVisibleInsideWindow(element("dashboard.workspace", in: app), in: app, message: "Dashboard did not start in the shell")
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: sidebarToggleLabel)

        navigateToProfiles(in: app)
        assertEmptyShellWorkspace(in: app)
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: sidebarToggleLabel)
        let expandedWidth = detailWidth(in: app, identifier: "profile.workspace")
        assertOuterProfilesTitle(in: app)
        assertToolbarReachable(in: app)

        for _ in 0..<3 {
            collapseOuterSidebar(in: app, detailIdentifier: "profile.workspace", expandedWidth: expandedWidth)
            expandOuterSidebar(in: app, detailIdentifier: "profile.workspace")
        }

        navigateToDashboard(in: app)
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: sidebarToggleLabel)
        navigateToProfiles(in: app)
        assertEmptyShellWorkspace(in: app)
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: sidebarToggleLabel)

        assertNoModal(in: app)
    }

    private func assertFullShellSelectedProfile(_ scenario: Scenario, size: String) {
        let app = launchFullShell(scenario, windowSize: size, resetDestination: true)
        navigateToProfiles(in: app)
        assertSelectedShellWorkspace(in: app)
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: "Toggle Main Sidebar")
        let expandedWidth = detailWidth(in: app, identifier: "profile.workspace.detail")
        assertOuterProfilesTitle(in: app)

        collapseOuterSidebar(in: app, detailIdentifier: "profile.workspace.detail", expandedWidth: expandedWidth)
        assertSelectedShellWorkspace(in: app, expectsOuterSidebar: false)
        expandOuterSidebar(in: app, detailIdentifier: "profile.workspace.detail")
        assertSelectedShellWorkspace(in: app)
        assertToolbarReachable(in: app)
        recordShellFrames(in: app, detailIdentifier: "profile.workspace.detail")
        assertNoModal(in: app)
    }

    private func assertRestoredShellWorkspace(size: String) {
        // XCTest cannot relaunch a macOS WindowGroup for the same bundle in
        // one test method after termination. This starts a fresh host process
        // with the test-only persisted destination seam used at that boundary.
        let restarted = launchFullShell(
            .emptyWorkspace,
            windowSize: size,
            resetDestination: true,
            restoredDestination: "profiles"
        )
        assertEmptyShellWorkspace(in: restarted)
        assertExactlyOneMainSidebarToggle(in: restarted, expectedLabel: "Toggle Main Sidebar")
        collapseOuterSidebar(in: restarted, detailIdentifier: "profile.workspace", expandedWidth: detailWidth(in: restarted, identifier: "profile.workspace"))
        recordShellFrames(in: restarted, detailIdentifier: "profile.workspace")
        assertNoModal(in: restarted)
    }

    private func launchFullShell(
        _ scenario: Scenario,
        windowSize: String,
        resetDestination: Bool,
        restoredDestination: String? = nil,
        language: String = "en",
        locale: String = "en_US"
    ) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.jason312928.TargetPresentationTestHost")
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-ApplePersistenceIgnoreState", "YES",
            "-NSAutomaticTextCompletionEnabled", "NO",
            "--presentation-scenario", scenario.rawValue,
            "--presentation-window-size", windowSize,
            "--presentation-full-shell"
        ]
        if resetDestination {
            app.launchArguments.append("--presentation-reset-shell-destination")
        }
        if let restoredDestination {
            app.launchArguments += ["--presentation-restored-destination", restoredDestination]
        }
        app.launch()
        activateIfNeeded(app)
        assertExists(app.windows.firstMatch, message: "Full-shell host window did not appear")
        waitForState("presentation.scenario", toEqual: scenario.rawValue, in: app)
        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
                _ = app.wait(for: .notRunning, timeout: 5)
            }
            self.cleanUpPresentationFixtures()
        }
        return app
    }

    private func navigateToProfiles(in app: XCUIApplication) {
        let destination = element("app-shell.destination.profiles", in: app)
        assertExists(destination, message: "Profiles destination is unavailable")
        activateForInteraction(app)
        guard destination.isHittable || waitUntilHittable(destination) else {
            return XCTFail("Profiles destination is not hittable")
        }
        destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        assertExists(element("profile.list", in: app), message: "Inner Profile list is unavailable")
    }

    private func navigateToDashboard(in app: XCUIApplication) {
        let destination = element("app-shell.destination.dashboard", in: app)
        assertExists(destination, message: "Dashboard destination is unavailable")
        activateForInteraction(app)
        guard destination.isHittable || waitUntilHittable(destination) else {
            return XCTFail("Dashboard destination is not hittable")
        }
        destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        assertVisibleInsideWindow(element("dashboard.workspace", in: app), in: app, message: "Dashboard did not return")
    }

    private func assertEmptyShellWorkspace(in app: XCUIApplication) {
        assertVisibleInsideWindow(element("app-shell.sidebar", in: app), in: app, message: "Outer sidebar is unavailable")
        assertVisibleInsideWindow(element("profile.list", in: app), in: app, message: "Inner Profile list is unavailable")
        let empty = element("profile.workspace.empty", in: app)
        assertVisibleInsideWindow(empty, in: app, message: "Empty Profile workspace is unavailable")
        XCTAssertGreaterThan(empty.firstMatch.frame.width, 150, "Empty state title is constrained to a character column")
        assertDetailUsesAvailableWidth(element("profile.workspace", in: app), in: app)
        recordShellFrames(in: app, detailIdentifier: "profile.workspace")
    }

    private func assertSelectedShellWorkspace(in app: XCUIApplication, expectsOuterSidebar: Bool = true) {
        if expectsOuterSidebar {
            assertVisibleInsideWindow(element("app-shell.sidebar", in: app), in: app, message: "Outer sidebar is unavailable")
        }
        assertVisibleInsideWindow(element("profile.list", in: app), in: app, message: "Inner Profile list is unavailable")
        assertVisibleInsideWindow(app.staticTexts["profile.summary.name"], in: app, message: "Profile name is unavailable")
        XCTAssertGreaterThan(app.staticTexts["profile.summary.name"].frame.width, 60, "Profile name is constrained to a character column")
        assertVisibleInsideWindow(element("profile.summary.source", in: app), in: app, message: "Profile source summary is unavailable")
        assertVisibleInsideWindow(element("profile.summary.validation", in: app), in: app, message: "Profile validation summary is unavailable")
        assertVisibleInsideWindow(app.scrollViews["profile.json-editor.scroll"], in: app, message: "JSON editor is unavailable")
        assertVisibleInsideWindow(app.buttons["Validate & Save"], in: app, message: "Save is unavailable")
        assertVisibleInsideWindow(app.buttons["Format"], in: app, message: "Format is unavailable")
        assertVisibleInsideWindow(app.menuButtons["More Actions"], in: app, message: "More Actions is unavailable")
        assertDetailUsesAvailableWidth(element("profile.workspace.detail", in: app), in: app)
    }

    private func assertOuterProfilesTitle(in app: XCUIApplication) {
        let profiles = element("app-shell.destination.profiles", in: app)
        assertVisibleInsideWindow(profiles, in: app, message: "Profiles title is unavailable")
        XCTAssertGreaterThan(profiles.frame.width, 55, "Profiles title is constrained to a character column")
        XCTAssertLessThan(profiles.frame.height, 32, "Profiles title wrapped vertically")
    }

    private func collapseOuterSidebar(
        in app: XCUIApplication,
        detailIdentifier: String,
        expandedWidth: CGFloat
    ) {
        clickOuterSidebarToggle(in: app)
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: sidebarToggleLabel(in: app))
        let sidebar = element("app-shell.sidebar", in: app)
        XCTAssertTrue(!sidebar.exists || sidebar.frame.width < 1, "Outer sidebar remained visible after collapse: \(sidebar.frame)")
        let detail = element(detailIdentifier, in: app).firstMatch
        assertVisibleInsideWindow(detail, in: app, message: "Profile detail disappeared after outer sidebar toggle")
        XCTAssertGreaterThan(detail.frame.width, expandedWidth + 80, "Profile detail did not receive the collapsed sidebar width")
    }

    private func expandOuterSidebar(in app: XCUIApplication, detailIdentifier: String) {
        clickOuterSidebarToggle(in: app)
        assertExactlyOneMainSidebarToggle(in: app, expectedLabel: sidebarToggleLabel(in: app))
        assertVisibleInsideWindow(element("app-shell.sidebar", in: app), in: app, message: "Outer sidebar did not return after expansion")
        assertOuterProfilesTitle(in: app)
        let detail = element(detailIdentifier, in: app).firstMatch
        assertVisibleInsideWindow(detail, in: app, message: "Profile detail disappeared after outer sidebar expansion")
        XCTAssertGreaterThan(detail.frame.width, 300, "Profile detail is too narrow after outer sidebar expansion")
    }

    private func clickOuterSidebarToggle(in app: XCUIApplication) {
        let toggle = button("app-shell.sidebar-toggle", in: app)
        assertExists(toggle, message: "Outer sidebar toggle is unavailable")
        activateForInteraction(app)
        assertVisibleInsideWindow(toggle, in: app, message: "Outer sidebar toggle is outside the window")
        toggle.click()
    }

    private func assertExactlyOneMainSidebarToggle(in app: XCUIApplication, expectedLabel: String) {
        let toolbar = app.toolbars.firstMatch
        assertExists(toolbar, message: "Main toolbar is unavailable")

        let candidates = toolbar.buttons.allElementsBoundByIndex.filter { button in
            button.exists && isVisibleInsideWindow(button, in: app) && isMainSidebarToggle(button)
        }
        let inventory = toolbar.buttons.allElementsBoundByIndex.map { button in
            "label=\(button.label) id=\(button.identifier) frame=\(button.frame) enabled=\(button.isEnabled)"
        }.joined(separator: "\\n")
        XCTAssertEqual(candidates.count, 1, "Expected one visible main sidebar toggle. Toolbar inventory:\\n\(inventory)")

        let toggle = button("app-shell.sidebar-toggle", in: app)
        assertExists(toggle, message: "Main sidebar toggle identifier is unavailable")
        XCTAssertEqual(toggle.label, expectedLabel, "Main sidebar toggle is not localized as expected")
        XCTAssertTrue(toggle.isEnabled, "Main sidebar toggle is disabled")
        assertVisibleInsideWindow(toggle, in: app, message: "Main sidebar toggle is outside the window")
    }

    private func isMainSidebarToggle(_ button: XCUIElement) -> Bool {
        if button.identifier == "app-shell.sidebar-toggle" { return true }
        let label = button.label.lowercased()
        return label.contains("sidebar") || button.label.contains("侧边栏")
    }

    private func sidebarToggleLabel(in app: XCUIApplication) -> String {
        button("app-shell.sidebar-toggle", in: app).label
    }

    private func detailWidth(in app: XCUIApplication, identifier: String) -> CGFloat {
        let detail = element(identifier, in: app).firstMatch
        assertVisibleInsideWindow(detail, in: app, message: "Profile detail is unavailable")
        return detail.frame.width
    }

    private func assertDetailUsesAvailableWidth(_ detail: XCUIElement, in app: XCUIApplication) {
        let rootDetail = detail.firstMatch
        assertVisibleInsideWindow(rootDetail, in: app, message: "Profile detail is unavailable")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(rootDetail.frame.width, 300, "Profile detail is too narrow for usable content")
        XCTAssertLessThanOrEqual(window.maxX - rootDetail.frame.maxX, 24, "Unused right-side shell space remains while Profile detail is narrow")
    }

    private func assertNoModal(in app: XCUIApplication) {
        XCTAssertFalse(app.sheets.firstMatch.exists, "Unexpected Sheet in shell layout test")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Unexpected Alert in shell layout test")
    }

    private func assertToolbarReachable(in app: XCUIApplication) {
        let create = button("profile.action.create", in: app)
        assertVisibleInsideWindow(create, in: app, message: "Profile toolbar is unavailable")
        XCTAssertTrue(create.isHittable || waitUntilHittable(create), "Profile toolbar is not reachable")
    }

    private func recordShellFrames(in app: XCUIApplication, detailIdentifier: String) {
        let window = app.windows.firstMatch.frame
        let outerSidebar = element("app-shell.sidebar", in: app)
        let profileList = element("profile.list", in: app)
        let outer = outerSidebar.exists ? outerSidebar.frame : .zero
        let list = profileList.exists ? profileList.frame : .zero
        let detail = element(detailIdentifier, in: app).firstMatch.frame
        let record = XCTAttachment(string: "window=\(window) outer=\(outer) list=\(list) detail=\(detail)")
        record.name = "Profiles full-shell frames"
        record.lifetime = .keepAlways
        add(record)
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

    private func assertCatalogText(_ expected: String, identifier: String, in app: XCUIApplication) {
        let result = app.staticTexts[identifier]
        assertExists(result, message: "Missing Policy Catalog element \(identifier)")
        XCTAssertEqual(result.label, expected, "Unexpected Policy Catalog text for \(identifier)")
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

    private func activateForInteraction(_ app: XCUIApplication) {
        app.activate()
        guard app.wait(for: .runningForeground, timeout: timeout) else {
            XCTFail("Application did not enter the foreground for interaction")
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
        let detail = "\(message) element=\(frame) window=\(windowFrame)"
        // macOS reports a native List scroller's accessibility frame a few
        // points beyond the content border. Keep this tight enough to catch
        // real clipping while accepting that platform-only edge rounding.
        let edgeTolerance: CGFloat = 6
        XCTAssertGreaterThan(frame.width, 0, detail)
        XCTAssertGreaterThan(frame.height, 0, detail)
        XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX - edgeTolerance, detail)
        XCTAssertGreaterThanOrEqual(frame.minY, windowFrame.minY - edgeTolerance, detail)
        XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX + edgeTolerance, detail)
        XCTAssertLessThanOrEqual(frame.maxY, windowFrame.maxY + edgeTolerance, detail)
    }

    private func isVisibleInsideWindow(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        return frame.width > 0 && frame.height > 0 && frame.intersects(window)
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
