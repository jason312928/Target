import Foundation

enum AppDestination: String, CaseIterable, Hashable, Identifiable {
    case dashboard
    case profiles

    static let defaultDestination: Self = .dashboard

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .dashboard: "dashboard.title"
        case .profiles: "profile.title"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "rectangle.grid.1x2"
        case .profiles: "doc.text"
        }
    }

    static func fallback(for selection: Self?) -> Self {
        selection ?? defaultDestination
    }
}

enum DashboardRouteIntent: Equatable {
    case selectDestination(AppDestination)
}

enum DashboardActionRouter {
    static func route(for action: DashboardPrimaryAction) -> DashboardRouteIntent? {
        guard action == .profileRequired else { return nil }
        return .selectDestination(.profiles)
    }
}
