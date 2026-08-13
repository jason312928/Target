import XCTest
@testable import Target

final class MenuBarPresentationTests: XCTestCase {
    func testStoppedStartableEngineOffersStart() {
        let presentation = makePresentation(canStart: true)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.stopped")
        XCTAssertEqual(presentation.primaryAction, .start)
    }

    func testRunningEngineOffersStop() {
        let presentation = makePresentation(status: runningStatus(), canStop: true)

        XCTAssertEqual(presentation.statusKey, "menu-bar.status.running")
        XCTAssertEqual(presentation.primaryAction, .stop)
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
        busy: Bool = false
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
            isBusy: busy
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
}
