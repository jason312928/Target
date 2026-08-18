import XCTest
@testable import Target
@testable import TargetCore

@MainActor
final class TargetRuntimeOperationsTests: XCTestCase {
    func testConnectStartsEngineThenEnablesAuthoritativeSystemProxy() async throws {
        let events = RuntimeEventRecorder()
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus(), events: events)
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableStatus: managedProxyStatus(), events: events)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        let result = try await operations.connect()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        XCTAssertEqual(result.systemProxyStatus.state, .enabled)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["engine.start", "proxy.query", "proxy.enable"])
    }

    func testHostSafeConnectStartsEngineWithoutEnablingSystemProxy() async throws {
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableStatus: managedProxyStatus())
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .safe)

        let result = try await operations.connect()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        let enableCount = await proxy.enableCount
        XCTAssertEqual(enableCount, 0)
    }

    func testEngineStartFailureNeverEnablesSystemProxy() async {
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableStatus: managedProxyStatus())
        let operations = TargetRuntimeOperations(backend: FailingStartBackend(), systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.connect()) { XCTAssertEqual($0 as? BackendError, .engineLaunchFailed) }
        let enableCount = await proxy.enableCount
        XCTAssertEqual(enableCount, 0)
    }

    func testConnectEnableFailureSafelyStopsEngineWhenProxyIsRestored() async {
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableError: .applyFailed)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.connect()) { error in
            let failure = error as? TargetConnectionOperationError
            XCTAssertEqual(failure?.engineStatus.engineState, .stopped)
            XCTAssertEqual(failure?.systemProxyStatus, .disabled)
            XCTAssertEqual(failure?.engineWasStopped, true)
        }
        let stopCount = await backend.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testConnectEnableFailurePreservesRecoveryEvidenceAndRunningEngine() async {
        let recovery = SystemProxyStatus(state: .recoveryRequired, engineReachable: true, affectedServiceCount: 1, error: .recoveryFailed, hasRecoverySnapshot: true)
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableError: .applyFailed, statusAfterEnableFailure: recovery)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.connect()) { error in
            let failure = error as? TargetConnectionOperationError
            XCTAssertEqual(failure?.engineStatus.engineState, .running)
            XCTAssertEqual(failure?.systemProxyStatus, recovery)
            XCTAssertEqual(failure?.engineWasStopped, false)
        }
        let stopCount = await backend.stopCount
        XCTAssertEqual(stopCount, 0)
    }

    func testRestartPreservesInitiallyConnectedSession() async throws {
        let events = RuntimeEventRecorder()
        let backend = SafeStopBackend(events: events)
        let proxy = SafeStopProxyClient(queryStatus: managedProxyStatus(), enableStatus: managedProxyStatus(), disableStatus: .disabled, events: events)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        let result = try await operations.restart()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        XCTAssertEqual(result.systemProxyStatus.state, .enabled)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["proxy.query", "proxy.query", "proxy.restore", "engine.stop", "engine.start", "proxy.query", "proxy.enable"])
    }

    func testRestartPreservesInitiallyDisabledProxy() async throws {
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableStatus: managedProxyStatus())
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        let result = try await operations.restart()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        XCTAssertEqual(result.systemProxyStatus.state, .disabled)
        let enableCount = await proxy.enableCount
        XCTAssertEqual(enableCount, 0)
    }

    func testRestartReenableFailureUsesFailClosedConnectionRollback() async {
        let recovery = SystemProxyStatus(state: .recoveryRequired, engineReachable: true, affectedServiceCount: 1, error: .recoveryFailed, hasRecoverySnapshot: true)
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(
            queryStatus: managedProxyStatus(),
            disableStatus: .disabled,
            enableError: .applyFailed,
            statusAfterEnableFailure: recovery
        )
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        await assertThrowsAsync(try await operations.restart()) { error in
            let failure = error as? TargetConnectionOperationError
            XCTAssertEqual(failure?.engineStatus.engineState, .running)
            XCTAssertEqual(failure?.systemProxyStatus, recovery)
            XCTAssertEqual(failure?.engineWasStopped, false)
        }
        let stopCount = await backend.stopCount
        XCTAssertEqual(stopCount, 1, "Only the pre-restart safe stop is allowed")
    }

    func testDisconnectRestoresRecoverySnapshotEvenWhenEngineIsAlreadyStopped() async throws {
        let events = RuntimeEventRecorder()
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus(), events: events)
        let proxy = SafeStopProxyClient(queryStatus: managedProxyStatus(), disableStatus: .disabled, events: events)
        let operations = TargetRuntimeOperations(backend: backend, systemProxyClient: proxy, hostNetworkSafetyMode: .authorizedNetworkTest)

        let result = try await operations.disconnect()

        XCTAssertEqual(result.engineStatus.engineState, .stopped)
        XCTAssertEqual(result.systemProxyStatus, .disabled)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["proxy.query", "proxy.restore"])
    }

    func testLifecycleRefreshNeverEnablesSystemProxy() async throws {
        let backend = SafeStopBackend()
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableStatus: managedProxyStatus())
        let model = BackendLifecycleModel(
            backend: backend,
            systemProxyClient: proxy,
            hostNetworkSafetyMode: .normalUser,
            serviceRegistrationStatusProvider: { .enabled }
        )

        model.refresh()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.status.engineState, .running)
        XCTAssertEqual(model.systemProxyStatus.state, .disabled)
        let enableCount = await proxy.enableCount
        XCTAssertEqual(enableCount, 0)
    }

    func testLifecycleConnectFailurePublishesRolledBackAuthoritativeState() async throws {
        let stopped = stoppedBackendStatus()
        let failure = TargetConnectionOperationError(
            operationError: .applyFailed,
            engineStatus: stopped,
            systemProxyStatus: .disabled,
            engineWasStopped: true
        )
        let shared = ConnectionOperationSpy(
            connectResult: .failure(failure),
            disconnectResult: .failure(BackendError.notImplemented)
        )
        let model = BackendLifecycleModel(
            backend: SafeStopBackend(initialStatus: stopped),
            connectionOperations: shared,
            hostNetworkSafetyMode: .normalUser
        )
        model.applyAutomationEngineStatus(stopped)

        model.start()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.status.engineState, .stopped)
        XCTAssertEqual(model.systemProxyStatus, .disabled)
        XCTAssertEqual(model.error, .serviceUnavailable)
        XCTAssertEqual(model.lifecycleState, .failed(.serviceUnavailable))
    }

    func testTargetCtlConnectionGrammarIsHighLevelAndArgumentFree() throws {
        XCTAssertEqual(try TargetCtlCommandParser.parse(["connect", "--json"]).action, "connection.start")
        XCTAssertEqual(try TargetCtlCommandParser.parse(["disconnect", "--json"]).action, "connection.stop")
        XCTAssertEqual(try TargetCtlCommandParser.parse(["restart", "--json"]).action, "connection.restart")
        XCTAssertThrowsError(try TargetCtlCommandParser.parse(["connect", "extra", "--json"]))
    }

    func testConnectionAutomationUsesSharedOperationAndReturnsConnectionTruth() async {
        let runtime = RuntimeOperationSpy(
            result: .failure(BackendError.notImplemented),
            startResult: .failure(BackendError.notImplemented)
        )
        let shared = ConnectionOperationSpy(
            connectResult: .success(TargetConnectionResult(engineStatus: runningBackendStatus(), systemProxyStatus: managedProxyStatus())),
            disconnectResult: .success(EngineStopResult(engineStatus: stoppedBackendStatus(), systemProxyStatus: .disabled))
        )
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: SafeStopBackend(initialStatus: stoppedBackendStatus()),
            runtimeOperations: runtime,
            connectionOperations: shared
        )

        let connected = await operations.handle(AutomationRequest(protocolVersion: 1, action: "connection.start"))
        let restarted = await operations.handle(AutomationRequest(protocolVersion: 1, action: "connection.restart"))
        let disconnected = await operations.handle(AutomationRequest(protocolVersion: 1, action: "connection.stop"))

        XCTAssertTrue(connected.ok)
        XCTAssertTrue(restarted.ok)
        XCTAssertTrue(disconnected.ok)
        let encoded = String(decoding: AutomationProtocol.encodeResponse(connected), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""connected":true"#))
        XCTAssertTrue(encoded.contains(#""statusAuthoritative":true"#))
        XCTAssertTrue(encoded.contains(#""hasRecoverySnapshot":true"#))
        let connectCount = await shared.connectCount
        let disconnectCount = await shared.disconnectCount
        let restartCount = await shared.restartCount
        let runtimeStartCount = await runtime.startCallCount
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(runtimeStartCount, 0)
    }

    func testLowLevelAutomationSemanticsRemainIndependent() async {
        let runtime = RuntimeOperationSpy(
            result: .failure(BackendError.notImplemented),
            startResult: .success(EngineStartResult(engineStatus: runningBackendStatus(), systemProxyStatus: .disabled))
        )
        let shared = ConnectionOperationSpy(
            connectResult: .failure(BackendError.notImplemented),
            disconnectResult: .failure(BackendError.notImplemented)
        )
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let proxy = SafeStopProxyClient(queryStatus: .disabled, enableStatus: managedProxyStatus())
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: backend,
            serviceClient: proxy,
            runtimeOperations: runtime,
            connectionOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        let engineResponse = await operations.handle(AutomationRequest(protocolVersion: 1, action: "engine.start"))
        XCTAssertTrue(engineResponse.ok)
        let runtimeStartCount = await runtime.startCallCount
        let connectCount = await shared.connectCount
        let initialEnableCount = await proxy.enableCount
        XCTAssertEqual(runtimeStartCount, 1)
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(initialEnableCount, 0)

        let proxyResponse = await operations.handle(AutomationRequest(protocolVersion: 1, action: "proxy.enable"))
        XCTAssertTrue(proxyResponse.ok)
        let backendStartCount = await backend.startCount
        let finalEnableCount = await proxy.enableCount
        XCTAssertEqual(backendStartCount, 0)
        XCTAssertEqual(finalEnableCount, 1)
    }

    func testStartCalibratesSystemProxyStatusAfterEngineStarts() async throws {
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let calibrated = SystemProxyStatus(
            state: .disabled,
            engineReachable: true,
            affectedServiceCount: 0,
            error: nil,
            hasRecoverySnapshot: false
        )
        let proxy = SafeStopProxyClient(queryStatus: calibrated)
        let sharedProxy = TargetSystemProxyOperations(client: proxy)
        let operations = TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: proxy,
            systemProxyOperations: sharedProxy,
            hostNetworkSafetyMode: .safe
        )

        let result = try await operations.startEngine()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        XCTAssertEqual(result.systemProxyStatus, calibrated)
        let startCount = await backend.startCount
        let queryCount = await proxy.queryCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(queryCount, 1)
    }

    func testStartStatusQueryFailureKeepsEngineRunningAndFailsProxyAuthorityClosed() async throws {
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let proxy = SafeStopProxyClient(queryStatus: .disabled, queryError: .statusUnavailable)
        let operations = TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: proxy,
            systemProxyOperations: TargetSystemProxyOperations(client: proxy),
            hostNetworkSafetyMode: .safe
        )

        let result = try await operations.startEngine()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        XCTAssertEqual(result.systemProxyStatus.state, .failed)
        XCTAssertEqual(result.systemProxyStatus.error, .statusUnavailable)
        XCTAssertFalse(result.systemProxyStatus.hasRecoverySnapshot)
    }

    func testStartStatusQueryFailurePreservesSharedRecoveryEvidence() async throws {
        let backend = SafeStopBackend(initialStatus: stoppedBackendStatus())
        let reconciled = SystemProxyStatus(
            state: .failed,
            engineReachable: false,
            affectedServiceCount: 1,
            error: .statusUnavailable,
            hasRecoverySnapshot: true
        )
        let proxyOperation = StartProxyOperationStub(result: .failure(
            TargetSystemProxyOperationError(operationError: .statusUnavailable, reconciledStatus: reconciled)
        ))
        let operations = TargetRuntimeOperations(
            backend: backend,
            systemProxyOperations: proxyOperation,
            hostNetworkSafetyMode: .safe
        )

        let result = try await operations.startEngine()

        XCTAssertEqual(result.engineStatus.engineState, .running)
        XCTAssertEqual(result.systemProxyStatus, reconciled)
        XCTAssertTrue(result.systemProxyStatus.hasRecoverySnapshot)
    }

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

    func testLifecycleModelStopPublishesReturnedProxyStatus() async throws {
        let finalProxy = SystemProxyStatus(
            state: .disabled,
            engineReachable: false,
            affectedServiceCount: 0,
            error: nil,
            hasRecoverySnapshot: false
        )
        let sharedOperation = RuntimeOperationSpy(result: .success(EngineStopResult(
            engineStatus: stoppedBackendStatus(),
            systemProxyStatus: finalProxy
        )))
        let model = BackendLifecycleModel(backend: SafeStopBackend(), runtimeOperations: sharedOperation)
        model.applyAutomationEngineStatus(runningBackendStatus())
        model.applyAutomationSystemProxyStatus(managedProxyStatus())

        model.stop()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.status.engineState, .stopped)
        XCTAssertEqual(model.systemProxyStatus, finalProxy)
        XCTAssertNil(model.error)
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

    func testAutomationEngineStopPublishesEngineAndReturnedProxyStatus() async {
        let finalProxy = SystemProxyStatus(
            state: .disabled,
            engineReachable: false,
            affectedServiceCount: 0,
            error: nil,
            hasRecoverySnapshot: false
        )
        let sharedOperation = RuntimeOperationSpy(result: .success(EngineStopResult(
            engineStatus: stoppedBackendStatus(),
            systemProxyStatus: finalProxy
        )))
        let model = BackendLifecycleModel(backend: SafeStopBackend(), runtimeOperations: sharedOperation)
        model.applyAutomationEngineStatus(runningBackendStatus())
        model.applyAutomationSystemProxyStatus(managedProxyStatus())
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: SafeStopBackend(),
            runtimeOperations: sharedOperation,
            engineStatusObserver: { status in
                await MainActor.run { model.applyAutomationEngineStatus(status) }
            },
            systemProxyStatusObserver: { status in
                await MainActor.run { model.applyAutomationSystemProxyStatus(status) }
            }
        )

        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "engine.stop"))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(model.status.engineState, .stopped)
        XCTAssertEqual(model.systemProxyStatus, finalProxy)
    }

    func testGUIAndAutomationEngineStartPublishSameCalibratedProxyStatus() async throws {
        let calibrated = SystemProxyStatus(
            state: .disabled,
            engineReachable: true,
            affectedServiceCount: 0,
            error: nil,
            hasRecoverySnapshot: false
        )
        let startResult = EngineStartResult(engineStatus: runningBackendStatus(), systemProxyStatus: calibrated)
        let sharedOperation = RuntimeOperationSpy(
            result: .success(EngineStopResult(engineStatus: stoppedBackendStatus(), systemProxyStatus: .disabled)),
            startResult: .success(startResult)
        )
        let model = BackendLifecycleModel(
            backend: SafeStopBackend(initialStatus: stoppedBackendStatus()),
            runtimeOperations: sharedOperation
        )
        model.applyAutomationEngineStatus(stoppedBackendStatus())
        model.applyAutomationSystemProxyStatus(SystemProxyStatus(
            state: .failed,
            engineReachable: false,
            affectedServiceCount: 0,
            error: .localProxyUnavailable,
            hasRecoverySnapshot: false
        ))

        model.start()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.status.engineState, .running)
        XCTAssertEqual(model.systemProxyStatus, calibrated)

        model.applyAutomationEngineStatus(stoppedBackendStatus())
        model.applyAutomationSystemProxyStatus(.disabled)
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: SafeStopBackend(initialStatus: stoppedBackendStatus()),
            runtimeOperations: sharedOperation,
            engineStatusObserver: { status in
                await MainActor.run { model.applyAutomationEngineStatus(status) }
            },
            systemProxyStatusObserver: { status in
                await MainActor.run { model.applyAutomationSystemProxyStatus(status) }
            }
        )
        let response = await automation.handle(AutomationRequest(protocolVersion: 1, action: "engine.start"))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(model.status.engineState, .running)
        XCTAssertEqual(model.systemProxyStatus, calibrated)
        let startCallCount = await sharedOperation.startCallCount
        XCTAssertEqual(startCallCount, 2)
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
    private(set) var startCount = 0

    init(initialStatus: BackendStatus = runningBackendStatus(), events: RuntimeEventRecorder? = nil) {
        status = initialStatus
        self.events = events
    }

    func queryStatus() async throws -> BackendStatus { status }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {}
    func startEngine() async throws -> BackendStatus {
        startCount += 1
        await events?.append("engine.start")
        status.engineState = .running
        return status
    }

    func stopEngine() async throws -> BackendStatus {
        stopCount += 1
        await events?.append("engine.stop")
        status.engineState = .stopped
        return status
    }
}

