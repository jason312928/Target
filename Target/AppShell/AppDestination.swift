import Foundation

enum AppNavigationSection: String, CaseIterable, Hashable, Identifiable {
    case workspace

    static let ordered: [Self] = [.workspace]

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .workspace: "navigation.section.workspace"
        }
    }
}

struct AppDestinationMetadata: Identifiable {
    let destination: AppDestination
    let section: AppNavigationSection
    let sortOrder: Int
    let title: LocalizedStringResource
    let symbolName: String

    var id: AppDestination { destination }
}

enum AppDestination: String, CaseIterable, Hashable, Identifiable {
    case dashboard
    case profiles
    case connections
    case traffic
    case logs

    static let defaultDestination: Self = .dashboard

    var id: Self { self }

    static let navigationMetadata: [AppDestinationMetadata] = [
        AppDestinationMetadata(
            destination: .dashboard,
            section: .workspace,
            sortOrder: 0,
            title: "dashboard.title",
            symbolName: "rectangle.grid.1x2"
        ),
        AppDestinationMetadata(
            destination: .profiles,
            section: .workspace,
            sortOrder: 1,
            title: "profile.title",
            symbolName: "doc.text"
        ),
        AppDestinationMetadata(
            destination: .connections,
            section: .workspace,
            sortOrder: 2,
            title: "connections.title",
            symbolName: "point.3.connected.trianglepath.dotted"
        ),
        AppDestinationMetadata(
            destination: .traffic,
            section: .workspace,
            sortOrder: 3,
            title: "traffic.title",
            symbolName: "chart.xyaxis.line"
        ),
        AppDestinationMetadata(
            destination: .logs,
            section: .workspace,
            sortOrder: 4,
            title: "logs.title",
            symbolName: "text.alignleft"
        ),
    ]

    static var visibleDestinations: [Self] {
        navigationMetadata
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.destination)
    }

    var metadata: AppDestinationMetadata {
        guard let metadata = Self.navigationMetadata.first(where: { $0.destination == self }) else {
            preconditionFailure("Every AppDestination must have navigation metadata.")
        }
        return metadata
    }

    static func metadata(in section: AppNavigationSection) -> [AppDestinationMetadata] {
        navigationMetadata
            .filter { $0.section == section }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    static func destination(for persistedRawValue: String?) -> Self {
        guard let persistedRawValue, let destination = Self(rawValue: persistedRawValue) else {
            return defaultDestination
        }
        return destination
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
