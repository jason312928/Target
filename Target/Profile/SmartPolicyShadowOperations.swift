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
                     connectionSnapshotTruncated: evidence.connections?.isTruncated ?? false)
    }

    // Internal deterministic inspection; no production output or persistence.
    func retainedState() -> SmartPolicyState { engine.state }
    func retainedConnectionIDCount() -> Int { connectionIDs.count }
}
