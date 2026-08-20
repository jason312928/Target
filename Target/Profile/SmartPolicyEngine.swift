import Foundation

/// Offline route-intelligence primitives. This type deliberately has no runtime,
/// networking, persistence, or wall-clock dependency.
struct SmartPolicyConfiguration: Equatable, Sendable {
    static let `default` = SmartPolicyConfiguration()

    var maximumNodeStates: Int = 64
    var maximumDestinationStates: Int = 24
    var maximumObservationsPerNode: Int = 8
    var maximumDestinationObservations: Int = 8
    var failureWindow: TimeInterval = 45
    var staleAfter: TimeInterval = 300
    var penaltyHalfLife: TimeInterval = 300
    var hardFailurePenalty: Double = 0.82
    var switchToleranceMilliseconds: Double = 15
    var explorationEnabled: Bool = true
    var explorationRate: UInt64 = 4
}

struct SmartPolicyCandidate: Equatable, Sendable {
    let tag: String
    let available: Bool

    init(tag: String, available: Bool = true) {
        self.tag = tag
        self.available = available
    }
}

struct SmartPolicyContext: Equatable, Sendable {
    let candidates: [SmartPolicyCandidate]
    let destination: String?
    let currentOutbound: String?
    let now: TimeInterval

    init(candidates: [SmartPolicyCandidate], destination: String? = nil, currentOutbound: String? = nil, now: TimeInterval) {
        self.candidates = candidates
        self.destination = destination
        self.currentOutbound = currentOutbound
        self.now = now
    }
}

enum SmartPolicyEvent: Equatable, Sendable {
    case probeSuccess(tag: String, latencyMilliseconds: Double, at: TimeInterval)
    case probeFailure(tag: String, at: TimeInterval)
    case connectionSuccess(tag: String, at: TimeInterval)
    case connectionFailure(tag: String, at: TimeInterval)
    case destinationSuccess(destination: String, tag: String, at: TimeInterval)
    case destinationFailure(destination: String, tag: String, at: TimeInterval)
    case networkEpochChanged(at: TimeInterval)
    case timeAdvanced(to: TimeInterval)
    case candidateRemoved(tag: String, at: TimeInterval)
}

enum SmartPolicyConfidence: String, Equatable, Sendable {
    case low
    case medium
    case high
}

enum SmartPolicyReasonCode: String, Equatable, Sendable {
    case insufficientEvidence
    case recentFailures
    case consecutiveFailures
    case relativeDegradation
    case destinationPreference
    case destinationFailure
    case networkWideDegradation
    case currentSelectionWithinTolerance
    case currentSelectionUnhealthy
    case recoveryEvidence
    case penaltyDecay
    case explorationCandidate
    case candidateIneligible
    case staleEvidence
}

struct SmartNodeState: Equatable, Sendable {
    let tag: String
    fileprivate(set) var successCount: Int = 0
    fileprivate(set) var failureCount: Int = 0
    fileprivate(set) var consecutiveFailures: Int = 0
    fileprivate(set) var latencyHistory: [Double] = []
    fileprivate(set) var lastLatencyMilliseconds: Double?
    fileprivate(set) var penalty: Double = 0
    fileprivate(set) var lastSuccessAt: TimeInterval?
    fileprivate(set) var lastFailureAt: TimeInterval?
    fileprivate(set) var recoveryEvidence: Int = 0
    fileprivate(set) var networkEpoch: Int = 0

    var latencyBaselineMilliseconds: Double? {
        // Exclude the latest probe so a degraded sample cannot dilute itself.
        let baselineSamples = latencyHistory.dropLast()
        guard !baselineSamples.isEmpty else { return nil }
        return baselineSamples.reduce(0, +) / Double(baselineSamples.count)
    }

    var observedLatencyAverageMilliseconds: Double? {
        guard !latencyHistory.isEmpty else { return nil }
        return latencyHistory.reduce(0, +) / Double(latencyHistory.count)
    }

    var relativeDegradation: Bool {
        guard latencyHistory.count >= 5, let latest = lastLatencyMilliseconds,
              let baseline = latencyBaselineMilliseconds, baseline > 0 else { return false }
        return latest >= baseline * 1.8 && latest - baseline >= 30
    }

