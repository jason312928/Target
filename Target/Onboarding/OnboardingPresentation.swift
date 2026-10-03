import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case profiles
    case systemProxy

    var titleKey: LocalizedStringKey {
        switch self {
        case .welcome: "onboarding.welcome.title"
        case .profiles: "onboarding.profiles.title"
        case .systemProxy: "onboarding.system-proxy.title"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .welcome: "onboarding.welcome.message"
        case .profiles: "onboarding.profiles.message"
        case .systemProxy: "onboarding.system-proxy.message"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: "scope"
        case .profiles: "doc.text"
        case .systemProxy: "network"
        }
    }
}

enum OnboardingActionRouter {
    static func routeToProfiles() -> AppRouteIntent {
        .selectDestination(.profiles)
    }
}
