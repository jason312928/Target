import XCTest
@testable import Target

final class AppShellRoutingTests: XCTestCase {
    func testSingleWorkspaceKeepsUsableMinimumWindowSize() {
        XCTAssertEqual(AppShellLayout.minimumWindowWidth, 740)
        XCTAssertEqual(AppShellLayout.minimumWindowHeight, 460)
    }
}