    var isFinite: Bool {
        latencyHistory.allSatisfy(\.isFinite) && (lastLatencyMilliseconds?.isFinite ?? true) && penalty.isFinite
    }
}

struct SmartDestinationState: Equatable, Sendable {
    let destination: String
    fileprivate(set) var observations: [String: SmartDestinationObservation] = [:]
    fileprivate(set) var lastEventAt: TimeInterval = 0
}

struct SmartDestinationObservation: Equatable, Sendable {
    fileprivate(set) var successes: Int = 0
    fileprivate(set) var failures: Int = 0
    fileprivate(set) var lastEventAt: TimeInterval = 0
    func isStale(at time: TimeInterval, staleAfter: TimeInterval) -> Bool {
        time - lastEventAt > staleAfter
    }
}

struct SmartNetworkEpoch: Equatable, Sendable {
    fileprivate(set) var identifier: Int = 0
    fileprivate(set) var startedAt: TimeInterval = 0
}

struct SmartPolicyState: Equatable, Sendable {
    fileprivate(set) var nodes: [String: SmartNodeState] = [:]
    fileprivate(set) var destinations: [String: SmartDestinationState] = [:]
    fileprivate(set) var networkEpoch = SmartNetworkEpoch()
    fileprivate(set) var currentTime: TimeInterval = 0

    var isFinite: Bool {
        currentTime.isFinite && networkEpoch.startedAt.isFinite && nodes.values.allSatisfy(\.isFinite)
    }
}

struct SmartPolicyDecision: Equatable, Sendable {
    let recommendedOutbound: String?
    let confidence: SmartPolicyConfidence
    let keepCurrentSelection: Bool
    let reasonCodes: [SmartPolicyReasonCode]
}

struct SmartPolicyEngine: Equatable, Sendable {
    private(set) var state: SmartPolicyState
    let configuration: SmartPolicyConfiguration
    let seed: UInt64

    init(configuration: SmartPolicyConfiguration = .default, seed: UInt64 = 0, initialState: SmartPolicyState = SmartPolicyState()) {
        self.configuration = configuration
        self.seed = seed
        self.state = initialState
    }

    mutating func apply(_ event: SmartPolicyEvent) {
        let timestamp = event.timestamp
        guard timestamp.isFinite, timestamp >= state.currentTime else { return }
        state.currentTime = timestamp
        switch event {
        case let .probeSuccess(tag, latency, _):
            guard validTag(tag), latency.isFinite, latency > 0, latency <= 65_535 else { return }
            var node = nodeState(for: tag)
            decay(&node, to: timestamp)
            node.successCount = min(node.successCount + 1, 10_000)
            node.consecutiveFailures = 0
            node.lastSuccessAt = timestamp
            node.recoveryEvidence = min(node.recoveryEvidence + 1, 10_000)
            node.lastLatencyMilliseconds = latency
            node.latencyHistory.append(latency)
            if node.latencyHistory.count > configuration.maximumObservationsPerNode { node.latencyHistory.removeFirst() }
            node.penalty = clamp(node.penalty * 0.72, 0, 1)
            state.nodes[tag] = node
        case let .probeFailure(tag, _), let .connectionFailure(tag, _):
            guard validTag(tag) else { return }
            var node = nodeState(for: tag)
            decay(&node, to: timestamp)
            node.failureCount = min(node.failureCount + 1, 10_000)
            node.consecutiveFailures = min(node.consecutiveFailures + 1, 10_000)
            node.lastFailureAt = timestamp
            node.recoveryEvidence = 0
            let escalation = min(0.18 * Double(node.consecutiveFailures), 0.75)
            node.penalty = clamp(max(node.penalty + escalation, 0.18), 0, 1)
            state.nodes[tag] = node
        case let .connectionSuccess(tag, _):
            guard validTag(tag) else { return }
            var node = nodeState(for: tag)
            decay(&node, to: timestamp)
            node.successCount = min(node.successCount + 1, 10_000)
            node.consecutiveFailures = 0
            node.lastSuccessAt = timestamp
            node.recoveryEvidence = min(node.recoveryEvidence + 1, 10_000)
            node.penalty = clamp(node.penalty * 0.82, 0, 1)
            state.nodes[tag] = node
        case let .destinationSuccess(destination, tag, _):
            updateDestination(destination, tag: tag, success: true, at: timestamp)
        case let .destinationFailure(destination, tag, _):
            updateDestination(destination, tag: tag, success: false, at: timestamp)
        case .networkEpochChanged:
            state.networkEpoch.identifier = min(state.networkEpoch.identifier + 1, 10_000)
            state.networkEpoch.startedAt = timestamp
            for tag in state.nodes.keys {
                var node = state.nodes[tag]!
                node.networkEpoch = state.networkEpoch.identifier
                node.latencyHistory.removeAll(keepingCapacity: true)
                node.lastLatencyMilliseconds = nil
                node.penalty = clamp(node.penalty * 0.65, 0, 1)
                state.nodes[tag] = node
            }
        case .timeAdvanced:
            for tag in state.nodes.keys {
                var node = state.nodes[tag]!
                decay(&node, to: timestamp)
                state.nodes[tag] = node
            }
        case let .candidateRemoved(tag, _):
            state.nodes.removeValue(forKey: tag)
            for destination in state.destinations.keys { state.destinations[destination]?.observations.removeValue(forKey: tag) }
        }
        trimState()
    }

