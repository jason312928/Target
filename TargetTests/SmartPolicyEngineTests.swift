import XCTest
@testable import Target

final class SmartPolicyEngineTests: XCTestCase {
    private let nodes = (1...3).map { SmartPolicyCandidate(tag: "node-\(String(format: "%02d", $0))") }

    func testEmptyAndUnknownEvidenceAreSafe() {
        var engine = SmartPolicyEngine(configuration: .default, seed: 1)
        XCTAssertNil(engine.decision(for: .init(candidates: [], now: 0)).recommendedOutbound)
        let decision = engine.decision(for: .init(candidates: nodes, now: 0))
        XCTAssertEqual(decision.confidence, .low)
        XCTAssertTrue(decision.reasonCodes.contains(.insufficientEvidence))
    }

    func testPenaltyEscalatesDecaysAndRecoversWithoutBlacklist() {
        var engine = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: 40, at: 1))
        engine.apply(.probeFailure(tag: "node-01", at: 2))
        let first = engine.state.nodes["node-01"]!.penalty
        engine.apply(.probeFailure(tag: "node-01", at: 3))
        XCTAssertGreaterThan(engine.state.nodes["node-01"]!.penalty, first)
        engine.apply(.timeAdvanced(to: 3_600))
        engine.apply(.connectionSuccess(tag: "node-01", at: 3_601))
        XCTAssertLessThan(engine.state.nodes["node-01"]!.penalty, first)
        XCTAssertTrue(engine.state.nodes["node-01"]!.penalty >= 0)
    }

    func testRelativeDegradationAndHysteresis() {
        var engine = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        for (index, latency) in [40.0, 42, 39, 41].enumerated() { engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: latency, at: TimeInterval(index + 1))) }
        engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: 105, at: 5))
        engine.apply(.probeSuccess(tag: "node-02", latencyMilliseconds: 190, at: 1))
        engine.apply(.probeSuccess(tag: "node-02", latencyMilliseconds: 200, at: 2))
        let degraded = engine.decision(for: .init(candidates: nodes, currentOutbound: "node-01", now: 5))
        XCTAssertTrue(degraded.reasonCodes.contains(.relativeDegradation))

        var stable = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        stable.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: 82, at: 1))
        stable.apply(.probeSuccess(tag: "node-02", latencyMilliseconds: 80, at: 1))
        let held = stable.decision(for: .init(candidates: Array(nodes.prefix(2)), currentOutbound: "node-01", now: 1))
        XCTAssertEqual(held.recommendedOutbound, "node-01")
        XCTAssertTrue(held.keepCurrentSelection)
    }

    func testDestinationEvidenceIsIsolatedAndPreferred() {
        var engine = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: 50, at: 0))
        engine.apply(.probeSuccess(tag: "node-02", latencyMilliseconds: 50, at: 0))
        for time in 1...3 {
            engine.apply(.destinationFailure(destination: "alpha.example", tag: "node-01", at: TimeInterval(time)))
            engine.apply(.destinationSuccess(destination: "alpha.example", tag: "node-02", at: TimeInterval(time)))
        }
        let alpha = engine.decision(for: .init(candidates: Array(nodes.prefix(2)), destination: "alpha.example", now: 3))
        XCTAssertEqual(engine.state.destinations["alpha.example"]?.observations["node-02"]?.successes, 3)
        XCTAssertEqual(engine.state.destinations["alpha.example"]?.observations["node-01"]?.failures, 3)
        XCTAssertEqual(alpha.recommendedOutbound, "node-02")
        XCTAssertTrue(alpha.reasonCodes.contains(.destinationPreference))
        XCTAssertEqual(engine.state.nodes["node-01"]?.failureCount, 0)
        let beta = engine.decision(for: .init(candidates: Array(nodes.prefix(2)), destination: "beta.example", now: 3))
        XCTAssertEqual(beta.recommendedOutbound, "node-01")
        XCTAssertEqual(engine.state.destinations["beta.example"], nil)
        XCTAssertNotNil(engine.state.destinations["alpha.example"])
    }

    func testNetworkEpochReducesAuthorityAndSimultaneousFailuresAreAmbiguous() {
        var engine = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        for node in nodes { engine.apply(.probeSuccess(tag: node.tag, latencyMilliseconds: 50, at: 1)) }
        for node in nodes { engine.apply(.probeFailure(tag: node.tag, at: 2)) }
        let decision = engine.decision(for: .init(candidates: nodes, now: 2))
        XCTAssertTrue(decision.reasonCodes.contains(.networkWideDegradation))
        engine.apply(.networkEpochChanged(at: 3))
        XCTAssertEqual(engine.state.networkEpoch.identifier, 1)
        XCTAssertEqual(engine.state.networkEpoch.startedAt, 3)
        XCTAssertTrue(engine.state.nodes.values.allSatisfy { $0.latencyHistory.isEmpty })
    }

    func testRelativeDegradationUsesPriorBaselineInsteadOfLatestAverage() {
        var engine = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        for (index, latency) in [40.0, 41, 39, 40, 120].enumerated() {
            engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: latency, at: TimeInterval(index + 1)))
        }
        engine.apply(.probeSuccess(tag: "node-02", latencyMilliseconds: 210, at: 5))

        let decision = engine.decision(for: .init(candidates: Array(nodes.prefix(2)), now: 5))
        XCTAssertTrue(engine.state.nodes["node-01"]!.relativeDegradation)
        XCTAssertEqual(decision.recommendedOutbound, "node-02")
        XCTAssertTrue(decision.reasonCodes.contains(.relativeDegradation))
    }

    func testDestinationFailureDoesNotEraseGlobalEligibilityAndBetaRemainsIndependent() {
        var engine = SmartPolicyEngine(configuration: .init(explorationEnabled: false), seed: 0)
        for tag in ["node-01", "node-02"] {
            engine.apply(.probeSuccess(tag: tag, latencyMilliseconds: 50, at: 1))
        }
        for time in 2...4 {
            engine.apply(.destinationFailure(destination: "alpha.example", tag: "node-01", at: TimeInterval(time)))
            engine.apply(.destinationSuccess(destination: "alpha.example", tag: "node-02", at: TimeInterval(time)))
        }

        XCTAssertEqual(engine.decision(for: .init(candidates: Array(nodes.prefix(2)), destination: "alpha.example", now: 4)).recommendedOutbound, "node-02")
        XCTAssertEqual(engine.decision(for: .init(candidates: Array(nodes.prefix(2)), destination: "beta.example", now: 4)).recommendedOutbound, "node-01")
        XCTAssertEqual(engine.state.nodes["node-01"]?.failureCount, 0)
    }

    func testIntermittentFailureRecoversAndPenaltyRemainsBounded() {
        var engine = SmartPolicyEngine(configuration: .init(penaltyHalfLife: 10, explorationEnabled: false), seed: 0)
        engine.apply(.probeFailure(tag: "node-01", at: 1))
        let singleFailurePenalty = engine.state.nodes["node-01"]!.penalty
        engine.apply(.connectionSuccess(tag: "node-01", at: 2))
        engine.apply(.probeFailure(tag: "node-01", at: 3))
        XCTAssertGreaterThan(engine.state.nodes["node-01"]!.penalty, 0)
        engine.apply(.timeAdvanced(to: 200))
        engine.apply(.connectionSuccess(tag: "node-01", at: 201))
        let recovered = engine.state.nodes["node-01"]!
        XCTAssertLessThan(recovered.penalty, singleFailurePenalty)
        XCTAssertEqual(recovered.consecutiveFailures, 0)
        XCTAssertTrue((0...1).contains(recovered.penalty))
    }

    func testReplayProducesExactStateAndDecision() {
        let events: [SmartPolicyEvent] = [
            .probeSuccess(tag: "node-01", latencyMilliseconds: 50, at: 1),
            .probeSuccess(tag: "node-02", latencyMilliseconds: 55, at: 2),
            .destinationFailure(destination: "alpha.example", tag: "node-01", at: 3),
            .connectionFailure(tag: "node-01", at: 4),
            .networkEpochChanged(at: 5),
            .probeSuccess(tag: "node-02", latencyMilliseconds: 60, at: 6)
        ]
        var replayed = SmartPolicyEngine(seed: 7)
        var applied = SmartPolicyEngine(seed: 7)
        replayed.replay(events)
        events.forEach { applied.apply($0) }
        let context = SmartPolicyContext(candidates: Array(nodes.prefix(2)), destination: "alpha.example", now: 6)
        XCTAssertEqual(replayed.state, applied.state)
        XCTAssertEqual(replayed.decision(for: context), applied.decision(for: context))
    }

    func testExplorationNeverSelectsHardFailedCandidate() {
        var engine = SmartPolicyEngine(configuration: .init(explorationRate: 100), seed: 42)
        engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: 50, at: 1))
        engine.apply(.probeSuccess(tag: "node-02", latencyMilliseconds: 51, at: 1))
        for time in 2...4 {
            engine.apply(.probeFailure(tag: "node-02", at: TimeInterval(time)))
        }
        let decision = engine.decision(for: .init(candidates: Array(nodes.prefix(2)), now: 4))
        XCTAssertEqual(decision.recommendedOutbound, "node-01")
        XCTAssertFalse(decision.reasonCodes.contains(.explorationCandidate))
    }

    func testExplorationIsSeededAndNeverUsesUnavailableCandidates() {
        var first = SmartPolicyEngine(seed: 42)
        var second = SmartPolicyEngine(seed: 42)
        for time in 1...20 {
            let event = SmartPolicyEvent.probeSuccess(tag: time.isMultiple(of: 2) ? "node-01" : "node-02", latencyMilliseconds: 40 + Double(time % 3), at: TimeInterval(time))
            first.apply(event); second.apply(event)
        }
        let context = SmartPolicyContext(candidates: [SmartPolicyCandidate(tag: "node-01"), SmartPolicyCandidate(tag: "node-02", available: false)], now: 20)
        XCTAssertEqual(first.decision(for: context), second.decision(for: context))
        XCTAssertNotEqual(first.decision(for: context).recommendedOutbound, "node-02")
    }

    func testBoundedStateAndExactReplayAcrossThirtyNineNodesAndSeeds() {
        let configuration = SmartPolicyConfiguration(maximumNodeStates: 39, maximumDestinationStates: 4, maximumObservationsPerNode: 8, maximumDestinationObservations: 8, explorationEnabled: false)
        let candidates = (1...39).map { SmartPolicyCandidate(tag: "node-\(String(format: "%02d", $0))") }
        for seed in [0, 1, 7, 42, UInt64.max] {
            var first = SmartPolicyEngine(configuration: configuration, seed: seed)
            var second = SmartPolicyEngine(configuration: configuration, seed: seed)
            for index in 0..<500 {
                let tag = candidates[index % candidates.count].tag
                let event: SmartPolicyEvent = index.isMultiple(of: 5)
                    ? .probeFailure(tag: tag, at: TimeInterval(index))
                    : .probeSuccess(tag: tag, latencyMilliseconds: Double(20 + index % 200), at: TimeInterval(index))
                first.apply(event); second.apply(event)
                if index.isMultiple(of: 7) { first.apply(.destinationSuccess(destination: "alpha.example", tag: tag, at: TimeInterval(index))); second.apply(.destinationSuccess(destination: "alpha.example", tag: tag, at: TimeInterval(index))) }
            }
            XCTAssertEqual(first.state, second.state)
            XCTAssertEqual(first.decision(for: .init(candidates: candidates, destination: "alpha.example", now: 499)), second.decision(for: .init(candidates: candidates, destination: "alpha.example", now: 499)))
            XCTAssertLessThanOrEqual(first.state.nodes.count, 39)
            XCTAssertLessThanOrEqual(first.state.destinations.count, 4)
            XCTAssertTrue(first.state.isFinite)
            XCTAssertTrue(first.state.nodes.values.allSatisfy { $0.penalty >= 0 && $0.penalty <= 1 && $0.latencyHistory.count <= 8 })
        }
    }

    func testNonMonotonicEventsAreIgnoredWithoutInvalidState() {
        var engine = SmartPolicyEngine()
        engine.apply(.probeSuccess(tag: "node-01", latencyMilliseconds: 50, at: 10))
        let before = engine.state
        engine.apply(.probeFailure(tag: "node-01", at: 9))
        XCTAssertEqual(engine.state, before)
        XCTAssertTrue(engine.state.isFinite)
    }
}
