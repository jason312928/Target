import Foundation
import TargetCore

/// No selector mutation, engine lifecycle, controller descriptor, or store writes
/// are available through either of the coordinator's dependencies.
protocol SmartShadowCatalogReading: Sendable {
    func read() throws -> PolicyCatalog
}
extension PolicyCatalogOperation: SmartShadowCatalogReading {}

protocol SmartShadowRuntimeReading: Sendable {
    func collectShadowEvidence(expectedRuntime: ExpectedPolicyRuntimeIdentity, selector: String, candidates: [String]) async throws -> SmartShadowRuntimeResult
}

struct SmartShadowRuntimeEvidence: Sendable {
    let sessionID: UUID
    let currentOutbound: String
    let probes: RuntimePolicyHealthProbeOutcome
    let connections: RuntimeConnectionsSnapshot?
}

enum SmartShadowRuntimeResult: Sendable {
    case stopped
    case unavailable(String)
    case available(SmartShadowRuntimeEvidence)
}

struct UnavailableSmartShadowRuntime: SmartShadowRuntimeReading {
    func collectShadowEvidence(expectedRuntime: ExpectedPolicyRuntimeIdentity, selector: String, candidates: [String]) async throws -> SmartShadowRuntimeResult {
        .unavailable("runtimeUnavailable")
    }
}

struct SmartShadowRecommendation: Equatable, Sendable {
    let state: String
    let observedAt: Date
    let selector: String?
    let currentOutbound: String?
    let recommendedOutbound: String?
    let confidence: SmartPolicyConfidence
    let keepCurrent: Bool
    let reasonCodes: [String]
    let candidateCount: Int
    var probeSuccessCount = 0
    var probeFailureCount = 0
    var ambiguousProbeCount = 0
    var connectionSuccessCount = 0
    var connectionSnapshotAvailable = false
    var connectionSnapshotTruncated = false
    // In-process authority only. Never serialized into automation output.
    var selectionEvidence: PolicySelectionEvidence?

    func automationJSON() -> JSONValue {
        .object([
            "state": .string(state), "observedAt": .string(observedAt.ISO8601Format()),
            "selector": selector.map(JSONValue.string) ?? .null,
            "currentOutbound": currentOutbound.map(JSONValue.string) ?? .null,
            "recommendedOutbound": recommendedOutbound.map(JSONValue.string) ?? .null,
            "confidence": .string(confidence.rawValue), "keepCurrent": .boolean(keepCurrent),
            "reasonCodes": .array(reasonCodes.map(JSONValue.string)), "candidateCount": .integer(candidateCount),
            "evidence": .object([
                "probeSuccessCount": .integer(probeSuccessCount), "probeFailureCount": .integer(probeFailureCount),
                "ambiguousProbeCount": .integer(ambiguousProbeCount), "connectionSuccessCount": .integer(connectionSuccessCount),
                "connectionSnapshotAvailable": .boolean(connectionSnapshotAvailable),
                "connectionSnapshotTruncated": .boolean(connectionSnapshotTruncated)
            ])
        ])
    }
}

