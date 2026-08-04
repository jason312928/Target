import XCTest
import CFNetwork
@testable import Target

@MainActor
final class BackendArchitectureTests: XCTestCase {
    func testSystemProxySnapshotRestoresEveryProxySetting() async throws {
        let original: [String: SystemProxyValue] = [
            "HTTPEnable": .integer(0),
            "HTTPProxy": .string("proxy.example"),
            "HTTPPort": .integer(3128),
            "HTTPSEnable": .integer(1),
            "HTTPSProxy": .string("secure.example"),
            "HTTPSPort": .integer(8443),
            "SOCKSEnable": .integer(1),
            "SOCKSProxy": .string("socks.example"),
            "SOCKSPort": .integer(1080),
            "ProxyAutoConfigEnable": .integer(1),
            "ProxyAutoConfigURLString": .string("https://pac.example/proxy.pac"),
            "ProxyAutoDiscoveryEnable": .integer(1),
            "ExceptionsList": .strings(["localhost", "*.internal"])
        ]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let store = InMemoryRecoveryStore()
        let probe = TogglePortProbe(available: true)
        let coordinator = testCoordinator(system: system, store: store, probe: probe)

        let enabled = try await coordinator.enableSystemProxy()
        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a")["HTTPProxy"], .string("127.0.0.1"))
        let disabled = try await coordinator.disableSystemProxy()
        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
        XCTAssertNil(try store.load())
    }

    func testSystemProxyPartialApplyFailureRollsBack() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(
            serviceIDs: ["service-a", "service-b"],
            settings: ["service-a": original, "service-b": original],
            failOnWrite: 2
        )
        let store = InMemoryRecoveryStore()
        let coordinator = testCoordinator(system: system, store: store, probe: TogglePortProbe(available: true))

