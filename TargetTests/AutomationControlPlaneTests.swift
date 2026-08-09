import Darwin
import XCTest
@testable import Target

final class AutomationControlPlaneTests: XCTestCase {
    func testPolicyCatalogAllowlistsSelectorMembersAndRedactsSecrets() throws {
        let secret = "POLICY-CREDENTIAL-SENTINEL"
        let catalog = PolicyCatalogParser.parse(Data("""
        {"outbounds":[{"type":"selector","tag":"group","outbounds":["b","a","missing"],"default":"a","token":"\(secret)"},{"type":"vmess","tag":"a","server":"\(secret)","uuid":"\(secret)"},{"type":"trojan","tag":"b","password":"\(secret)","transport":{"path":"\(secret)"}}]}
        """.utf8))
        XCTAssertEqual(catalog.selectors.first?.members.map(\.tag), ["b", "a", "missing"])
        XCTAssertEqual(catalog.selectors.first?.configuredDefault, "a")
        XCTAssertEqual(catalog.selectors.first?.members.last?.status, .missingReference)
        let encoded = try JSONEncoder().encode(catalog.automationJSON())
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
    }

    func testPolicyCatalogKeepsDuplicateTagsAmbiguous() {
        let catalog = PolicyCatalogParser.parse(Data("{\"outbounds\":[{\"type\":\"selector\",\"tag\":\"g\",\"outbounds\":[\"x\"]},{\"type\":\"direct\",\"tag\":\"x\"},{\"type\":\"block\",\"tag\":\"x\"}]}".utf8))
        XCTAssertEqual(catalog.selectors.first?.members.first?.status, .duplicateTag)
    }

    func testPolicyCatalogParserPreservesOrderDefaultAndStructuralStates() {
        let catalog = PolicyCatalogParser.parse(Data("""
        {"outbounds":[
          {"type":"selector","tag":"group","outbounds":["first","missing","first"],"default":"first"},
          {"type":"future-protocol","tag":"first"},
          {"type":"selector","tag":"","outbounds":[]},
          {"type":"selector","tag":"malformed","outbounds":"not-an-array"}
        ]}
        """.utf8))
        XCTAssertEqual(catalog.selectors.map(\.tag), ["group", nil, "malformed"])
        XCTAssertEqual(catalog.selectors[0].members.map(\.tag), ["first", "missing", "first"])
        XCTAssertEqual(catalog.selectors[0].configuredDefault, "first")
        XCTAssertEqual(catalog.selectors[0].members[0].type, "future-protocol")
        XCTAssertEqual(catalog.selectors[0].members[1].status, .missingReference)
        XCTAssertEqual(catalog.selectors[1].status, .invalidTag)
        XCTAssertEqual(catalog.selectors[2].status, .malformedMembers)
        XCTAssertEqual(Set(catalog.selectors.map(\.id)).count, catalog.selectors.count)
        XCTAssertEqual(Set(catalog.selectors[0].members.map(\.id)).count, catalog.selectors[0].members.count)
    }