    mutating func replay(_ events: [SmartPolicyEvent]) {
        for event in events {
            apply(event)
        }
    }

    func decision(for context: SmartPolicyContext) -> SmartPolicyDecision {
        guard context.now.isFinite else { return .init(recommendedOutbound: nil, confidence: .low, keepCurrentSelection: false, reasonCodes: [.insufficientEvidence]) }
        let candidates = uniqueCandidates(context.candidates)
        guard !candidates.isEmpty else { return .init(recommendedOutbound: nil, confidence: .low, keepCurrentSelection: false, reasonCodes: [.insufficientEvidence]) }
        let eligible = candidates.filter(\.available).filter { !isHardIneligible($0.tag, at: context.now) }
        guard !eligible.isEmpty else { return .init(recommendedOutbound: nil, confidence: .low, keepCurrentSelection: false, reasonCodes: [.candidateIneligible, .insufficientEvidence]) }
        var evaluations = eligible.map { candidate in
            evaluate(candidate.tag, destination: context.destination, at: context.now)
        }
        evaluations.sort { left, right in
            if left.score == right.score { return left.tag < right.tag }
            return left.score < right.score
        }
        let best = evaluations[0]
        var selected = best
        var reasons = best.reasons
        if evaluations.dropFirst().contains(where: { $0.reasons.contains(.relativeDegradation) }) {
            reasons.append(.relativeDegradation)
        }
        var keepCurrent = false

        if let current = context.currentOutbound, let currentEvaluation = evaluations.first(where: { $0.tag == current }) {
            let improvement = currentEvaluation.score - best.score
            let threshold = max(configuration.switchToleranceMilliseconds, abs(currentEvaluation.latency - best.latency) * 0.12)
            let severeCurrentFailure = currentEvaluation.hardFailure
            if best.tag != current && !severeCurrentFailure && improvement < threshold {
                selected = currentEvaluation
                keepCurrent = true
                reasons = [SmartPolicyReasonCode.currentSelectionWithinTolerance]
            } else if severeCurrentFailure && best.tag != current {
                reasons.insert(SmartPolicyReasonCode.currentSelectionUnhealthy, at: 0)
            }
        }

        if configuration.explorationEnabled, evaluations.count > 1, shouldExplore(context: context, best: best) {
            let nearBest = evaluations.filter { $0.score <= best.score + max(configuration.switchToleranceMilliseconds, 20) }
            if nearBest.count > 1 {
                let index = Int(mix(seed ^ UInt64(bitPattern: Int64(context.now.rounded())) ^ stableHash(context.destination ?? "")) % UInt64(nearBest.count))
                selected = nearBest[index]
                reasons.append(SmartPolicyReasonCode.explorationCandidate)
                keepCurrent = selected.tag == context.currentOutbound
            }
        }

        let evidence = selected.evidenceCount
        let contradiction = selected.destinationFailures > 0 && selected.destinationSuccesses > 0
        let networkWide = networkWideDegradation(candidates: eligible, at: context.now)
        if networkWide { reasons.append(SmartPolicyReasonCode.networkWideDegradation) }
        if selected.isStale { reasons.append(SmartPolicyReasonCode.staleEvidence) }
        let confidence: SmartPolicyConfidence
        if evidence == 0 { confidence = .low; reasons.append(SmartPolicyReasonCode.insufficientEvidence) }
        else if contradiction || networkWide || evidence < 3 { confidence = .medium }
        else { confidence = .high }
        return SmartPolicyDecision(recommendedOutbound: selected.tag, confidence: confidence, keepCurrentSelection: keepCurrent, reasonCodes: stableReasons(reasons))
    }

