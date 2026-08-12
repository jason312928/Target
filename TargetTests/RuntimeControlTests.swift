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

private func profile() -> Profile {
    Profile(id: UUID(), name: "Runtime", subscription: nil, createdAt: .now, updatedAt: .now, validation: .notChecked, validRevision: 1)
}
