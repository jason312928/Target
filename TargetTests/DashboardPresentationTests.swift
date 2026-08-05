import XCTest
@testable import Target

final class DashboardPresentationTests: XCTestCase {
    private func makePresentation(
        status: BackendStatus = .mockDefault,
        lifecycle: BackendLifecycleState = .stopped,
        service: ServiceInstallationState = .notRegistered,
        xpc: XPCConnectionState = .unknown,
        error: BackendError? = nil,
        proxy: SystemProxyStatus = .disabled,
        busy: Bool = false,
        safeMode: Bool = true
    ) -> DashboardPresentation {
        DashboardPresentation(status: status, lifecycleState: lifecycle, serviceInstallation: service, xpcState: xpc, error: error, systemProxyStatus: proxy, isBusy: busy, isHostSafeMode: safeMode)
    }

    func testEngineNotInstalledOffersInstallationInsteadOfStart() {
        let presentation = makePresentation()
        XCTAssertEqual(presentation.primaryAction, .installEngine)
        XCTAssertEqual(presentation.titleKey, "dashboard.status.engine-unavailable")
    }

    func testInstalledStoppedEngineOffersStart() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed)
        XCTAssertEqual(makePresentation(status: status).primaryAction, .start)
    }

    func testBusyStateDoesNotOfferDuplicateAction() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .starting, engineInstallation: .installed)
        let presentation = makePresentation(status: status, lifecycle: .starting, busy: true)
        XCTAssertEqual(presentation.primaryAction, .unavailable)
        XCTAssertEqual(presentation.titleKey, "dashboard.status.working")
    }

    func testRunningEngineOffersStop() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed)
        XCTAssertEqual(makePresentation(status: status, lifecycle: .running).primaryAction, .stop)
    }

    func testRestartRequirementIsProminentWhenRunning() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed, restartRequired: true)
        let presentation = makePresentation(status: status, lifecycle: .running)
        XCTAssertEqual(presentation.primaryAction, .restart)
        XCTAssertTrue(presentation.showsRestartNotice)
    }

    func testBackendErrorUsesLocalizedKeyRatherThanEnumValue() {
        let presentation = makePresentation(error: .profileNotSelected)
        XCTAssertEqual(presentation.backendErrorKey, "backend.error.profile-not-selected")
        XCTAssertNotEqual(presentation.descriptionKey, "profileNotSelected")
    }

    func testServiceApprovalAndUnavailableXPCRemainDistinct() {
        XCTAssertEqual(makePresentation(service: .requiresApproval, xpc: .unknown).serviceInstallationKey, "service.status.requires-approval")
        XCTAssertEqual(makePresentation(service: .enabled, xpc: .unavailable).xpcStateKey, "xpc.status.unavailable")
    }

    func testSafeModeStateIsExposedWithoutMakingProxyWritable() {
        let presentation = makePresentation(safeMode: true)
        XCTAssertTrue(presentation.isHostSafeMode)
        XCTAssertEqual(presentation.systemProxyStateKey, "system-proxy.status.disabled")
    }

    func testMissingFieldsStayEmpty() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed)
        let presentation = makePresentation(status: status, lifecycle: .running)
        XCTAssertNil(presentation.engineVersion)
        XCTAssertNil(presentation.endpoint)
        XCTAssertNil(presentation.runningRevision)
    }

    func testRunningEndpointAndRevisionAreShownOnlyWhenAvailable() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed, engineVersion: "1.0", enginePort: 51_234, runningProfileRevision: 7)
        let presentation = makePresentation(status: status, lifecycle: .running)
        XCTAssertEqual(presentation.endpoint, "127.0.0.1:51234")
        XCTAssertEqual(presentation.runningRevision, 7)
    }
}
