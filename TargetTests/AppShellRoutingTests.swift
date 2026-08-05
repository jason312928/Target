import XCTest
@testable import Target

final class AppShellRoutingTests: XCTestCase {
    func testDefaultDestinationIsDashboard() {
        XCTAssertEqual(AppDestination.defaultDestination, .dashboard)
    }

    func testDestinationSetContainsOnlyDashboardAndProfilesWithStableIdentity() {
        XCTAssertEqual(AppDestination.allCases, [.dashboard, .profiles])
        XCTAssertEqual(AppDestination.dashboard.id, .dashboard)
        XCTAssertEqual(AppDestination.profiles.id, .profiles)
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

    func testMissingSelectionFallsBackToDashboard() {
        XCTAssertEqual(AppDestination.fallback(for: nil), .dashboard)
    }
}
