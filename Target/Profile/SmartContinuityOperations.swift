import Foundation
import TargetCore

enum SmartContinuityClassification: String, Sendable {
    case protect, replaceable, unknown
    // Uncertainty always preserves the connection. This is not close authority.
    var preservesConnection: Bool { self != .replaceable }
}

struct SmartContinuityEvidence: Sendable {
    let identity: EngineRuntimeRecord
    let snapshot: RuntimeConnectionsSnapshot
    let observedAt: Date
}

enum SmartContinuityRuntimeResult: Sendable {
    case available(SmartContinuityEvidence)
    case stopped
    case unavailable
}

protocol SmartContinuityRuntimeReading: Sendable {
    func collectContinuityEvidence() async throws -> SmartContinuityRuntimeResult
}

struct UnavailableSmartContinuityRuntime: SmartContinuityRuntimeReading {
    func collectContinuityEvidence() async throws -> SmartContinuityRuntimeResult { .unavailable }
}

struct SmartContinuitySummary: Sendable {
    let state: String
    let observedAt: Date?
    let sampleCount: Int
    let observedConnectionCount: Int
    let protectCount: Int
    let replaceableCount: Int
    let unknownCount: Int
    let snapshotTruncated: Bool
    let snapshotUnavailable: Bool
    let reasonCodes: [String]

    static func unavailable(_ reason: String, state: String = "unavailable") -> Self {
        .init(state: state, observedAt: nil, sampleCount: 0, observedConnectionCount: 0,
              protectCount: 0, replaceableCount: 0, unknownCount: 0,
              snapshotTruncated: false, snapshotUnavailable: true, reasonCodes: [reason])
    }

    func automationJSON() -> JSONValue {
        .object([
            "state": .string(state),
            "observedAt": observedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "sampleCount": .integer(sampleCount), "observedConnectionCount": .integer(observedConnectionCount),
            "protectCount": .integer(protectCount), "replaceableCount": .integer(replaceableCount),
            "unknownCount": .integer(unknownCount), "snapshotTruncated": .boolean(snapshotTruncated),
            "snapshotUnavailable": .boolean(snapshotUnavailable),
            "reasonCodes": .array(reasonCodes.map(JSONValue.string))
        ])
    }
}

/// Deterministic, process-local short windows. No destination data or history is retained.
struct SmartContinuityClassifier: Sendable {
    static let window: TimeInterval = 30
    static let maximumSampleGap: TimeInterval = 10
    static let longLivedAge: TimeInterval = 300
    static let sustainedBytes: Int64 = 1_024
    static let lowRiskTotalBytes: Int64 = 4_096
    static let maximumConnections = RuntimeConnectionsParser.maximumDetailedConnections
    static let maximumSamples = 7
    static let maximumFieldBytes = 256
    static let maximumChainLength = 32

    private struct Sample: Sendable {
        let time: Date
        let upload: Int64
        let download: Int64
    }
    private struct Flow: Sendable {
        let startedAt: Date
        let network: String
        let chain: [String]
        var samples: [Sample]
    }
    private var identity: EngineRuntimeRecord?
    private var times: [Date] = []
    private var flows: [String: Flow] = [:]
    private(set) var classifications: [String: SmartContinuityClassification] = [:]
    var retainedConnectionCount: Int { flows.count }
    var retainedSampleCount: Int { flows.values.reduce(0) { $0 + $1.samples.count } }

    mutating func reset() { identity = nil; times.removeAll(); flows.removeAll(); classifications.removeAll() }

