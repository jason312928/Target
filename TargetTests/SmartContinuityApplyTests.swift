import Foundation
import XCTest
import TargetCore
@testable import Target

final class SmartContinuityApplyTests: XCTestCase, ProfileTestCaseSupport {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let identity = EngineRuntimeRecord(pid: 1, executablePath: "/synthetic/engine", executableFingerprint: "fixture",
        endpoint: .init(port: 51_234), profileID: UUID(), profileRevision: 1, sourceConfigurationFingerprint: "source",
        configurationFingerprint: "runtime", startedAt: Date(timeIntervalSince1970: 1), runtimeConfigurationID: UUID())

    private func flow(_ id: String = "private-id", chain: [String] = ["a", "group"],
                      upload: Int64 = 100, download: Int64 = 100, start: Date? = nil) -> RuntimeConnection {
        .init(id: id, destinationHost: "private.example.invalid", destinationIP: "203.0.113.99", destinationPort: 443,
              network: "tcp", inbound: "private-inbound", outboundChain: chain,
              uploadBytes: upload, downloadBytes: download, startedAt: start ?? epoch.addingTimeInterval(-50))
    }

    private func evidence(_ connections: [RuntimeConnection], at offset: TimeInterval,
                          record: EngineRuntimeRecord? = nil, truncated: Bool = false) -> SmartContinuityEvidence {
        .init(identity: record ?? identity,
              snapshot: .init(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0,
                                           activeConnectionCount: connections.count + (truncated ? 1 : 0)), connections: connections),
              observedAt: epoch.addingTimeInterval(offset))
    }

    private func plan(_ connections: [RuntimeConnection], activeIDs: Set<String> = [], truncated: Bool = false) -> SmartContinuityPlan {
        var classifier = SmartContinuityClassifier()
        var last: SmartContinuityEvidence!
        var summary: SmartContinuitySummary!
        for time in [0.0, 10, 20, 30] {
            let values = connections.map { value in
                activeIDs.contains(value.id) ? flow(value.id, chain: value.outboundChain, download: Int64(time) * 1_024,
                                                    start: value.startedAt) : value
            }
            last = evidence(values, at: time, truncated: truncated)
            summary = classifier.observe(last)
        }
        return .init(evidence: last, classifier: classifier, classifications: classifier.classifications, summary: summary)
    }

    private func receipt(record: EngineRuntimeRecord? = nil, generation: UInt64 = 1) -> PolicySelectionReceipt {
        let catalog = PolicyCatalogParser.parse(Data(policyConfiguration(configuredDefault: "a", members: ["a", "b"]).utf8),
                                               profileID: identity.profileID, profileRevision: 1,
                                               overrides: ["group": "b"])
        return .init(identity: record ?? identity, catalog: catalog, generation: generation,
                     selector: "group", oldOutbound: "a", newOutbound: "b")
    }

    private func applying(_ plan: SmartContinuityPlan, policy: ContinuityApplyPolicySpy,
                          selection: SmartPolicyApplyResult? = nil, time: TimeInterval = 31) -> SmartContinuityApplyOperations {
        let fixed = epoch.addingTimeInterval(time)
        let authority = receipt()
        let defaultRecommendation = SmartShadowRecommendation(
            state: "available", observedAt: epoch, selector: authority.selector,
            currentOutbound: authority.oldOutbound, recommendedOutbound: authority.newOutbound,
            confidence: .high, keepCurrent: false, reasonCodes: [], candidateCount: 2,
            connectionSnapshotAvailable: true,
            selectionEvidence: .init(catalog: authority.catalog,
                                     sessionID: identity.runtimeConfigurationID,
                                     selector: authority.selector,
                                     currentOutbound: authority.oldOutbound,
                                     observedAt: epoch))
        return .init(continuity: ContinuityPlanSpy(plan),
                     smartApply: ContinuitySelectorSpy(selection ?? .init(recommendation: defaultRecommendation,
                                                                            applied: true,
                                                                            after: authority.newOutbound,
                                                                            reasonCode: "applied",
                                                                            receipt: authority)),
                     policy: policy, clock: { fixed })
    }

    func testProtectUnknownUnrelatedAndNewSelectionArePreserved() async {
        let unknown = flow("unknown", start: epoch.addingTimeInterval(20))
        let initial = plan([flow("protect"), unknown, flow("unrelated", chain: ["a", "another-group"]),
                            flow("new", chain: ["b", "group"]), flow("eligible")], activeIDs: ["protect"])
        XCTAssertEqual(initial.classifications["protect"], .protect)
        XCTAssertEqual(initial.classifications["unknown"], .unknown)
        let policy = ContinuityApplyPolicySpy()
        let result = await applying(initial, policy: policy).apply()
        XCTAssertTrue(result.selectorApplied)
        XCTAssertEqual(result.eligibleConnectionCount, 1)
        XCTAssertEqual(result.closedConnectionCount, 1)
        XCTAssertEqual(result.preservedConnectionCount, 4)
        XCTAssertEqual(result.protectCount, 1)
        XCTAssertEqual(result.unknownCount, 1)
        XCTAssertEqual(result.replaceableCount, 3)
        XCTAssertEqual(policy.ids, ["eligible"])
        for value in [plan([flow("protect")], activeIDs: ["protect"]), plan([unknown])] {
            let preserved = ContinuityApplyPolicySpy()
            let outcome = await applying(value, policy: preserved).apply()
            XCTAssertEqual(outcome.closedConnectionCount, 0)
            XCTAssertTrue(preserved.ids.isEmpty)
        }
    }

    func testRelevantChainRequiresUniqueAdjacentSelectorAndOldMember() {
        let authority = receipt()
        XCTAssertTrue(SmartContinuityPlan.isRelevantOldConnection(flow(chain: ["leaf", "a", "group"]), receipt: authority))
        for chain in [["a"], ["group", "a"], ["a", "intermediate", "group"], ["a", "a", "group"],
                      ["a", "group", "group"], ["b", "group"], ["a", "b", "group"], ["b", "a", "group"]] {
            XCTAssertFalse(SmartContinuityPlan.isRelevantOldConnection(flow(chain: chain), receipt: authority), "\(chain)")
        }
    }

    func testCheckpointRevalidationRequiresSameConnectionAndContinuousIdleEvidence() {
        let original = flow()
        let initial = plan([original])
        XCTAssertTrue(initial.permitsClose(original, with: evidence([original], at: 31), now: epoch.addingTimeInterval(31)))
        let changed = [flow(start: epoch.addingTimeInterval(-40)), flow(chain: ["other", "group"]), flow(upload: 101), flow(download: 101),
            RuntimeConnection(id: original.id, destinationHost: "reused.example.invalid", destinationIP: original.destinationIP,
                destinationPort: original.destinationPort, network: original.network, inbound: original.inbound,
                outboundChain: original.outboundChain, uploadBytes: original.uploadBytes, downloadBytes: original.downloadBytes, startedAt: original.startedAt),
            RuntimeConnection(id: original.id, destinationHost: original.destinationHost, destinationIP: original.destinationIP,
                destinationPort: original.destinationPort, network: "udp", inbound: original.inbound,
                outboundChain: original.outboundChain, uploadBytes: original.uploadBytes, downloadBytes: original.downloadBytes, startedAt: original.startedAt)]
        for value in changed {
            XCTAssertFalse(initial.permitsClose(value, with: evidence([value], at: 31), now: epoch.addingTimeInterval(31)))
        }
        for fresh in [evidence([], at: 31), evidence([original, original], at: 31), evidence([original], at: 31, truncated: true),
                      evidence([original], at: 30), evidence([original], at: 29), evidence([original], at: 41)] {
            XCTAssertFalse(initial.permitsClose(original, with: fresh, now: fresh.observedAt))
        }
        XCTAssertFalse(initial.permitsClose(original, with: evidence([original], at: 31), now: epoch.addingTimeInterval(41)))
        XCTAssertFalse(plan([original], truncated: true).permitsClose(original, with: evidence([original], at: 31), now: epoch.addingTimeInterval(31)))
    }

    func testRuntimeSessionProfileConfigurationAndOwnedProcessChangesPreserve() {
        let original = flow()
        let initial = plan([original])
        for field in ["session", "profile", "revision", "source", "configuration", "pid", "start", "executable", "fingerprint", "endpoint", "bindings"] {
            let changed = EngineRuntimeRecord(pid: field == "pid" ? 2 : identity.pid,
                executablePath: field == "executable" ? "/synthetic/changed" : identity.executablePath,
                executableFingerprint: field == "fingerprint" ? "changed" : identity.executableFingerprint,
                endpoint: field == "endpoint" ? .init(port: 51_235) : identity.endpoint,
                profileID: field == "profile" ? UUID() : identity.profileID, profileRevision: field == "revision" ? 2 : identity.profileRevision,
                sourceConfigurationFingerprint: field == "source" ? "changed" : identity.sourceConfigurationFingerprint,
                configurationFingerprint: field == "configuration" ? "changed" : identity.configurationFingerprint,
                startedAt: field == "start" ? epoch : identity.startedAt,
                runtimeConfigurationID: field == "session" ? UUID() : identity.runtimeConfigurationID,
                routeBindingsFingerprint: field == "bindings" ? "changed" : identity.routeBindingsFingerprint)
            XCTAssertFalse(initial.permitsClose(original, with: evidence([original], at: 31, record: changed), now: epoch.addingTimeInterval(31)), field)
        }
    }

    func testSelectionMustActuallyApplyAndProvideMatchingReceipt() async {
        let initial = plan([flow()])
        for selection in [SmartPolicyApplyResult(recommendation: nil, applied: false, after: nil, reasonCode: "keepCurrent"),
                          .init(recommendation: nil, applied: false, after: nil, reasonCode: "lowConfidence"),
                          .init(recommendation: nil, applied: true, after: "b", reasonCode: "applied"),
                          .init(recommendation: nil, applied: true, after: "a", reasonCode: "applied", receipt: receipt())] {
            let policy = ContinuityApplyPolicySpy()
            let result = await applying(initial, policy: policy, selection: selection).apply()
            XCTAssertEqual(result.closedConnectionCount, 0)
            XCTAssertTrue(policy.ids.isEmpty)
        }
        for value in [plan([flow()], truncated: true), initial] {
            let policy = ContinuityApplyPolicySpy()
            let result = await applying(value, policy: policy, time: 41).apply()
            XCTAssertEqual(result.closedConnectionCount, 0)
            XCTAssertTrue(policy.ids.isEmpty)
        }
    }

    func testCancellationWhilePreparingPlanIsReportedAsCancelled() async {
        let gate = NilPlanGate()
        let fixed = epoch
        let operation = SmartContinuityApplyOperations(
            continuity: WaitingNilPlanSpy(gate: gate),
            smartApply: ContinuitySelectorSpy(.init(recommendation: nil, applied: false, after: nil, reasonCode: "keepCurrent")),
            policy: ContinuityApplyPolicySpy(),
            clock: { fixed })
        let task = Task { await operation.apply() }
        await Task.yield()
        task.cancel()
        await gate.release()
        let result = await task.value
        XCTAssertTrue(result.reasonCodes.contains("cancelled"))
        XCTAssertFalse(result.reasonCodes.contains("runtimeUnavailable"))
    }

    func testCloseFailureAndCancellationStopLaterClosesWithoutRollbackClaim() async {
        let initial = plan([flow("a"), flow("b"), flow("c")])
        for stop in [SmartContinuityCloseOutcome.failed, .cancelled] {
            let policy = ContinuityApplyPolicySpy(outcomes: [.closed, stop, .closed])
            let result = await applying(initial, policy: policy).apply()
            XCTAssertEqual(policy.ids, ["a", "b"])
            XCTAssertEqual(result.closedConnectionCount, 1)
            XCTAssertEqual(result.preservedConnectionCount, stop.isFailure ? 1 : 2)
            XCTAssertEqual(result.failedCloseCount, stop.isFailure ? 1 : 0)
            XCTAssertTrue(result.reasonCodes.contains(stop.isFailure ? "closeFailed" : "cancelled"))
        }
        let policy = ContinuityApplyPolicySpy()
        let operation = applying(initial, policy: policy)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return await operation.apply() }
        let cancelledResult = await cancelled.value
        XCTAssertEqual(cancelledResult.closedConnectionCount, 0)
        XCTAssertTrue(policy.ids.isEmpty)
    }

    func testCloseCountIsBoundedAndOutputContainsOnlySafeAggregates() async throws {
        let values = (0..<12).map { flow("private-id-\($0)") }
        let policy = ContinuityApplyPolicySpy()
        let result = await applying(plan(values), policy: policy).apply()
        XCTAssertEqual(result.eligibleConnectionCount, 12)
        XCTAssertEqual(result.closedConnectionCount, SmartContinuityApplyOperations.maximumCloses)
        XCTAssertEqual(policy.ids.count, SmartContinuityApplyOperations.maximumCloses)
        XCTAssertTrue(result.reasonCodes.contains("closeLimitReached"))
        let encoded = String(decoding: AutomationProtocol.encodeResponse(.success(result.automationJSON())), as: UTF8.self)
        for forbidden in ["private-id", "private.example.invalid", "203.0.113.99", "private-inbound", "synthetic/engine", "endpoint", "secret", "subscription", "destination", "sessionID", "profileID"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
        XCTAssertLessThan(encoded.utf8.count, 2_048)
        let contaminated = ContinuityApplyPolicySpy(outcomes: [.preserved("private-controller-secret")])
        let sanitized = await applying(plan([flow()]), policy: contaminated).apply()
        XCTAssertFalse(String(decoding: AutomationProtocol.encodeResponse(.success(sanitized.automationJSON())), as: UTF8.self).contains("private-controller-secret"))
    }

    func testCancellationThrownDuringCloseDoesNotClaimCurrentAttemptPreserved() async {
        let policy = ContinuityApplyPolicySpy(outcomes: [.closed], cancellationIndex: 1)
        let result = await applying(plan([flow("a"), flow("b"), flow("c")]), policy: policy).apply()
        XCTAssertTrue(result.selectorApplied)
        XCTAssertEqual(policy.ids, ["a", "b"])
        XCTAssertEqual(result.closedConnectionCount, 1)
        XCTAssertEqual(result.failedCloseCount, 1)
        XCTAssertEqual(result.preservedConnectionCount, 1)
        XCTAssertTrue(result.reasonCodes.contains("cancelled"))
    }

    func testSharedPolicyReceiptCapturesExactCommitAndFinalGuardsRejectRaces() async throws {
        for race in ["none", "manual", "profile", "revision", "bindings"] {
            let store = try makeStore()
            let profile = try store.create(name: "Synthetic")
            try store.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: profile.id)
            let version = try store.selectedValidVersion()
            let record = EngineRuntimeRecord(pid: 1, executablePath: "/synthetic/engine", executableFingerprint: "fixture", endpoint: .init(port: 51_234),
                profileID: profile.id, profileRevision: version.revision, sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(version.data),
                configurationFingerprint: "runtime", startedAt: epoch, runtimeConfigurationID: UUID())
            let runtime = ReceiptRuntimeSpy(record: record)
            let policy = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: runtime)
            let catalog = try policy.readPersisted()
            let selection = try await policy.selectIfUnchanged(evidence: .init(catalog: catalog, sessionID: record.runtimeConfigurationID,
                selector: "group", currentOutbound: "a", observedAt: .now), outboundTag: "b", generation: policy.selectionGeneration())
            let receipt = try XCTUnwrap(selection.receipt)
            XCTAssertEqual(receipt.generation, 1)
            XCTAssertEqual(receipt.catalog, try policy.readPersisted())
            XCTAssertEqual(receipt.identity, record)
            if race == "manual" { _ = try await policy.select(selectorTag: "group", outboundTag: "a"); _ = try await policy.select(selectorTag: "group", outboundTag: "b") }
            if race == "profile" { let other = try store.create(name: "Other"); try store.select(other.id) }
            if race == "revision" { try store.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: profile.id) }
            if race == "bindings" {
                let binding = try XCTUnwrap(ProfileRouteBinding(domain: "example.invalid", outboundTag: "a", countryCode: "US"))
                try store.persistRouteBinding(profileID: profile.id, expectedRevision: version.revision, binding: binding)
            }
            let original = plan([flow()])
            let outcome = try await policy.closeContinuityConnectionIfUnchanged(.init(plan: original, connection: flow(), receipt: receipt))
            let dispatched = await runtime.dispatches
            XCTAssertEqual(dispatched, race == "none" ? 1 : 0, race)
            if case .closed = outcome { XCTAssertEqual(race, "none") }
        }
    }

    func testExistingSmartApplyNeverCallsContinuityClose() async {
        let policy = ContinuityApplyPolicySpy()
        let catalog = receipt().catalog
        let now = epoch
        let recommendation = SmartShadowRecommendation(state: "available", observedAt: now, selector: "group", currentOutbound: "a",
            recommendedOutbound: "b", confidence: .high, keepCurrent: false, reasonCodes: [], candidateCount: 2,
            connectionSnapshotAvailable: true,
            selectionEvidence: .init(catalog: catalog, sessionID: identity.runtimeConfigurationID, selector: "group", currentOutbound: "a", observedAt: now))
        let result = await SmartPolicyApplyOperations(evaluator: ContinuityRecommendationSpy(recommendation), policy: policy, clock: { now }).apply()
        XCTAssertTrue(result.applied)
        XCTAssertTrue(policy.ids.isEmpty)
    }
}