        do {
            _ = try await coordinator.enableSystemProxy()
            XCTFail("Expected transactional apply to fail")
        } catch let error as SystemProxyError {
            XCTAssertEqual(error, .applyFailed)
        }
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
        XCTAssertEqual(try system.proxySettings(for: "service-b"), original)
        XCTAssertNil(try store.load())
    }

    func testSystemProxyEnableDisableIsIdempotent() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let coordinator = testCoordinator(system: system, store: InMemoryRecoveryStore(), probe: TogglePortProbe(available: true))

        let firstEnable = try await coordinator.enableSystemProxy()
        let secondEnable = try await coordinator.enableSystemProxy()
        XCTAssertEqual(firstEnable.state, .enabled)
        XCTAssertEqual(secondEnable.state, .enabled)
        XCTAssertEqual(system.writeCount, 1)
        let firstDisable = try await coordinator.disableSystemProxy()
        let secondDisable = try await coordinator.disableSystemProxy()
        XCTAssertEqual(firstDisable.state, .disabled)
        XCTAssertEqual(secondDisable.state, .disabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
    }

    func testSystemProxyAutomaticallyRestoresWhenLocalPortDisappears() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let probe = TogglePortProbe(available: true)
        let store = InMemoryRecoveryStore()
        let coordinator = testCoordinator(system: system, store: store, probe: probe)

        _ = try await coordinator.enableSystemProxy()
        await probe.setAvailable(false)
        await coordinator.checkPortHealth()
        XCTAssertNotEqual(try system.proxySettings(for: "service-a"), original)
        XCTAssertNotNil(try store.load())
        let status = await coordinator.querySystemProxyStatus()
        XCTAssertEqual(status.state, .recoveryRequired)
    }

    func testSystemProxyXPCPayloadRejectsUnknownState() {
        let invalid = Data(#"{"state":"shell","engineReachable":true,"affectedServiceCount":1}"#.utf8)
        XCTAssertThrowsError(try XPCPayloadCodec.decodeSystemProxyStatus(invalid))
    }

    func testSystemProxyStatesExposeRequiredTransitions() async throws {
        XCTAssertEqual(SystemProxyState.disabled.rawValue, "disabled")
        XCTAssertEqual(SystemProxyState.enabling.rawValue, "enabling")
        XCTAssertEqual(SystemProxyState.enabled.rawValue, "enabled")
        XCTAssertEqual(SystemProxyState.disabling.rawValue, "disabling")
        XCTAssertEqual(SystemProxyState.recoveryRequired.rawValue, "recovery_required")
        XCTAssertEqual(SystemProxyState.failed.rawValue, "failed")
    }

    func testSafeModeBlocksNetworkWrites() async throws {
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]])
        let coordinator = SystemProxyCoordinator(system: system, recoveryStore: InMemoryRecoveryStore(), portProbe: TogglePortProbe(available: true))
        await XCTAssertThrowsErrorAsync(try await coordinator.enableSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .safeModeBlocked)
        }
        XCTAssertEqual(system.writeCount, 0)
    }

    func testExistingProxyApplicationRefusesTakeover() async throws {
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]])
        let coordinator = SystemProxyCoordinator(
            system: system,
            recoveryStore: InMemoryRecoveryStore(),
            portProbe: TogglePortProbe(available: true),
            environment: FixedHostEnvironment(proxyConfigured: false, proxyApplicationRunning: true),
            safetyMode: .authorizedNetworkTest
        )
        await XCTAssertThrowsErrorAsync(try await coordinator.enableSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .existingNetworkController)
        }
        XCTAssertEqual(system.writeCount, 0)
    }

    func testRecoveryRequiresTargetOwnedSnapshotAndUnmodifiedSettings() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let store = InMemoryRecoveryStore()
        let coordinator = testCoordinator(system: system, store: store, probe: TogglePortProbe(available: true))
        _ = try await coordinator.enableSystemProxy()
        system.forceSettings(["HTTPEnable": .integer(0)], for: "service-a")
        await XCTAssertThrowsErrorAsync(try await coordinator.recoverSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .externalModificationConflict)
        }
        let foreign = SystemProxyRecoveryRecord(owner: "foreign", snapshots: [], writtenSettings: [:])
        try store.save(foreign)
        await XCTAssertThrowsErrorAsync(try await coordinator.recoverSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .invalidSnapshotOwner)
        }
    }

    func testNoSnapshotDisablesRecovery() async throws {
        let coordinator = testCoordinator(
            system: InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]]),
            store: InMemoryRecoveryStore(),
            probe: TogglePortProbe(available: true)
        )
        let status = await coordinator.querySystemProxyStatus()
        XCTAssertFalse(status.hasRecoverySnapshot)
    }
    func testLifecycleStateTransitions() throws {
        XCTAssertEqual(try BackendLifecycleState.begin(.start, from: .stopped), .starting)
        XCTAssertEqual(try BackendLifecycleState.begin(.stop, from: .running), .stopping)
        XCTAssertThrowsError(try BackendLifecycleState.begin(.stop, from: .stopped)) { error in
            XCTAssertEqual(error as? BackendError, .invalidLifecycleTransition)
        }
    }

    func testServiceRegistrationAndXPCStatusAreIndependent() {
        XCTAssertEqual(ServiceConnectionAssessment.xpcState(registration: .requiresApproval, xpcReachable: false), .unknown)
        XCTAssertEqual(ServiceConnectionAssessment.xpcState(registration: .enabled, xpcReachable: false), .unavailable)
        XCTAssertEqual(ServiceConnectionAssessment.xpcState(registration: .enabled, xpcReachable: true), .connected)
    }

    func testProcessWithoutOwnedPortIsNotReportedAsRunning() {
        XCTAssertEqual(EngineRuntimeReadiness.visibleState(processIsOwned: true, portIsListening: false), .stopped)
        XCTAssertEqual(EngineRuntimeReadiness.startupFailure(processStillRunning: true), .enginePortUnavailable)
    }

    func testEngineRuntimeRecordRequiresHighDynamicPort() {
        let lowPort = EngineRuntimeRecord(pid: 42, executablePath: "/tmp/sing-box", endpoint: LocalEngineEndpoint(port: 2080))
        let highPort = EngineRuntimeRecord(pid: 42, executablePath: "/tmp/sing-box", endpoint: LocalEngineEndpoint(port: 51_234))
        XCTAssertFalse(lowPort.isValid)
        XCTAssertTrue(highPort.isValid)
    }

    func testOwnedRuntimeRejectsUnmatchedProcessEvenWhenPortListens() async {
        let record = EngineRuntimeRecord(pid: 42, executablePath: "/tmp/target-sing-box", endpoint: LocalEngineEndpoint(port: 51_234))
        let ownership = EngineRuntimeOwnership(
            store: FixedEngineRuntimeStore(record: record),
            processInspector: FixedEngineProcessInspector(shouldMatch: false),
            portProbe: FixedEnginePortProbe(listening: true)
        )
        let endpoint = await ownership.ownedEndpoint()
        XCTAssertNil(endpoint)
    }

    func testDynamicPortSelectorReturnsHighPort() throws {
        XCTAssertGreaterThanOrEqual(try DynamicHighLocalPortSelector().selectAvailablePort(), LocalEngineEndpoint.minimumDynamicPort)
    }

    func testServiceRegistrationRejectsDerivedDataBundlePath() {
        let temporaryApp = URL(fileURLWithPath: "/tmp/DerivedData/Target/Build/Products/Release/Target.app")
        XCTAssertFalse(TargetServiceBundleLocation.isStable(temporaryApp))
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

    func testSuccessfulRefreshClearsOldBackendError() async throws {
        let backend = MockBackend(initialStatus: BackendStatus(serviceInstallation: .enabled, engineState: .stopped))
        let model = BackendLifecycleModel(backend: backend)
        model.stop()
        XCTAssertEqual(model.error, .invalidLifecycleTransition)
        model.refresh()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.error)
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
            kCFNetworkProxiesHTTPPort as String: running.enginePort!,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: running.enginePort!
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

    private func testCoordinator(
        system: InMemorySystemProxySystem,
        store: InMemoryRecoveryStore,
        probe: TogglePortProbe
    ) -> SystemProxyCoordinator {
        SystemProxyCoordinator(
            system: system,
            recoveryStore: store,
            portProbe: probe,
            environment: FixedHostEnvironment(proxyConfigured: false, proxyApplicationRunning: false),
            safetyMode: .authorizedNetworkTest,
            endpointProvider: { LocalEngineEndpoint(port: 51_234) }
        )
    }
}