    mutating func observe(_ evidence: SmartContinuityEvidence) -> SmartContinuitySummary {
        let now = evidence.observedAt
        classifications.removeAll(keepingCapacity: true)
        guard now.timeIntervalSince1970.isFinite else { reset(); return .unavailable("clockUnavailable") }
        var reasons = Set<String>()
        if identity != evidence.identity {
            reset(); identity = evidence.identity; reasons.insert("runtimeWindowStarted")
        }
        if let last = times.last, now <= last || now.timeIntervalSince(last) > Self.maximumSampleGap {
            times.removeAll(); flows.removeAll(); reasons.insert("samplingDiscontinuity")
        }
        times.append(now)
        Self.trim(&times, now: now, time: { $0 })
        let connections = Array(evidence.snapshot.connections.prefix(Self.maximumConnections))
        let truncated = evidence.snapshot.isTruncated || evidence.snapshot.connections.count > Self.maximumConnections
        if truncated { reasons.insert("snapshotTruncated"); reasons.insert("preserveUnobserved") }
        // Even a truncated snapshot cannot extend an absent ID's window.
        let present = Set(connections.map(\.id))
        flows = flows.filter { present.contains($0.key) }
        var counts: [SmartContinuityClassification: Int] = [:]
        let duplicates = Set(Dictionary(grouping: connections, by: \.id).filter { $0.value.count > 1 }.keys)
        for connection in connections {
            let result: (SmartContinuityClassification, String)
            if duplicates.contains(connection.id) {
                flows.removeValue(forKey: connection.id); result = (.unknown, "duplicateID")
            } else {
                result = classify(connection, now: now, truncated: truncated)
            }
            counts[result.0, default: 0] += 1
            classifications[connection.id] = result.0
            reasons.insert(result.1)
        }
        return .init(state: truncated ? "partial" : "available", observedAt: now, sampleCount: times.count,
                     observedConnectionCount: connections.count, protectCount: counts[.protect, default: 0],
                     replaceableCount: counts[.replaceable, default: 0], unknownCount: counts[.unknown, default: 0],
                     snapshotTruncated: truncated, snapshotUnavailable: false, reasonCodes: reasons.sorted())
    }

    private static func trim<T>(_ samples: inout [T], now: Date, time: (T) -> Date) {
        // Retain one boundary anchor, but never more than seven samples.
        while samples.count > 1, now.timeIntervalSince(time(samples[1])) >= window { samples.removeFirst() }
        if samples.count > maximumSamples { samples.removeFirst(samples.count - maximumSamples) }
    }

    private mutating func classify(_ connection: RuntimeConnection, now: Date, truncated: Bool) -> (SmartContinuityClassification, String) {
        let id = connection.id
        guard !id.isEmpty, id.utf8.count <= Self.maximumFieldBytes,
              let start = connection.startedAt, start.timeIntervalSince1970.isFinite, start <= now,
              let upload = connection.uploadBytes, let download = connection.downloadBytes, upload >= 0, download >= 0,
              let network = connection.network?.lowercased(), ["tcp", "udp"].contains(network),
              !connection.outboundChain.isEmpty, connection.outboundChain.count <= Self.maximumChainLength,
              connection.outboundChain.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumFieldBytes }) else {
            flows.removeValue(forKey: id); return (.unknown, "missingEvidence")
        }
        let sample = Sample(time: now, upload: upload, download: download)
        var flow = flows[id] ?? Flow(startedAt: start, network: network, chain: connection.outboundChain, samples: [])
        var resetReason: String?
        if flow.startedAt != start || flow.network != network || flow.chain != connection.outboundChain {
            resetReason = "connectionIdentityChanged"
        } else if let previous = flow.samples.last, upload < previous.upload || download < previous.download {
            resetReason = "counterReset"
        }
        if resetReason != nil { flow = Flow(startedAt: start, network: network, chain: connection.outboundChain, samples: []) }
        flow.samples.append(sample)
        Self.trim(&flow.samples, now: now, time: { $0.time })
        flows[id] = flow
        if let resetReason { return (.unknown, resetReason) }
        let age = now.timeIntervalSince(start)
        guard age >= Self.window else { return (.unknown, "justCreated") }
        guard flow.samples.count >= 2 else { return (.unknown, "warmingWindow") }
        let deltas = zip(flow.samples, flow.samples.dropFirst()).map { ($1.upload - $0.upload, $1.download - $0.download) }
        if network == "udp", deltas.contains(where: { $0.0 > 0 || $0.1 > 0 }) { return (.protect, "recentUDP") }
        let recent = deltas.suffix(2)
        if recent.count == 2, recent.allSatisfy({ $0.0 >= Self.sustainedBytes && $0.1 >= Self.sustainedBytes }) {
            return (.protect, "sustainedBidirectional")
        }
        if recent.count == 2, recent.allSatisfy({ $0.1 >= Self.sustainedBytes }) { return (.protect, "sustainedDownload") }
        if deltas.contains(where: { $0.0 > 0 || $0.1 > 0 }) { return (.protect, "recentActivity") }
        if age >= Self.longLivedAge { return (.unknown, "longLivedFlow") }
        guard !truncated, network == "tcp", upload <= Self.lowRiskTotalBytes, download <= Self.lowRiskTotalBytes - upload,
              flow.samples.count >= 4, let first = flow.samples.first,
              now.timeIntervalSince(first.time) >= Self.window else { return (.unknown, "insufficientIdleEvidence") }
        return (.replaceable, "continuousIdleLowRisk")
    }
}

