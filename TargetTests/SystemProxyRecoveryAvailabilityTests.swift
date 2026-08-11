import XCTest
@testable import Target
@testable import TargetCore

@MainActor
final class SystemProxyRecoveryAvailabilityTests: XCTestCase {
    func testRecoveryPolicyAllowsOwnedSnapshotWhenLocalProxyIsUnavailable() {
        let capability = recoveryStatus(error: .localProxyUnavailable).recoveryCapability(
            hostNetworkSafetyMode: .authorizedNetworkTest,
            isOperationInProgress: false
        )
        XCTAssertEqual(capability, SystemProxyRecoveryCapability(isAvailable: true, blocker: nil))
    }

    func testRecoveryPolicyBlocksExternalModificationConflictPrecisely() {
        let capability = recoveryStatus(error: .externalModificationConflict).recoveryCapability(
            hostNetworkSafetyMode: .authorizedNetworkTest,
            isOperationInProgress: false
        )
        XCTAssertEqual(capability.blocker, .externalModificationConflict)
        XCTAssertFalse(capability.isAvailable)
    }

    func testRecoveryPolicyBlocksInvalidOwnerAndUnreadableRecord() {
        let invalidOwner = recoveryStatus(error: .invalidSnapshotOwner, hasSnapshot: false).recoveryCapability(
            hostNetworkSafetyMode: .authorizedNetworkTest,
            isOperationInProgress: false
        )
        let unreadable = recoveryStatus(error: .snapshotFailed, hasSnapshot: false).recoveryCapability(
            hostNetworkSafetyMode: .authorizedNetworkTest,
            isOperationInProgress: false
        )
        XCTAssertEqual(invalidOwner.blocker, .invalidSnapshotOwner)
        XCTAssertEqual(unreadable.blocker, .unreadableRecoveryRecord)
        XCTAssertFalse(invalidOwner.isAvailable)
        XCTAssertFalse(unreadable.isAvailable)
    }

    func testRecoveryPolicyDisablesRestoredStateAndBusyOperation() {
        let restored = SystemProxyStatus.disabled.recoveryCapability(
            hostNetworkSafetyMode: .authorizedNetworkTest,
            isOperationInProgress: false
        )
        let busy = recoveryStatus(error: .localProxyUnavailable).recoveryCapability(
            hostNetworkSafetyMode: .authorizedNetworkTest,
            isOperationInProgress: true
        )
        XCTAssertEqual(restored.blocker, .recoveryNotRequired)
        XCTAssertEqual(busy.blocker, .operationInProgress)
        XCTAssertFalse(restored.isAvailable)
        XCTAssertFalse(busy.isAvailable)
    }

