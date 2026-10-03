import Foundation
import XCTest
import TargetCore
@testable import Target

final class SmartPolicyShadowTests: XCTestCase, ProfileTestCaseSupport {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func catalog(_ tags: [String] = ["a", "b"]) -> PolicyCatalog {
        PolicyCatalogParser.parse(Data(policyConfiguration(configuredDefault: tags.first ?? "a", members: tags).utf8), profileID: UUID(), profileRevision: 1)
    }

    private func health(_ tag: String, _ latency: Int = 100) -> RuntimeProxyHealth {
        .reachable(tag: tag, latencyMilliseconds: latency, observedAt: time)!
    }

    private func flow(_ id: String, chain: [String] = ["a", "group"], bytes: Int64 = 1) -> RuntimeConnection {
        .init(id: id, destinationHost: "sensitive.example.invalid", destinationIP: "203.0.113.77", destinationPort: 443,
              network: "tcp", inbound: "mixed", outboundChain: chain, uploadBytes: 1, downloadBytes: bytes, startedAt: time)
    }

    private func result(_ probes: [RuntimeProxyHealth], current: String = "a", flows: [RuntimeConnection] = [], total: Int? = nil, session: UUID = UUID()) -> SmartShadowRuntimeResult {
        .available(.init(sessionID: session, currentOutbound: current, probes: .results(probes),
                         connections: .init(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: total ?? flows.count), connections: flows)))
    }

    private func coordinator(_ catalog: PolicyCatalog, runtime: ShadowRuntimeSpy) -> SmartPolicyShadowOperations {
        let fixed = time
        return .init(catalogReader: ShadowCatalogReader(catalog), runtime: runtime, clock: { fixed })
    }

    func testStoppedUnavailableOwnershipAndIdentityDoNotPolluteNodes() async throws {
        for value in [SmartShadowRuntimeResult.stopped, .unavailable("runtimeUnavailable"), .unavailable("ownershipUnavailable"), .unavailable("identityMismatch"), .unavailable("controllerUnavailable")] {
            let runtime = ShadowRuntimeSpy(value)
            let operations = coordinator(catalog(), runtime: runtime)
            let output = try await operations.evaluate()
            XCTAssertEqual(output.confidence, .low)
            XCTAssertNil(output.recommendedOutbound)
            let state = await operations.retainedState()
            XCTAssertTrue(state.nodes.isEmpty)
        }
    }

    func testEmptySingleMultipleAndCandidateBounds() async throws {
        let emptyRuntime = ShadowRuntimeSpy(.stopped)
        let empty = try await coordinator(catalog([]), runtime: emptyRuntime).evaluate()
        XCTAssertNil(empty.recommendedOutbound)
        let count = await emptyRuntime.calls
        XCTAssertEqual(count, 0)
        let single = try await coordinator(catalog(["a"]), runtime: ShadowRuntimeSpy(result([health("a")]))).evaluate()
        XCTAssertEqual(single.recommendedOutbound, "a")
        XCTAssertEqual(single.candidateCount, 1)
        let multi = try await coordinator(catalog(), runtime: ShadowRuntimeSpy(result([health("a"), health("b", 40)]))).evaluate()
        XCTAssertEqual(multi.recommendedOutbound, "b")
        let oversized = try await coordinator(catalog((0...64).map { "n\($0)" }), runtime: emptyRuntime).evaluate()
        XCTAssertEqual(oversized.reasonCodes, ["candidateSetUnavailable"])
        XCTAssertEqual(oversized.candidateCount, 64)
    }

    func testCurrentMissingStaleAndUntrustedProbeSetAreUnavailable() async throws {
        for value in [result([health("a"), health("b")], current: "removed"), result([health("a"), health("a")]), .unavailable("selectorMissing"), .unavailable("selectorStale")] {
            let operations = coordinator(catalog(), runtime: ShadowRuntimeSpy(value))
            let output = try await operations.evaluate()
            XCTAssertEqual(output.state, "unavailable")
        let state1 = await operations.retainedState()
            XCTAssertTrue(state1.nodes.isEmpty)
        }
    }

    func testNearEqualKeepsLiveSelectionEvenWhenPersistedDefaultDiffers() async throws {
        let output = try await coordinator(catalog(), runtime: ShadowRuntimeSpy(result([health("a", 100), health("b", 105)], current: "b"))).evaluate()
        XCTAssertEqual(output.currentOutbound, "b")
        XCTAssertEqual(output.recommendedOutbound, "b")
        XCTAssertTrue(output.keepCurrent)
        XCTAssertTrue(output.reasonCodes.contains("currentSelectionWithinTolerance"))
    }

    func testRepeatedMemberFailureAndRecovery() async throws {
        let session = UUID()
        let runtime = ShadowRuntimeSpy(result([.unreachable(tag: "a", observedAt: time), health("b")], session: session))
        let operations = coordinator(catalog(), runtime: runtime)
        for _ in 0..<4 { _ = try await operations.evaluate() }
        let failed = await operations.retainedState()
        XCTAssertEqual(failed.nodes["a"]?.failureCount, 4)
        XCTAssertEqual(failed.nodes["b"]?.failureCount, 0)
        await runtime.set(result([health("a", 30), health("b")], session: session))
        _ = try await operations.evaluate()
        let recovered = await operations.retainedState()
        XCTAssertEqual(recovered.nodes["a"]?.consecutiveFailures, 0)
        XCTAssertGreaterThan(recovered.nodes["a"]?.recoveryEvidence ?? 0, 0)
    }

    func testTransportWideAndMixedAmbiguityNeverBecomeNodeFailures() async throws {
        for probes in [["a", "b"].map { RuntimeProxyHealth.unreachable(tag: $0, observedAt: time, isConclusiveFailure: false) },
                       [health("a"), .unreachable(tag: "b", observedAt: time, isConclusiveFailure: false)]] {
            let operations = coordinator(catalog(), runtime: ShadowRuntimeSpy(result(probes)))
            let output = try await operations.evaluate()
            XCTAssertEqual(output.confidence, .low)
            XCTAssertEqual(output.probeFailureCount, 0)
        let state2 = await operations.retainedState()
            XCTAssertTrue(state2.nodes.values.allSatisfy { $0.failureCount == 0 })
        }
    }

    func testReliableConnectionsDedupTruncationDisappearanceAndAmbiguity() async throws {
        let session = UUID()
        let flows = [flow("unique"), flow("unique"), flow("ambiguous", chain: ["a", "b", "group"]), flow("no-bytes", bytes: 0), flow("unknown", chain: ["other"])]
        let runtime = ShadowRuntimeSpy(result([health("a"), health("b")], flows: flows, total: 50, session: session))
        let operations = coordinator(catalog(), runtime: runtime)
        let first = try await operations.evaluate()
        XCTAssertEqual(first.connectionSuccessCount, 1)
        XCTAssertTrue(first.connectionSnapshotTruncated)
        let output3 = try await operations.evaluate()
        XCTAssertEqual(output3.connectionSuccessCount, 0)
        await runtime.set(result([health("a"), health("b")], session: session))
        _ = try await operations.evaluate()
        let state = await operations.retainedState()
        XCTAssertTrue(state.nodes.values.allSatisfy { $0.failureCount == 0 })
        XCTAssertTrue(state.destinations.isEmpty) // This one-shot surface has no destination-affinity request.
    }

    func testStrictDedupeCapDoesNotRecycleLongLivedFlows() async throws {
        let session = UUID()
        let runtime = ShadowRuntimeSpy(result([health("a"), health("b")], flows: (0..<1000).map { flow("id-\($0)") }, session: session))
        let operations = coordinator(catalog(), runtime: runtime)
        let output4 = try await operations.evaluate()
        XCTAssertEqual(output4.connectionSuccessCount, 1000)
        await runtime.set(result([health("a"), health("b")], flows: [flow("new"), flow("id-0")], session: session))
        let output5 = try await operations.evaluate()
        XCTAssertEqual(output5.connectionSuccessCount, 0)
        let count6 = await operations.retainedConnectionIDCount()
        XCTAssertEqual(count6, 1000)
    }

    func testCandidateRemovalAndRuntimeReplacementClearAppropriateState() async throws {
        let reader = ShadowCatalogReader(catalog())
        let session = UUID()
        let runtime = ShadowRuntimeSpy(result([health("a"), health("b")], flows: [flow("id")], session: session))
        let fixed = time
        let operations = SmartPolicyShadowOperations(catalogReader: reader, runtime: runtime, clock: { fixed })
        _ = try await operations.evaluate()
        reader.set(PolicyCatalogParser.parse(Data(policyConfiguration(configuredDefault: "b", members: ["b"]).utf8), profileID: reader.read().profileID, profileRevision: 2))
        await runtime.set(result([health("b")], current: "b", flows: [flow("removed", chain: ["a"])], session: session))
        let removed = try await operations.evaluate()
        XCTAssertEqual(removed.connectionSuccessCount, 0)
        let state7 = await operations.retainedState()
        XCTAssertNil(state7.nodes["a"])
        await runtime.set(result([health("b")], current: "b", session: UUID()))
        _ = try await operations.evaluate()
        let state8 = await operations.retainedState()
        XCTAssertEqual(state8.nodes["b"]?.successCount, 1)
        let count9 = await operations.retainedConnectionIDCount()
        XCTAssertEqual(count9, 0)
    }

    func testStaleAndContradictoryEvidence() async throws {
        let stale = RuntimeProxyHealth.reachable(tag: "a", latencyMilliseconds: 30, observedAt: time.addingTimeInterval(-301))!
        let staleOutput = try await coordinator(catalog(["a"]), runtime: ShadowRuntimeSpy(result([stale]))).evaluate()
        XCTAssertEqual(staleOutput.confidence, .low)
        XCTAssertTrue(staleOutput.reasonCodes.contains("staleEvidence"))
        let operations = coordinator(catalog(), runtime: ShadowRuntimeSpy(result([.unreachable(tag: "a", observedAt: time), health("b")], flows: [flow("success-despite-probe")])) )
        let output = try await operations.evaluate()
        XCTAssertEqual(output.probeFailureCount, 1)
        XCTAssertEqual(output.connectionSuccessCount, 1)
        let state = await operations.retainedState()
        XCTAssertEqual(state.nodes["a"]?.failureCount, 1)
        XCTAssertEqual(state.nodes["a"]?.successCount, 1)
    }

    func testUnavailableEvaluationDoesNotAddFailuresToRetainedEvidence() async throws {
        let runtime = ShadowRuntimeSpy(result([health("a"), health("b")]))
        let operations = coordinator(catalog(), runtime: runtime)
        _ = try await operations.evaluate()
        let before = await operations.retainedState()
        await runtime.set(.unavailable("runtimeUnavailable"))
        _ = try await operations.evaluate()
        let after = await operations.retainedState()
        XCTAssertEqual(before, after)
    }

    func testProfileChangeDuringCollectionDiscardsEvidence() async throws {
        let reader = ShadowCatalogReader(catalog())
        let replacement = catalog(["b"])
        let runtime = ShadowRuntimeSpy(result([health("a"), health("b")]))
        await runtime.onCollection { reader.set(replacement) }
        let fixed = time
        let operations = SmartPolicyShadowOperations(catalogReader: reader, runtime: runtime, clock: { fixed })
        let output = try await operations.evaluate()
        XCTAssertEqual(output.reasonCodes, ["profileChanged"])
        let state = await operations.retainedState()
        XCTAssertTrue(state.nodes.isEmpty)
    }

    func testConcurrentEvaluationIsBoundedAndCancellationAddsNoEvidence() async throws {
        let runtime = GatedShadowRuntime(result([health("a"), health("b")]))
        let fixed = time
        let operations = SmartPolicyShadowOperations(catalogReader: ShadowCatalogReader(catalog()), runtime: runtime, clock: { fixed })
        let first = Task { try await operations.evaluate() }
        await runtime.waitUntilCollecting()
        let concurrent = try await operations.evaluate()
        XCTAssertEqual(concurrent.reasonCodes, ["evaluationInProgress"])
        first.cancel()
        await runtime.release()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let state = await operations.retainedState()
        XCTAssertTrue(state.nodes.isEmpty)
    }

    func testCLIAndAutomationPrivacyMutationZeroAndPersistenceUnchanged() async throws {
        XCTAssertEqual(try TargetCtlCommandParser.parse(["smart", "shadow", "--json"]).action, "smart.shadow")
        for verb in ["apply", "select", "enable"] { XCTAssertThrowsError(try TargetCtlCommandParser.parse(["smart", verb, "--json"])) }
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Shadow")
        try store.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: profile.id)
        try store.persistPolicyOverride(profileID: profile.id, expectedRevision: store.selectedValidVersion().revision, selectorTag: "group", outboundTag: "b")
        let before = try treeSnapshot(root)
        let runtime = ShadowRuntimeSpy(result([health("a"), health("b")], flows: [flow("private-connection-id")]))
        let policy = ShadowPolicySpy(catalog())
        let automation = TargetAutomationOperations(profileStore: store, policyOperations: policy, backend: runtime)
        for _ in 0..<8 {
            let response = await automation.handle(.init(protocolVersion: 1, action: "smart.shadow"))
            XCTAssertTrue(response.ok)
            let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
            for forbidden in ["destination", "sourceAddress", "private-connection-id", "sensitive.example.invalid", "203.0.113.77", "secret", "endpoint", "privateConfig", "subscription", "127.0.0.1"] { XCTAssertFalse(encoded.contains(forbidden), forbidden) }
            XCTAssertLessThan(encoded.utf8.count, 4096)
        }
        let selectCalls = await runtime.selectCalls
        XCTAssertEqual(selectCalls, 0)
        let applyCalls = await runtime.applyCalls
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(policy.selectCalls, 0)
        XCTAssertEqual(try treeSnapshot(root), before)
        XCTAssertEqual(try store.selectedValidVersion().profile.policyOverrides, ["group": "b"])
        let capabilities = await automation.handle(.init(protocolVersion: 1, action: "capabilities"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("smart.shadow"))
        let invalid = await automation.handle(.init(protocolVersion: 1, action: "smart.shadow", arguments: ["selector": "group"]))
        XCTAssertFalse(invalid.ok)
    }
}

