import Foundation
import XCTest

@testable import Target

final class ProfilePolicyPersistenceTests: XCTestCase, ProfileTestCaseSupport {
    func testPrePolicyProfileMetadataDecodesWithoutOverrides() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","createdAt":0,"updatedAt":0,"validation":{"status":"notChecked"},"validRevision":1}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let profile = try decoder.decode(Profile.self, from: data)
        XCTAssertEqual(profile.policyOverrides, [:])
        XCTAssertEqual(profile.routeBindings, [])
    }

    func testSiteRouteBindingNormalizesPersistsReassignsAndRemovesWithoutChangingSource() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Routes")
        let source = policyConfiguration(configuredDefault: "United States 01", members: ["United States 01", "Japan 01"])
        try store.save(json: source, for: profile.id)
        let version = try store.selectedValidVersion()
        let first = try XCTUnwrap(ProfileRouteBinding(domain: "Chat.OpenAI.COM.", outboundTag: "United States 01", countryCode: "us"))
        try store.persistRouteBinding(profileID: profile.id, expectedRevision: version.revision, binding: first)
        let replacement = try XCTUnwrap(ProfileRouteBinding(domain: "chat.openai.com", outboundTag: "Japan 01", countryCode: "JP"))
        try store.persistRouteBinding(profileID: profile.id, expectedRevision: version.revision, binding: replacement)

        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.selectedValidVersion().profile.routeBindings, [replacement])
        XCTAssertEqual(try reopened.configurationText(for: profile.id), source)
        XCTAssertEqual(try reopened.selectedValidVersion().revision, version.revision)
        let disk = try recursiveData(in: root)
        XCTAssertFalse(disk.contains(Data("chat.openai.com".utf8)))
        XCTAssertTrue(try reopened.removeRouteBinding(profileID: profile.id, expectedRevision: version.revision, domain: "CHAT.OPENAI.COM"))
        XCTAssertFalse(try reopened.removeRouteBinding(profileID: profile.id, expectedRevision: version.revision, domain: "chat.openai.com"))
    }

    func testRuntimeCopyPrependsValidSiteRoutesAndSkipsRemovedOutbounds() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Runtime Routes")
        let source = #"{"inbounds":[{"type":"mixed","tag":"local","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"selector","tag":"group","outbounds":["United States 01"],"default":"United States 01"},{"type":"direct","tag":"United States 01"}],"route":{"rules":[{"domain_suffix":["example.org"],"outbound":"group"}],"final":"group"}}"#
        try store.save(json: source, for: profile.id)
        let version = try store.selectedValidVersion()
        let active = try XCTUnwrap(ProfileRouteBinding(domain: "chat.openai.com", outboundTag: "United States 01", countryCode: "US"))
        try store.persistRouteBinding(profileID: profile.id, expectedRevision: version.revision, binding: active)

        let prepared = try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234))
            .prepare(store.selectedValidVersion())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0]["domain_suffix"] as? [String], ["chat.openai.com"])
        XCTAssertEqual(rules[0]["outbound"] as? String, "United States 01")
        XCTAssertEqual(rules[1]["outbound"] as? String, "group")

        try store.save(json: #"{"outbounds":[{"type":"direct","tag":"replacement"}],"route":{"final":"replacement"}}"#, for: profile.id)
        let refreshed = try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_235))
            .prepare(store.selectedValidVersion())
        let refreshedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: refreshed.data) as? [String: Any])
        XCTAssertNil((refreshedRoot["route"] as? [String: Any])?["rules"])
    }

    func testSiteRouteRejectsInvalidDomainsAndUnavailableOutbound() throws {
        XCTAssertNil(ProfileRouteBinding(domain: "localhost", outboundTag: "node", countryCode: "US"))
        XCTAssertNil(ProfileRouteBinding(domain: "127.0.0.1", outboundTag: "node", countryCode: "US"))
        XCTAssertNil(ProfileRouteBinding(domain: "example.local", outboundTag: "node", countryCode: "US"))
        XCTAssertNil(ProfileRouteBinding(domain: "example.com", outboundTag: "", countryCode: "US"))

        let store = try makeStore()
        let profile = try store.create(name: "Unavailable Route")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first"]), for: profile.id)
        let version = try store.selectedValidVersion()
        let binding = try XCTUnwrap(ProfileRouteBinding(domain: "chat.openai.com", outboundTag: "missing", countryCode: "US"))
        XCTAssertThrowsError(try store.persistRouteBinding(profileID: profile.id, expectedRevision: version.revision, binding: binding))
    }

    func testPolicySelectionPersistsEncryptedMetadataWithoutChangingSourceOrRevision() async throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Policy")
        let source = policyConfiguration(configuredDefault: "first", members: ["first", "second"])
        try store.save(json: source, for: profile.id)
        let before = try store.selectedValidVersion()

        _ = try await TargetPolicyOperations(profileStore: store).select(
            selectorTag: "group",
            outboundTag: "second"
        )

        let after = try store.selectedValidVersion()
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(try store.configurationText(for: profile.id), source)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([
            ProfileEncryptedStorage.markerName, "profiles.json", "selected-profile.json", profile.id.uuidString
        ]))
        let disk = try recursiveData(in: root)
        XCTAssertFalse(disk.contains(Data("group".utf8)))
        XCTAssertFalse(disk.contains(Data("second".utf8)))

        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.selectedValidVersion().profile.policyOverrides, ["group": "second"])
        XCTAssertEqual(try TargetPolicyOperations(profileStore: reopened).readPersisted().selectors[0].effectiveDesired, "second")
    }

    func testFailedPolicyPersistenceRetainsPreviousCommittedSelection() async throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let faults = MutableProfileStorageFaults()
        let store = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keys,
            storageFaults: faults
        )
        let profile = try store.create(name: "Policy")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: profile.id)
        let operations = TargetPolicyOperations(profileStore: store)
        _ = try await operations.select(selectorTag: "group", outboundTag: "first")
        faults.failing = .manifestWrite

        do {
            _ = try await operations.select(selectorTag: "group", outboundTag: "second")
            XCTFail("Expected persistence failure")
        } catch let error as TargetPolicyOperationError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        faults.failing = nil

        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.selectedValidVersion().profile.policyOverrides, ["group": "first"])
    }

    func testPolicyResetClearsAllOverridesWithoutChangingSourceRevisionOrHistory() async throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Policy")
        let source = #"{"outbounds":[{"type":"selector","tag":"one","outbounds":["a","b"],"default":"a"},{"type":"selector","tag":"two","outbounds":["c","d"],"default":"c"},{"type":"direct","tag":"a"},{"type":"block","tag":"b"},{"type":"direct","tag":"c"},{"type":"block","tag":"d"}]}"#
        try store.save(json: source, for: profile.id)
        let policy = TargetPolicyOperations(profileStore: store)
        _ = try await policy.select(selectorTag: "one", outboundTag: "b")
        _ = try await policy.select(selectorTag: "two", outboundTag: "d")
        let before = try store.selectedValidVersion()

        let reset = try await policy.reset()
        XCTAssertEqual(reset.clearedOverrideCount, 2)
        XCTAssertEqual(reset.catalog.storedOverrideCount, 0)
        XCTAssertEqual(reset.catalog.selectors.map(\.effectiveDesired), ["a", "c"])
        let after = try store.selectedValidVersion()
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(try store.availableValidVersions(for: profile.id).map(\.revision), [2, 1])

        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.selectedValidVersion().profile.policyOverrides, [:])
    }

    func testPolicyResetClearsOrphanedOverrideAndNoOpDoesNotWriteManifest() async throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let faults = MutableProfileStorageFaults()
        let store = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keys,
            storageFaults: faults
        )
        let profile = try store.create(name: "Policy")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: profile.id)
        _ = try await TargetPolicyOperations(profileStore: store).select(selectorTag: "group", outboundTag: "second")
        try store.save(json: #"{"outbounds":[{"type":"direct","tag":"direct"}]}"#, for: profile.id)
        XCTAssertEqual(try store.selectedValidVersion().profile.policyOverrides, ["group": "second"])

        let reset = try await TargetPolicyOperations(profileStore: store).reset()
        XCTAssertEqual(reset.clearedOverrideCount, 1)
        XCTAssertEqual(reset.catalog.storedOverrideCount, 0)
        XCTAssertTrue(reset.catalog.selectors.isEmpty)
        let beforeNoOp = try store.selectedValidVersion().profile
        faults.failing = .manifestWrite
        let noOp = try await TargetPolicyOperations(profileStore: store).reset()
        XCTAssertEqual(noOp.clearedOverrideCount, 0)
        XCTAssertEqual(try store.selectedValidVersion().profile.updatedAt, beforeNoOp.updatedAt)
        faults.failing = nil
    }

    func testPolicyResetRejectsWrongSelectionStaleRevisionAndRetainsCommittedOverridesOnFault() async throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let faults = MutableProfileStorageFaults()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: faults)
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: first.id)
        try store.select(first.id)
        _ = try await TargetPolicyOperations(profileStore: store).select(selectorTag: "group", outboundTag: "second")
        let revision = try store.selectedValidVersion().revision
        XCTAssertThrowsError(try store.clearPolicyOverrides(profileID: second.id, expectedRevision: 1)) {
            XCTAssertEqual($0 as? ProfileStoreError, .noSelectedProfile)
        }
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: first.id)
        XCTAssertThrowsError(try store.clearPolicyOverrides(profileID: first.id, expectedRevision: revision)) {
            XCTAssertEqual($0 as? ProfileStoreError, .noValidVersion)
        }
        faults.failing = .manifestWrite
        do {
            _ = try await TargetPolicyOperations(profileStore: store).reset()
            XCTFail("Expected persistence failure")
        } catch let error as TargetPolicyOperationError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        faults.failing = nil
        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.selectedValidVersion().profile.policyOverrides, ["group": "second"])
    }

    func testPolicySelectionAndResetCommitInSerializedOrder() async throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let faults = BlockingManifestWriteFault()
        let store = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keys,
            storageFaults: faults
        )
        let profile = try store.create(name: "Policy")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: profile.id)
        let policy = TargetPolicyOperations(profileStore: store)

        // A selection owns the shared commit lock while its manifest write is
        // explicitly gated. Reset may be invoked, but cannot commit first.
        faults.armNextManifestWrite()
        let selectFirst = Task.detached { try await policy.select(selectorTag: "group", outboundTag: "second") }
        XCTAssertEqual(faults.waitUntilBlocked(), .success)
        let resetStarted = DispatchSemaphore(value: 0)
        let resetAfterSelect = Task.detached {
            resetStarted.signal()
            return try await policy.reset()
        }
        XCTAssertEqual(resetStarted.wait(timeout: .now() + 2), .success)
        faults.release()
        let firstSelection = try await selectFirst.value
        let resetFollowingSelection = try await resetAfterSelect.value
        XCTAssertEqual(firstSelection.selectors.first?.effectiveDesired, "second")
        XCTAssertEqual(resetFollowingSelection.clearedOverrideCount, 1)
        XCTAssertEqual(try policy.readPersisted().selectors.first?.effectiveDesired, "first")

        // The inverse order must also hold: reset commits before the later
        // selection, so the final persisted desired choice is the selection.
        _ = try await policy.select(selectorTag: "group", outboundTag: "second")
        faults.armNextManifestWrite()
        let resetFirst = Task.detached { try await policy.reset() }
        XCTAssertEqual(faults.waitUntilBlocked(), .success)
        let selectStarted = DispatchSemaphore(value: 0)
        let selectAfterReset = Task.detached {
            selectStarted.signal()
            return try await policy.select(selectorTag: "group", outboundTag: "second")
        }
        XCTAssertEqual(selectStarted.wait(timeout: .now() + 2), .success)
        faults.release()
        let firstReset = try await resetFirst.value
        let selectionFollowingReset = try await selectAfterReset.value
        XCTAssertEqual(firstReset.clearedOverrideCount, 1)
        XCTAssertEqual(selectionFollowingReset.selectors.first?.effectiveDesired, "second")
        XCTAssertEqual(try policy.readPersisted().selectors.first?.effectiveDesired, "second")
    }

    func testPolicyOverrideReconcilesAcrossSaveAndRestoreWithoutApplyingStaleChoice() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Policy History")
        let first = policyConfiguration(configuredDefault: "first", members: ["first", "second"])
        try store.save(json: first, for: profile.id)
        let operations = TargetPolicyOperations(profileStore: store)
        _ = try await operations.select(selectorTag: "group", outboundTag: "second")

        let stillValid = policyConfiguration(configuredDefault: "first", members: ["second", "first"])
        try store.save(json: stillValid, for: profile.id)
        var catalog = try operations.readPersisted()
        XCTAssertTrue(catalog.selectors[0].overrideValid)
        XCTAssertEqual(catalog.selectors[0].effectiveDesired, "second")

        let removed = policyConfiguration(configuredDefault: "first", members: ["first"])
        try store.save(json: removed, for: profile.id)
        catalog = try operations.readPersisted()
        XCTAssertEqual(catalog.selectors[0].targetOverride, "second")
        XCTAssertFalse(catalog.selectors[0].overrideValid)
        XCTAssertEqual(catalog.selectors[0].effectiveDesired, "first")
        let prepared = try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234))
            .prepare(store.selectedValidVersion())
        let runtime = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let selector = try XCTUnwrap((runtime["outbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(selector["default"] as? String, "first")

        try store.restorePreviousValidVersion(for: profile.id)
        catalog = try operations.readPersisted()
        XCTAssertTrue(catalog.selectors[0].overrideValid)
        XCTAssertEqual(catalog.selectors[0].effectiveDesired, "second")
    }

    func testSubscriptionApplicationReconcilesStalePolicyOverride() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Remote", subscriptionURL: URL(string: "https://example.invalid/sub")!)
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: profile.id)
        let operations = TargetPolicyOperations(profileStore: store)
        _ = try await operations.select(selectorTag: "group", outboundTag: "second")
        let replacement = policyConfiguration(configuredDefault: "first", members: ["first"])
        let response = SubscriptionResponse(data: Data(replacement.utf8), cacheStatus: .updated, etag: "v2", lastModified: nil)
        let pending = try XCTUnwrap(store.previewSubscriptionUpdate(response, for: profile.id))
        try store.applySubscriptionUpdate(pending)
        let catalog = try operations.readPersisted()
        XCTAssertEqual(catalog.selectors[0].targetOverride, "second")
        XCTAssertFalse(catalog.selectors[0].overrideValid)
        XCTAssertEqual(catalog.selectors[0].effectiveDesired, "first")
    }
    func testRuntimeCopyAppliesOnlyValidPolicyOverrideToEphemeralJSON() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Runtime Policy")
        let source = policyConfiguration(configuredDefault: "first", members: ["first", "second"])
        try store.save(json: source, for: profile.id)
        let revision = try store.selectedValidVersion().revision
        _ = try await TargetPolicyOperations(profileStore: store).select(selectorTag: "group", outboundTag: "second")

        let prepared = try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234))
            .prepare(store.selectedValidVersion())
        XCTAssertEqual(try store.configurationText(for: profile.id), source)
        XCTAssertEqual(try store.selectedValidVersion().revision, revision)
        let runtime = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let selector = try XCTUnwrap((runtime["outbounds"] as? [[String: Any]])?.first)
        let inbound = try XCTUnwrap((runtime["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(selector["default"] as? String, "second")
        XCTAssertEqual(inbound["listen_port"] as? Int, 51_234)
    }

}
