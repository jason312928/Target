import Foundation
import XCTest
@testable import Target
import TargetCore

final class RuntimeControlTests: XCTestCase, ProfileTestCaseSupport {
    func testPreparationOwnsLoopbackControllerAndPreservesExperimentalFields() throws {
        let version = ProfileConfigurationVersion(
            profile: profile(), revision: 1,
            data: Data(#"{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":0}],"experimental":{"cache_file":{"enabled":true},"clash_api":{"external_controller":"0.0.0.0:9090","secret":"user-secret","external_ui":"https://example.invalid","access_control_allow_origin":"*"}},"outbounds":[{"type":"direct","tag":"direct"}]}"#.utf8)
        )
        let prepared = try ProfileRuntimeConfigurationPreparer(
            portSelector: TestPortSelector([51_234]),
            controllerPortSelector: TestPortSelector([51_235]),
            secretGenerator: TestSecretGenerator(value: "unit-test-secret-not-production")
        ).prepare(version)
        XCTAssertEqual(prepared.runtimeControl.host, "127.0.0.1")
        XCTAssertEqual(prepared.runtimeControl.port, 51_235)
        XCTAssertEqual(prepared.runtimeControl.secret, "unit-test-secret-not-production")
        XCTAssertNotEqual(prepared.runtimeControl.port, prepared.primaryPort)
        XCTAssertNotEqual(prepared.configurationFingerprint, TargetConfigurationFingerprint.sha256(version.data))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        XCTAssertNotNil(experimental["cache_file"])
        let clash = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clash["external_controller"] as? String, "127.0.0.1:51235")
        XCTAssertEqual(clash["secret"] as? String, "unit-test-secret-not-production")
        XCTAssertNil(clash["external_ui"])
        XCTAssertNil(clash["access_control_allow_origin"])
        XCTAssertEqual(String(decoding: version.data, as: UTF8.self).contains("0.0.0.0:9090"), true)
    }

