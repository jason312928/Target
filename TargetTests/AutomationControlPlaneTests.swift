import Darwin
import XCTest
@testable import Target
@testable import TargetCore

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
        XCTAssertNil(catalog.selectors[0].configuredDefault)
        XCTAssertEqual(catalog.selectors[0].members[0].status, .duplicateTag)
        XCTAssertEqual(catalog.selectors[0].members[1].status, .missingReference)
        XCTAssertEqual(catalog.selectors[1].status, .invalidTag)
        XCTAssertEqual(catalog.selectors[2].status, .malformedMembers)
        XCTAssertEqual(Set(catalog.selectors.map(\.id)).count, catalog.selectors.count)
        XCTAssertEqual(Set(catalog.selectors[0].members.map(\.id)).count, catalog.selectors[0].members.count)
    }

    func testPolicyCatalogParserProducesEmptyCatalogWhenPersistedOutboundsHaveNoSelector() {
        let catalog = PolicyCatalogParser.parse(Data(#"{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vmess","tag":"node"}]}"#.utf8))

        XCTAssertEqual(catalog.formatVersion, 2)
        XCTAssertTrue(catalog.selectors.isEmpty)
    }

    func testPolicyCatalogUsesDocumentedFirstMemberFallbackAndRejectsAmbiguousSelectors() throws {
        let catalog = PolicyCatalogParser.parse(Data(#"{"outbounds":[{"type":"selector","tag":"fallback","outbounds":["first","second"]},{"type":"direct","tag":"first"},{"type":"block","tag":"second"},{"type":"selector","tag":"duplicate","outbounds":["first"]},{"type":"selector","tag":"duplicate","outbounds":["second"]}]}"#.utf8))
        XCTAssertEqual(catalog.selectors[0].configuredDefault, nil)
        XCTAssertEqual(catalog.selectors[0].effectiveDesired, "first")
        XCTAssertTrue(catalog.selectors[0].isMutable)
        XCTAssertEqual(catalog.selectors[1].status, .duplicateTag)
        XCTAssertEqual(catalog.selectors[2].status, .duplicateTag)
        XCTAssertFalse(catalog.selectors[1].isMutable)
        XCTAssertThrowsError(try PolicySelectionValidator.validate(selectorTag: "duplicate", outboundTag: "first", in: catalog)) {
            XCTAssertEqual($0 as? TargetPolicyOperationError, .selectorAmbiguous)
        }
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

    func testTargetCtlPolicyResetParserRequiresExactArgumentFreeGrammar() throws {
        let parsed = try TargetCtlCommandParser.parse(["policy", "reset", "--json"])
        XCTAssertEqual(parsed.action, "policy.reset")
        XCTAssertEqual(parsed.arguments, [:])
        XCTAssertThrowsError(try TargetCtlCommandParser.parse(["policy", "reset"]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse(["policy", "reset", "extra", "--json"]))
    }

    func testTargetCtlSubscriptionParsersRequireStdinAndExplicitConfirmation() throws {
        let create = try TargetCtlCommandParser.parse([
            "profile", "subscribe", "--name", "Provider", "--url-stdin", "--confirm", "--json"
        ])
        XCTAssertEqual(create.action, "profile.subscribe")
        XCTAssertEqual(create.arguments, ["name": "Provider", "confirm": "true", "urlStdin": "true"])
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "profile", "subscribe", "--name", "Provider", "--url", "https://example.com/secret", "--confirm", "--json"
        ]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "profile", "subscribe", "--name", "Provider", "--url-stdin", "--json"
        ]))

        let id = "11111111-1111-4111-8111-111111111111"
        let update = try TargetCtlCommandParser.parse([
            "profile", "subscription-update", id, "--confirm", id, "--json"
        ])
        XCTAssertEqual(update.action, "profile.subscription-update")
        XCTAssertEqual(update.arguments, ["id": id, "confirm": id])
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "profile", "subscription-update", id, "--confirm", "different", "--json"
        ]))
    }

    func testTargetCtlSubscriptionStdinIsBoundedSingleUTF8URL() throws {
        XCTAssertEqual(
            try TargetCtlSubscriptionInput.parse(Data("https://example.com/subscription/test-token\n".utf8)),
            "https://example.com/subscription/test-token"
        )
        for invalid in [Data(), Data("https://example.com/one\nhttps://example.com/two\n".utf8), Data([0xFF])] {
            XCTAssertThrowsError(try TargetCtlSubscriptionInput.parse(invalid))
        }
        XCTAssertThrowsError(try TargetCtlSubscriptionInput.parse(Data(repeating: 65, count: TargetCtlSubscriptionInput.maximumBytes + 1)))
    }


    func testTargetCtlPolicySelectParserRequiresExactArguments() throws {
        let parsed = try TargetCtlCommandParser.parse([
            "policy", "select", "--selector", "group", "--outbound", "second", "--json"
        ])
        XCTAssertEqual(parsed.action, "policy.select")
        XCTAssertEqual(parsed.arguments, ["selector": "group", "outbound": "second"])
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "policy", "select", "--outbound", "second", "--json"
        ]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "policy", "select", "--selector", "group", "--json"
        ]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "policy", "select", "--selector", "group", "--outbound", "second", "extra", "--json"
        ]))
    }

    func testTargetCtlPolicyProbeParserRequiresExactSelector() throws {
        let parsed = try TargetCtlCommandParser.parse([
            "policy", "probe", "--selector", "group", "--json"
        ])
        XCTAssertEqual(parsed.action, "policy.probe")
        XCTAssertEqual(parsed.arguments, ["selector": "group"])
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "policy", "probe", "--json"
        ]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "policy", "probe", "--selector", "group", "extra", "--json"
        ]))
        XCTAssertThrowsError(try TargetCtlCommandParser.parse([
            "policy", "probe", "--selector", "group"
        ]))
    }

    func testPolicyProbeAutomationUsesSharedOperationAndReturnsDeterministicSafeJSON() async throws {
        let profileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let shared = AutomationProbePolicyOperation(result: PolicyLatencyProbeResult(
            profileID: profileID,
            profileRevision: 3,
            sourceFingerprint: "SOURCE-FINGERPRINT-SENTINEL",
            selector: "Proxy",
            runtimeAvailable: true,
            members: [
                RuntimeProxyHealth.reachable(
                    tag: "Hong Kong 01",
                    latencyMilliseconds: 42,
                    observedAt: Date(timeIntervalSince1970: 1)
                )!,
                .unreachable(tag: "Tokyo 02", observedAt: Date(timeIntervalSince1970: 2))
            ]
        ))
        let operations = TargetAutomationOperations(policyOperations: shared, backend: MockBackend())
        let response = await operations.handle(.init(
            protocolVersion: 1,
            action: "policy.probe",
            arguments: ["selector": "Proxy"]
        ))
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(shared.probeCount, 1)
        XCTAssertEqual(shared.lastSelector, "Proxy")
        XCTAssertEqual(encoded, String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self))
        XCTAssertTrue(encoded.contains(#""formatVersion":1"#))
        XCTAssertTrue(encoded.contains(#""latencyMilliseconds":42"#))
        XCTAssertTrue(encoded.contains(#""state":"unreachable""#))
        XCTAssertTrue(encoded.contains(#""runtimeAvailable":true"#))
        XCTAssertFalse(encoded.contains("SOURCE-FINGERPRINT-SENTINEL"))
        XCTAssertFalse(encoded.contains("127.0.0.1"))
        XCTAssertFalse(encoded.lowercased().contains("secret"))

        let capabilities = await operations.handle(.init(protocolVersion: 1, action: "capabilities"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("policy.probe"))
        let invalid = await operations.handle(.init(
            protocolVersion: 1,
            action: "policy.probe",
            arguments: ["selector": "Proxy", "extra": "x"]
        ))
        XCTAssertEqual(invalid.error?.code, "invalid_arguments")
    }

    func testPolicyProbeAutomationRuntimeMismatchUsesStableSafeState() async {
        let shared = AutomationProbePolicyOperation(result: PolicyLatencyProbeResult(
            profileID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            profileRevision: 7,
            sourceFingerprint: "PRIVATE-SOURCE-FINGERPRINT",
            selector: "Proxy",
            runtimeAvailable: false,
            members: [.runtimeUnavailable(tag: "node")]
        ))
        let response = await TargetAutomationOperations(
            policyOperations: shared,
            backend: MockBackend()
        ).handle(.init(
            protocolVersion: 1,
            action: "policy.probe",
            arguments: ["selector": "Proxy"]
        ))
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(encoded.contains(#""runtimeAvailable":false"#))
        XCTAssertTrue(encoded.contains(#""state":"runtimeUnavailable""#))
        XCTAssertFalse(encoded.contains("PRIVATE-SOURCE-FINGERPRINT"))
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
        XCTAssertTrue(encoded.contains("\"formatVersion\":2"))
        XCTAssertFalse(encoded.contains("AUTOMATION-SECRET"))
        let unexpectedArguments = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.list", arguments: ["extra": "x"]))
        XCTAssertFalse(unexpectedArguments.ok)
        let capabilities = await operations.handle(AutomationRequest(protocolVersion: 1, action: "capabilities"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("policy.list"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("policy.select"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capabilities), as: UTF8.self).contains("policy.reset"))
    }

    func testPolicyResetAutomationReturnsVersionedReconciledSecretSafeResultAndStableErrors() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: AutomationPassingChecker(), keyProvider: keys)
        let none = await TargetAutomationOperations(profileStore: store, backend: MockBackend()).handle(
            AutomationRequest(protocolVersion: 1, action: "policy.reset")
        )
        XCTAssertEqual(none.error?.code, "profile_not_selected")

        let profile = try store.create(name: "Policy")
        let source = #"{"inbounds":[{"type":"mixed","tag":"local-mixed","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"selector","tag":"group","outbounds":["first","second"],"default":"first"},{"type":"direct","tag":"first"},{"type":"block","tag":"second","password":"RESET-SECRET"}]}"#
        try store.save(json: source, for: profile.id)
        let evidence = MutablePolicyRuntimeEvidence()
        let shared = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: evidence)
        _ = try await shared.select(selectorTag: "group", outboundTag: "second")
        let version = try store.selectedValidVersion()
        let runtime = try ProfileRuntimeConfigurationPreparer(portSelector: AutomationFixedPortSelector(port: 51_237)).prepare(version)
        await evidence.set(.running(profileID: profile.id, profileRevision: version.revision, sourceFingerprint: runtime.sourceFingerprint, configuration: runtime.data))
        let operations = TargetAutomationOperations(profileStore: store, policyOperations: shared, backend: MockBackend())
        let response = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.reset"))
        XCTAssertTrue(response.ok)
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertEqual(encoded, String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self))
        XCTAssertTrue(encoded.contains("\"clearedOverrideCount\":1"))
        XCTAssertTrue(encoded.contains("\"restartRequired\":true"))
        XCTAssertFalse(encoded.contains("RESET-SECRET"))
        let second = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.reset"))
        XCTAssertTrue(second.ok)
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(second), as: UTF8.self).contains("\"clearedOverrideCount\":0"))
        let invalid = await operations.handle(AutomationRequest(protocolVersion: 1, action: "policy.reset", arguments: ["extra": "x"]))
        XCTAssertEqual(invalid.error?.code, "invalid_arguments")
    }

    func testPolicyResetSemanticRequestMapsNoValidVersionAndPersistenceFailure() async throws {
        let noVersion = await TargetAutomationOperations(
            profileStore: ProfileStore(
                rootDirectory: temporaryRoot(),
                checker: AutomationPassingChecker(),
                keyProvider: TestProfileKeyProvider()
            ),
            policyOperations: ResetErrorPolicyOperation(),
            backend: MockBackend()
        ).handle(
            AutomationRequest(protocolVersion: 1, action: "policy.reset")
        )
        XCTAssertEqual(noVersion.error?.code, "profile_no_valid_version")

        let persistenceRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let faults = ResetManifestWriteFault()
        let persistenceStore = ProfileStore(
            rootDirectory: persistenceRoot,
            checker: AutomationPassingChecker(),
            keyProvider: TestProfileKeyProvider(),
            storageFaults: faults
        )
        let profile = try persistenceStore.create(name: "Persistence failure")
        try persistenceStore.save(json: Self.runtimePolicyConfiguration, for: profile.id)
        let policy = TargetPolicyOperations(profileStore: persistenceStore)
        _ = try await policy.select(selectorTag: "group", outboundTag: "second")
        faults.failManifestWrites = true
        let persistenceFailure = await TargetAutomationOperations(
            profileStore: persistenceStore,
            policyOperations: policy,
            backend: MockBackend()
        ).handle(AutomationRequest(protocolVersion: 1, action: "policy.reset"))
        XCTAssertEqual(persistenceFailure.error?.code, "policy_persistence_failed")
    }


    func testPolicySelectionPersistsAndReconcilesAuthoritativeRuntimeWithoutMutation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root, checker: AutomationPassingChecker(), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Policy")
        let source = Self.runtimePolicyConfiguration
        try store.save(json: source, for: profile.id)
        let evidence = MutablePolicyRuntimeEvidence()
        let policy = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: evidence)

        let selectedA = try await policy.select(selectorTag: "group", outboundTag: "first")
        XCTAssertEqual(selectedA.selectors[0].effectiveDesired, "first")
        let versionA = try store.selectedValidVersion()
        let runtimeA = try ProfileRuntimeConfigurationPreparer(portSelector: AutomationFixedPortSelector(port: 51_234)).prepare(versionA)
        await evidence.set(.running(
            profileID: versionA.profile.id,
            profileRevision: versionA.revision,
            sourceFingerprint: runtimeA.sourceFingerprint,
            configuration: runtimeA.data,
            liveSelections: ["group": "first"]
        ))
        let runtimeBeforeMutation = runtimeA.data

        let selectedB = try await policy.select(selectorTag: "group", outboundTag: "second")
        XCTAssertEqual(selectedB.selectors[0].effectiveDesired, "second")
        XCTAssertEqual(selectedB.selectors[0].runningSelection, "first")
        XCTAssertEqual(selectedB.selectors[0].runtimeConvergence, .restartRequired)
        XCTAssertTrue(selectedB.selectors[0].restartRequired)
        let runtimeAfterMutation = await evidence.configuration
        XCTAssertEqual(runtimeAfterMutation, runtimeBeforeMutation)

        let versionB = try store.selectedValidVersion()
        let runtimeB = try ProfileRuntimeConfigurationPreparer(portSelector: AutomationFixedPortSelector(port: 51_235)).prepare(versionB)
        await evidence.set(.running(
            profileID: versionB.profile.id,
            profileRevision: versionB.revision,
            sourceFingerprint: runtimeB.sourceFingerprint,
            configuration: runtimeB.data,
            liveSelections: ["group": "second"]
        ))
        let converged = try await policy.read()
        XCTAssertEqual(converged.selectors[0].runningSelection, "second")
        XCTAssertEqual(converged.selectors[0].runtimeConvergence, .converged)
        XCTAssertFalse(converged.selectors[0].restartRequired)
    }

    func testUnknownRuntimeEvidenceNeverClaimsConvergence() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root, checker: AutomationPassingChecker(), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Policy")
        try store.save(json: Self.runtimePolicyConfiguration, for: profile.id)
        let policy = TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: FixedPolicyRuntimeEvidence(value: .unavailable)
        )
        let catalog = try await policy.read()
        XCTAssertNil(catalog.selectors[0].runningSelection)
        XCTAssertEqual(catalog.selectors[0].runtimeConvergence, .unavailable)
        XCTAssertTrue(catalog.selectors[0].restartRequired)
    }

    func testConcurrentPolicySelectionsReturnTheirOwnCommittedState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root, checker: AutomationPassingChecker(), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Policy")
        try store.save(json: Self.runtimePolicyConfiguration, for: profile.id)
        let evidence = GatedFirstPolicyRuntimeEvidence()
        let policy = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: evidence)

        let firstTask = Task {
            try await policy.select(selectorTag: "group", outboundTag: "first")
        }
        await evidence.waitUntilFirstRead()
        let second = try await policy.select(selectorTag: "group", outboundTag: "second")
        await evidence.releaseFirstRead()
        let first = try await firstTask.value

        XCTAssertEqual(first.selectors[0].effectiveDesired, "first")
        XCTAssertEqual(second.selectors[0].effectiveDesired, "second")
        XCTAssertEqual(try policy.readPersisted().selectors[0].effectiveDesired, "second")
    }

    func testPolicySelectAutomationReturnsStableAllowlistedFactsAndErrors() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root, checker: AutomationPassingChecker(), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Policy")
        try store.save(json: Self.runtimePolicyConfiguration, for: profile.id)
        let shared = TargetPolicyOperations(profileStore: store)
        let operations = TargetAutomationOperations(
            profileStore: store,
            policyOperations: shared,
            backend: MockBackend()
        )
        let response = await operations.handle(AutomationRequest(
            protocolVersion: 1,
            action: "policy.select",
            arguments: ["selector": "group", "outbound": "second"]
        ))
        XCTAssertTrue(response.ok)
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""desiredSelection":"second""#))
        XCTAssertTrue(encoded.contains(#""runtimeConvergence":"notRunning""#))
        XCTAssertFalse(encoded.contains("AUTOMATION-SECRET"))

        let missing = await operations.handle(AutomationRequest(
            protocolVersion: 1,
            action: "policy.select",
            arguments: ["selector": "missing", "outbound": "second"]
        ))
        XCTAssertEqual(missing.error?.code, "policy_selector_not_found")
        let outbound = await operations.handle(AutomationRequest(
            protocolVersion: 1,
            action: "policy.select",
            arguments: ["selector": "group", "outbound": "missing"]
        ))
        XCTAssertEqual(outbound.error?.code, "policy_outbound_not_found")

        try store.save(
            json: #"{"inbounds":[],"outbounds":[{"type":"selector","tag":"group","outbounds":["duplicate","duplicate"]},{"type":"direct","tag":"duplicate"}]}"#,
            for: profile.id
        )
        let unavailableOutbound = await operations.handle(AutomationRequest(
            protocolVersion: 1,
            action: "policy.select",
            arguments: ["selector": "group", "outbound": "duplicate"]
        ))
        XCTAssertEqual(unavailableOutbound.error?.code, "policy_outbound_unavailable")

        try store.save(
            json: #"{"inbounds":[],"outbounds":[{"type":"selector","tag":"duplicate","outbounds":["first"]},{"type":"selector","tag":"duplicate","outbounds":["first"]},{"type":"direct","tag":"first"}]}"#,
            for: profile.id
        )
        let ambiguousSelector = await operations.handle(AutomationRequest(
            protocolVersion: 1,
            action: "policy.select",
            arguments: ["selector": "duplicate", "outbound": "first"]
        ))
        XCTAssertEqual(ambiguousSelector.error?.code, "policy_selector_ambiguous")
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

    func testProfileSubscribeAutomationUsesSharedOperationAndReturnsSafeFacts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            rootDirectory: root.appending(path: "Profiles"),
            checker: AutomationPassingChecker(),
            keyProvider: TestProfileKeyProvider()
        )
        let token = "automation-token-must-not-appear"
        let operations = TargetAutomationOperations(
            profileStore: store,
            subscriptionFetcher: AutomationSubscriptionFetcher(response: .init(
                data: Data("ss://YWVzLTEyOC1nY206dGVzdC1wYXNzd29yZA==@example.com:8388#Node".utf8),
                cacheStatus: .updated, etag: "v1", lastModified: nil
            )),
            backend: MockBackend()
        )
        let response = await operations.handle(.init(
            protocolVersion: 1,
            action: "profile.subscribe",
            arguments: ["name": "Provider", "url": "https://example.com/subscription/\(token)", "confirm": "true"]
        ))
        XCTAssertTrue(response.ok)
        let encoded = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertFalse(encoded.contains(token))
        XCTAssertFalse(encoded.contains("example.com"))
        XCTAssertFalse(encoded.contains("test-password"))
        XCTAssertTrue(encoded.contains("uri-list"))
        XCTAssertTrue(encoded.contains("nodeCount"))
        XCTAssertEqual(try store.listProfiles().count, 1)
    }

    func testSubscriptionAutomationErrorsAreStableAndCredentialSafe() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "error-token-must-not-appear"
        let operations = TargetAutomationOperations(
            profileStore: ProfileStore(
                rootDirectory: root.appending(path: "Profiles"),
                checker: AutomationPassingChecker(),
                keyProvider: TestProfileKeyProvider()
            ),
            subscriptionFetcher: AutomationSubscriptionFetcher(response: .init(
                data: Data("hysteria2://\(token)@example.com:443".utf8),
                cacheStatus: .updated, etag: nil, lastModified: nil
            )),
            backend: MockBackend()
        )
        let response = await operations.handle(.init(
            protocolVersion: 1,
            action: "profile.subscribe",
            arguments: ["name": "Provider", "url": "https://example.com/\(token)", "confirm": "true"]
        ))
        XCTAssertEqual(response.error?.code, "subscription_protocol_unsupported")
        XCTAssertFalse(String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self).contains(token))

        let variantOperations = TargetAutomationOperations(
            profileStore: ProfileStore(
                rootDirectory: root.appending(path: "VariantProfiles"),
                checker: AutomationPassingChecker(),
                keyProvider: TestProfileKeyProvider()
            ),
            subscriptionFetcher: AutomationSubscriptionFetcher(response: .init(
                data: Data("trojan://test-password@example.com:443?security=none".utf8),
                cacheStatus: .updated, etag: nil, lastModified: nil
            )),
            backend: MockBackend()
        )
        let variant = await variantOperations.handle(.init(
            protocolVersion: 1,
            action: "profile.subscribe",
            arguments: ["name": "Provider", "url": "https://example.com/variant", "confirm": "true"]
        ))
        XCTAssertEqual(variant.error?.code, "subscription_variant_unsupported")
    }

    func testProfileSubscriptionUpdateAutomationUsesStoredSourceAndConfirmation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            rootDirectory: root.appending(path: "Profiles"),
            checker: AutomationPassingChecker(),
            keyProvider: TestProfileKeyProvider()
        )
        let profile = try store.create(name: "Provider", subscriptionURL: URL(string: "https://example.com/stored-token")!)
        let operations = TargetAutomationOperations(
            profileStore: store,
            subscriptionFetcher: AutomationSubscriptionFetcher(response: .init(
                data: Data("trojan://test-password@example.com:443?security=tls&type=tcp#Node".utf8),
                cacheStatus: .updated, etag: "v2", lastModified: nil
            )),
            backend: MockBackend()
        )
        let id = profile.id.uuidString.lowercased()
        let denied = await operations.handle(.init(
            protocolVersion: 1, action: "profile.subscription-update", arguments: ["id": id, "confirm": "different"]
        ))
        XCTAssertEqual(denied.error?.code, "subscription_confirmation_required")
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).validRevision, profile.validRevision)

        let applied = await operations.handle(.init(
            protocolVersion: 1, action: "profile.subscription-update", arguments: ["id": id, "confirm": id]
        ))
        XCTAssertTrue(applied.ok)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).validRevision, profile.validRevision + 1)
        let encoded = String(decoding: AutomationProtocol.encodeResponse(applied), as: UTF8.self)
        XCTAssertFalse(encoded.contains("stored-token"))
        XCTAssertFalse(encoded.contains("test-password"))
        XCTAssertFalse(encoded.contains("example.com"))
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

    private static let runtimePolicyConfiguration = #"{"inbounds":[{"type":"mixed","tag":"local","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"selector","tag":"group","outbounds":["first","second"],"default":"first"},{"type":"direct","tag":"first"},{"type":"block","tag":"second"}],"route":{"final":"group"}}"#
}