/// One verified read per invocation, no timers, background tasks or mutations.
actor SmartContinuityOperations {
    private let runtime: any SmartContinuityRuntimeReading
    private var classifier = SmartContinuityClassifier()
    private var evaluating = false
    init(runtime: any SmartContinuityRuntimeReading) { self.runtime = runtime }

    func evaluate() async -> SmartContinuitySummary {
        await observe().summary
    }

    func preparePlan() async -> SmartContinuityPlan? {
        await observe().plan
    }

    private func observe() async -> (summary: SmartContinuitySummary, plan: SmartContinuityPlan?) {
        guard !evaluating else { return (.unavailable("evaluationInProgress"), nil) }
        evaluating = true
        defer { evaluating = false }
        do {
            try Task.checkCancellation()
            let result = try await runtime.collectContinuityEvidence()
            try Task.checkCancellation()
            switch result {
            case .available(let evidence):
                let summary = classifier.observe(evidence)
                return (summary, .init(evidence: evidence, classifier: classifier,
                                       classifications: classifier.classifications, summary: summary))
            case .stopped: classifier.reset(); return (.unavailable("engineStopped", state: "stopped"), nil)
            case .unavailable: classifier.reset(); return (.unavailable("runtimeUnavailable"), nil)
            }
        } catch {
            classifier.reset()
            return (.unavailable(error is CancellationError ? "cancelled" : "runtimeUnavailable"), nil)
        }
    }
    func retainedConnectionCount() -> Int { classifier.retainedConnectionCount }
}

protocol SmartContinuityPlanning: Sendable {
    func preparePlan() async -> SmartContinuityPlan?
}
extension SmartContinuityOperations: SmartContinuityPlanning {}

/// A bounded in-process checkpoint. Connection identities are never exported.
struct SmartContinuityPlan: Sendable {
    let evidence: SmartContinuityEvidence
    let classifier: SmartContinuityClassifier
    let classifications: [String: SmartContinuityClassification]
    let summary: SmartContinuitySummary

    func permitsClose(_ connection: RuntimeConnection, with fresh: SmartContinuityEvidence, now: Date) -> Bool {
        let age = now.timeIntervalSince(evidence.observedAt)
        let freshAge = now.timeIntervalSince(fresh.observedAt)
        guard age.isFinite, (0...SmartPolicyApplyOperations.maximumEvidenceAge).contains(age),
              freshAge.isFinite, (0...SmartPolicyApplyOperations.maximumEvidenceAge).contains(freshAge),
              fresh.observedAt > evidence.observedAt, evidence.identity == fresh.identity,
              !evidence.snapshot.isTruncated, !fresh.snapshot.isTruncated,
              classifications[connection.id] == .replaceable,
              let initial = evidence.snapshot.connections.first(where: { $0.id == connection.id }),
              fresh.snapshot.connections.filter({ $0.id == connection.id }).count == 1,
              fresh.snapshot.connections.first(where: { $0.id == connection.id }) == connection,
              initial == connection else { return false }
        var checkpoint = classifier
        _ = checkpoint.observe(fresh)
        return checkpoint.classifications[connection.id] == .replaceable
    }