/// One-shot, process-local, memory-only evaluation of the first persisted selector.
/// A single bounded engine is retained; changing Profile/selector/runtime clears it.
actor SmartPolicyShadowOperations {
    static let maximumCandidates = 64
    static let maximumConnectionIDs = 1_000
    private let catalogReader: any SmartShadowCatalogReading
    private let runtime: any SmartShadowRuntimeReading
    private let clock: @Sendable () -> Date
    private var engine = SmartPolicyShadowOperations.makeEngine()
    private var scope: String?
    private var connectionIDs = Set<String>()
    private var evaluating = false

    init(catalogReader: any SmartShadowCatalogReading, runtime: any SmartShadowRuntimeReading,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.catalogReader = catalogReader
        self.runtime = runtime
        self.clock = clock
    }

    private static func makeEngine() -> SmartPolicyEngine {
        var configuration = SmartPolicyConfiguration.default
        configuration.explorationEnabled = false
        return SmartPolicyEngine(configuration: configuration)
    }

    func evaluate() async throws -> SmartShadowRecommendation {
        let startedAt = clock()
        func unavailable(_ reason: String, state: String = "unavailable", selector: String? = nil, count: Int = 0) -> SmartShadowRecommendation {
            .init(state: state, observedAt: startedAt, selector: selector, currentOutbound: nil,
                  recommendedOutbound: nil, confidence: .low, keepCurrent: true, reasonCodes: [reason], candidateCount: count)
        }
        guard !evaluating else { return unavailable("evaluationInProgress") }
        evaluating = true
        defer { evaluating = false }
        let catalog = try catalogReader.read()
        // No implicit choice between malformed/duplicate selectors.
        guard let group = catalog.selectors.first, let selector = group.tag,
              selector.utf8.count <= 256, group.status == .available,
              catalog.selectors.filter({ $0.tag == selector }).count == 1 else {
            return unavailable("selectorUnavailable")
        }
        let tags = Array(Set(group.members.filter { $0.status == .available }.map(\.tag))).sorted()
        guard !tags.isEmpty else { return unavailable("emptyCandidates", selector: selector) }
        guard group.members.allSatisfy({ $0.status == .available }),
              tags.count <= Self.maximumCandidates, tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              let profileID = catalog.profileID, let revision = catalog.profileRevision,
              let fingerprint = catalog.sourceFingerprint else {
            return unavailable("candidateSetUnavailable", selector: selector, count: min(tags.count, Self.maximumCandidates))
        }
        let identity = ExpectedPolicyRuntimeIdentity(profileID: profileID, profileRevision: revision, sourceFingerprint: fingerprint)
        let evidence: SmartShadowRuntimeEvidence
        switch try await runtime.collectShadowEvidence(expectedRuntime: identity, selector: selector, candidates: tags) {
        case .stopped: return unavailable("engineStopped", state: "stopped", selector: selector, count: tags.count)
        case .unavailable(let reason):
            let allowed = ["ownershipUnavailable", "identityMismatch", "selectorMissing", "selectorStale", "controllerUnavailable", "runtimeUnavailable", "identityChanged", "runtimeChanged"]
            return unavailable(allowed.contains(reason) ? reason : "runtimeUnavailable", selector: selector, count: tags.count)
        case .available(let value): evidence = value
        }
        try Task.checkCancellation()
        guard try catalogReader.read() == catalog else { return unavailable("profileChanged", selector: selector, count: tags.count) }
        guard tags.contains(evidence.currentOutbound), case .results(let probes) = evidence.probes,
              probes.count == tags.count, Set(probes.map(\.tag)) == Set(tags),
              !probes.contains(where: { $0.state == .runtimeUnavailable }) else {
            return unavailable("runtimeUnavailable", selector: selector, count: tags.count)
        }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, now >= startedAt else { return unavailable("clockUnavailable") }
        let nextScope = "\(profileID)/\(selector)/\(evidence.sessionID)"
        if scope != nextScope { engine = Self.makeEngine(); connectionIDs.removeAll(); scope = nextScope }
        let time = max(now.timeIntervalSince1970, engine.state.currentTime)
        engine.apply(.timeAdvanced(to: time))
        for removed in Set(engine.state.nodes.keys).subtracting(tags) { engine.apply(.candidateRemoved(tag: removed, at: time)) }
        var successes = 0, failures = 0, ambiguous = 0
        for probe in probes {
            guard let observedAt = probe.observedAt, observedAt >= startedAt, observedAt <= now else { ambiguous += 1; continue }
            switch probe.state {
            case .reachable:
                if let latency = probe.latencyMilliseconds, (1...65_535).contains(latency) {
                    engine.apply(.probeSuccess(tag: probe.tag, latencyMilliseconds: Double(latency), at: time)); successes += 1
                } else { ambiguous += 1 }
            case .unreachable where probe.isConclusiveFailure:
                engine.apply(.probeFailure(tag: probe.tag, at: time)); failures += 1
            default: ambiguous += 1
            }
        }
        var connections = 0
        if let snapshot = evidence.connections {
            for connection in snapshot.connections.prefix(RuntimeConnectionsParser.maximumDetailedConnections) {
                let matches = Set(connection.outboundChain).intersection(tags)
                // An active flow alone is not proof of reachability. Require
                // received bytes, and exactly one attributable candidate.
                guard matches.count == 1, let tag = matches.first,
                      (connection.downloadBytes ?? 0) > 0,
                      !connection.id.isEmpty, connection.id.utf8.count <= 256,
                      !connectionIDs.contains(connection.id) else { continue }
                // Saturation ignores new IDs rather than evicting old IDs and
                // repeatedly counting a long-lived flow as fresh evidence.
                guard connectionIDs.count < Self.maximumConnectionIDs else { continue }
                connectionIDs.insert(connection.id)
                engine.apply(.connectionSuccess(tag: tag, at: time)); connections += 1
            }
        }
        let decision = engine.decision(for: .init(candidates: tags.map { .init(tag: $0) }, currentOutbound: evidence.currentOutbound, now: time))
        var reasons = decision.reasonCodes.map(\.rawValue)
        if ambiguous > 0 { reasons.append("ambiguousProbeEvidence") }
        if evidence.connections == nil { reasons.append("connectionsUnavailable") }
        if connectionIDs.count == Self.maximumConnectionIDs { reasons.append("connectionEvidenceLimit") }
        return .init(state: "available", observedAt: now, selector: selector, currentOutbound: evidence.currentOutbound,
                     recommendedOutbound: decision.recommendedOutbound, confidence: ambiguous > 0 ? .low : decision.confidence,
                     keepCurrent: decision.keepCurrentSelection, reasonCodes: reasons.sorted(), candidateCount: tags.count,
                     probeSuccessCount: successes, probeFailureCount: failures, ambiguousProbeCount: ambiguous,
                     connectionSuccessCount: connections, connectionSnapshotAvailable: evidence.connections != nil,
                     connectionSnapshotTruncated: evidence.connections?.isTruncated ?? false,
                     selectionEvidence: .init(catalog: catalog, sessionID: evidence.sessionID,
                                              selector: selector, currentOutbound: evidence.currentOutbound, observedAt: now))
    }

    // Internal deterministic inspection; no production output or persistence.
    func retainedState() -> SmartPolicyState { engine.state }
    func retainedConnectionIDCount() -> Int { connectionIDs.count }
}