private final class FixedEngineRuntimeStore: EngineRuntimeStoring, @unchecked Sendable {
    private let record: EngineRuntimeRecord?

    init(record: EngineRuntimeRecord?) {
        self.record = record
    }

    func load() throws -> EngineRuntimeRecord? { record }
    func save(_ record: EngineRuntimeRecord) throws { XCTFail("Unexpected runtime record write") }
    func clear() throws { XCTFail("Unexpected runtime record removal") }
}

private struct FixedEngineProcessInspector: EngineProcessInspecting {
    let shouldMatch: Bool

    func matches(pid: Int32, executablePath: String) -> Bool { shouldMatch }
}

private struct FixedEnginePortProbe: LocalEnginePortProbing {
    let listening: Bool

    func isListening(on port: UInt16) async -> Bool { listening }
}

private final class InMemorySystemProxySystem: SystemProxySystemManaging, @unchecked Sendable {
    private let serviceIDs: [String]
    private var settings: [String: [String: SystemProxyValue]]
    private var failOnWrite: Int?
    private(set) var writeCount = 0

    init(serviceIDs: [String], settings: [String: [String: SystemProxyValue]], failOnWrite: Int? = nil) {
        self.serviceIDs = serviceIDs
        self.settings = settings
        self.failOnWrite = failOnWrite
    }

    func activeServiceIDs() throws -> [String] { serviceIDs }

    func proxySettings(for serviceID: String) throws -> [String: SystemProxyValue] {
        guard let settings = settings[serviceID] else { throw SystemProxyError.noActiveNetworkService }
        return settings
    }

    func setProxySettings(_ settings: [String: SystemProxyValue], for serviceID: String) throws {
        writeCount += 1
        if writeCount == failOnWrite {
            failOnWrite = nil
            throw SystemProxyError.applyFailed
        }
        self.settings[serviceID] = settings
    }

    func forceSettings(_ settings: [String: SystemProxyValue], for serviceID: String) {
        self.settings[serviceID] = settings
    }
}

private final class InMemoryRecoveryStore: SystemProxyRecoveryStoring, @unchecked Sendable {
    private var record: SystemProxyRecoveryRecord?

    func load() throws -> SystemProxyRecoveryRecord? { record }
    func save(_ record: SystemProxyRecoveryRecord) throws { self.record = record }
    func clear() throws { record = nil }
}

private actor TogglePortProbe: LocalProxyProbing {
    private var available: Bool

    init(available: Bool) { self.available = available }
    func isAvailable() async -> Bool { available }
    func setAvailable(_ available: Bool) { self.available = available }
}

private struct FixedHostEnvironment: HostNetworkEnvironmentChecking {
    let proxyConfigured: Bool
    let proxyApplicationRunning: Bool

    func inspect() -> HostNetworkEnvironmentStatus {
        HostNetworkEnvironmentStatus(
            hasConfiguredSystemProxy: proxyConfigured,
            hasRunningProxyApplication: proxyApplicationRunning
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        handler(error)
    }
}