    static func isRelevantOldConnection(_ connection: RuntimeConnection, receipt: PolicySelectionReceipt) -> Bool {
        let chain = connection.outboundChain
        guard receipt.oldOutbound != receipt.newOutbound,
              receipt.oldOutbound != receipt.selector, !chain.contains(receipt.newOutbound),
              chain.filter({ $0 == receipt.selector }).count == 1,
              chain.filter({ $0 == receipt.oldOutbound }).count == 1,
              let index = chain.firstIndex(of: receipt.selector), index > chain.startIndex else { return false }
        return chain[chain.index(before: index)] == receipt.oldOutbound
    }
}

struct SmartContinuityCloseRequest: Sendable {
    let plan: SmartContinuityPlan
    let connection: RuntimeConnection
    let receipt: PolicySelectionReceipt
}

enum SmartContinuityCloseOutcome: Sendable {
    case closed
    case preserved(String)
    case failed
    /// Cancellation is returned only when destructive dispatch never occurred.
    case cancelled
}

protocol SmartContinuityRuntimeClosing: Sendable {
    func closeContinuityConnection(_ request: SmartContinuityCloseRequest,
        authorize: @escaping @Sendable (_ dispatch: @Sendable () -> Void) throws -> Void) async throws -> SmartContinuityCloseOutcome
}

struct SmartContinuityApplyResult: Sendable {
    let selectorApplied: Bool
    let observedConnectionCount: Int
    let eligibleConnectionCount: Int
    let closedConnectionCount: Int
    let preservedConnectionCount: Int
    let failedCloseCount: Int
    let protectCount: Int
    let unknownCount: Int
    let replaceableCount: Int
    let reasonCodes: [String]

    func automationJSON() -> JSONValue {
        .object([
            "selectorApplied": .boolean(selectorApplied),
            "observedConnectionCount": .integer(observedConnectionCount),
            "eligibleConnectionCount": .integer(eligibleConnectionCount),
            "closedConnectionCount": .integer(closedConnectionCount),
            "preservedConnectionCount": .integer(preservedConnectionCount),
            "failedCloseCount": .integer(failedCloseCount),
            "protectCount": .integer(protectCount),
            "unknownCount": .integer(unknownCount),
            "replaceableCount": .integer(replaceableCount),
            "reasonCodes": .array(reasonCodes.map(JSONValue.string))
        ])
    }
}