protocol SmartPolicyEvaluating: Sendable {
    func evaluate() async throws -> SmartShadowRecommendation
}
extension SmartPolicyShadowOperations: SmartPolicyEvaluating {}

struct SmartPolicyApplyResult: Sendable {
    let recommendation: SmartShadowRecommendation?
    let applied: Bool
    let after: String?
    let reasonCode: String
    var receipt: PolicySelectionReceipt? = nil

    func automationJSON() -> JSONValue {
        var fields: [String: JSONValue] = [
            "applied": .boolean(applied), "before": recommendation?.currentOutbound.map(JSONValue.string) ?? .null,
            "after": after.map(JSONValue.string) ?? .null,
            "recommended": recommendation?.recommendedOutbound.map(JSONValue.string) ?? .null,
            "confidence": .string(recommendation?.confidence.rawValue ?? "low"),
            "reasonCodes": .array([.string(reasonCode)])
        ]
        if case .object(let evaluation)? = recommendation?.automationJSON() {
            fields["evidence"] = evaluation["evidence"]
            fields["decisionReasonCodes"] = evaluation["reasonCodes"]
        }
        return .object(fields)
    }
}

protocol SmartPolicyApplying: Sendable {
    func apply() async -> SmartPolicyApplyResult
}

/// An explicit invocation evaluates once and may request one shared Policy write.
/// There is no background task, retry, lifecycle action or connection interruption.
actor SmartPolicyApplyOperations {
    private let evaluator: any SmartPolicyEvaluating
    private let policy: any TargetPolicyOperating
    private let clock: @Sendable () -> Date
    private var applying = false
    static let maximumEvidenceAge: TimeInterval = 10

    init(evaluator: any SmartPolicyEvaluating, policy: any TargetPolicyOperating,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.evaluator = evaluator
        self.policy = policy
        self.clock = clock
    }

    func apply() async -> SmartPolicyApplyResult {
        func result(_ reason: String, _ recommendation: SmartShadowRecommendation? = nil) -> SmartPolicyApplyResult {
            .init(recommendation: recommendation, applied: false, after: nil, reasonCode: reason)
        }
        guard !applying else { return result("applyInProgress") }
        applying = true
        defer { applying = false }
        let generation = policy.selectionGeneration()
        var recommendation: SmartShadowRecommendation?
        do {
            try Task.checkCancellation()
            let value = try await evaluator.evaluate()
            recommendation = value
            try Task.checkCancellation()
            guard value.state == "available" else { return result(value.reasonCodes.first ?? "runtimeUnavailable", value) }
            guard let evidence = value.selectionEvidence,
                  evidence.selector == value.selector, evidence.currentOutbound == value.currentOutbound,
                  evidence.observedAt == value.observedAt,
                  let recommended = value.recommendedOutbound else { return result("invalidRecommendation", value) }
            guard (try? PolicySelectionValidator.validate(selectorTag: evidence.selector, outboundTag: recommended, in: evidence.catalog)) != nil else {
                return result("invalidRecommendation", value)
            }
            let age = clock().timeIntervalSince(value.observedAt)
            guard age.isFinite, (0...Self.maximumEvidenceAge).contains(age),
                  !value.reasonCodes.contains("staleEvidence") else { return result("staleEvidence", value) }
            guard value.ambiguousProbeCount == 0, !value.reasonCodes.contains("ambiguousProbeEvidence"),
                  !value.reasonCodes.contains("networkWideDegradation") else { return result("ambiguousEvidence", value) }
            guard value.connectionSnapshotAvailable else { return result("runtimeUnavailable", value) }
            guard value.confidence != .low else { return result("lowConfidence", value) }
            guard !value.keepCurrent else { return result("keepCurrent", value) }
            guard recommended != evidence.currentOutbound else { return result("alreadySelected", value) }
            let outcome = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: recommended, generation: generation)
            return .init(recommendation: value, applied: outcome.applied, after: outcome.after,
                         reasonCode: outcome.reason.rawValue, receipt: outcome.receipt)
        } catch is CancellationError { return result("cancelled", recommendation) }
        catch { return result("operationUnavailable", recommendation) }
    }
}
extension SmartPolicyApplyOperations: SmartPolicyApplying {}

