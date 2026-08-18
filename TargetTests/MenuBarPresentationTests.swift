import XCTest
@testable import Target

final class MenuBarPresentationTests: XCTestCase {
    func testStoppedStartableEngineOffersStart() {
        let presentation = makePresentation(canStart: true)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.stopped")
        XCTAssertEqual(presentation.primaryAction, .start)
    }

    func testRunningEngineOffersStop() {
        let presentation = makePresentation(status: runningStatus(), proxy: managedProxyStatus(), canStop: true)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.running")
        XCTAssertEqual(presentation.primaryAction, .stop)
    }

    func testRunningEngineWithoutSystemProxyIsNotShownAsConnected() {
        let presentation = makePresentation(status: runningStatus(), proxy: .disabled, canStop: true)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.proxy-disabled")
        XCTAssertEqual(presentation.symbolName, "exclamationmark.circle")
    }

    func testHostSafeRunningEngineIsExplicitlyEngineOnly() {
        let presentation = makePresentation(status: runningStatus(), proxy: .disabled, canStop: true, hostSafe: true)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.host-safe-running")
    }

    func testRestartRequiredOffersRestartOnlyWhenLifecycleAllowsIt() {
        var status = runningStatus()
        status.restartRequired = true

        XCTAssertEqual(makePresentation(status: status, canRestart: true).primaryAction, .restart)
        XCTAssertEqual(makePresentation(status: status).primaryAction, .unavailable)
    }

    func testBusyStateDisablesMutatingActions() {
        let presentation = makePresentation(
            status: runningStatus(),
            canStop: true,
            canDisableProxy: true,
            busy: true
        )

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.working")
        XCTAssertEqual(presentation.primaryAction, .unavailable)
        XCTAssertEqual(presentation.systemProxyAction, .unavailable)
    }

    func testSystemProxyMapsEnabledAndDisabledCapabilities() {
        let enabled = SystemProxyStatus(state: .enabled, engineReachable: true, affectedServiceCount: 1, error: nil)

        XCTAssertEqual(makePresentation(proxy: .disabled, canEnableProxy: true).systemProxyAction, .enable)
        XCTAssertEqual(makePresentation(proxy: enabled, canDisableProxy: true).systemProxyAction, .disable)
    }

    func testHostSafeOrUnavailableCapabilityNeverOffersProxyEnable() {
        let presentation = makePresentation(proxy: .disabled)

        XCTAssertEqual(presentation.systemProxyAction, .unavailable)
    }

    func testErrorUsesLocalizedPresentationWithoutRuntimeDetails() {
        let presentation = makePresentation(error: .serviceUnavailable)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.error")
        XCTAssertEqual(presentation.errorKey, "backend.error.service-unavailable")
        XCTAssertFalse(presentation.symbolName.contains("127.0.0.1"))
        XCTAssertFalse(presentation.statusKey.contains("endpoint"))
    }

    func testWindowActivationSelectsTargetMainWindowInsteadOfAnotherTitledWindow() {
        let decision = TargetMainWindowActivation.decision(for: [
            NSUserInterfaceItemIdentifier("subscription-sheet"),
            TargetMainWindowActivation.windowIdentifier,
            NSUserInterfaceItemIdentifier("profile-editor")
        ])

        XCTAssertEqual(decision, .activateExistingMainWindow(index: 1))
    }

    func testWindowActivationDoesNotTreatAnotherTitledWindowAsTargetMainWindow() {
        let decision = TargetMainWindowActivation.decision(for: [
            NSUserInterfaceItemIdentifier("subscription-sheet"),
            NSUserInterfaceItemIdentifier("profile-editor")
        ])

        XCTAssertEqual(decision, .openMainWindow)
    }

    func testWindowActivationRequestsOpenWindowWhenMainWindowDoesNotExist() {
        XCTAssertEqual(TargetMainWindowActivation.decision(for: []), .openMainWindow)
    }

    func testRepeatedWindowActivationKeepsUsingExistingMainWindow() {
        let windows: [NSUserInterfaceItemIdentifier?] = [TargetMainWindowActivation.windowIdentifier]

        XCTAssertEqual(TargetMainWindowActivation.decision(for: windows), .activateExistingMainWindow(index: 0))
        XCTAssertEqual(TargetMainWindowActivation.decision(for: windows), .activateExistingMainWindow(index: 0))
    }

    func testMenuBarProvidesSeparateNativeSettingsNavigationAction() {
        XCTAssertEqual(MenuBarNavigationAction.allCases, [.openTarget, .openSettings])
        XCTAssertNotEqual(MenuBarNavigationAction.openTarget, .openSettings)
        XCTAssertEqual(MenuBarNavigationAction.openSettings.titleKey, "menu-bar.settings")
    }

    private func makePresentation(
        status: BackendStatus = BackendStatus(
            serviceInstallation: .enabled,
            engineState: .stopped,
            engineInstallation: .installed,
            hasSelectedValidProfile: true
        ),
        error: BackendError? = nil,
        proxy: SystemProxyStatus = .disabled,
        canStart: Bool = false,
        canStop: Bool = false,
        canRestart: Bool = false,
        canEnableProxy: Bool = false,
        canDisableProxy: Bool = false,
        busy: Bool = false,
        hostSafe: Bool = false
    ) -> MenuBarPresentation {
        MenuBarPresentation(
            status: status,
            lifecycleState: .settled(from: status),
            error: error,
            systemProxyStatus: proxy,
            canStart: canStart,
            canStop: canStop,
            canRestart: canRestart,
            canEnableSystemProxy: canEnableProxy,
            canDisableSystemProxy: canDisableProxy,
            isBusy: busy,
            isHostSafeMode: hostSafe
        )
    }

    private func runningStatus() -> BackendStatus {
        BackendStatus(
            serviceInstallation: .enabled,
            engineState: .running,
            engineInstallation: .installed,
            hasSelectedValidProfile: true
        )
    }

    private func managedProxyStatus() -> SystemProxyStatus {
        SystemProxyStatus(state: .enabled, engineReachable: true, affectedServiceCount: 1, error: nil, hasRecoverySnapshot: true)
    }
}