private final class ShadowCatalogReader: SmartShadowCatalogReading, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PolicyCatalog
    init(_ value: PolicyCatalog) { self.value = value }
    func read() -> PolicyCatalog { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: PolicyCatalog) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private actor ShadowRuntimeSpy: SmartShadowRuntimeReading, EngineBackend, RuntimeControlClient, RuntimePolicyApplying {
    private var value: SmartShadowRuntimeResult
    private var onCollect: (@Sendable () -> Void)?
    private(set) var calls = 0
    private(set) var selectCalls = 0
    private(set) var applyCalls = 0
    init(_ value: SmartShadowRuntimeResult) { self.value = value }
    func set(_ value: SmartShadowRuntimeResult) { self.value = value }
    func onCollection(_ action: @escaping @Sendable () -> Void) { onCollect = action }
    func collectShadowEvidence(expectedRuntime: ExpectedPolicyRuntimeIdentity, selector: String, candidates: [String]) async throws -> SmartShadowRuntimeResult { calls += 1; onCollect?(); return value }
    func select(selector: String, outbound: String, using descriptor: RuntimeControlDescriptor) async throws { selectCalls += 1 }
    func applyLivePolicySelection(expectedRuntime: ExpectedPolicyRuntimeIdentity, selectorTag: String, outboundTag: String) async -> Bool { applyCalls += 1; return true }
    func selectors(using descriptor: RuntimeControlDescriptor) async throws -> [String: RuntimeSelectorState] { [:] }
    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals { .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: 0) }
    func queryStatus() async throws -> BackendStatus { .mockDefault }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {}
    func startEngine() async throws -> BackendStatus { throw BackendError.notImplemented }
    func stopEngine() async throws -> BackendStatus { throw BackendError.notImplemented }
}

private final class ShadowPolicySpy: TargetPolicyOperating, @unchecked Sendable {
    private let catalog: PolicyCatalog
    private(set) var selectCalls = 0
    init(_ catalog: PolicyCatalog) { self.catalog = catalog }
    func readPersisted() throws -> PolicyCatalog { catalog }
    func read() async throws -> PolicyCatalog { catalog }
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog { selectCalls += 1; return catalog }
    func reset() async throws -> PolicyResetResult { .init(clearedOverrideCount: 0, catalog: catalog) }
}

private actor GatedShadowRuntime: SmartShadowRuntimeReading {
    let value: SmartShadowRuntimeResult
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    init(_ value: SmartShadowRuntimeResult) { self.value = value }
    func collectShadowEvidence(expectedRuntime: ExpectedPolicyRuntimeIdentity, selector: String, candidates: [String]) async throws -> SmartShadowRuntimeResult {
        await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil }
        return value
    }
    func waitUntilCollecting() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