/// The two explicit user-facing Smart actions share these already-guarded
/// application operations. The result used by the GUI contains only bounded
/// aggregate facts; automation keeps its existing machine-readable result.
enum SmartApplicationAction: String, Sendable {
    case switchAction
    case continuityApply
}

struct SmartApplicationResult: Equatable, Sendable {
    let action: SmartApplicationAction
    let selectorSwitched: Bool
    let closedConnectionCount: Int
    let preservedConnectionCount: Int
    let reasonCode: String

    init(action: SmartApplicationAction, result: SmartPolicyApplyResult) {
        self.action = action
        selectorSwitched = result.applied
        closedConnectionCount = 0
        preservedConnectionCount = 0
        reasonCode = result.reasonCode
    }

    init(action: SmartApplicationAction, result: SmartContinuityApplyResult) {
        self.action = action
        selectorSwitched = result.selectorApplied
        closedConnectionCount = result.closedConnectionCount
        preservedConnectionCount = result.preservedConnectionCount
        if result.failedCloseCount > 0 {
            reasonCode = "closeFailed"
        } else if result.closedConnectionCount > 0 {
            reasonCode = "completed"
        } else if let reason = Self.continuityPresentationReason(in: result.reasonCodes) {
            reasonCode = reason
        } else if result.selectorApplied {
            reasonCode = result.eligibleConnectionCount > 0 ? "connectionsPreserved" : "noEligibleConnections"
        } else {
            // A selector that never applied cannot have a connection-preservation
            // outcome. Keep the UI finite and credential-safe when a lower layer
            // returns a reason outside the presentation contract.
            reasonCode = "operationUnavailable"
        }
    }

    private static func continuityPresentationReason(in reasons: [String]) -> String? {
        // Keep this ordered: SmartContinuityApplyResult is an aggregate and may
        // contain more than one bounded reason after a partial operation.
        let allowed = [
            "lowConfidence", "ambiguousEvidence", "applyInProgress", "evaluationInProgress",
            "operationUnavailable", "alreadySelected", "keepCurrent", "cancelled",
            "selectionUnconfirmed", "runtimeUnavailable", "staleEvidence",
            "noEligibleConnections", "connectionsPreserved"
        ]
        return allowed.first(where: reasons.contains)
    }
}

protocol SmartApplicationOperating: Sendable {
    func evaluateShadow() async throws -> SmartShadowRecommendation
    func applySwitch() async -> SmartPolicyApplyResult
    func applyContinuity() async -> SmartContinuityApplyResult
    func evaluateContinuity() async -> SmartContinuitySummary
}

/// Composition root for Smart Policy application. Both the GUI and local
/// automation receive the same instance, including the same stateful shadow,
/// selector-apply and continuity-apply actors.
actor TargetSmartApplicationOperations: SmartApplicationOperating {
    private let shadow: any SmartPolicyEvaluating
    private let smartApply: any SmartPolicyApplying
    private let continuity: SmartContinuityOperations
    private let continuityApply: SmartContinuityApplyOperations

    init(shadow: any SmartPolicyEvaluating, smartApply: any SmartPolicyApplying, continuity: SmartContinuityOperations,
         continuityApply: SmartContinuityApplyOperations) {
        self.shadow = shadow
        self.smartApply = smartApply
        self.continuity = continuity
        self.continuityApply = continuityApply
    }

    func evaluateShadow() async throws -> SmartShadowRecommendation {
        try await shadow.evaluate()
    }

    func applySwitch() async -> SmartPolicyApplyResult {
        await smartApply.apply()
    }

    func applyContinuity() async -> SmartContinuityApplyResult {
        await continuityApply.apply()
    }

    func evaluateContinuity() async -> SmartContinuitySummary {
        await continuity.evaluate()
    }
}