    func testPolicyCatalogParserProducesEmptyCatalogWhenPersistedOutboundsHaveNoSelector() {
        let catalog = PolicyCatalogParser.parse(Data(#"{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vmess","tag":"node"}]}"#.utf8))

        XCTAssertEqual(catalog.formatVersion, 1)
        XCTAssertTrue(catalog.selectors.isEmpty)
    }

    func testPolicyCatalogMissingOrEmptyMemberTypeIsUnavailable() {
        let catalog = PolicyCatalogParser.parse(Data("""
        {"outbounds":[{"type":"selector","tag":"group","outbounds":["missing-type","empty-type"]},{"tag":"missing-type"},{"type":"","tag":"empty-type"}]}
        """.utf8))
        XCTAssertEqual(catalog.selectors[0].members.map(\.status), [.unavailable, .unavailable])
        XCTAssertEqual(catalog.selectors[0].members.map(\.type), [nil, nil])
    }

    func testTargetCtlPolicyListParserUsesProductionGrammar() throws {
        let parsed = try TargetCtlCommandParser.parse(["policy", "list", "--json"])
        XCTAssertEqual(parsed.action, "policy.list")
        XCTAssertEqual(parsed.arguments, [:])
        XCTAssertThrowsError(try TargetCtlCommandParser.parse(["policy", "list"]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse(["policy", "list", "extra", "--json"]))
    }

    func testPolicyCatalogRedactsExpandedCredentialSentinels() throws {
        let secret = "POLICY-SECRET-SENTINEL"
        let catalog = PolicyCatalogParser.parse(Data("""
        {"outbounds":[{"type":"selector","tag":"group","outbounds":["member"]},{"type":"vmess","tag":"member","server":"\(secret)","server_port":"\(secret)","username":"\(secret)","password":"\(secret)","uuid":"\(secret)","token":"\(secret)","private_key":"\(secret)","certificate":"\(secret)","subscription":"\(secret)","tls":{"server_name":"\(secret)","reality":{"public_key":"\(secret)","short_id":"\(secret)"}},"wireguard":{"private_key":"\(secret)"},"transport":{"path":"\(secret)արվում"},"unknown":{"nested":"\(secret)"}}]}
        """.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(catalog.automationJSON()), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertEqual(catalog.selectors[0].members[0].type, "vmess")
    }

    func testPolicyListUsesSharedPersistedCatalogAndStableErrors() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root, checker: AutomationPassingChecker(), keyProvider: TestProfileKeyProvider())
        let operations = TargetAutomationOperations(profileStore: store, backend: MockBackend())
        let none = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.list"))
        XCTAssertEqual(none.error?.code, "profile_not_selected")

        let profile = try store.create(name: "Policy")
        try store.save(json: #"{"outbounds":[{"type":"selector","tag":"group","outbounds":["node"]},{"type":"direct","tag":"node","password":"AUTOMATION-SECRET"}]}"#, for: profile.id)
        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.list"))
        XCTAssertTrue(response.ok)
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"formatVersion\":1"))
        XCTAssertFalse(encoded.contains("AUTOMATION-SECRET"))
        let unexpectedArguments = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.list", arguments: ["extra": "x"]))
        XCTAssertFalse(unexpectedArguments.ok)
        let capabilities = await operations.handle(AutomationRequest(protocolVersion: 1, action: "capabilities"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("policy.list"))
    }

    func testPolicyListNoValidRevisionKeepsStableProfileErrorMapping() async {
        let response = await makeOperations(root: temporaryRoot()).profileStoreFailure(.noValidVersion)
        XCTAssertEqual(response.error?.code, "profile_no_valid_version")
    }
    func testProtocolDecodesValidRequestStrictly() throws {
        let data = Data(#"{"action":"status","arguments":{},"protocolVersion":1}"#.utf8)
        XCTAssertEqual(
            try AutomationProtocol.decodeRequest(data),
            AutomationRequest(protocolVersion: 1, action: "status", arguments: [:])
        )
    }

    func testProtocolRejectsMalformedAndUnknownFields() {
        XCTAssertThrowsError(try AutomationProtocol.decodeRequest(Data("[]".utf8)))
        XCTAssertThrowsError(try AutomationProtocol.decodeRequest(
            Data(#"{"action":"status","extra":true,"protocolVersion":1}"#.utf8)
        ))
    }

    func testProtocolRejectsOversizedRequest() {
        XCTAssertThrowsError(try AutomationProtocol.decodeRequest(
            Data(repeating: 0x20, count: AutomationProtocol.maximumMessageBytes + 1)
        )) { error in
            XCTAssertEqual(error as? AutomationProtocolError, .oversizedRequest)
        }
    }

    func testStableJSONResponse() {
        let response = AutomationResponse.success(.object(["b": .boolean(true), "a": .integer(1)]))
        XCTAssertEqual(
            String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self),
            #"{"error":null,"ok":true,"protocolVersion":1,"result":{"a":1,"b":true}}"#
        )
    }

    func testWrongVersionAndUnknownActionUseStableErrors() async {
        let operations = makeOperations(root: temporaryRoot())
        let version = await operations.handle(AutomationRequest(protocolVersion: 2, action: "status"))
        XCTAssertEqual(version.error?.code, "unsupported_version")
        let action = await operations.handle(AutomationRequest(protocolVersion: 1, action: "future.command"))
        XCTAssertEqual(action.error?.code, "unknown_action")
    }

    func testProfileStoreFailuresUseStableNonSecretCodes() async {
        let operations = makeOperations(root: temporaryRoot())
        let keychain = await operations.profileStoreFailure(.keychainReadFailed).error?.code
        let authentication = await operations.profileStoreFailure(.encryptedStorageAuthenticationFailed).error?.code
        let structural = await operations.profileStoreFailure(.invalidStoredMetadata).error?.code
        XCTAssertEqual(keychain, "profile_keychain_unavailable")
        XCTAssertEqual(authentication, "profile_store_authentication_failed")
        XCTAssertEqual(structural, "profile_store_invalid")
    }

    func testBackendFailuresUseStableNonSecretCodes() async {
        let operations = makeOperations(root: temporaryRoot())
        let check = await operations.backendFailure(.configurationCheckFailed).error?.code
        let unsafe = await operations.backendFailure(.profileConfigurationUnsafe).error?.code
        let launch = await operations.backendFailure(.engineLaunchFailed).error?.code
        XCTAssertEqual(check, "configuration_check_failed")
        XCTAssertEqual(unsafe, "profile_configuration_unsafe")
        XCTAssertEqual(launch, "engine_launch_failed")
    }

    func testSocketPathRejectsSymlinkDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Target", directoryHint: .isDirectory)
        let elsewhere = root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: target.appending(path: "Automation"),
            withDestinationURL: elsewhere
        )
        XCTAssertThrowsError(try AutomationSocketPath.prepareServerURL(
            target.appending(path: "Automation/control.sock")
        )) { error in
            XCTAssertEqual(error as? AutomationSocketError, .unsafePath)
        }
    }

    func testSocketAcceptsSameUserAndRejectsUnexpectedUID() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "Target/Automation/control.sock")
        let server = LocalAutomationServer(socketURL: socket) { _ in .success(.object(["accepted": .boolean(true)])) }
        try server.start()
        let accepted = try LocalAutomationClient.send(
            AutomationRequest(protocolVersion: 1, action: "status"), socketURL: socket
        )
        XCTAssertTrue(try JSONDecoder().decode(AutomationResponse.self, from: accepted).ok)
        server.stop()

        let rejectedSocket = socket.deletingLastPathComponent().appending(path: "rejected.sock")
        let rejectedServer = LocalAutomationServer(socketURL: rejectedSocket, expectedUID: geteuid() &+ 1) { _ in .success() }
        try rejectedServer.start()
        defer { rejectedServer.stop() }
        let rejected = try LocalAutomationClient.send(
            AutomationRequest(protocolVersion: 1, action: "status"), socketURL: rejectedSocket
        )
        XCTAssertEqual(try JSONDecoder().decode(AutomationResponse.self, from: rejected).error?.code, "peer_rejected")
    }