    func testDisableFailureReconcilesAuthoritativeSnapshotAndKeepsRecoveryAvailable() async throws {
        let initial = SystemProxyStatus(
            state: .enabled,
            engineReachable: true,
            affectedServiceCount: 1,
            error: nil,
            hasRecoverySnapshot: true
        )
        let authoritative = recoveryStatus(error: .localProxyUnavailable)
        let client = SequencedSystemProxyClient(
            queries: [.success(initial), .success(authoritative)],
            disableError: .recoveryFailed
        )
        let shared = TargetSystemProxyOperations(client: client)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyClient: client,
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        model.disableSystemProxy()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.systemProxyStatus, authoritative)
        XCTAssertTrue(model.systemProxyStatus.hasRecoverySnapshot)
        XCTAssertTrue(model.canRecoverSystemProxy)
    }

    func testExternalConflictReconciliationRemainsFailClosedWithExactReason() async throws {
        let initial = SystemProxyStatus(
            state: .enabled,
            engineReachable: true,
            affectedServiceCount: 1,
            error: nil,
            hasRecoverySnapshot: true
        )
        let authoritative = recoveryStatus(error: .externalModificationConflict)
        let client = SequencedSystemProxyClient(
            queries: [.success(initial), .success(authoritative)],
            disableError: .externalModificationConflict
        )
        let shared = TargetSystemProxyOperations(client: client)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyClient: client,
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        model.disableSystemProxy()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.systemProxyStatus.error, .externalModificationConflict)
        XCTAssertEqual(model.systemProxyRecoveryCapability.blocker, .externalModificationConflict)
        XCTAssertFalse(model.canRecoverSystemProxy)
    }

    func testFailedMutationAndFailedQueryDoNotFabricateRecoverySnapshot() async throws {
        let initial = SystemProxyStatus(
            state: .failed,
            engineReachable: false,
            affectedServiceCount: 0,
            error: .applyFailed,
            hasRecoverySnapshot: false
        )
        let client = SequencedSystemProxyClient(
            queries: [.success(initial), .failure(.snapshotFailed)],
            disableError: .recoveryFailed
        )
        let shared = TargetSystemProxyOperations(client: client)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyClient: client,
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        model.disableSystemProxy()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.systemProxyStatus.state, .failed)
        XCTAssertEqual(model.systemProxyStatus.error, .statusUnavailable)
        XCTAssertFalse(model.systemProxyStatus.hasRecoverySnapshot)
        XCTAssertEqual(model.systemProxyRecoveryCapability.blocker, .statusUnavailable)
        XCTAssertFalse(model.canRecoverSystemProxy)
    }

    func testFailedAuthoritativeQueryPreservesKnownSnapshotButBlocksRecovery() async throws {
        let initial = SystemProxyStatus(
            state: .enabled,
            engineReachable: true,
            affectedServiceCount: 1,
            error: nil,
            hasRecoverySnapshot: true
        )
        let client = SequencedSystemProxyClient(
            queries: [.success(initial), .failure(.snapshotFailed)],
            disableError: .recoveryFailed
        )
        let shared = TargetSystemProxyOperations(client: client)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyClient: client,
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        model.disableSystemProxy()
        try await waitUntil { !model.isBusy }

        XCTAssertTrue(model.systemProxyStatus.hasRecoverySnapshot)
        XCTAssertEqual(model.systemProxyStatus.error, .statusUnavailable)
        XCTAssertEqual(model.systemProxyRecoveryCapability.blocker, .statusUnavailable)
        XCTAssertFalse(model.canRecoverSystemProxy)
    }

    func testSuccessfulRecoveryClearsRecoveryAvailability() async throws {
        let client = SequencedSystemProxyClient(
            queries: [.success(recoveryStatus(error: .localProxyUnavailable))],
            recoverStatus: .disabled
        )
        let shared = TargetSystemProxyOperations(client: client)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyClient: client,
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        model.recoverSystemProxy()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.systemProxyStatus, .disabled)
        XCTAssertFalse(model.canRecoverSystemProxy)
    }

    func testSuccessfulGUIEnableUsesSharedResultAndSettlesToggleOn() async throws {
        let enabled = SystemProxyStatus(
            state: .enabled,
            engineReachable: true,
            affectedServiceCount: 1,
            error: nil,
            hasRecoverySnapshot: true
        )
        let shared = StaticSystemProxyOperation(status: enabled)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        model.applyAutomationEngineStatus(BackendStatus(
            serviceInstallation: .enabled,
            engineState: .running,
            engineInstallation: .installed,
            hasSelectedValidProfile: true
        ))

        model.enableSystemProxy()
        model.enableSystemProxy()
        try await waitUntil { !model.isBusy }

        let enableCount = await shared.enableCount
        XCTAssertEqual(enableCount, 1)
        XCTAssertEqual(model.systemProxyStatus, enabled)
        XCTAssertNil(model.systemProxyStatus.error)
        XCTAssertTrue(DashboardPresentation(
            status: model.status,
            lifecycleState: model.lifecycleState,
            serviceInstallation: model.serviceInstallation,
            xpcState: model.xpcState,
            error: model.error,
            systemProxyStatus: model.systemProxyStatus,
            isBusy: model.isBusy,
            isHostSafeMode: model.isHostSafeMode
        ).isSystemProxyToggleOn)
    }

    func testSuccessfulGUIDisableUsesSharedResultAndSettlesToggleOff() async throws {
        let disabled = SystemProxyStatus(
            state: .disabled,
            engineReachable: true,
            affectedServiceCount: 0,
            error: nil,
            hasRecoverySnapshot: false
        )
        let shared = StaticSystemProxyOperation(status: disabled)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        model.applyAutomationSystemProxyStatus(SystemProxyStatus(
            state: .enabled,
            engineReachable: true,
            affectedServiceCount: 1,
            error: nil,
            hasRecoverySnapshot: true
        ))

        model.disableSystemProxy()
        model.disableSystemProxy()
        try await waitUntil { !model.isBusy }

        let disableCount = await shared.disableCount
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(model.systemProxyStatus, disabled)
        XCTAssertFalse(DashboardPresentation(
            status: model.status,
            lifecycleState: model.lifecycleState,
            serviceInstallation: model.serviceInstallation,
            xpcState: model.xpcState,
            error: model.error,
            systemProxyStatus: model.systemProxyStatus,
            isBusy: model.isBusy,
            isHostSafeMode: model.isHostSafeMode
        ).isSystemProxyToggleOn)
    }

    func testFailedEnableKeepsSpecificErrorAndReconciledToggleTruth() async throws {
        let reconciled = SystemProxyStatus(
            state: .failed,
            engineReachable: false,
            affectedServiceCount: 0,
            error: .localProxyUnavailable,
            hasRecoverySnapshot: false
        )
        let shared = FailingEnableSystemProxyOperation(reconciledStatus: reconciled)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        model.applyAutomationEngineStatus(BackendStatus(
            serviceInstallation: .enabled,
            engineState: .running,
            engineInstallation: .installed,
            hasSelectedValidProfile: true
        ))

        model.enableSystemProxy()
        try await waitUntil { !model.isBusy }

        XCTAssertEqual(model.systemProxyStatus, reconciled)
        XCTAssertEqual(model.systemProxyErrorKey, "system-proxy.error.local-proxy-unavailable")
        XCTAssertFalse(DashboardPresentation(
            status: model.status,
            lifecycleState: model.lifecycleState,
            serviceInstallation: model.serviceInstallation,
            xpcState: model.xpcState,
            error: model.error,
            systemProxyStatus: model.systemProxyStatus,
            isBusy: model.isBusy,
            isHostSafeMode: model.isHostSafeMode
        ).isSystemProxyToggleOn)
    }

    func testBusyModelPreventsDuplicateRecovery() async throws {
        let gate = RecoveryOperationGate()
        let shared = GatedSystemProxyOperation(status: recoveryStatus(error: .localProxyUnavailable), gate: gate)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }

        model.recoverSystemProxy()
        model.recoverSystemProxy()
        try await waitUntil { await shared.recoverCount == 1 }
        XCTAssertEqual(model.systemProxyRecoveryCapability.blocker, .operationInProgress)
        await gate.release()
        try await waitUntil { !model.isBusy }

        let recoverCount = await shared.recoverCount
        XCTAssertEqual(recoverCount, 1)
    }

    func testAutomationProxyStatusAndConsolidatedStatusUseSameRecoveryFacts() async {
        let status = recoveryStatus(error: .localProxyUnavailable)
        let shared = StaticSystemProxyOperation(status: status)
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        let proxy = await operations.handle(AutomationRequest(protocolVersion: 1, action: "proxy.status"))
        let consolidated = await operations.handle(AutomationRequest(protocolVersion: 1, action: "status"))
        let proxyFields = objectFields(proxy)
        let consolidatedFields = objectFields(consolidated)

        for fields in [proxyFields, consolidatedFields] {
            XCTAssertEqual(fields["systemProxyState"], .string("recovery_required"))
            XCTAssertEqual(fields["engineReachable"], .boolean(false))
            XCTAssertEqual(fields["affectedServiceCount"], .integer(1))
            XCTAssertEqual(fields["hasRecoverySnapshot"], .boolean(true))
            XCTAssertEqual(fields["recoveryAvailable"], .boolean(true))
        }
        XCTAssertEqual(proxyFields["recoveryBlocker"], .null)
        XCTAssertEqual(consolidatedFields["recoveryBlocker"], .null)
    }

    func testAutomationConflictUsesSharedPolicyAndRedactsRecoveryFailure() async {
        let conflict = recoveryStatus(error: .externalModificationConflict)
        let internalDetail = "/private/test-path service-a credential-fixture"
        let client = SensitiveRecoveryClient(
            status: conflict,
            error: NSError(
                domain: "com.jason312928.Target.TargetService",
                code: 106,
                userInfo: [NSLocalizedDescriptionKey: internalDetail]
            )
        )
        let shared = TargetSystemProxyOperations(client: client)
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        let statusResponse = await operations.handle(AutomationRequest(protocolVersion: 1, action: "proxy.status"))
        let recoveryResponse = await operations.handle(AutomationRequest(protocolVersion: 1, action: "proxy.recover"))
        let json = String(decoding: AutomationProtocol.encodeResponse(recoveryResponse), as: UTF8.self)

        XCTAssertEqual(objectFields(statusResponse)["recoveryBlocker"], .string("external_modification_conflict"))
        XCTAssertEqual(objectFields(statusResponse)["recoveryAvailable"], .boolean(false))
        XCTAssertEqual(recoveryResponse.error?.code, "proxy_external_change_conflict")
        XCTAssertFalse(json.contains("NSError"))
        XCTAssertFalse(json.contains(internalDetail))
        XCTAssertFalse(json.contains("service-a"))
        XCTAssertFalse(json.contains("credential-fixture"))
    }

    func testAutomationProxyStatusPreservesKnownSnapshotWhenAuthorityBecomesUnavailable() async throws {
        let shared = TargetSystemProxyOperations(client: SequencedSystemProxyClient(queries: [
            .success(recoveryStatus(error: .localProxyUnavailable)),
            .failure(.statusUnavailable)
        ]))
        _ = try await shared.queryStatus()
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "proxy.status"))
        let fields = objectFields(response)
        let json = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(fields["systemProxyState"], .string("failed"))
        XCTAssertEqual(fields["engineReachable"], .boolean(false))
        XCTAssertEqual(fields["affectedServiceCount"], .integer(1))
        XCTAssertEqual(fields["hasRecoverySnapshot"], .boolean(true))
        XCTAssertEqual(fields["recoveryAvailable"], .boolean(false))
        XCTAssertEqual(fields["recoveryBlocker"], .string("status_unavailable"))
        XCTAssertEqual(fields["statusAuthoritative"], .boolean(false))
        XCTAssertFalse(json.contains("NSError"))
        XCTAssertFalse(json.contains("/private/"))
    }

    func testAutomationConsolidatedStatusPreservesKnownSnapshotWhenAuthorityBecomesUnavailable() async throws {
        let shared = TargetSystemProxyOperations(client: SequencedSystemProxyClient(queries: [
            .success(recoveryStatus(error: .localProxyUnavailable)),
            .failure(.statusUnavailable)
        ]))
        _ = try await shared.queryStatus()
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "status"))
        let fields = objectFields(response)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(fields["systemProxyState"], .string("failed"))
        XCTAssertEqual(fields["engineReachable"], .boolean(false))
        XCTAssertEqual(fields["affectedServiceCount"], .integer(1))
        XCTAssertEqual(fields["hasRecoverySnapshot"], .boolean(true))
        XCTAssertEqual(fields["recoveryAvailable"], .boolean(false))
        XCTAssertEqual(fields["recoveryBlocker"], .string("status_unavailable"))
        XCTAssertEqual(fields["statusAuthoritative"], .boolean(false))
    }

    func testAutomationStatusDoesNotFabricateSnapshotWithoutAuthoritativeEvidence() async {
        let shared = TargetSystemProxyOperations(client: SequencedSystemProxyClient(queries: [
            .failure(.statusUnavailable),
            .failure(.statusUnavailable)
        ]))
        let operations = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        for action in ["proxy.status", "status"] {
            let fields = objectFields(await operations.handle(
                AutomationRequest(protocolVersion: 1, action: action)
            ))
            XCTAssertEqual(fields["systemProxyState"], .string("failed"))
            XCTAssertEqual(fields["engineReachable"], .boolean(false))
            XCTAssertEqual(fields["affectedServiceCount"], .integer(0))
            XCTAssertEqual(fields["hasRecoverySnapshot"], .boolean(false))
            XCTAssertEqual(fields["recoveryAvailable"], .boolean(false))
            XCTAssertEqual(fields["recoveryBlocker"], .string("status_unavailable"))
            XCTAssertEqual(fields["statusAuthoritative"], .boolean(false))
        }
    }

    func testGUIAndAutomationAgreeAfterSharedAuthoritativeQueryFailure() async throws {
        let shared = TargetSystemProxyOperations(client: SequencedSystemProxyClient(queries: [
            .success(recoveryStatus(error: .localProxyUnavailable)),
            .failure(.statusUnavailable),
            .failure(.statusUnavailable)
        ]))
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        let fields = objectFields(await automation.handle(
            AutomationRequest(protocolVersion: 1, action: "proxy.status")
        ))

        XCTAssertEqual(fields["hasRecoverySnapshot"], .boolean(model.systemProxyStatus.hasRecoverySnapshot))
        XCTAssertEqual(fields["recoveryAvailable"], .boolean(model.canRecoverSystemProxy))
        XCTAssertEqual(
            fields["recoveryBlocker"],
            model.systemProxyRecoveryCapability.blocker.map { .string($0.rawValue) } ?? .null
        )
        XCTAssertEqual(fields["statusAuthoritative"], .boolean(false))
    }

    func testGUIAndAutomationInvokeOneInjectedSystemProxyOperation() async throws {
        let shared = StaticSystemProxyOperation(status: recoveryStatus(error: .localProxyUnavailable))
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )

        model.refreshSystemProxyStatus()
        try await waitUntil { !model.isBusy }
        _ = await automation.handle(AutomationRequest(protocolVersion: 1, action: "proxy.status"))

        let queryCount = await shared.queryCount
        XCTAssertEqual(queryCount, 2)
    }

    func testAutomationProxyStatusPublishesRecoveryAvailabilityToDashboardModel() async throws {
        let authoritative = recoveryStatus(error: .localProxyUnavailable)
        let shared = StaticSystemProxyOperation(status: authoritative)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest,
            systemProxyStatusObserver: { status in
                await MainActor.run { model.applyAutomationSystemProxyStatus(status) }
            }
        )

        let response = await automation.handle(AutomationRequest(
            protocolVersion: 1,
            action: "proxy.status"
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(model.systemProxyStatus, authoritative)
        XCTAssertTrue(model.canRecoverSystemProxy)
        XCTAssertNil(model.systemProxyRecoveryCapability.blocker)
    }

    func testAutomationProxyEnablePublishesSameFinalStatusAndJSON() async {
        let enabled = SystemProxyStatus(
            state: .enabled,
            engineReachable: true,
            affectedServiceCount: 1,
            error: nil,
            hasRecoverySnapshot: true
        )
        let shared = StaticSystemProxyOperation(status: enabled)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest,
            systemProxyStatusObserver: { status in
                await MainActor.run { model.applyAutomationSystemProxyStatus(status) }
            }
        )

        let response = await automation.handle(AutomationRequest(protocolVersion: 1, action: "proxy.enable"))
        guard case let .object(fields) = response.result else { return XCTFail("Expected result") }

        XCTAssertTrue(response.ok)
        XCTAssertEqual(fields["systemProxyState"], .string("enabled"))
        XCTAssertEqual(fields["engineReachable"], .boolean(true))
        XCTAssertEqual(model.systemProxyStatus, enabled)
        let enableCount = await shared.enableCount
        XCTAssertEqual(enableCount, 1)
    }

    func testAutomationProxyDisablePublishesSameFinalStatusAndJSON() async {
        let disabled = SystemProxyStatus(
            state: .disabled,
            engineReachable: true,
            affectedServiceCount: 0,
            error: nil,
            hasRecoverySnapshot: false
        )
        let shared = StaticSystemProxyOperation(status: disabled)
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        model.applyAutomationSystemProxyStatus(managedProxyStatusForIssue4())
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest,
            systemProxyStatusObserver: { status in
                await MainActor.run { model.applyAutomationSystemProxyStatus(status) }
            }
        )

        let response = await automation.handle(AutomationRequest(protocolVersion: 1, action: "proxy.disable"))
        guard case let .object(fields) = response.result else { return XCTFail("Expected result") }

        XCTAssertTrue(response.ok)
        XCTAssertEqual(fields["systemProxyState"], .string("disabled"))
        XCTAssertEqual(fields["hasRecoverySnapshot"], .boolean(false))
        XCTAssertEqual(model.systemProxyStatus, disabled)
        let disableCount = await shared.disableCount
        XCTAssertEqual(disableCount, 1)
    }

    func testFailedAutomationProxyMutationPublishesReconciledStatusToDashboardModel() async {
        let reconciled = recoveryStatus(error: .externalModificationConflict)
        let shared = TargetSystemProxyOperations(client: SensitiveRecoveryClient(
            status: reconciled,
            error: NSError(domain: "com.jason312928.Target.TargetService", code: 106)
        ))
        let model = BackendLifecycleModel(
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest
        )
        let automation = TargetAutomationOperations(
            profileStore: testProfileStore(),
            backend: MockBackend(),
            systemProxyOperations: shared,
            hostNetworkSafetyMode: .authorizedNetworkTest,
            systemProxyStatusObserver: { status in
                await MainActor.run { model.applyAutomationSystemProxyStatus(status) }
            }
        )

        let response = await automation.handle(AutomationRequest(
            protocolVersion: 1,
            action: "proxy.recover"
        ))

        XCTAssertEqual(response.error?.code, "proxy_external_change_conflict")
        XCTAssertEqual(model.systemProxyStatus, reconciled)
        XCTAssertEqual(model.systemProxyRecoveryCapability.blocker, .externalModificationConflict)
        XCTAssertFalse(model.canRecoverSystemProxy)
    }

    private func objectFields(_ response: AutomationResponse) -> [String: JSONValue] {
        guard case let .object(fields) = response.result else {
            XCTFail("Expected object response")
            return [:]
        }
        return fields
    }

    private func testProfileStore() -> ProfileStore {
        ProfileStore(
            rootDirectory: FileManager.default.temporaryDirectory.appending(path: "Target-Issue3-\(UUID().uuidString)"),
            checker: Issue3PassingChecker(),
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
}

private func recoveryStatus(
    error: SystemProxyError?,
    hasSnapshot: Bool = true
) -> SystemProxyStatus {
    SystemProxyStatus(
        state: .recoveryRequired,
        engineReachable: error != .localProxyUnavailable,
        affectedServiceCount: hasSnapshot ? 1 : 0,
        error: error,
        hasRecoverySnapshot: hasSnapshot
    )
}

private func managedProxyStatusForIssue4() -> SystemProxyStatus {
    SystemProxyStatus(
        state: .enabled,
        engineReachable: true,
        affectedServiceCount: 1,
        error: nil,
        hasRecoverySnapshot: true
    )
}

private actor SequencedSystemProxyClient: SystemProxyClient {
    private var queries: [Result<SystemProxyStatus, SystemProxyError>]
    private let disableError: SystemProxyError?
    private let recoverStatus: SystemProxyStatus

    init(
        queries: [Result<SystemProxyStatus, SystemProxyError>],
        disableError: SystemProxyError? = nil,
        recoverStatus: SystemProxyStatus = .disabled
    ) {
        self.queries = queries
        self.disableError = disableError
        self.recoverStatus = recoverStatus
    }

    func ping() async throws -> String { "test" }
    func querySystemProxyStatus() async throws -> SystemProxyStatus {
        guard !queries.isEmpty else { throw SystemProxyError.statusUnavailable }
        return try queries.removeFirst().get()
    }
    func enableSystemProxy() async throws -> SystemProxyStatus { .disabled }
    func disableSystemProxy() async throws -> SystemProxyStatus {
        if let disableError { throw disableError }
        return .disabled
    }
    func recoverSystemProxy() async throws -> SystemProxyStatus { recoverStatus }
}

private actor RecoveryOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedSystemProxyOperation: TargetSystemProxyOperating {
    private let status: SystemProxyStatus
    private let gate: RecoveryOperationGate
    private(set) var recoverCount = 0
    init(status: SystemProxyStatus, gate: RecoveryOperationGate) {
        self.status = status
        self.gate = gate
    }
    func queryStatus() async throws -> SystemProxyStatus { status }
    func enable() async throws -> SystemProxyStatus { status }
    func disable() async throws -> SystemProxyStatus { status }
    func recover() async throws -> SystemProxyStatus {
        recoverCount += 1
        await gate.wait()
        return .disabled
    }
}

private actor StaticSystemProxyOperation: TargetSystemProxyOperating {
    private let status: SystemProxyStatus
    private(set) var queryCount = 0
    private(set) var enableCount = 0
    private(set) var disableCount = 0
    init(status: SystemProxyStatus) { self.status = status }
    func queryStatus() async throws -> SystemProxyStatus { queryCount += 1; return status }
    func enable() async throws -> SystemProxyStatus { enableCount += 1; return status }
    func disable() async throws -> SystemProxyStatus { disableCount += 1; return status }
    func recover() async throws -> SystemProxyStatus { .disabled }
}

private actor FailingEnableSystemProxyOperation: TargetSystemProxyOperating {
    private let reconciledStatus: SystemProxyStatus
    init(reconciledStatus: SystemProxyStatus) { self.reconciledStatus = reconciledStatus }
    func queryStatus() async throws -> SystemProxyStatus { reconciledStatus }
    func enable() async throws -> SystemProxyStatus {
        throw TargetSystemProxyOperationError(
            operationError: .localProxyUnavailable,
            reconciledStatus: reconciledStatus
        )
    }
    func disable() async throws -> SystemProxyStatus { reconciledStatus }
    func recover() async throws -> SystemProxyStatus { reconciledStatus }
}

private actor SensitiveRecoveryClient: SystemProxyClient {
    private let status: SystemProxyStatus
    private let error: NSError
    init(status: SystemProxyStatus, error: NSError) {
        self.status = status
        self.error = error
    }
    func ping() async throws -> String { "test" }
    func querySystemProxyStatus() async throws -> SystemProxyStatus { status }
    func enableSystemProxy() async throws -> SystemProxyStatus { status }
    func disableSystemProxy() async throws -> SystemProxyStatus { status }
    func recoverSystemProxy() async throws -> SystemProxyStatus { throw error }
}

private struct Issue3PassingChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}
