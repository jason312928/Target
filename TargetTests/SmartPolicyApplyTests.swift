import Foundation
import XCTest
import TargetCore
@testable import Target

final class SmartPolicyApplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func recommendation(confidence: SmartPolicyConfidence = .high, keep: Bool = false,
                                reasons: [String] = [], age: TimeInterval = 0,
                                recommended: String? = "b", state: String = "available",
                                ambiguous: Int = 0, connections: Bool = true) -> SmartShadowRecommendation {
        let catalog = PolicyCatalogParser.parse(Data(#"{"outbounds":[{"type":"selector","tag":"group","outbounds":["a","b"],"default":"a"},{"type":"direct","tag":"a"},{"type":"direct","tag":"b"}]}"#.utf8), profileID: UUID(), profileRevision: 1)
        let time = now.addingTimeInterval(-age)
        return .init(state: state, observedAt: time, selector: "group", currentOutbound: "a",
                     recommendedOutbound: recommended, confidence: confidence, keepCurrent: keep,
                     reasonCodes: reasons, candidateCount: 2, probeSuccessCount: 2,
                     ambiguousProbeCount: ambiguous, connectionSnapshotAvailable: connections,
                     selectionEvidence: .init(catalog: catalog, sessionID: UUID(), selector: "group", currentOutbound: "a", observedAt: time))
    }

    func testSafeRecommendationRequestsExactlyOneSharedMutation() async {
        let policy = ApplyPolicySpy()
        let evaluator = ApplyEvaluator(recommendation())
        let fixed = now
        let result = await SmartPolicyApplyOperations(evaluator: evaluator, policy: policy, clock: { fixed }).apply()
        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.after, "b")
        XCTAssertEqual(result.reasonCode, "applied")
        XCTAssertEqual(policy.count, 1)
        let count = await evaluator.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(policy.ordinaryCount, 0)
    }

    func testSafetyGateTableNeverRequestsMutation() async {
        let rows: [(SmartShadowRecommendation, String)] = [
            (recommendation(confidence: .low), "lowConfidence"),
            (recommendation(keep: true), "keepCurrent"),
            (recommendation(age: 11), "staleEvidence"),
            (recommendation(age: -1), "staleEvidence"),
            (recommendation(reasons: ["staleEvidence"]), "staleEvidence"),
            (recommendation(ambiguous: 1), "ambiguousEvidence"),
            (recommendation(reasons: ["networkWideDegradation"]), "ambiguousEvidence"),
            (recommendation(connections: false), "runtimeUnavailable"),
            (recommendation(recommended: "removed"), "invalidRecommendation"),
            (recommendation(recommended: nil), "invalidRecommendation"),
            (recommendation(recommended: "a"), "alreadySelected"),
            (recommendation(reasons: ["engineStopped"], state: "stopped"), "engineStopped"),
            (recommendation(reasons: ["identityChanged"], state: "unavailable"), "identityChanged")
        ]
        for (value, reason) in rows {
            let policy = ApplyPolicySpy()
            let fixed = now
            let result = await SmartPolicyApplyOperations(evaluator: ApplyEvaluator(value), policy: policy, clock: { fixed }).apply()
            XCTAssertFalse(result.applied, reason)
            XCTAssertEqual(result.reasonCode, reason)
            XCTAssertEqual(policy.count, 0, reason)
            XCTAssertEqual(policy.ordinaryCount, 0)
        }
    }

    func testApplyDoesNotRetrySharedRefusalOrFailure() async {
        let fixed = now
        for reason in [PolicySelectionApplyReason.identityChanged, .profileChanged, .liveSelectionChanged, .selectionChanged, .mutationInProgress, .mutationUnconfirmed] {
            let policy = ApplyPolicySpy(outcome: .refused(reason))
            let result = await SmartPolicyApplyOperations(evaluator: ApplyEvaluator(recommendation()), policy: policy, clock: { fixed }).apply()
            XCTAssertFalse(result.applied)
            XCTAssertEqual(result.reasonCode, reason.rawValue)
            XCTAssertEqual(policy.count, 1)
        }
    }

    func testConcurrentApplyReturnsImmediatelyAndCancelledEvaluationNeverMutates() async {
        let evaluator = ApplyEvaluator(recommendation(), gated: true)
        let policy = ApplyPolicySpy()
        let fixed = now
        let operation = SmartPolicyApplyOperations(evaluator: evaluator, policy: policy, clock: { fixed })
        let first = Task { await operation.apply() }
        await evaluator.waitUntilEvaluating()
        let concurrent = await operation.apply()
        XCTAssertEqual(concurrent.reasonCode, "applyInProgress")
        first.cancel()
        await evaluator.release()
        let cancelled = await first.value
        XCTAssertEqual(cancelled.reasonCode, "cancelled")
        XCTAssertEqual(policy.count, 0)
        let next = await operation.apply()
        XCTAssertTrue(next.applied)
        XCTAssertEqual(policy.count, 1)
    }

    func testParserAndBoundedOutputContainOnlySafeAggregateEvidence() throws {
        XCTAssertEqual(try TargetCtlCommandParser.parse(["smart", "apply", "--json"]).action, "smart.apply")
        for arguments in [["smart", "apply"], ["smart", "apply", "--selector", "group", "--json"], ["smart", "enable", "--json"]] {
            XCTAssertThrowsError(try TargetCtlCommandParser.parse(arguments))
        }
        let output = SmartPolicyApplyResult(recommendation: recommendation(), applied: true, after: "b", reasonCode: "applied")
        let encoded = String(decoding: AutomationProtocol.encodeResponse(.success(output.automationJSON())), as: UTF8.self)
        XCTAssertLessThan(encoded.utf8.count, 2048)
        for forbidden in ["sessionID", "profileID", "sourceFingerprint", "destination", "connectionID", "secret", "controller", "subscription", "endpoint", "127.0.0.1", "privateConfig"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }
}

private actor ApplyEvaluator: SmartPolicyEvaluating {
    let value: SmartShadowRecommendation
    private var gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    init(_ value: SmartShadowRecommendation, gated: Bool = false) { self.value = value; self.gated = gated }
    func evaluate() async throws -> SmartShadowRecommendation {
        count += 1
        if gated {
            await withCheckedContinuation { gate = $0; waiting?.resume(); waiting = nil }
        }
        return value
    }
    func waitUntilEvaluating() async {
        if gate != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { gated = false; gate?.resume(); gate = nil }
}

private final class ApplyPolicySpy: TargetPolicyOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var ordinaryCalls = 0
    let outcome: PolicySelectionApplyResult
    init(outcome: PolicySelectionApplyResult = .init(applied: true, after: "b", reason: .applied)) { self.outcome = outcome }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var ordinaryCount: Int { lock.lock(); defer { lock.unlock() }; return ordinaryCalls }
    func readPersisted() throws -> PolicyCatalog { throw TargetPolicyOperationError.selectorUnavailable }
    func read() async throws -> PolicyCatalog { try readPersisted() }
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog {
        incrementOrdinary(); return try readPersisted()
    }
    private func incrementOrdinary() { lock.lock(); defer { lock.unlock() }; ordinaryCalls += 1 }
    func reset() async throws -> PolicyResetResult { throw TargetPolicyOperationError.selectorUnavailable }
    func selectIfUnchanged(evidence: PolicySelectionEvidence, outboundTag: String, generation: UInt64) async throws -> PolicySelectionApplyResult {
        increment(); return outcome
    }
    private func increment() { lock.lock(); defer { lock.unlock() }; calls += 1 }
}