private extension SmartContinuityCloseOutcome {
    var isFailure: Bool { if case .failed = self { return true }; return false }
}

private struct ContinuityPlanSpy: SmartContinuityPlanning {
    let value: SmartContinuityPlan
    init(_ value: SmartContinuityPlan) { self.value = value }
    func preparePlan() async -> SmartContinuityPlan? { value }
}
private actor NilPlanGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct WaitingNilPlanSpy: SmartContinuityPlanning {
    let gate: NilPlanGate

    func preparePlan() async -> SmartContinuityPlan? {
        await gate.wait()
        return nil
    }
}
private struct ContinuitySelectorSpy: SmartPolicyApplying {
    let value: SmartPolicyApplyResult
    init(_ value: SmartPolicyApplyResult) { self.value = value }
    func apply() async -> SmartPolicyApplyResult { value }
}
private struct ContinuityRecommendationSpy: SmartPolicyEvaluating {
    let value: SmartShadowRecommendation
    init(_ value: SmartShadowRecommendation) { self.value = value }
    func evaluate() async throws -> SmartShadowRecommendation { value }
}
private final class ContinuityApplyPolicySpy: TargetPolicyOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var closedIDs: [String] = []
    private let outcomes: [SmartContinuityCloseOutcome]
    private let cancellationIndex: Int?
    init(outcomes: [SmartContinuityCloseOutcome] = [], cancellationIndex: Int? = nil) {
        self.outcomes = outcomes; self.cancellationIndex = cancellationIndex
    }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return closedIDs }
    func readPersisted() throws -> PolicyCatalog { throw TargetPolicyOperationError.selectorUnavailable }
    func read() async throws -> PolicyCatalog { try readPersisted() }
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog { try readPersisted() }
    func reset() async throws -> PolicyResetResult { throw TargetPolicyOperationError.selectorUnavailable }
    func selectIfUnchanged(evidence: PolicySelectionEvidence, outboundTag: String, generation: UInt64) async throws -> PolicySelectionApplyResult {
        .init(applied: true, after: outboundTag, reason: .applied)
    }
    func closeContinuityConnectionIfUnchanged(_ request: SmartContinuityCloseRequest) async throws -> SmartContinuityCloseOutcome {
        let index = record(request.connection.id)
        if index == cancellationIndex { throw CancellationError() }
        return index < outcomes.count ? outcomes[index] : .closed
    }
    private func record(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let index = closedIDs.count
        closedIDs.append(id)
        return index
    }
}
private final class ReceiptDispatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
private actor ReceiptRuntimeSpy: PolicyRuntimeEvidenceProviding, RuntimePolicyApplying, SmartContinuityRuntimeClosing {
    let record: EngineRuntimeRecord
    private let counter = ReceiptDispatchCounter()
    var dispatches: Int { counter.read() }
    init(record: EngineRuntimeRecord) { self.record = record }
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .stopped }
    func applyLivePolicySelection(expectedRuntime: ExpectedPolicyRuntimeIdentity, selectorTag: String, outboundTag: String) async -> Bool { false }
    func applyLivePolicySelectionIfUnchanged(evidence: PolicySelectionEvidence, outboundTag: String,
        authorize: @escaping @Sendable () throws -> Void) async throws -> PolicySelectionApplyResult {
        try authorize()
        return .init(applied: true, after: outboundTag, reason: .applied, runtimeIdentity: record)
    }
    func closeContinuityConnection(_ request: SmartContinuityCloseRequest,
        authorize: @escaping @Sendable (_ dispatch: @Sendable () -> Void) throws -> Void) async throws -> SmartContinuityCloseOutcome {
        do { let counter = counter; try authorize { counter.increment() }; return .closed }
        catch PolicySelectionApplyRefusal.selectionChanged { return .preserved("selectionChanged") }
        catch { return .preserved("profileChanged") }
    }
}
