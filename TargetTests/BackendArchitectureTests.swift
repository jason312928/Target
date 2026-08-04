import XCTest
@testable import Target

@MainActor
final class BackendArchitectureTests: XCTestCase {
    func testLifecycleStateTransitions() throws {
        XCTAssertEqual(try BackendLifecycleState.begin(.start, from: .stopped), .starting)
        XCTAssertEqual(try BackendLifecycleState.begin(.stop, from: .running), .stopping)
        XCTAssertThrowsError(try BackendLifecycleState.begin(.stop, from: .stopped)) { error in
            XCTAssertEqual(error as? BackendError, .invalidLifecycleTransition)
        }
    }

    func testMockBackendStartsAndStopsWhenServiceIsInstalled() async throws {
        let backend = MockBackend(initialStatus: BackendStatus(serviceInstallation: .installed, engineState: .stopped))

        let runningStatus = try await backend.startEngine()
        XCTAssertEqual(runningStatus.engineState, .running)

        let stoppedStatus = try await backend.stopEngine()
        XCTAssertEqual(stoppedStatus.engineState, .stopped)
    }

    func testMockBackendReportsServiceNotInstalled() async throws {
        let backend = MockBackend()

        do {
            _ = try await backend.startEngine()
            XCTFail("Expected a service-not-installed error")
        } catch let error as BackendError {
            XCTAssertEqual(error, .serviceNotInstalled)
        }
    }

    func testModelPresentsStartErrorWhenDefaultServiceIsMissing() async throws {
        let model = BackendLifecycleModel()
        model.start()

        try await waitUntil { model.error == .serviceNotInstalled }
        XCTAssertEqual(model.status.serviceInstallation, .notInstalled)
        XCTAssertEqual(model.status.engineState, .stopped)
        XCTAssertEqual(model.lifecycleState, .failed(.serviceNotInstalled))
    }

    func testConfigurationRequestValidationRejectsUnsupportedFieldsAndPaths() throws {
        let valid = XPCConfigurationRequest(profileName: "Default Profile")
        XCTAssertEqual(try XPCConfigurationRequest.decodeAndValidate(valid.encoded()), valid)

        let pathLikeRequest = XPCConfigurationRequest(profileName: "../Library/LaunchDaemons")
        XCTAssertThrowsError(try pathLikeRequest.validated()) { error in
            XCTAssertEqual(error as? BackendError, .invalidConfiguration(.invalidProfileName))
        }

        let unexpectedField = Data(#"{"version":1,"profileName":"Default","command":"sh"}"#.utf8)
        XCTAssertThrowsError(try XPCConfigurationRequest.decodeAndValidate(unexpectedField)) { error in
            XCTAssertEqual(error as? BackendError, .invalidConfiguration(.malformedRequest))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