    func testDescriptorParserRejectsNonLoopbackController() {
        XCTAssertNil(RuntimeControlDescriptorParser.parse(Data(#"{"experimental":{"clash_api":{"external_controller":"0.0.0.0:51234","secret":"fixture"}}}"#.utf8)))
        XCTAssertNil(RuntimeControlDescriptorParser.parse(Data(#"{"experimental":{"clash_api":{"external_controller":"127.0.0.1:80","secret":"fixture"}}}"#.utf8)))
    }

    func testControllerRequestUsesLoopbackBearerAndNoSystemProxy() throws {
        let descriptor = RuntimeControlDescriptor(host: "127.0.0.1", port: 51_234, secret: "unit-test-secret-not-production")
        let request = try SingBoxRuntimeControlClient.makeRequest(path: "/proxies/group", method: "PUT", descriptor: descriptor, body: Data("{}".utf8))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:51234/proxies/group")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
        XCTAssertThrowsError(try SingBoxRuntimeControlClient.makeRequest(path: "/connections", method: "GET", descriptor: .init(host: "localhost", port: 51_234, secret: "fixture"), body: nil))
        XCTAssertEqual(SingBoxRuntimeControlClient.makeSession().configuration.connectionProxyDictionary?.isEmpty, true)
    }

    func testDelayRequestUsesFixedLoopbackPolicyAndPercentEncodesMember() throws {
        let descriptor = RuntimeControlDescriptor(
            host: "127.0.0.1",
            port: 51_234,
            secret: "unit-test-secret-not-production"
        )
        let request = try SingBoxRuntimeControlClient.makeDelayRequest(
            outbound: "Hong Kong/01?fast",
            descriptor: descriptor
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.port, 51_234)
        XCTAssertEqual(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath,
            "/proxies/Hong%20Kong%2F01%3Ffast/delay"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems?.first(where: { $0.name == "url" })?.value, "https://www.gstatic.com/generate_204")
        XCTAssertEqual(query.queryItems?.first(where: { $0.name == "timeout" })?.value, "1500")
    }

    func testDelayProbeParsesBoundedLatency() async throws {
        let client = makeRuntimeControlClient(status: 200, body: Data(#"{"delay":42}"#.utf8))
        let latency = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
        XCTAssertEqual(latency, 42)
        let request = try XCTUnwrap(RuntimeControlURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
    }

    func testDelayProbeRejectsMalformedAndNegativeLatencyWithoutLeakingSecret() async {
        for body in [Data(#"{"delay":"fast"}"#.utf8), Data(#"{"delay":-1}"#.utf8)] {
            let client = makeRuntimeControlClient(status: 200, body: body)
            do {
                _ = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
                XCTFail("Expected malformed delay response")
            } catch {
                XCTAssertEqual(error as? RuntimeControlError, .malformedResponse)
                XCTAssertFalse(String(describing: error).contains(runtimeDescriptor.secret))
            }
        }
    }

    func testDelayProbeMapsNonSuccessToBoundedProbeFailure() async {
        let client = makeRuntimeControlClient(status: 503, body: Data(#"{"message":"sensitive-upstream-detail"}"#.utf8))
        do {
            _ = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
            XCTFail("Expected probe failure")
        } catch {
            XCTAssertEqual(error as? RuntimeControlError, .probeFailed)
            XCTAssertFalse(String(describing: error).contains("sensitive-upstream-detail"))
            XCTAssertFalse(String(describing: error).contains(runtimeDescriptor.secret))
        }
    }

    func testControllerRedirectDelegateRefusesRedirect() throws {
        let session = URLSession(configuration: .ephemeral)
        let original = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:51234/proxies/node/delay")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://example.invalid"]
        ))
        let task = session.dataTask(with: original.url!)
        let refused = expectation(description: "redirect refused")
        RedirectRefusingDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: original,
            newRequest: URLRequest(url: URL(string: "https://example.invalid")!)
        ) { redirected in
            XCTAssertNil(redirected)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 1)
    }

    func testRateReducerUsesElapsedTimeAndResetsCountersSafely() {
        var reducer = RuntimeObservationReducer()
        let first = reducer.reduce(totals: .init(uploadTotalBytes: 100, downloadTotalBytes: 300, activeConnectionCount: 2), at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(first.uploadBytesPerSecond, 0)
        let second = reducer.reduce(totals: .init(uploadTotalBytes: 160, downloadTotalBytes: 380, activeConnectionCount: 3), at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(second.uploadBytesPerSecond, 30)
        XCTAssertEqual(second.downloadBytesPerSecond, 40)
        let reset = reducer.reduce(totals: .init(uploadTotalBytes: 2, downloadTotalBytes: 3, activeConnectionCount: 0), at: Date(timeIntervalSince1970: 13))
        XCTAssertEqual(reset.uploadBytesPerSecond, 0)
        XCTAssertEqual(reset.downloadBytesPerSecond, 0)
    }

    func testPolicySelectPersistsThenHotAppliesAndRereadsAuthority() async throws {
        let store = try makeStore()
        let selected = try store.create(name: "Runtime")
        try store.save(json: #"{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"selector","tag":"group","outbounds":["first","second"],"default":"first"},{"type":"direct","tag":"first"},{"type":"direct","tag":"second"}]}"#, for: selected.id)
        let version = try store.selectedValidVersion()
        let evidence = HotPolicyEvidence(profileID: selected.id, revision: version.revision, source: version.data)
        let operations = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: evidence)
        let result = try await operations.select(selectorTag: "group", outboundTag: "second")
        XCTAssertEqual(result.selectors.first?.runningSelection, "second")
        XCTAssertEqual(result.selectors.first?.runtimeConvergence, .converged)
        XCTAssertFalse(result.selectors.first?.restartRequired ?? true)
        let applyCount = await evidence.applyCount
        XCTAssertEqual(applyCount, 1)
    }

    func testPolicyLatencyProbePreservesPartialResultsAndProfileIdentity() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: profile.id)
        let version = try store.selectedValidVersion()
        let identity = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let provider = HealthProbeEvidence(identity: identity) { tags in
            .results([
                RuntimeProxyHealth.reachable(tag: tags[0], latencyMilliseconds: 42, observedAt: Date(timeIntervalSince1970: 1))!,
                .unreachable(tag: tags[1], observedAt: Date(timeIntervalSince1970: 1))
            ])
        }
        let result = try await TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: provider
        ).probeLatency(selectorTag: "group")

        XCTAssertTrue(result.runtimeAvailable)
        XCTAssertEqual(result.profileID, profile.id)
        XCTAssertEqual(result.profileRevision, version.revision)
        XCTAssertEqual(result.members.map(\.tag), ["first", "second"])
        XCTAssertEqual(result.members.map(\.state), [.reachable, .unreachable])
        XCTAssertEqual(result.members.first?.latencyMilliseconds, 42)
        let requestCount = await provider.controllerRequestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testPolicyLatencyProbeRuntimeIdentityMismatchMakesZeroControllerRequests() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first"]), for: profile.id)
        let version = try store.selectedValidVersion()
        let selectedIdentity = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let mismatches = [
            ExpectedPolicyRuntimeIdentity(profileID: UUID(), profileRevision: selectedIdentity.profileRevision, sourceFingerprint: selectedIdentity.sourceFingerprint),
            ExpectedPolicyRuntimeIdentity(profileID: selectedIdentity.profileID, profileRevision: selectedIdentity.profileRevision + 1, sourceFingerprint: selectedIdentity.sourceFingerprint),
            ExpectedPolicyRuntimeIdentity(profileID: selectedIdentity.profileID, profileRevision: selectedIdentity.profileRevision, sourceFingerprint: "different")
        ]

        for runtimeIdentity in mismatches {
            let provider = HealthProbeEvidence(identity: runtimeIdentity) { _ in .runtimeUnavailable }
            let result = try await TargetPolicyOperations(
                profileStore: store,
                runtimeEvidenceProvider: provider
            ).probeLatency(selectorTag: "group")
            XCTAssertFalse(result.runtimeAvailable)
            XCTAssertEqual(result.members.map(\.state), [.runtimeUnavailable])
            let requestCount = await provider.controllerRequestCount
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testPolicyLatencyProbeStoppedOrUnprovenRuntimeIsUnavailable() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first"]), for: profile.id)
        let stopped = try await TargetPolicyOperations(profileStore: store).probeLatency(selectorTag: "group")
        XCTAssertFalse(stopped.runtimeAvailable)
        XCTAssertEqual(stopped.members.map(\.state), [.runtimeUnavailable])

        let unproven = try await TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: UnprovenPolicyRuntimeEvidence()
        ).probeLatency(selectorTag: "group")
        XCTAssertFalse(unproven.runtimeAvailable)
        XCTAssertEqual(unproven.members.map(\.state), [.runtimeUnavailable])
    }

    func testPolicyLatencyProbeSkipsStructurallyInvalidMembersAndRejectsAmbiguousSelector() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(
            json: #"{"outbounds":[{"type":"selector","tag":"group","outbounds":["good","missing"]},{"type":"vmess","tag":"good"}]}"#,
            for: profile.id
        )
        let version = try store.selectedValidVersion()
        let identity = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let provider = HealthProbeEvidence(identity: identity) { tags in
            .results([RuntimeProxyHealth.reachable(tag: tags[0], latencyMilliseconds: 9, observedAt: .now)!])
        }
        let result = try await TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: provider
        ).probeLatency(selectorTag: "group")
        XCTAssertEqual(result.members.map(\.tag), ["good"])
        let requestCount = await provider.controllerRequestCount
        XCTAssertEqual(requestCount, 1)

        try store.save(
            json: #"{"outbounds":[{"type":"selector","tag":"group","outbounds":["good"]},{"type":"selector","tag":"group","outbounds":["good"]},{"type":"vmess","tag":"good"}]}"#,
            for: profile.id
        )
        do {
            _ = try await TargetPolicyOperations(
                profileStore: store,
                runtimeEvidenceProvider: provider
            ).probeLatency(selectorTag: "group")
            XCTFail("Expected ambiguous selector")
        } catch {
            XCTAssertEqual(error as? TargetPolicyOperationError, .selectorAmbiguous)
        }
        let finalRequestCount = await provider.controllerRequestCount
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testRuntimeProxyHealthRejectsOutOfRangeLatency() {
        XCTAssertNil(RuntimeProxyHealth.reachable(tag: "node", latencyMilliseconds: -1, observedAt: .now))
        XCTAssertNil(RuntimeProxyHealth.reachable(tag: "node", latencyMilliseconds: 0, observedAt: .now))
        XCTAssertNil(RuntimeProxyHealth.reachable(
            tag: "node",
            latencyMilliseconds: RuntimeProxyHealth.maximumLatencyMilliseconds + 1,
            observedAt: .now
        ))
    }

    func testRuntimeStatusCommandIsBoundedAndDoesNotExposeControllerMaterial() async throws {
        XCTAssertEqual(try TargetCtlCommandParser.parse(["runtime", "status", "--json"]).action, "runtime.status")
        let operations = TargetAutomationOperations(runtimeObservationOperations: FixedRuntimeObservationProvider(value: .init(
            state: .available, uploadTotalBytes: 10, downloadTotalBytes: 20,
            uploadBytesPerSecond: 1.5, downloadBytesPerSecond: 2.5,
            activeConnectionCount: 1, observedAt: Date()
        )))
        let response = await operations.handle(.init(protocolVersion: 1, action: "runtime.status"))
        let data = AutomationProtocol.encodeResponse(response)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("uploadTotalBytes"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("127.0.0.1"))
    }
}

private let runtimeDescriptor = RuntimeControlDescriptor(
    host: "127.0.0.1",
    port: 51_234,
    secret: "unit-test-secret-not-production"
)

private func makeRuntimeControlClient(status: Int, body: Data) -> SingBoxRuntimeControlClient {
    RuntimeControlURLProtocol.configure(status: status, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RuntimeControlURLProtocol.self]
    configuration.connectionProxyDictionary = [:]
    return SingBoxRuntimeControlClient(session: URLSession(configuration: configuration))
}

private final class RuntimeControlURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response = (status: 200, body: Data())
    private(set) static var lastRequest: URLRequest?

    static func configure(status: Int, body: Data) {
        lock.lock()
        response = (status, body)
        lastRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        let response = Self.response
        Self.lock.unlock()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct TestPortSelector: LocalEnginePortSelecting {
    let ports: [UInt16]
    init(_ ports: [UInt16]) { self.ports = ports }
    func selectAvailablePort() throws -> UInt16 { ports[0] }
}

private struct TestSecretGenerator: RuntimeControlSecretGenerating {
    let value: String
    func generate() throws -> String { value }
}

private struct FixedRuntimeObservationProvider: TargetRuntimeObserving {
    let value: RuntimeObservation
    func read() async -> RuntimeObservation { value }
}

private actor HotPolicyEvidence: PolicyRuntimeEvidenceProviding, RuntimePolicyApplying {
    let profileID: UUID
    let revision: Int
    let source: Data
    private var selection = "first"
    private(set) var applyCount = 0

    init(profileID: UUID, revision: Int, source: Data) {
        self.profileID = profileID
        self.revision = revision
        self.source = source
    }

    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence {
        .running(
            profileID: profileID, profileRevision: revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(source),
            configuration: source, liveSelections: ["group": selection]
        )
    }

    func applyLivePolicySelection(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        selectorTag: String,
        outboundTag: String
    ) async -> Bool {
        guard expectedRuntime.profileID == profileID,
              expectedRuntime.profileRevision == revision,
              expectedRuntime.sourceFingerprint == TargetConfigurationFingerprint.sha256(source) else {
            return false
        }
        applyCount += 1
        selection = outboundTag
        return true
    }
}

private actor HealthProbeEvidence: PolicyRuntimeEvidenceProviding, RuntimePolicyHealthProbing {
    let identity: ExpectedPolicyRuntimeIdentity
    let outcome: @Sendable ([String]) -> RuntimePolicyHealthProbeOutcome
    private(set) var controllerRequestCount = 0

    init(
        identity: ExpectedPolicyRuntimeIdentity,
        outcome: @escaping @Sendable ([String]) -> RuntimePolicyHealthProbeOutcome
    ) {
        self.identity = identity
        self.outcome = outcome
    }

    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .unavailable }

    func probePolicyMemberLatency(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        outboundTags: [String]
    ) async throws -> RuntimePolicyHealthProbeOutcome {
        guard expectedRuntime == identity else { return .runtimeUnavailable }
        controllerRequestCount += outboundTags.count
        return outcome(outboundTags)
    }
}

private struct UnprovenPolicyRuntimeEvidence: PolicyRuntimeEvidenceProviding {
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .unavailable }
}

private func profile() -> Profile {
    Profile(id: UUID(), name: "Runtime", subscription: nil, createdAt: .now, updatedAt: .now, validation: .notChecked, validRevision: 1)
}