    private struct Evaluation: Sendable {
        let tag: String
        let score: Double
        let latency: Double
        let evidenceCount: Int
        let destinationSuccesses: Int
        let destinationFailures: Int
        let hardFailure: Bool
        let isStale: Bool
        let reasons: [SmartPolicyReasonCode]
    }

    private func evaluate(_ tag: String, destination: String?, at time: TimeInterval) -> Evaluation {
        let node = state.nodes[tag]
        let decayedPenalty = effectivePenalty(node, at: time)
        let latency = node?.lastLatencyMilliseconds ?? node?.observedLatencyAverageMilliseconds ?? 1_000
        var score = latency
        var reasons: [SmartPolicyReasonCode] = []
        let failures = node?.consecutiveFailures ?? 0
        score += decayedPenalty * 300 + Double(min(failures, 5)) * 35
        if failures > 0 { reasons.append(.recentFailures) }
        if failures >= 2 { reasons.append(.consecutiveFailures) }
        if node?.relativeDegradation == true { score += 120; reasons.append(.relativeDegradation) }
        let destinationObservation = destination.flatMap { state.destinations[$0]?.observations[tag] }
        let destinationSuccesses = destinationObservation?.successes ?? 0
        let destinationFailures = destinationObservation?.failures ?? 0
        let destinationIsStale = destinationObservation.map { $0.isStale(at: time, staleAfter: configuration.staleAfter) } ?? false
        if !destinationIsStale && destinationSuccesses >= 2 && destinationFailures == 0 { score -= 120; reasons.append(.destinationPreference) }
        if !destinationIsStale && destinationFailures > 0 { score += Double(Swift.min(destinationFailures, 4)) * 90; reasons.append(.destinationFailure) }
        let stale = node?.lastSuccessAt.map { time - $0 > configuration.staleAfter } ?? true
        if stale || destinationIsStale { score += 25 }
        if node?.recoveryEvidence ?? 0 > 0 && decayedPenalty < 0.5 { reasons.append(.recoveryEvidence) }
        if node != nil && decayedPenalty < (node?.penalty ?? 0) { reasons.append(.penaltyDecay) }
        return Evaluation(tag: tag, score: finite(score), latency: finite(latency), evidenceCount: (node?.successCount ?? 0) + (node?.failureCount ?? 0), destinationSuccesses: destinationSuccesses, destinationFailures: destinationFailures, hardFailure: isHardIneligible(tag, at: time), isStale: stale || destinationIsStale, reasons: reasons)
    }

    private func isHardIneligible(_ tag: String, at time: TimeInterval) -> Bool {
        guard let node = state.nodes[tag], let failureAt = node.lastFailureAt else { return false }
        let penalty = effectivePenalty(node, at: time)
        return penalty >= configuration.hardFailurePenalty && time - failureAt <= configuration.staleAfter
    }

    private func networkWideDegradation(candidates: [SmartPolicyCandidate], at time: TimeInterval) -> Bool {
        let failures = candidates.compactMap { state.nodes[$0.tag]?.lastFailureAt }.filter { time - $0 <= configuration.failureWindow }.count
        return candidates.count >= 3 && failures * 100 >= candidates.count * 60
    }

    private func shouldExplore(context: SmartPolicyContext, best: Evaluation) -> Bool {
        guard best.evidenceCount > 0 else { return false }
        let value = mix(seed ^ stableHash(best.tag) ^ UInt64(bitPattern: Int64(context.now.rounded())))
        return value % 100 < configuration.explorationRate
    }

