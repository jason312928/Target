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
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: true)
        let presentation = makePresentation(status: status)
        XCTAssertEqual(presentation.primaryAction, .start)
        XCTAssertEqual(presentation.titleKey, "dashboard.status.ready")
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
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed, hasSelectedValidProfile: true, restartRequired: true)
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

    func testStoppedInstalledEngineWithoutSelectedProfileRequiresProfile() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: false)
        let presentation = makePresentation(status: status)

        XCTAssertEqual(presentation.primaryAction, .profileRequired)
        XCTAssertEqual(presentation.titleKey, "dashboard.status.profile-required")
        XCTAssertEqual(presentation.descriptionKey, "dashboard.status.profile-required.description")
    }

    func testRunningEngineWithBackendErrorOffersStopInsteadOfStart() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed)
        let presentation = makePresentation(status: status, lifecycle: .failed(.serviceUnavailable), error: .serviceUnavailable)

        XCTAssertEqual(presentation.primaryAction, .stop)
        XCTAssertEqual(presentation.backendErrorKey, "backend.error.service-unavailable")
    }

    func testRunningEngineWithServiceRegistrationErrorKeepsEngineAction() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed)
        let presentation = makePresentation(status: status, lifecycle: .failed(.serviceRegistrationFailed), error: .serviceRegistrationFailed)

        XCTAssertEqual(presentation.primaryAction, .stop)
        XCTAssertEqual(presentation.backendErrorKey, "backend.error.service-registration-failed")
    }

    func testRestartRequiredWithErrorDoesNotFallBackToStart() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed, hasSelectedValidProfile: true, restartRequired: true)
        let presentation = makePresentation(status: status, lifecycle: .failed(.serviceUnavailable), error: .serviceUnavailable)

        XCTAssertEqual(presentation.primaryAction, .restart)
        XCTAssertNotEqual(presentation.primaryAction, .start)
    }

    func testStoppedErrorWithoutSelectedProfileDoesNotOfferStart() {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed)
        let presentation = makePresentation(status: status, lifecycle: .failed(.profileNotSelected), error: .profileNotSelected)

        XCTAssertEqual(presentation.primaryAction, .profileRequired)
        XCTAssertEqual(presentation.titleKey, "dashboard.status.profile-required")
    }
}