private struct AutomationPassingChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}

private struct AutomationSubscriptionFetcher: ProfileSubscriptionFetching {
    let response: SubscriptionResponse
    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse { response }
}

private final class ResetManifestWriteFault: ProfileStorageFaultInjecting, @unchecked Sendable {
    var failManifestWrites = false

    func check(_ point: ProfileStorageFaultPoint) throws {
        guard failManifestWrites, point == .manifestWrite else { return }
        throw NSError(domain: "ResetManifestWriteFault", code: 1)
    }
}

private struct ResetErrorPolicyOperation: TargetPolicyOperating {
    func readPersisted() throws -> PolicyCatalog { throw ProfileStoreError.noValidVersion }
    func read() async throws -> PolicyCatalog { throw ProfileStoreError.noValidVersion }
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog { throw ProfileStoreError.noValidVersion }
    func reset() async throws -> PolicyResetResult { throw ProfileStoreError.noValidVersion }
}

private final class AutomationProbePolicyOperation: TargetPolicyOperating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PolicyLatencyProbeResult
    private var probes = 0
    private var selector: String?

    init(result: PolicyLatencyProbeResult) { self.result = result }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    var lastSelector: String? {
        lock.lock()
        defer { lock.unlock() }
        return selector
    }

    func readPersisted() throws -> PolicyCatalog { throw ProfileStoreError.noValidVersion }
    func read() async throws -> PolicyCatalog { throw ProfileStoreError.noValidVersion }
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog { throw ProfileStoreError.noValidVersion }
    func reset() async throws -> PolicyResetResult { throw ProfileStoreError.noValidVersion }

    func probeLatency(selectorTag: String) async throws -> PolicyLatencyProbeResult {
        lock.withLock {
            probes += 1
            selector = selectorTag
        }
        return result
    }
}