    private mutating func updateDestination(_ destination: String, tag: String, success: Bool, at: TimeInterval) {
        guard validTag(destination), validTag(tag) else { return }
        var stateForDestination = state.destinations[destination] ?? SmartDestinationState(destination: destination)
        var observation = stateForDestination.observations[tag] ?? SmartDestinationObservation()
        if success { observation.successes = min(observation.successes + 1, 10_000) }
        else { observation.failures = min(observation.failures + 1, 10_000) }
        observation.lastEventAt = at
        stateForDestination.observations[tag] = observation
        stateForDestination.lastEventAt = at
        state.destinations[destination] = stateForDestination
    }

    private mutating func nodeState(for tag: String) -> SmartNodeState {
        state.nodes[tag] ?? SmartNodeState(tag: tag)
    }

    private func effectivePenalty(_ node: SmartNodeState?, at time: TimeInterval) -> Double {
        guard let node, let failureAt = node.lastFailureAt else { return node?.penalty ?? 0 }
        let elapsed = max(0, time - failureAt)
        let decay = exp(-elapsed / max(configuration.penaltyHalfLife, 1))
        return clamp((node.penalty * decay) - Double(node.recoveryEvidence) * 0.015, 0, 1)
    }

    private func decay(_ node: inout SmartNodeState, to time: TimeInterval) {
        node.penalty = effectivePenalty(node, at: time)
    }

    private mutating func trimState() {
        if state.nodes.count > configuration.maximumNodeStates {
            let excess = state.nodes.values.sorted { (a, b) in
                (a.lastSuccessAt ?? a.lastFailureAt ?? 0, a.tag) < (b.lastSuccessAt ?? b.lastFailureAt ?? 0, b.tag)
            }.prefix(state.nodes.count - configuration.maximumNodeStates)
            excess.forEach { state.nodes.removeValue(forKey: $0.tag) }
        }
        if state.destinations.count > configuration.maximumDestinationStates {
            let excess = state.destinations.values.sorted { ($0.lastEventAt, $0.destination) < ($1.lastEventAt, $1.destination) }.prefix(state.destinations.count - configuration.maximumDestinationStates)
            excess.forEach { state.destinations.removeValue(forKey: $0.destination) }
        }
        for key in state.destinations.keys {
            if state.destinations[key]!.observations.count > configuration.maximumDestinationObservations {
                let observations = state.destinations[key]!.observations.sorted { ($0.value.lastEventAt, $0.key) < ($1.value.lastEventAt, $1.key) }
                for (tag, _) in observations.prefix(state.destinations[key]!.observations.count - configuration.maximumDestinationObservations) { state.destinations[key]!.observations.removeValue(forKey: tag) }
            }
        }
    }

    private func uniqueCandidates(_ candidates: [SmartPolicyCandidate]) -> [SmartPolicyCandidate] {
        var seen = Set<String>()
        return candidates.filter { validTag($0.tag) && seen.insert($0.tag).inserted }
    }

    private func stableReasons(_ reasons: [SmartPolicyReasonCode]) -> [SmartPolicyReasonCode] {
        var seen = Set<SmartPolicyReasonCode>()
        return reasons.filter { seen.insert($0).inserted }.sorted { $0.rawValue < $1.rawValue }
    }

    private func validTag(_ tag: String) -> Bool { !tag.isEmpty && tag.utf8.count <= 256 }
    private func finite(_ value: Double) -> Double { value.isFinite ? max(0, min(value, 65_535)) : 65_535 }
    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(max(value.isFinite ? value : upper, lower), upper) }
    private func stableHash(_ string: String) -> UInt64 { string.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    private func mix(_ value: UInt64) -> UInt64 { var x = value; x ^= x >> 30; x &*= 0xbf58476d1ce4e5b9; x ^= x >> 27; x &*= 0x94d049bb133111eb; return x ^ (x >> 31) }
}

private extension SmartPolicyEvent {
    var timestamp: TimeInterval {
        switch self {
        case let .probeSuccess(_, _, at), let .probeFailure(_, at), let .connectionSuccess(_, at), let .connectionFailure(_, at), let .destinationSuccess(_, _, at), let .destinationFailure(_, _, at), let .networkEpochChanged(at), let .candidateRemoved(_, at): return at
        case let .timeAdvanced(to): return to
        }
    }
}
