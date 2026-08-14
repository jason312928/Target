import Foundation
import Observation

enum LoginItemRegistrationStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
}

@MainActor
protocol LoginItemManaging: AnyObject {
    func currentStatus() throws -> LoginItemRegistrationStatus
    func register() throws
    func unregister() throws
}

protocol OnboardingPersisting: AnyObject {
    var hasCompletedOnboarding: Bool { get set }
}

final class UserDefaultsOnboardingPreferences: OnboardingPersisting {
    private enum Key {
        static let hasCompletedOnboarding = "onboarding.has-completed"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }
}

enum LaunchAtLoginState: Equatable {
    case loading
    case enabled
    case disabled
    case requiresApproval
    case unavailable

    var statusKey: String {
        switch self {
        case .loading: "settings.launch-at-login.status.loading"
        case .enabled: "settings.launch-at-login.status.enabled"
        case .disabled: "settings.launch-at-login.status.disabled"
        case .requiresApproval: "settings.launch-at-login.status.requires-approval"
        case .unavailable: "settings.launch-at-login.status.unavailable"
        }
    }

    var isEnabled: Bool { self == .enabled }
}

enum LaunchAtLoginFeedback: Equatable {
    case enableFailed
    case disableFailed
    case statusReadFailed

    var messageKey: String {
        switch self {
        case .enableFailed: "settings.launch-at-login.error.enable-failed"
        case .disableFailed: "settings.launch-at-login.error.disable-failed"
        case .statusReadFailed: "settings.launch-at-login.error.status-unavailable"
        }
    }
}

@MainActor
@Observable
final class ApplicationPreferencesModel {
    private let onboardingPreferences: any OnboardingPersisting
    private let loginItemManager: any LoginItemManaging

    private(set) var launchAtLoginState: LaunchAtLoginState = .loading
    private(set) var launchAtLoginFeedback: LaunchAtLoginFeedback?
    private(set) var isUpdatingLaunchAtLogin = false
    private(set) var shouldPresentOnboarding: Bool

    init(
        onboardingPreferences: any OnboardingPersisting = UserDefaultsOnboardingPreferences(),
        loginItemManager: any LoginItemManaging
    ) {
        self.onboardingPreferences = onboardingPreferences
        self.loginItemManager = loginItemManager
        shouldPresentOnboarding = !onboardingPreferences.hasCompletedOnboarding
    }

    var canChangeLaunchAtLogin: Bool {
        !isUpdatingLaunchAtLogin && [.enabled, .disabled].contains(launchAtLoginState)
    }

    func refreshLaunchAtLoginStatus() {
        guard !isUpdatingLaunchAtLogin else { return }
        launchAtLoginFeedback = nil
        if !refreshAuthoritativeLaunchAtLoginStatus() {
            launchAtLoginFeedback = .statusReadFailed
        }
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        guard canChangeLaunchAtLogin else { return }

        isUpdatingLaunchAtLogin = true
        launchAtLoginFeedback = nil
        var feedback: LaunchAtLoginFeedback?
        do {
            if isEnabled {
                try loginItemManager.register()
            } else {
                try loginItemManager.unregister()
            }
        } catch {
            feedback = isEnabled ? .enableFailed : .disableFailed
        }

        let refreshed = refreshAuthoritativeLaunchAtLoginStatus()
        if !refreshed {
            feedback = .statusReadFailed
        }
        launchAtLoginFeedback = feedback
        isUpdatingLaunchAtLogin = false
    }

    func completeOnboarding() {
        onboardingPreferences.hasCompletedOnboarding = true
        shouldPresentOnboarding = false
    }

    func reopenOnboarding() {
        shouldPresentOnboarding = true
    }

    func dismissOnboarding() {
        shouldPresentOnboarding = false
    }

    @discardableResult
    private func refreshAuthoritativeLaunchAtLoginStatus() -> Bool {
        do {
            switch try loginItemManager.currentStatus() {
            case .enabled: launchAtLoginState = .enabled
            case .disabled: launchAtLoginState = .disabled
            case .requiresApproval: launchAtLoginState = .requiresApproval
            }
            return true
        } catch {
            launchAtLoginState = .unavailable
            return false
        }
    }
}