private actor AutomationConcurrencyTracker {
    private var active = 0
    private(set) var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}

private actor MutablePolicyRuntimeEvidence: PolicyRuntimeEvidenceProviding {
    private var value: PolicyRuntimeEvidence = .stopped
    func set(_ value: PolicyRuntimeEvidence) { self.value = value }
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { value }
    var configuration: Data? {
        guard case .running(_, _, _, let configuration, _) = value else { return nil }
        return configuration
    }
}

private struct FixedPolicyRuntimeEvidence: PolicyRuntimeEvidenceProviding {
    let value: PolicyRuntimeEvidence
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { value }
}

private actor GatedFirstPolicyRuntimeEvidence: PolicyRuntimeEvidenceProviding {
    private var readCount = 0
    private var firstReadContinuation: CheckedContinuation<Void, Never>?

    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence {
        readCount += 1
        if readCount == 1 {
            await withCheckedContinuation { continuation in
                firstReadContinuation = continuation
            }
        }
        return .stopped
    }

    func waitUntilFirstRead() async {
        while readCount == 0 { await Task.yield() }
    }

    func releaseFirstRead() {
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }
}

private struct AutomationFixedPortSelector: LocalEnginePortSelecting {
    let port: UInt16
    func selectAvailablePort() throws -> UInt16 { port }
}