    func testSocketSerializesRequests() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "Target/Automation/control.sock")
        let tracker = AutomationConcurrencyTracker()
        let server = LocalAutomationServer(socketURL: socket) { _ in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(50))
            await tracker.leave()
            return .success()
        }
        try server.start()
        defer { server.stop() }
        async let first = Task.detached {
            try LocalAutomationClient.send(AutomationRequest(protocolVersion: 1, action: "status"), socketURL: socket)
        }.value
        async let second = Task.detached {
            try LocalAutomationClient.send(AutomationRequest(protocolVersion: 1, action: "status"), socketURL: socket)
        }.value
        _ = try await (first, second)
        let maximum = await tracker.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testActiveSocketIsNeverRemovedAsStale() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "Target/Automation/control.sock")
        let server = LocalAutomationServer(socketURL: socket) { _ in .success() }
        try server.start()
        defer { server.stop() }
        let competing = LocalAutomationServer(socketURL: socket) { _ in .success() }
        XCTAssertThrowsError(try competing.start()) { error in
            XCTAssertEqual(error as? AutomationSocketError, .unavailable)
        }
        let response = try LocalAutomationClient.send(
            AutomationRequest(protocolVersion: 1, action: "status"), socketURL: socket
        )
        XCTAssertTrue(try JSONDecoder().decode(AutomationResponse.self, from: response).ok)
    }

    func testProfileImportUsesSecureStoreOperationAndRedactsConfiguration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profileRoot = root.appending(path: "Profiles", directoryHint: .isDirectory)
        let store = ProfileStore(
            rootDirectory: profileRoot,
            checker: AutomationPassingChecker(),
            keyProvider: TestProfileKeyProvider()
        )
        let operations = TargetAutomationOperations(profileStore: store, backend: MockBackend())
        let secretFixture = "credential-fixture-must-not-appear"
        let input = root.appending(path: "input.json")
        try Data(#"{"outbounds":[{"password":"credential-fixture-must-not-appear","type":"direct"}]}"#.utf8).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)

        let response = await operations.handle(AutomationRequest(
            protocolVersion: 1,
            action: "profile.import",
            arguments: ["file": input.path, "name": "Imported"]
        ))
        XCTAssertTrue(response.ok)
        XCTAssertFalse(String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self).contains(secretFixture))
        let profiles = try store.listProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].validRevision, 1)
        XCTAssertEqual(profiles[0].validation.status, .valid)
        XCTAssertEqual(try store.selectedProfileID(), profiles[0].id)
        XCTAssertTrue(try store.configurationText(for: profiles[0].id).contains(secretFixture))
    }

    func testPrivilegedServiceErrorsUseStableRedactedCodes() async {
        let operations = makeOperations(root: temporaryRoot())
        for (serviceCode, expected) in [
            (100, "proxy_safe_mode_blocked"),
            (101, "proxy_conflict"),
            (102, "proxy_no_active_service"),
            (103, "proxy_engine_unavailable"),
            (104, "proxy_snapshot_failed"),
            (105, "proxy_snapshot_owner_invalid"),
            (106, "proxy_external_change_conflict"),
            (107, "proxy_apply_failed"),
            (108, "proxy_verification_failed"),
            (109, "proxy_recovery_failed"),
            (110, "proxy_status_unavailable"),
            (999, "service_operation_failed")
        ] {
            let response = await operations.serviceFailure(serviceCode)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, expected)
            XCTAssertFalse(String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self).contains("NSError"))
        }
    }

    func testTargetctlBinaryHasNoProfileStoreOrKeychainSymbols() throws {
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/targetctl")
        let binary = try Data(contentsOf: executable)
        XCTAssertFalse(binary.range(of: Data("ProfileStore".utf8)) != nil)
        XCTAssertFalse(binary.range(of: Data("Keychain".utf8)) != nil)
    }

    private func makeOperations(root: URL) -> TargetAutomationOperations {
        TargetAutomationOperations(
            profileStore: ProfileStore(
                rootDirectory: root.appending(path: "Profiles"),
                checker: AutomationPassingChecker(),
                keyProvider: TestProfileKeyProvider()
            ),
            backend: MockBackend()
        )
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp/ta-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
}

private struct AutomationPassingChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}

private actor AutomationConcurrencyTracker {
    private var active = 0
    private(set) var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}
