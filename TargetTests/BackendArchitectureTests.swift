import XCTest
import CFNetwork
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
        let backend = MockBackend(initialStatus: BackendStatus(serviceInstallation: .enabled, engineState: .stopped))

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
        let model = BackendLifecycleModel(backend: MockBackend())
        model.start()

        try await waitUntil { model.error == .serviceNotInstalled }
        XCTAssertEqual(model.status.serviceInstallation, .notRegistered)
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

    func testEngineLogRedactorRemovesIPv4Addresses() {
        let result = String(decoding: EngineLogRedactor.redact(Data("dial 203.0.113.42 [2001:db8::1] /Users/example/secret".utf8)), as: UTF8.self)
        XCTAssertFalse(result.contains("203.0.113.42"))
        XCTAssertFalse(result.contains("2001:db8"))
        XCTAssertFalse(result.contains("/Users/example"))
    }

    func testSingBoxManagedConfigurationAndLocalProxy() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SING_BOX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_SING_BOX_INTEGRATION_TESTS=1 after running the bundled installer.")
        }

        let backend = SingBoxBackend()
        try await backend.validateConfiguration(XPCConfigurationRequest(profileName: "Local Direct"))
        let running = try await backend.startEngine()
        XCTAssertEqual(running.engineState, .running)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: 2080,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: 2080
        ]
        let (_, response) = try await URLSession(configuration: configuration).data(from: URL(string: "https://example.com")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let stopped = try await backend.stopEngine()
        XCTAssertEqual(stopped.engineState, .stopped)
    }

    func testPrivilegedServicePingAndStatusWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["RUN_PRIVILEGED_SERVICE_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_PRIVILEGED_SERVICE_INTEGRATION_TESTS=1 after approving the service.")
        }

        let client = TargetServiceXPCClient()
        let ping = try await client.ping()
        XCTAssertEqual(ping, "target-service")

        let status = try await client.queryStatus()
        XCTAssertEqual(status.serviceInstallation, .enabled)
        XCTAssertEqual(status.engineState, .stopped)
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