private actor SafeStopProxyClient: SystemProxyClient {
    private var queryStatus: SystemProxyStatus
    private let enableStatus: SystemProxyStatus
    private let disableStatus: SystemProxyStatus
    private let enableError: SystemProxyError?
    private let statusAfterEnableFailure: SystemProxyStatus?
    private let queryError: SystemProxyError?
    private let disableError: SystemProxyError?
    private let events: RuntimeEventRecorder?
    private let disableGate: RuntimeGate?
    private(set) var queryCount = 0
    private(set) var enableCount = 0
    private(set) var disableCount = 0

    init(
        queryStatus: SystemProxyStatus,
        enableStatus: SystemProxyStatus? = nil,
        disableStatus: SystemProxyStatus = .disabled,
        enableError: SystemProxyError? = nil,
        statusAfterEnableFailure: SystemProxyStatus? = nil,
        queryError: SystemProxyError? = nil,
        disableError: SystemProxyError? = nil,
        events: RuntimeEventRecorder? = nil,
        disableGate: RuntimeGate? = nil
    ) {
        self.queryStatus = queryStatus
        self.enableStatus = enableStatus ?? queryStatus
        self.disableStatus = disableStatus
        self.enableError = enableError
        self.statusAfterEnableFailure = statusAfterEnableFailure
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

    func enableSystemProxy() async throws -> SystemProxyStatus {
        enableCount += 1
        await events?.append("proxy.enable")
        if let enableError {
            if let statusAfterEnableFailure { queryStatus = statusAfterEnableFailure }
            throw enableError
        }
        queryStatus = enableStatus
        return enableStatus
    }

    func disableSystemProxy() async throws -> SystemProxyStatus {
        disableCount += 1
        await events?.append("proxy.restore")
        await disableGate?.waitUntilReleased()
        if let disableError { throw disableError }
        queryStatus = disableStatus
        return disableStatus
    }

    func recoverSystemProxy() async throws -> SystemProxyStatus { try await disableSystemProxy() }
}

private actor FailingStartBackend: EngineBackend {
    func queryStatus() async throws -> BackendStatus { stoppedBackendStatus() }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {}
    func startEngine() async throws -> BackendStatus { throw BackendError.engineLaunchFailed }
    func stopEngine() async throws -> BackendStatus { stoppedBackendStatus() }
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

private actor RuntimeOperationSpy: TargetRuntimeOperating, TargetConnectionOperating {
    private let result: Result<EngineStopResult, Error>
    private let startResult: Result<EngineStartResult, Error>
    private(set) var callCount = 0
    private(set) var startCallCount = 0

    init(
        result: Result<EngineStopResult, Error>,
        startResult: Result<EngineStartResult, Error> = .failure(BackendError.notImplemented)
    ) {
        self.result = result
        self.startResult = startResult
    }

    func startEngine() async throws -> EngineStartResult {
        startCallCount += 1
        return try startResult.get()
    }

    func stopEngineSafely() async throws -> EngineStopResult {
        callCount += 1
        return try result.get()
    }

    func connect() async throws -> TargetConnectionResult {
        let started = try await startEngine()
        return TargetConnectionResult(engineStatus: started.engineStatus, systemProxyStatus: started.systemProxyStatus)
    }

    func disconnect() async throws -> EngineStopResult { try await stopEngineSafely() }

    func restart() async throws -> TargetConnectionResult {
        _ = try await stopEngineSafely()
        return try await connect()
    }
}

private actor ConnectionOperationSpy: TargetConnectionOperating {
    private let connectResult: Result<TargetConnectionResult, Error>
    private let disconnectResult: Result<EngineStopResult, Error>
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var restartCount = 0

    init(
        connectResult: Result<TargetConnectionResult, Error>,
        disconnectResult: Result<EngineStopResult, Error>
    ) {
        self.connectResult = connectResult
        self.disconnectResult = disconnectResult
    }

    func connect() async throws -> TargetConnectionResult {
        connectCount += 1
        return try connectResult.get()
    }

    func disconnect() async throws -> EngineStopResult {
        disconnectCount += 1
        return try disconnectResult.get()
    }

    func restart() async throws -> TargetConnectionResult {
        restartCount += 1
        return try connectResult.get()
    }
}

private actor StartProxyOperationStub: TargetSystemProxyOperating {
    private let result: Result<SystemProxyStatus, Error>
    init(result: Result<SystemProxyStatus, Error>) { self.result = result }
    func queryStatus() async throws -> SystemProxyStatus { try result.get() }
    func enable() async throws -> SystemProxyStatus { try result.get() }
    func disable() async throws -> SystemProxyStatus { try result.get() }
    func recover() async throws -> SystemProxyStatus { try result.get() }
}

private struct RuntimePassingChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}
