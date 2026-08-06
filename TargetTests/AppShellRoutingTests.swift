import XCTest
@testable import Target

final class AppShellRoutingTests: XCTestCase {
    func testDefaultDestinationIsDashboard() {
        XCTAssertEqual(AppDestination.defaultDestination, .dashboard)
    }

    func testShellMinimumWidthLeavesSpaceForNarrowDashboardAndProfileWorkspace() {
        XCTAssertEqual(AppShellLayout.minimumWindowWidth, 740)
        XCTAssertEqual(AppShellLayout.minimumWindowHeight, 460)
    }

    func testDestinationSetContainsOnlyDashboardAndProfilesWithStableIdentity() {
        XCTAssertEqual(AppDestination.allCases, [.dashboard, .profiles])
        XCTAssertEqual(AppDestination.visibleDestinations, [.dashboard, .profiles])
        XCTAssertEqual(AppDestination.dashboard.id, .dashboard)
        XCTAssertEqual(AppDestination.profiles.id, .profiles)
    }

    func testNavigationSectionsAndDestinationOrderAreStable() {
        XCTAssertEqual(AppNavigationSection.ordered, [.workspace])
        XCTAssertEqual(
            AppNavigationSection.ordered.flatMap { AppDestination.metadata(in: $0).map(\.destination) },
            [.dashboard, .profiles]
        )
    }

    func testEveryVisibleDestinationBelongsToExactlyOneSection() {
        for destination in AppDestination.visibleDestinations {
            let sections = AppNavigationSection.ordered.filter {
                AppDestination.metadata(in: $0).contains { $0.destination == destination }
            }
            XCTAssertEqual(sections, [destination.metadata.section])
        }
    }

    func testNavigationMetadataContainsNoUnimplementedDestination() {
        XCTAssertEqual(
            Set(AppDestination.navigationMetadata.map(\.destination)),
            Set([.dashboard, .profiles])
        )
    }

    func testMissingProfileRoutesOnlyToProfiles() {
        XCTAssertEqual(
            DashboardActionRouter.route(for: .profileRequired),
            .selectDestination(.profiles)
        )
    }

    func testProfileRequiredRouteNeverProducesLifecycleAction() {
        let route = DashboardActionRouter.route(for: .profileRequired)

        XCTAssertNotEqual(route, .selectDestination(.dashboard))
    }

    func testLifecycleActionsAreNotReplacedByNavigation() {
        XCTAssertNil(DashboardActionRouter.route(for: .installEngine))
        XCTAssertNil(DashboardActionRouter.route(for: .start))
        XCTAssertNil(DashboardActionRouter.route(for: .stop))
        XCTAssertNil(DashboardActionRouter.route(for: .restart))
        XCTAssertNil(DashboardActionRouter.route(for: .unavailable))
    }

    func testMissingPersistedSelectionFallsBackToDashboard() {
        XCTAssertEqual(AppDestination.destination(for: nil), .dashboard)
    }

    func testInvalidOrOldPersistedSelectionFallsBackToDashboard() {
        XCTAssertEqual(AppDestination.destination(for: "connections"), .dashboard)
        XCTAssertEqual(AppDestination.destination(for: ""), .dashboard)
    }

    func testValidPersistedSelectionRestoresDestination() {
        XCTAssertEqual(AppDestination.destination(for: "dashboard"), .dashboard)
        XCTAssertEqual(AppDestination.destination(for: "profiles"), .profiles)
    }
}
