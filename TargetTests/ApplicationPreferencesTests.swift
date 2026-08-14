import XCTest
@testable import Target

@MainActor
final class ApplicationPreferencesTests: XCTestCase {
    func testInitialEnabledSystemStatusIsPresentedAsEnabled() {
        let model = makeModel(status: .enabled)

        model.refreshLaunchAtLoginStatus()

        XCTAssertEqual(model.launchAtLoginState, .enabled)
    }

    func testInitialUnregisteredSystemStatusIsPresentedAsDisabled() {
        let model = makeModel(status: .disabled)

        model.refreshLaunchAtLoginStatus()

        XCTAssertEqual(model.launchAtLoginState, .disabled)
    }

    func testRequiresApprovalIsPresentedWithoutOfferingAnotherRegistration() {
        let manager = FakeLoginItemManager(status: .requiresApproval)
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()
        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(model.launchAtLoginState, .requiresApproval)
        XCTAssertFalse(model.canChangeLaunchAtLogin)
        XCTAssertEqual(manager.registerCallCount, 0)
    }

    func testEnablingRefreshesToAuthoritativeEnabledState() {
        let manager = FakeLoginItemManager(status: .disabled)
        manager.registeredStatus = .enabled
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()
        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(model.launchAtLoginState, .enabled)
        XCTAssertEqual(manager.registerCallCount, 1)
    }

    func testDisablingRefreshesToAuthoritativeDisabledState() {
        let manager = FakeLoginItemManager(status: .enabled)
        manager.unregisteredStatus = .disabled
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()
        model.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(model.launchAtLoginState, .disabled)
        XCTAssertEqual(manager.unregisterCallCount, 1)
    }

    func testRegisterFailureDoesNotLeaveAnOptimisticEnabledState() {
        let manager = FakeLoginItemManager(status: .disabled)
        manager.registerError = FakeError.failed
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()
        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(model.launchAtLoginState, .disabled)
        XCTAssertEqual(model.launchAtLoginFeedback, .enableFailed)
    }

    func testUnregisterFailureRefreshesAuthoritativeEnabledState() {
        let manager = FakeLoginItemManager(status: .enabled)
        manager.unregisterError = FakeError.failed
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()
        model.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(model.launchAtLoginState, .enabled)
        XCTAssertEqual(model.launchAtLoginFeedback, .disableFailed)
    }

    func testStatusReadFailureUsesExplicitUnavailableState() {
        let manager = FakeLoginItemManager(status: .disabled)
        manager.statusError = FakeError.failed
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()

        XCTAssertEqual(model.launchAtLoginState, .unavailable)
        XCTAssertEqual(model.launchAtLoginFeedback, .statusReadFailed)
    }

    func testRepeatedRefreshDoesNotMutateLoginItem() {
        let manager = FakeLoginItemManager(status: .disabled)
        let model = makeModel(manager: manager)

        model.refreshLaunchAtLoginStatus()
        model.refreshLaunchAtLoginStatus()

        XCTAssertEqual(manager.registerCallCount, 0)
        XCTAssertEqual(manager.unregisterCallCount, 0)
        XCTAssertEqual(manager.statusReadCount, 2)
    }

    func testFreshPreferencePresentsOnboardingAndCompletionPersistsIt() {
        let store = FakeOnboardingPreferences(hasCompletedOnboarding: false)
        let model = ApplicationPreferencesModel(onboardingPreferences: store, loginItemManager: FakeLoginItemManager(status: .disabled))

        XCTAssertTrue(model.shouldPresentOnboarding)
        model.completeOnboarding()

        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertFalse(model.shouldPresentOnboarding)
        XCTAssertFalse(ApplicationPreferencesModel(onboardingPreferences: store, loginItemManager: FakeLoginItemManager(status: .disabled)).shouldPresentOnboarding)
    }

    func testReopeningOnboardingDoesNotClearCompletionPreference() {
        let store = FakeOnboardingPreferences(hasCompletedOnboarding: true)
        let model = ApplicationPreferencesModel(onboardingPreferences: store, loginItemManager: FakeLoginItemManager(status: .disabled))

        model.reopenOnboarding()

        XCTAssertTrue(model.shouldPresentOnboarding)
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    func testOnboardingProfilesActionUsesExistingAppNavigationIntent() {
        XCTAssertEqual(OnboardingActionRouter.routeToProfiles(), .selectDestination(.profiles))
    }

    private func makeModel(status: LoginItemRegistrationStatus) -> ApplicationPreferencesModel {
        makeModel(manager: FakeLoginItemManager(status: status))
    }

    private func makeModel(manager: FakeLoginItemManager) -> ApplicationPreferencesModel {
        ApplicationPreferencesModel(
            onboardingPreferences: FakeOnboardingPreferences(hasCompletedOnboarding: true),
            loginItemManager: manager
        )
    }
}

@MainActor
private final class FakeLoginItemManager: LoginItemManaging {
    var status: LoginItemRegistrationStatus
    var registeredStatus: LoginItemRegistrationStatus?
    var unregisteredStatus: LoginItemRegistrationStatus?
    var statusError: Error?
    var registerError: Error?
    var unregisterError: Error?
    private(set) var statusReadCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LoginItemRegistrationStatus) {
        self.status = status
    }

    func currentStatus() throws -> LoginItemRegistrationStatus {
        statusReadCount += 1
        if let statusError { throw statusError }
        return status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        if let registeredStatus { status = registeredStatus }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        if let unregisteredStatus { status = unregisteredStatus }
    }
}

private final class FakeOnboardingPreferences: OnboardingPersisting {
    var hasCompletedOnboarding: Bool

    init(hasCompletedOnboarding: Bool) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

private enum FakeError: Error {
    case failed
}
