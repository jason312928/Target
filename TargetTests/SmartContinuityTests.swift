import Foundation
import XCTest
import TargetCore
@testable import Target

final class SmartContinuityTests: XCTestCase, ProfileTestCaseSupport {
    private let epoch = Date(timeIntervalSince1970: 1_000)
    private let identity = EngineRuntimeRecord(pid: 1, executablePath: "/synthetic/engine", executableFingerprint: "fixture",
        endpoint: .init(port: 51_234), profileID: UUID(), profileRevision: 1, sourceConfigurationFingerprint: "source",
        configurationFingerprint: "runtime", startedAt: Date(timeIntervalSince1970: 1), runtimeConfigurationID: UUID())

    private func flow(_ id: String = "private-id", upload: Int64? = 100, download: Int64? = 100,
                      network: String? = "tcp", start: Date? = Date(timeIntervalSince1970: 950), chain: [String] = ["private-outbound"]) -> RuntimeConnection {
        .init(id: id, destinationHost: "private.example.invalid", destinationIP: "203.0.113.77", destinationPort: 443,
              network: network, inbound: "private-inbound", outboundChain: chain,
              uploadBytes: upload, downloadBytes: download, startedAt: start)
    }
    private func evidence(_ flows: [RuntimeConnection], at offset: Double = 0, total: Int? = nil,
                          record: EngineRuntimeRecord? = nil) -> SmartContinuityEvidence {
        .init(identity: record ?? identity,
              snapshot: .init(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: total ?? flows.count), connections: flows),
              observedAt: epoch.addingTimeInterval(offset))
    }
    private func idleWindow(_ classifier: inout SmartContinuityClassifier, connection: RuntimeConnection? = nil) -> SmartContinuitySummary {
        var result = classifier.observe(evidence([connection ?? flow()]))
        for t in [10.0, 20, 30] { result = classifier.observe(evidence([connection ?? flow()], at: t)) }
        return result
    }

    func testBasicClassesAndPreserveSemantics() {
        var classifier = SmartContinuityClassifier()
        XCTAssertEqual(classifier.observe(evidence([flow()])).unknownCount, 1)
        XCTAssertEqual(idleWindow(&classifier).replaceableCount, 1)
        XCTAssertEqual(classifier.observe(evidence([flow(upload: 101)], at: 40)).protectCount, 1)
        XCTAssertTrue(SmartContinuityClassification.unknown.preservesConnection)
        XCTAssertTrue(SmartContinuityClassification.protect.preservesConnection)
        XCTAssertFalse(SmartContinuityClassification.replaceable.preservesConnection)
    }
    func testSustainedBidirectionalAndDownloadThresholds() {
        for bidirectional in [false, true] {
            var classifier = SmartContinuityClassifier()
            for i in 0...2 {
                let result = classifier.observe(evidence([flow(upload: bidirectional ? Int64(i) * SmartContinuityClassifier.sustainedBytes : 0,
                    download: Int64(i) * SmartContinuityClassifier.sustainedBytes)], at: Double(i) * 5))
                if i == 2 {
                    XCTAssertEqual(result.protectCount, 1)
                    XCTAssertTrue(result.reasonCodes.contains(bidirectional ? "sustainedBidirectional" : "sustainedDownload"))
                }
            }
        }
        var classifier = SmartContinuityClassifier()
        for i in 0...2 {
            let result = classifier.observe(evidence([flow(download: Int64(i) * (SmartContinuityClassifier.sustainedBytes - 1))], at: Double(i) * 5))
            if i == 2 { XCTAssertFalse(result.reasonCodes.contains("sustainedDownload")); XCTAssertEqual(result.protectCount, 1) }
        }
    }
    func testLongLivedLowBandwidthAndIdleRemainPreserved() {
        var classifier = SmartContinuityClassifier()
        let old = epoch.addingTimeInterval(-SmartContinuityClassifier.longLivedAge)
        XCTAssertEqual(idleWindow(&classifier, connection: flow(start: old)).unknownCount, 1)
        let active = classifier.observe(evidence([flow(upload: 101, start: old)], at: 40))
        XCTAssertEqual(active.protectCount, 1)
        XCTAssertEqual(active.replaceableCount, 0)
    }
    func testRecentUDPAndIdleUDP() {
        var classifier = SmartContinuityClassifier()
        XCTAssertEqual(idleWindow(&classifier, connection: flow(network: "udp")).unknownCount, 1)
        XCTAssertEqual(classifier.observe(evidence([flow(download: 101, network: "udp")], at: 40)).reasonCodes, ["recentUDP"])
        XCTAssertEqual(classifier.observe(evidence([flow(download: 101, network: "udp")], at: 50)).protectCount, 1)
    }
    func testIdleKeepAliveWindowAgeAndCounterBoundaries() {
        var classifier = SmartContinuityClassifier()
        for t in [0.0, 10, 20, 29] { XCTAssertEqual(classifier.observe(evidence([flow()], at: t)).replaceableCount, 0) }
        XCTAssertEqual(classifier.observe(evidence([flow()], at: 30)).replaceableCount, 1)
        var atLimit = SmartContinuityClassifier()
        XCTAssertEqual(idleWindow(&atLimit, connection: flow(upload: SmartContinuityClassifier.lowRiskTotalBytes, download: 0)).replaceableCount, 1)
        var overLimit = SmartContinuityClassifier()
        XCTAssertEqual(idleWindow(&overLimit, connection: flow(upload: SmartContinuityClassifier.lowRiskTotalBytes, download: 1)).unknownCount, 1)
        var ageLimit = SmartContinuityClassifier()
        XCTAssertEqual(idleWindow(&ageLimit, connection: flow(start: epoch.addingTimeInterval(-270))).unknownCount, 1)
    }
    func testJustCreatedEvenWhenActiveAndFutureStart() {
        var classifier = SmartContinuityClassifier()
        _ = classifier.observe(evidence([flow(start: epoch)]))
        XCTAssertEqual(classifier.observe(evidence([flow(download: 100_000, start: epoch)], at: 10)).reasonCodes, ["justCreated"])
        XCTAssertEqual(classifier.observe(evidence([flow(start: epoch.addingTimeInterval(100))], at: 20)).unknownCount, 1)
    }
    func testMissingOrInvalidFieldsDiscardWindow() {
        let missing = [flow(start: nil), flow(upload: nil), flow(download: nil), flow(upload: -1), flow(network: nil), flow(network: "other"), flow(chain: [])]
        for value in missing {
            var classifier = SmartContinuityClassifier()
            XCTAssertEqual(idleWindow(&classifier).replaceableCount, 1)
            XCTAssertEqual(classifier.observe(evidence([value], at: 40)).unknownCount, 1)
            XCTAssertEqual(classifier.retainedConnectionCount, 0)
            XCTAssertEqual(classifier.observe(evidence([flow()], at: 50)).unknownCount, 1)
        }
    }
    func testCounterResetDecreaseAndLargeCounters() {
        for value in [flow(upload: 0), flow(download: 99)] {
            var classifier = SmartContinuityClassifier()
            _ = idleWindow(&classifier)
            XCTAssertEqual(classifier.observe(evidence([value], at: 40)).reasonCodes, ["counterReset"])
            XCTAssertEqual(classifier.observe(evidence([value], at: 50)).unknownCount, 1)
        }
        var classifier = SmartContinuityClassifier()
        _ = classifier.observe(evidence([flow(upload: 0, download: 0)]))
        XCTAssertEqual(classifier.observe(evidence([flow(upload: Int64.max, download: Int64.max)], at: 10)).protectCount, 1)
    }
    func testDisappearReappearAndConnectionIdentityChanges() {
        var classifier = SmartContinuityClassifier()
        _ = idleWindow(&classifier)
        _ = classifier.observe(evidence([], at: 40))
        XCTAssertEqual(classifier.retainedConnectionCount, 0)
        XCTAssertEqual(classifier.observe(evidence([flow()], at: 50)).unknownCount, 1)
        for changed in [flow(chain: ["other"]), flow(start: epoch.addingTimeInterval(-100)), flow(network: "udp")] {
            var classifier = SmartContinuityClassifier()
            _ = idleWindow(&classifier)
            XCTAssertEqual(classifier.observe(evidence([changed], at: 40)).reasonCodes, ["connectionIdentityChanged"])
            XCTAssertEqual(classifier.observe(evidence([changed], at: 50)).unknownCount, 1)
        }
    }
    func testRuntimeSessionAndIdentityChangesClearAllWindows() {
        for field in ["session", "profile", "revision", "source", "config", "pid", "start"] {
            var classifier = SmartContinuityClassifier()
            _ = idleWindow(&classifier)
            let changed = EngineRuntimeRecord(pid: field == "pid" ? 2 : identity.pid, executablePath: identity.executablePath,
                executableFingerprint: identity.executableFingerprint, endpoint: identity.endpoint,
                profileID: field == "profile" ? UUID() : identity.profileID, profileRevision: field == "revision" ? 2 : 1,
                sourceConfigurationFingerprint: field == "source" ? "changed" : identity.sourceConfigurationFingerprint,
                configurationFingerprint: field == "config" ? "changed" : identity.configurationFingerprint,
                startedAt: field == "start" ? epoch : identity.startedAt,
                runtimeConfigurationID: field == "session" ? UUID() : identity.runtimeConfigurationID)
            let result = classifier.observe(evidence([flow()], at: 40, record: changed))
            XCTAssertEqual(result.unknownCount, 1, field)
            XCTAssertEqual(result.sampleCount, 1, field)
        }
    }
    func testTruncationPreservesUnobservedAndInvalidatesAbsentIDs() {
        var classifier = SmartContinuityClassifier()
        _ = idleWindow(&classifier)
        let partial = classifier.observe(evidence([flow()], at: 40, total: 2))
        XCTAssertEqual(partial.state, "partial"); XCTAssertTrue(partial.snapshotTruncated)
        XCTAssertEqual(partial.observedConnectionCount, 1); XCTAssertEqual(partial.unknownCount, 1)
        XCTAssertEqual(partial.replaceableCount, 0); XCTAssertTrue(partial.reasonCodes.contains("preserveUnobserved"))
        _ = classifier.observe(evidence([], at: 50, total: 2))
        XCTAssertEqual(classifier.observe(evidence([flow()], at: 60)).unknownCount, 1)
    }
    func testBoundedStateAndFieldLimitsAndDuplicateIDs() {
        var classifier = SmartContinuityClassifier()
        for i in 0..<12 {
            let flows = (0...SmartContinuityClassifier.maximumConnections).map { flow("id-\($0)") }
            let result = classifier.observe(evidence(flows, at: Double(i) * 5))
            XCTAssertEqual(result.observedConnectionCount, SmartContinuityClassifier.maximumConnections)
            XCTAssertTrue(result.snapshotTruncated)
            XCTAssertLessThanOrEqual(classifier.retainedConnectionCount, SmartContinuityClassifier.maximumConnections)
            XCTAssertLessThanOrEqual(classifier.retainedSampleCount, SmartContinuityClassifier.maximumConnections * SmartContinuityClassifier.maximumSamples)
            XCTAssertLessThanOrEqual(result.sampleCount, SmartContinuityClassifier.maximumSamples)
        }
        for value in [flow(String(repeating: "x", count: 257)), flow(chain: Array(repeating: "a", count: 33)), flow(chain: [String(repeating: "x", count: 257)])] {
            XCTAssertEqual(classifier.observe(evidence([value], at: 60)).unknownCount, 1)
            XCTAssertEqual(classifier.retainedConnectionCount, 0)
        }
        XCTAssertEqual(classifier.observe(evidence([flow(), flow()], at: 70)).unknownCount, 2)
        XCTAssertEqual(classifier.retainedConnectionCount, 0)
    }
    func testClockAndSamplingDiscontinuityAndFrequentSamples() {
        for offset in [30.0, 29, 40.001] {
            var classifier = SmartContinuityClassifier()
            _ = idleWindow(&classifier)
            let result = classifier.observe(evidence([flow()], at: offset))
            XCTAssertEqual(result.unknownCount, 1); XCTAssertEqual(result.sampleCount, 1)
            XCTAssertTrue(result.reasonCodes.contains("samplingDiscontinuity"))
        }
        var classifier = SmartContinuityClassifier()
        for i in 0...35 { XCTAssertEqual(classifier.observe(evidence([flow()], at: Double(i))).replaceableCount, 0) }
        XCTAssertEqual(classifier.observe(evidence([flow()], at: .infinity)).reasonCodes, ["clockUnavailable"])
        XCTAssertEqual(classifier.retainedConnectionCount, 0)
    }
    func testUnavailableStoppedAndErrorsResetWindow() async {
        for unavailable in [SmartContinuityRuntimeResult.unavailable, .stopped] {
            let runtime = ContinuityRuntimeSpy(.available(evidence([flow()])))
            let operations = SmartContinuityOperations(runtime: runtime)
            for t in [0.0, 10, 20, 30] { await runtime.set(.available(evidence([flow()], at: t))); _ = await operations.evaluate() }
            await runtime.set(unavailable)
            let result = await operations.evaluate()
            XCTAssertTrue(result.snapshotUnavailable)
            let retained = await operations.retainedConnectionCount(); XCTAssertEqual(retained, 0)
            await runtime.set(.available(evidence([flow()], at: 40)))
            let fresh = await operations.evaluate(); XCTAssertEqual(fresh.unknownCount, 1)
            await runtime.fail(); let failed = await operations.evaluate()
            XCTAssertEqual(failed.reasonCodes, ["runtimeUnavailable"])
        }
    }
    func testCancellationAndConcurrentInvocationDoNotPublishOrReuseEvidence() async {
        let runtime = ContinuityRuntimeSpy(.available(evidence([flow()])))
        let operations = SmartContinuityOperations(runtime: runtime)
        _ = await operations.evaluate()
        await runtime.gate()
        let first = Task { await operations.evaluate() }
        await runtime.waitUntilReading()
        let concurrent = await operations.evaluate()
        XCTAssertEqual(concurrent.reasonCodes, ["evaluationInProgress"])
        first.cancel(); await runtime.release()
        let cancelled = await first.value; XCTAssertEqual(cancelled.reasonCodes, ["cancelled"])
        let retained = await operations.retainedConnectionCount(); XCTAssertEqual(retained, 0)
        let preCancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return await operations.evaluate() }
        let result = await preCancelled.value; XCTAssertEqual(result.reasonCodes, ["cancelled"])
        let reads = await runtime.reads; XCTAssertEqual(reads, 2)
    }
    func testCLIPrivacyAndZeroMutationOrPersistence() async throws {
        XCTAssertEqual(try TargetCtlCommandParser.parse(["smart", "continuity", "--json"]).action, "smart.continuity")
        for args in [["smart", "continuity"], ["smart", "continuity", "--close", "--json"], ["smart", "close", "--json"]] {
            XCTAssertThrowsError(try TargetCtlCommandParser.parse(args))
        }
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Synthetic")
        try store.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: profile.id)
        let before = try treeSnapshot(root)
        let runtime = ContinuityRuntimeSpy(.available(evidence([flow()])))
        let automation = TargetAutomationOperations(profileStore: store, backend: runtime)
        for t in [0.0, 10, 20, 30] {
            await runtime.set(.available(evidence([flow()], at: t)))
            let response = await automation.handle(.init(protocolVersion: 1, action: "smart.continuity"))
            XCTAssertTrue(response.ok)
            let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
            for forbidden in ["private-id", "private-outbound", "private-inbound", "private.example.invalid", "203.0.113.77", "sourceAddress", "destination", "secret", "endpoint", "profile", "subscription", "127.0.0.1", "synthetic/engine"] {
                XCTAssertFalse(encoded.contains(forbidden), forbidden)
            }
            XCTAssertLessThan(encoded.utf8.count, 2_048)
            if t == 30 { XCTAssertTrue(encoded.contains("\"replaceableCount\":1")) }
        }
        let mutations = await runtime.mutations; XCTAssertEqual(mutations, 0)
        XCTAssertEqual(try treeSnapshot(root), before)
        let capabilities = await automation.handle(.init(protocolVersion: 1, action: "capabilities"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("smart.continuity"))
        let invalid = await automation.handle(.init(protocolVersion: 1, action: "smart.continuity", arguments: ["connection": "private-id"]))
        XCTAssertFalse(invalid.ok)
        let fallback = TargetAutomationOperations(profileStore: store, backend: MockBackend())
        let unavailable = await fallback.handle(.init(protocolVersion: 1, action: "smart.continuity"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(unavailable), as: UTF8.self).contains("runtimeUnavailable"))
    }
}

private actor ContinuityRuntimeSpy: SmartContinuityRuntimeReading, EngineBackend {
    private var value: SmartContinuityRuntimeResult
    private var shouldFail = false
    private var shouldGate = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    private(set) var mutations = 0
    init(_ value: SmartContinuityRuntimeResult) { self.value = value }
    func set(_ value: SmartContinuityRuntimeResult) { self.value = value }
    func fail() { shouldFail = true }
    func gate() { shouldGate = true }
    func collectContinuityEvidence() async throws -> SmartContinuityRuntimeResult {
        reads += 1
        if shouldFail { throw RuntimeControlError.unavailable }
        if shouldGate {
            shouldGate = false
            await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil }
        }
        return value
    }
    func waitUntilReading() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func queryStatus() async throws -> BackendStatus { .mockDefault }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws { mutations += 1 }
    func startEngine() async throws -> BackendStatus { mutations += 1; return .mockDefault }
    func stopEngine() async throws -> BackendStatus { mutations += 1; return .mockDefault }
}
