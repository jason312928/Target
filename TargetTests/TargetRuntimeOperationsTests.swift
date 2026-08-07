import XCTest
@testable import Target

@MainActor
final class TargetRuntimeOperationsTests: XCTestCase {
    func testNoManagedProxyStopsEngineExactlyOnce() async throws {
        let events = RuntimeEventRecorder()
        let backend = SafeStopBackend(events: events)
        let proxy = SafeStopProxyClient(queryStatus: .disabled, events: events)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        let result = try await operations.stopEngineSafely()

        XCTAssertEqual(result.engineStatus.engineState, .stopped)
        let stopCount = await backend.stopCount
        let disableCount = await proxy.disableCount
        let recordedEvents = await events.values
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(disableCount, 0)
        XCTAssertEqual(recordedEvents, ["proxy.query", "engine.stop"])
    }

    func testManagedProxyRestoresBeforeEngineStop() async throws {
        let events = RuntimeEventRecorder()
        let backend = SafeStopBackend(events: events)
        let proxy = SafeStopProxyClient(queryStatus: managedProxyStatus(), disableStatus: .disabled, events: events)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        let result = try await operations.stopEngineSafely()

        XCTAssertEqual(result.systemProxyStatus, .disabled)
        XCTAssertEqual(result.engineStatus.engineState, .stopped)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["proxy.query", "proxy.restore", "engine.stop"])
    }

    func testRestoreFailurePreventsEngineStop() async { await assertRestoreFailure(.recoveryFailed) }
    func testExternalModificationConflictPreventsEngineStop() async { await assertRestoreFailure(.externalModificationConflict) }
    func testInvalidSnapshotOwnerPreventsEngineStop() async { await assertRestoreFailure(.invalidSnapshotOwner) }
    func testVerificationFailurePreventsEngineStop() async { await assertRestoreFailure(.verificationFailed) }

    func testUnverifiedRestoreResultPreventsEngineStop() async {
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(
            queryStatus: managedProxyStatus(),
            disableStatus: SystemProxyStatus(
                state: .recoveryRequired,
                engineReachable: true,
                affectedServiceCount: 1,
                error: .verificationFailed,
                hasRecoverySnapshot: true
            )
        )
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.stopEngineSafely()) { error in
            XCTAssertEqual(error as? SystemProxyError, .verificationFailed)
        }
        let stopCount = await backend.stopCount
        XCTAssertEqual(stopCount, 0)
    }

    func testUnknownProxyStatePreventsEngineStop() async {
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(queryStatus: .disabled, queryError: .snapshotFailed)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.stopEngineSafely()) { error in
            XCTAssertEqual(error as? SystemProxyError, .snapshotFailed)
        }
        let stopCount = await backend.stopCount
        XCTAssertEqual(stopCount, 0)
    }

    func testHostSafeStopDoesNotRequirePrivilegedService() async throws {
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(queryStatus: .disabled, queryError: .snapshotFailed)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .safe)

        let result = try await operations.stopEngineSafely()

        XCTAssertEqual(result.engineStatus.engineState, .stopped)
        let stopCount = await backend.stopCount
        let queryCount = await proxy.queryCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(queryCount, 0)
    }

    func testCancellationAfterRestoreLeavesEngineRunningAndDoesNotWriteAgain() async throws {
        let gate = RuntimeGate()
        let events = RuntimeEventRecorder()
        let backend = SafeStopBackend(events: events)
        let proxy = SafeStopProxyClient(
            queryStatus: managedProxyStatus(),
            disableStatus: .disabled,
            events: events,
            disableGate: gate
        )
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)
        let task = Task { try await operations.stopEngineSafely() }
        try await waitUntil { await events.values.contains("proxy.restore") }

        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation after proxy restoration")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let stopCount = await backend.stopCount
        let disableCount = await proxy.disableCount
        let recordedEvents = await events.values
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(recordedEvents, ["proxy.query", "proxy.restore"])
    }

    func testLifecycleModelUsesSharedSafeStopAndSettlesRunningAfterFailure() async throws {
        let running = runningBackendStatus()
        let backend = SafeStopBackend(initialStatus: running)
        let sharedOperation = RuntimeOperationSpy(result: .failure(SystemProxyError.externalModificationConflict))
        let model = BackendLifecycleModel(backend: backend, runtimeOperations: sharedOperation, hostNetworkSafetyMode: .safe)
        model.applyAutomationEngineStatus(running)

        model.stop()
        try await waitUntil { !model.isBusy }

        let operationCallCount = await sharedOperation.callCount
        let backendStopCount = await backend.stopCount
        XCTAssertEqual(operationCallCount, 1)
        XCTAssertEqual(backendStopCount, 0)
        XCTAssertEqual(model.status.engineState, .running)
        XCTAssertEqual(model.lifecycleState, .running)
        XCTAssertEqual(model.error, .serviceUnavailable)
        XCTAssertTrue(model.canStop)
    }

    func testAutomationEngineStopUsesSharedOperationAndReturnsStableJSON() async {
        let backend = SafeStopBackend()
        let sharedOperation = RuntimeOperationSpy(result: .success(EngineStopResult(
            engineStatus: stoppedBackendStatus(),
            systemProxyStatus: .disabled
        )))
        let operations = TargetAutomationOperations(profileStore: testProfileStore(), backend: backend, runtimeOperations: sharedOperation)

        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "engine.stop"))

        XCTAssertTrue(response.ok)
        let operationCallCount = await sharedOperation.callCount
        let backendStopCount = await backend.stopCount
        XCTAssertEqual(operationCallCount, 1)
        XCTAssertEqual(backendStopCount, 0)
        XCTAssertEqual(
            String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self),
            #"{"error":null,"ok":true,"protocolVersion":1,"result":{"engineInstallation":"installed","engineState":"stopped","restartRequired":false,"selectedValidProfile":true}}"#
        )
    }

    func testAutomationRestoreFailureUsesStableRedactedProxyError() async {
        let internalDetail = "/private/path credential-fixture"
        let failure = NSError(
            domain: "com.jason312928.Target.TargetService",
            code: 106,
            userInfo: [NSLocalizedDescriptionKey: internalDetail]
        )
        let sharedOperation = RuntimeOperationSpy(result: .failure(failure))
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: SafeStopBackend(),
            runtimeOperations: sharedOperation
        )

        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "engine.stop"))
        let json = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "proxy_external_change_conflict")
        XCTAssertFalse(json.contains("NSError"))
        XCTAssertFalse(json.contains(internalDetail))
        XCTAssertFalse(json.contains("credential-fixture"))
    }

    private func assertRestoreFailure(_ error: SystemProxyError) async {
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(queryStatus: managedProxyStatus(), disableError: error)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.stopEngineSafely()) { thrown in
            XCTAssertEqual(thrown as? SystemProxyError, error)
        }
        let stopCount = await backend.stopCount
        XCTAssertEqual(stopCount, 0)
    }

    private func testProfileStore() -> ProfileStore {
        ProfileStore(
            rootDirectory: FileManager.default.temporaryDirectory.appending(path: "Target-Issue2-\(UUID().uuidString)"),
            checker: RuntimePassingChecker(),
            keyProvider: TestProfileKeyProvider()
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertThrowsAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        verify: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected operation to throw")
        } catch {
            verify(error)
        }
    }
}