/// Explicit selector convergence followed by individually guarded interruption.
/// Ordinary Smart apply retains no reference to the close boundary.
actor SmartContinuityApplyOperations {
    static let maximumCloses = 8
    private let continuity: any SmartContinuityPlanning
    private let smartApply: any SmartPolicyApplying
    private let policy: any TargetPolicyOperating
    private let clock: @Sendable () -> Date
    private var applying = false

    init(continuity: any SmartContinuityPlanning, smartApply: any SmartPolicyApplying,
         policy: any TargetPolicyOperating, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.continuity = continuity; self.smartApply = smartApply; self.policy = policy; self.clock = clock
    }

    func apply() async -> SmartContinuityApplyResult {
        var selectorApplied = false
        var observed = 0, eligible = 0, closed = 0, failed = 0
        var protect = 0, unknown = 0, replaceable = 0
        var closeInFlight = false
        var reasons = Set<String>()
        func result(_ reason: String? = nil) -> SmartContinuityApplyResult {
            if let reason { reasons.insert(Self.safeReason(reason)) }
            return .init(selectorApplied: selectorApplied, observedConnectionCount: observed,
                         eligibleConnectionCount: eligible, closedConnectionCount: closed,
                         preservedConnectionCount: max(0, observed - closed - failed), failedCloseCount: failed,
                         protectCount: protect, unknownCount: unknown, replaceableCount: replaceable,
                         reasonCodes: reasons.sorted())
        }
        guard !applying else { return result("applyInProgress") }
        applying = true
        defer { applying = false }
        do {
            try Task.checkCancellation()
            guard let plan = await continuity.preparePlan() else {
                return result(Task.isCancelled ? "cancelled" : "runtimeUnavailable")
            }
            observed = plan.summary.observedConnectionCount
            protect = plan.summary.protectCount; unknown = plan.summary.unknownCount; replaceable = plan.summary.replaceableCount
            try Task.checkCancellation()
            let selection = await smartApply.apply()
            selectorApplied = selection.applied
            try Task.checkCancellation()
            guard selection.applied else { return result(selection.reasonCode) }
            guard let recommendation = selection.recommendation,
                  recommendation.state == "available",
                  let recommendationSelector = recommendation.selector,
                  let recommendationCurrent = recommendation.currentOutbound,
                  let recommendationRecommended = recommendation.recommendedOutbound,
                  let recommendationEvidence = recommendation.selectionEvidence,
                  recommendationSelector == recommendationEvidence.selector,
                  recommendationCurrent == recommendationEvidence.currentOutbound,
                  !recommendation.keepCurrent,
                  recommendation.confidence != .low,
                  let receipt = selection.receipt,
                  recommendationEvidence.catalog == receipt.catalog,
                  recommendationEvidence.sessionID == receipt.identity.runtimeConfigurationID,
                  recommendationEvidence.observedAt == recommendation.observedAt,
                  recommendationRecommended == receipt.newOutbound,
                  recommendationCurrent == receipt.oldOutbound,
                  recommendationSelector == receipt.selector,
                  selection.after == receipt.newOutbound,
                  receipt.identity == plan.evidence.identity else { return result("selectionUnconfirmed") }
            guard !plan.evidence.snapshot.isTruncated else { return result("snapshotTruncated") }
            let age = clock().timeIntervalSince(plan.evidence.observedAt)
            guard age.isFinite, (0...SmartPolicyApplyOperations.maximumEvidenceAge).contains(age) else { return result("staleEvidence") }
            let candidates = plan.evidence.snapshot.connections.filter {
                plan.classifications[$0.id] == .replaceable && SmartContinuityPlan.isRelevantOldConnection($0, receipt: receipt)
            }.sorted { $0.id < $1.id }
            eligible = candidates.count
            if eligible > Self.maximumCloses { reasons.insert("closeLimitReached") }
            for connection in candidates.prefix(Self.maximumCloses) {
                try Task.checkCancellation()
                closeInFlight = true
                let outcome = try await policy.closeContinuityConnectionIfUnchanged(.init(plan: plan, connection: connection, receipt: receipt))
                closeInFlight = false
                switch outcome {
                case .closed: closed += 1
                case .preserved(let reason): reasons.insert(Self.safeReason(reason))
                case .failed: failed += 1; return result("closeFailed")
                case .cancelled: return result("cancelled")
                }
            }
            return result(eligible == 0 ? "noEligibleConnections" : closed > 0 ? "completed" : "connectionsPreserved")
        } catch is CancellationError { if closeInFlight { failed += 1 }; return result("cancelled") }
        catch { if closeInFlight { failed += 1 }; return result("closeFailed") }
    }

    private static func safeReason(_ reason: String) -> String {
        let allowed: Set<String> = ["applyInProgress", "runtimeUnavailable", "engineStopped", "selectionUnconfirmed",
            "snapshotTruncated", "staleEvidence", "closeLimitReached", "closeFailed", "cancelled", "noEligibleConnections",
            "completed", "connectionsPreserved", "keepCurrent", "alreadySelected", "lowConfidence", "ambiguousEvidence",
            "invalidRecommendation", "identityChanged", "profileChanged", "liveSelectionChanged", "selectionChanged",
            "mutationInProgress", "mutationUnconfirmed", "operationUnavailable", "controllerUnavailable", "connectionDisappeared",
            "connectionIdentityChanged", "connectionActive", "connectionProtected", "connectionUnknown", "unrelatedConnection",
            "newSelectionConnection", "invalidConnectionID", "replaceableEvidenceUnavailable", "clockUnavailable", "connectionChanged"]
        return allowed.contains(reason) ? reason : "runtimeUnavailable"
    }
}
