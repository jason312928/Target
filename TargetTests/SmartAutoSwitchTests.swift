import Foundation
import XCTest
import TargetCore
@testable import Target

@MainActor
final class SmartAutoSwitchTests: XCTestCase, ProfileTestCaseSupport {
    private func makeRig(transform: (@Sendable (SmartShadowRecommendation) -> SmartShadowRecommendation)? = nil) throws -> AutoRig {
        let store = try makeStore()
        let profile = try store.create(name: "Synthetic Auto")
        try store.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: profile.id)
        let clock = AutoTestClock()
        let sleeper = AutoTestSleeper(clock: clock)
        let runtime = AutoTestRuntime(clock: clock)
        let policy = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: runtime)
        let shadow = SmartPolicyShadowOperations(catalogReader: PolicyCatalogOperation(profileStore: store), runtime: runtime, clock: { clock.date })
        let evaluator: any SmartPolicyEvaluating = transform.map { AutoTransformEvaluator(base: shadow, transform: $0) } ?? shadow
        let apply = SmartPolicyApplyOperations(evaluator: evaluator, policy: policy, clock: { clock.date })
        let auto = SmartAutoSwitchCoordinator(policy: policy, runtime: runtime, apply: apply,
            uptime: { clock.uptime }, date: { clock.date }, sleep: { try await sleeper.sleep($0) })
        return .init(store: store, runtime: runtime, policy: policy, apply: apply, auto: auto, clock: clock, sleeper: sleeper)
    }

    func testDefaultOffExplicitOnOffAndNewProcessDoesNotRestore() async throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.auto.status, SmartAutoStatus())
        let initialCalls = await rig.runtime.collectionCount
        XCTAssertEqual(initialCalls, 0)
        await rig.auto.on()
        await rig.sleeper.waitForRequests(1)
        XCTAssertTrue(rig.auto.status.enabled)
        XCTAssertEqual(rig.auto.status.lastResult, "applied")
        let off = await rig.auto.off()
        XCTAssertEqual(off.state, .off)
        XCTAssertFalse(off.enabled)
        let replacement = SmartAutoSwitchCoordinator(policy: rig.policy, runtime: rig.runtime, apply: rig.apply)
        XCTAssertEqual(replacement.status, SmartAutoStatus())
        await rig.sleeper.advance(10_000)
        let writes = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes, 1)
    }

    func testStoppedUntrustedAndMissingProfileNeverEnableOrMutate() async throws {
        for unavailable in ["engineStopped", "ownershipUnavailable", "identityMismatch"] {
            let rig = try makeRig()
            await rig.runtime.setUnavailable(unavailable)
            let status = await rig.auto.on()
            XCTAssertEqual(status.state, .off, unavailable)
            let calls = await rig.runtime.collectionCount
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(writes, 0)
        }
        let rig = try makeRig()
        try rig.store.select(nil)
        let missing = await rig.auto.on()
        XCTAssertEqual(missing.state, .off)
    }

    func testQualityRefusalsKeepSelectionAndWait300Seconds() async throws {
        for reason in ["lowConfidence", "ambiguousEvidence", "staleEvidence"] {
            let rig = try makeRig { value in
                var copy = value
                if reason == "lowConfidence" {
                    copy = .init(state: value.state, observedAt: value.observedAt, selector: value.selector,
                        currentOutbound: value.currentOutbound, recommendedOutbound: value.recommendedOutbound,
                        confidence: .low, keepCurrent: false, reasonCodes: [], candidateCount: 2,
                        connectionSnapshotAvailable: true, selectionEvidence: value.selectionEvidence)
                } else if reason == "ambiguousEvidence" { copy.ambiguousProbeCount = 1 }
                else {
                    copy = .init(state: value.state, observedAt: value.observedAt, selector: value.selector,
                        currentOutbound: value.currentOutbound, recommendedOutbound: value.recommendedOutbound,
                        confidence: .high, keepCurrent: false, reasonCodes: ["staleEvidence"], candidateCount: 2,
                        connectionSnapshotAvailable: true, selectionEvidence: value.selectionEvidence)
                }
                return copy
            }
            await rig.auto.on()
            await rig.sleeper.waitForRequests(1)
            XCTAssertEqual(rig.auto.status.state, .waiting)
            XCTAssertEqual(rig.auto.status.lastResult, reason)
            let interval = await rig.sleeper.requests
            XCTAssertEqual(interval, [300])
            await rig.sleeper.advance(299)
            let before = await rig.runtime.collectionCount
            XCTAssertEqual(before, 1)
            await rig.sleeper.advance(1)
            await rig.sleeper.waitForRequests(2)
            let after = await rig.runtime.collectionCount
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(after, 2)
            XCTAssertEqual(writes, 0)
            await rig.auto.off()
        }
    }

    func testIncompleteConnectionObservationStopsAuto() async throws {
        for truncated in [false, true] {
            let rig = try makeRig { value in
                var copy = value
                copy.connectionSnapshotAvailable = truncated
                copy.connectionSnapshotTruncated = truncated
                return copy
            }
            await rig.auto.on()
            await settle { rig.auto.status.state == .off }
            XCTAssertEqual(rig.auto.status.lastResult, "runtimeUnavailable")
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(writes, 0)
        }
    }

    func testImmediateGUIOnThenOffOrManualIntentCancelsQueuedStart() async throws {
        for manual in [false, true] {
            let rig = try makeRig()
            let model = ProfileViewModel(store: rig.store, policyOperations: rig.policy, smartAuto: rig.auto)
            model.setSmartAutoEnabled(true)
            XCTAssertEqual(rig.auto.status.state, .starting)
            if manual { model.selectPolicy(selectorTag: "group", outboundTag: "a") }
            else { model.setSmartAutoEnabled(false) }
            XCTAssertEqual(rig.auto.status.state, .stopping)
            await settle { rig.auto.status.state == .off && !model.isSelectingPolicy }
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(writes, 0)
        }
    }

    func testEngineExitWhileWaitingDisablesWithoutRestartOrWrites() async throws {
        let rig = try makeRig()
        await rig.runtime.keepCurrentInitially()
        await rig.auto.on()
        await rig.sleeper.waitForRequests(1)
        await rig.runtime.setUnavailable("engineStopped")
        await rig.sleeper.advance(300)
        await settle { rig.auto.status.state == .off }
        XCTAssertEqual(rig.auto.status.lastResult, "engineStopped")
        let writes = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes, 0)
        await rig.runtime.replaceSession()
        await rig.sleeper.advance(10_000)
        XCTAssertEqual(rig.auto.status.state, .off)
    }

    func testSingleSwitch300SecondEvaluationAnd900SecondCooldownCannotBeBypassed() async throws {
        let rig = try makeRig()
        await rig.auto.on()
        await rig.sleeper.waitForRequests(1)
        await rig.sleeper.advance(299)
        let before = await rig.runtime.collectionCount
        XCTAssertEqual(before, 1)
        await rig.sleeper.advance(1)
        await rig.sleeper.waitForRequests(2)
        let after300 = await rig.runtime.collectionCount
        let writes300 = await rig.runtime.conditionalWrites
        XCTAssertEqual(after300, 2)
        XCTAssertEqual(writes300, 1, "The good current node must not be selected again")
        XCTAssertEqual(rig.auto.status.lastResult, "keepCurrent")
        await rig.runtime.reverseLatencies()
        await rig.sleeper.advance(300)
        await rig.sleeper.waitForRequests(3)
        XCTAssertEqual(rig.auto.status.lastResult, "cooldown")
        await rig.auto.off()
        await rig.auto.on()
        await rig.sleeper.waitForRequests(4)
        let writes600 = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes600, 1, "OFF/ON must retain the process cooldown")
        XCTAssertEqual(rig.auto.status.lastResult, "cooldown")
        await rig.sleeper.advance(299)
        let writes899 = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes899, 1)
        await rig.sleeper.advance(1)
        await rig.sleeper.waitForRequests(5)
        let writes900 = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes900, 2)
        XCTAssertEqual(rig.auto.status.lastResult, "applied")
        let intervals = await rig.sleeper.requests
        XCTAssertEqual(intervals, [300, 300, 300, 300, 300])
        await rig.auto.off()
    }

    func testSingleFlightCancelBeforeDispatchAndOffConfirmationHasNoLaterMutation() async throws {
        let rig = try makeRig()
        let gate = AutoTestGate()
        await rig.runtime.gateCollection(gate)
        await rig.auto.on()
        await gate.waitUntilEntered()
        await rig.auto.on()
        let collections = await rig.runtime.collectionCount
        XCTAssertEqual(collections, 1)
        rig.auto.requestStop()
        let off = Task { await rig.auto.off() }
        XCTAssertEqual(rig.auto.status.state, .stopping)
        let reenable = await rig.auto.on()
        XCTAssertEqual(reenable.state, .stopping)
        await gate.release()
        let confirmed = await off.value
        XCTAssertEqual(confirmed.state, .off)
        let writes = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes, 0)
        await rig.sleeper.advance(10_000)
        let after = await rig.runtime.conditionalWrites
        XCTAssertEqual(after, 0)
    }

    func testOffDrainsDispatchedWriteAndRetainsAcknowledgedSuccess() async throws {
        let rig = try makeRig()
        let gate = AutoTestGate()
        await rig.runtime.gateAfterDispatch(gate)
        await rig.auto.on()
        await gate.waitUntilEntered()
        rig.auto.requestStop()
        let firstOff = Task { await rig.auto.off() }
        let secondOff = Task { await rig.auto.off() }
        XCTAssertEqual(rig.auto.status.state, .stopping)
        await gate.release()
        let first = await firstOff.value
        let second = await secondOff.value
        XCTAssertEqual(first.state, .off)
        XCTAssertEqual(second.state, .off)
        XCTAssertEqual(first.lastResult, "applied")
        XCTAssertNotNil(first.lastSwitchAt)
        await rig.sleeper.advance(10_000)
        let writes = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes, 1)
    }

    func testGUIManualSelectionDrainsAutoAndWins() async throws {
        let rig = try makeRig()
        let model = ProfileViewModel(store: rig.store, policyOperations: rig.policy, smartAuto: rig.auto)
        let gate = AutoTestGate()
        await rig.runtime.gateAfterDispatch(gate)
        await rig.auto.on()
        await gate.waitUntilEntered()
        model.selectPolicy(selectorTag: "group", outboundTag: "a")
        XCTAssertEqual(rig.auto.status.state, .stopping)
        await gate.release()
        await settle { !model.isSelectingPolicy && rig.auto.status.state == .off }
        XCTAssertEqual(try rig.policy.readPersisted().selectors.first?.effectiveDesired, "a")
        let current = await rig.runtime.current
        XCTAssertEqual(current, "a")
        await rig.sleeper.advance(10_000)
        let writes = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes, 1)
    }

    func testProfileSelectorAndGenerationChangesInvalidateAcrossTicks() async throws {
        for change in ["profile", "selector", "generation"] {
            let rig = try makeRig { value in
                .init(state: value.state, observedAt: value.observedAt, selector: value.selector,
                      currentOutbound: value.currentOutbound, recommendedOutbound: value.currentOutbound,
                      confidence: .high, keepCurrent: true, reasonCodes: [], candidateCount: 2,
                      connectionSnapshotAvailable: true, selectionEvidence: value.selectionEvidence)
            }
            await rig.auto.on()
            await rig.sleeper.waitForRequests(1)
            if change == "profile" { try rig.store.select(nil) }
            if change == "selector" {
                let id = try XCTUnwrap(rig.store.selectedProfileID())
                try rig.store.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "c"]), for: id)
            }
            if change == "generation" { _ = try await rig.policy.select(selectorTag: "group", outboundTag: "a") }
            await rig.sleeper.advance(300)
            await settle { rig.auto.status.state == .off }
            let calls = await rig.runtime.collectionCount
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(calls, 1, change)
            XCTAssertEqual(writes, 0, change)
        }
    }

    func testGenerationRaceAtSharedCommitDoesNotWrite() async throws {
        let rig = try makeRig()
        let gate = AutoTestGate()
        await rig.runtime.gateBeforeAuthorization(gate)
        await rig.auto.on()
        await gate.waitUntilEntered()
        _ = try await rig.policy.select(selectorTag: "group", outboundTag: "a")
        await gate.release()
        await settle { rig.auto.status.state == .off }
        let writes = await rig.runtime.conditionalWrites
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(rig.auto.status.lastResult, "selectionChanged")
    }

    func testRuntimeExitAndRebuildNeverAdoptNewSession() async throws {
        for changeDuringEvaluation in [false, true] {
            let rig = try makeRig()
            let gate = AutoTestGate()
            if changeDuringEvaluation { await rig.runtime.gateCollection(gate) }
            else { await rig.runtime.keepCurrentInitially() }
            await rig.auto.on()
            if changeDuringEvaluation {
                await gate.waitUntilEntered()
                await rig.runtime.replaceSession()
                await gate.release()
            } else {
                await rig.sleeper.waitForRequests(1)
                await rig.runtime.replaceSession()
                await rig.sleeper.advance(300)
            }
            await settle { rig.auto.status.state == .off }
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(writes, 0)
            await rig.sleeper.advance(10_000)
            XCTAssertFalse(rig.auto.status.enabled)
        }
    }

    func testUnconfirmedWriteStopsWithoutRetry() async throws {
        let rig = try makeRig()
        await rig.runtime.setUnconfirmed()
        await rig.auto.on()
        await settle { rig.auto.status.state == .off }
        XCTAssertEqual(rig.auto.status.lastResult, "mutationUnconfirmed")
        let calls = await rig.runtime.conditionalWrites
        XCTAssertEqual(calls, 1)
        await rig.sleeper.advance(10_000)
        let after = await rig.runtime.conditionalWrites
        XCTAssertEqual(after, 1)
    }

    func testGUIAndCLIShareStateAndBoundedOutput() async throws {
        let rig = try makeRig()
        let model = ProfileViewModel(store: rig.store, policyOperations: rig.policy, smartAuto: rig.auto)
        let automation = TargetAutomationOperations(profileStore: rig.store, policyOperations: rig.policy,
            backend: MockBackend(), smartAuto: rig.auto)
        for action in ["on", "off", "status"] {
            XCTAssertEqual(try TargetCtlCommandParser.parse(["smart", "auto", action, "--json"]).action, "smart.auto.\(action)")
            XCTAssertThrowsError(try TargetCtlCommandParser.parse(["smart", "auto", action]))
            let invalid = await automation.handle(.init(protocolVersion: 1, action: "smart.auto.\(action)", arguments: ["selector": "group"]))
            XCTAssertFalse(invalid.ok)
        }
        model.setSmartAutoEnabled(true)
        await rig.sleeper.waitForRequests(1)
        let response = await automation.handle(.init(protocolVersion: 1, action: "smart.auto.status"))
        XCTAssertEqual(response.result, rig.auto.status.automationJSON())
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertLessThan(encoded.utf8.count, 1024)
        for forbidden in ["sessionID", "profileID", "sourceFingerprint", "endpoint", "secret", "subscription", "connectionID", "127.0.0.1"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
        let off = await automation.handle(.init(protocolVersion: 1, action: "smart.auto.off"))
        XCTAssertTrue(off.ok)
        XCTAssertEqual(model.smartAuto?.status.state, .off)
        let on = await automation.handle(.init(protocolVersion: 1, action: "smart.auto.on"))
        XCTAssertTrue(on.ok)
        XCTAssertTrue(model.smartAuto?.status.enabled == true)
        model.setSmartAutoEnabled(false)
        await settle { rig.auto.status.state == .off }
    }

    func testAutoCommandsRoundTripThroughAuthenticatedLocalSocket() async throws {
        let rig = try makeRig()
        let operations = TargetAutomationOperations(profileStore: rig.store, policyOperations: rig.policy,
            backend: MockBackend(), smartAuto: rig.auto)
        let root = URL(fileURLWithPath: "/tmp/AutoSocket-\(UUID().uuidString)")
        let socket = root.appending(path: "Target/Automation/control.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalAutomationServer(socketURL: socket) { await operations.handle($0) }
        try server.start()
        defer { server.stop() }
        for action in ["status", "on", "status", "off", "status"] {
            let parsed = try TargetCtlCommandParser.parse(["smart", "auto", action, "--json"])
            let request = AutomationRequest(protocolVersion: 1, action: parsed.action, arguments: parsed.arguments)
            let data = try await Task.detached { try LocalAutomationClient.send(request, socketURL: socket) }.value
            let response = try JSONDecoder().decode(AutomationResponse.self, from: data)
            XCTAssertTrue(response.ok)
            if action == "off" { XCTAssertEqual(rig.auto.status.state, .off) }
        }
        XCTAssertFalse(rig.auto.status.enabled)
    }

    func testCLIManualSelectionAndProfileChangeStopAuto() async throws {
        for action in ["policy.select", "profile.select"] {
            let rig = try makeRig()
            let automation = TargetAutomationOperations(profileStore: rig.store, policyOperations: rig.policy,
                backend: MockBackend(), smartAuto: rig.auto)
            await rig.auto.on()
            await rig.sleeper.waitForRequests(1)
            let arguments = action == "policy.select" ? ["selector": "group", "outbound": "a"] : ["id": "none"]
            let response = await automation.handle(.init(protocolVersion: 1, action: action, arguments: arguments))
            XCTAssertTrue(response.ok)
            XCTAssertEqual(rig.auto.status.state, .off)
            await rig.sleeper.advance(10_000)
            let writes = await rig.runtime.conditionalWrites
            XCTAssertEqual(writes, 1)
        }
    }

    private func settle(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

@MainActor
private struct AutoRig {
    let store: ProfileStore
    let runtime: AutoTestRuntime
    let policy: TargetPolicyOperations
    let apply: SmartPolicyApplyOperations
    let auto: SmartAutoSwitchCoordinator
    let clock: AutoTestClock
    let sleeper: AutoTestSleeper
}

private actor AutoTransformEvaluator: SmartPolicyEvaluating {
    let base: SmartPolicyShadowOperations
    let transform: @Sendable (SmartShadowRecommendation) -> SmartShadowRecommendation
    init(base: SmartPolicyShadowOperations, transform: @escaping @Sendable (SmartShadowRecommendation) -> SmartShadowRecommendation) {
        self.base = base; self.transform = transform
    }
    func evaluate() async throws -> SmartShadowRecommendation { transform(try await base.evaluate()) }
}

private final class AutoTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var uptime: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    var date: Date { Date(timeIntervalSince1970: 1_800_000_000 + uptime) }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

private actor AutoTestSleeper {
    let clock: AutoTestClock
    private var pending: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [TimeInterval] = []
    init(clock: AutoTestClock) { self.clock = clock }
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = (clock.uptime + seconds, continuation)
                requests.append(seconds)
                let ready = waiters.filter { $0.0 <= requests.count }
                waiters.removeAll { $0.0 <= requests.count }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func advance(_ seconds: TimeInterval) {
        clock.advance(seconds)
        let due = pending.filter { $0.value.0 <= clock.uptime }
        for (id, value) in due { pending.removeValue(forKey: id); value.1.resume() }
    }
}

private actor AutoTestGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor AutoTestRuntime: SmartAutoRuntimeReading, SmartShadowRuntimeReading, PolicyRuntimeEvidenceProviding, RuntimePolicyApplying {
    let clock: AutoTestClock
    var session = UUID()
    private(set) var current = "a"
    private(set) var collectionCount = 0
    private(set) var conditionalWrites = 0
    private var unavailable: String?
    private var initialKeep = false
    private var unconfirmed = false
    private var reversed = false
    private var collectionGate: AutoTestGate?
    private var dispatchGate: AutoTestGate?
    private var authorizationGate: AutoTestGate?
    init(clock: AutoTestClock) { self.clock = clock }
    func setUnavailable(_ reason: String) { unavailable = reason }
    func keepCurrentInitially() { initialKeep = true }
    func replaceSession() { session = UUID(); unavailable = nil }
    func setUnconfirmed() { unconfirmed = true }
    func reverseLatencies() { reversed = true }
    func gateCollection(_ gate: AutoTestGate) { collectionGate = gate }
    func gateAfterDispatch(_ gate: AutoTestGate) { dispatchGate = gate }
    func gateBeforeAuthorization(_ gate: AutoTestGate) { authorizationGate = gate }
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .stopped }
    func autoSelectionEvidence(catalog: PolicyCatalog) async throws -> PolicySelectionEvidence {
        if unavailable != nil { throw SmartAutoUnavailable.runtimeUnavailable }
        return .init(catalog: catalog, sessionID: session, selector: "group", currentOutbound: current, observedAt: clock.date)
    }
    func collectShadowEvidence(expectedRuntime: ExpectedPolicyRuntimeIdentity, selector: String, candidates: [String]) async throws -> SmartShadowRuntimeResult {
        collectionCount += 1
        if let unavailable { return unavailable == "engineStopped" ? .stopped : .unavailable(unavailable) }
        let value = SmartShadowRuntimeEvidence(sessionID: session, currentOutbound: current,
            probes: .results(candidates.map { .reachable(tag: $0, latencyMilliseconds: initialKeep ? 100 : (($0 == "a") != reversed ? 300 : 30), observedAt: clock.date)! }),
            connections: .init(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: 0), connections: []))
        if let collectionGate { self.collectionGate = nil; await collectionGate.wait() }
        return .available(value)
    }
    func applyLivePolicySelection(expectedRuntime: ExpectedPolicyRuntimeIdentity, selectorTag: String, outboundTag: String) async -> Bool {
        current = outboundTag
        return true
    }
    func applyLivePolicySelectionIfUnchanged(evidence: PolicySelectionEvidence, outboundTag: String,
                                            authorize: @escaping @Sendable () throws -> Void) async throws -> PolicySelectionApplyResult {
        if let authorizationGate { self.authorizationGate = nil; await authorizationGate.wait() }
        try Task.checkCancellation()
        guard session == evidence.sessionID else { return .refused(.identityChanged) }
        guard current == evidence.currentOutbound else { return .refused(.liveSelectionChanged) }
        do { try authorize() }
        catch PolicySelectionApplyRefusal.selectionChanged { return .refused(.selectionChanged) }
        catch PolicySelectionApplyRefusal.profileChanged { return .refused(.profileChanged) }
        conditionalWrites += 1
        current = outboundTag
        if let dispatchGate { self.dispatchGate = nil; await dispatchGate.wait() }
        if unconfirmed { return .refused(.mutationUnconfirmed) }
        let record = EngineRuntimeRecord(pid: 1, executablePath: "/synthetic/engine", executableFingerprint: "synthetic",
            endpoint: .init(port: 51234), profileID: evidence.catalog.profileID!, profileRevision: evidence.catalog.profileRevision!,
            sourceConfigurationFingerprint: evidence.catalog.sourceFingerprint!, configurationFingerprint: "synthetic",
            startedAt: clock.date, runtimeConfigurationID: session)
        return .init(applied: true, after: outboundTag, reason: .applied, runtimeIdentity: record)
    }
}