private func managedProxyStatus() -> SystemProxyStatus {
    SystemProxyStatus(state: .enabled, engineReachable: true, affectedServiceCount: 1, error: nil, hasRecoverySnapshot: true)
}

private func runningBackendStatus() -> BackendStatus {
    BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed, hasSelectedValidProfile: true)
}

private func stoppedBackendStatus() -> BackendStatus {
    BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: true)
}

private actor RuntimeEventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor SafeStopBackend: EngineBackend {
    private var status: BackendStatus
    private let events: RuntimeEventRecorder?
    private(set) var stopCount = 0

    init(initialStatus: BackendStatus = runningBackendStatus(), events: RuntimeEventRecorder? = nil) {
        status = initialStatus
        self.events = events
    }

    func queryStatus() async throws -> BackendStatus { status }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {}
    func startEngine() async throws -> BackendStatus { status }

    func stopEngine() async throws -> BackendStatus {
        stopCount += 1
        await events?.append("engine.stop")
        status.engineState = .stopped
        return status
    }
}

private actor SafeStopProxyClient: SystemProxyClient {
    private let queryStatus: SystemProxyStatus
    private let disableStatus: SystemProxyStatus
    private let queryError: SystemProxyError?
    private let disableError: SystemProxyError?
    private let events: RuntimeEventRecorder?
    private let disableGate: RuntimeGate?
    private(set) var queryCount = 0
    private(set) var disableCount = 0

    init(
        queryStatus: SystemProxyStatus,
        disableStatus: SystemProxyStatus = .disabled,
        queryError: SystemProxyError? = nil,
        disableError: SystemProxyError? = nil,
        events: RuntimeEventRecorder? = nil,
        disableGate: RuntimeGate? = nil
    ) {
        self.queryStatus = queryStatus
        self.disableStatus = disableStatus
        self.queryError = queryError
        self.disableError = disableError
        self.events = events
        self.disableGate = disableGate
    }

    func ping() async throws -> String { "test" }

    func querySystemProxyStatus() async throws -> SystemProxyStatus {
        queryCount += 1
        await events?.append("proxy.query")
        if let queryError { throw queryError }
        return queryStatus
    }

    func enableSystemProxy() async throws -> SystemProxyStatus { queryStatus }

    func disableSystemProxy() async throws -> SystemProxyStatus {
        disableCount += 1
        await events?.append("proxy.restore")
        await disableGate?.waitUntilReleased()
        if let disableError { throw disableError }
        return disableStatus
    }

    func recoverSystemProxy() async throws -> SystemProxyStatus { try await disableSystemProxy() }
}

private actor RuntimeGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeOperationSpy: TargetRuntimeOperating {
    private let result: Result<EngineStopResult, Error>
    private(set) var callCount = 0

    init(result: Result<EngineStopResult, Error>) { self.result = result }

    func stopEngineSafely() async throws -> EngineStopResult {
        callCount += 1
        return try result.get()
    }
}

private struct RuntimePassingChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}
