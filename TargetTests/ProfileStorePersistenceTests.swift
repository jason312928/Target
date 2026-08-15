import Foundation
import XCTest

@testable import Target

final class ProfileStorePersistenceTests: XCTestCase, ProfileTestCaseSupport {
    func testAppBundleUpgradePreservesDefaultRootKeyIdentitySelectionAndConfiguration() throws {
        let expectedDefaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/Profiles", directoryHint: .isDirectory)
            .standardizedFileURL
        XCTAssertEqual(ProfileStore.defaultRootDirectory(), expectedDefaultRoot)
        XCTAssertEqual(KeychainProfileEncryptionKeyProvider.service, "com.jason312928.Target.profile-storage.v1")
        XCTAssertEqual(KeychainProfileEncryptionKeyProvider.account, "master-key-v1")

        let root = try temporaryDirectory()
        let keyProvider = TestProfileKeyProvider(key: Data(repeating: 0x4D, count: 32))
        let expectedConfiguration = #"{"inbounds":[],"outbounds":[{"type":"direct","tag":"upgrade-preservation"}],"route":{"final":"upgrade-preservation"}}"#
        let profileID: UUID

        do {
            let preUpdateStore = ProfileStore(
                rootDirectory: root,
                checker: TestChecker(result: .success(())),
                keyProvider: keyProvider
            )
            let profile = try preUpdateStore.create(name: "Updater Preservation Fixture")
            try preUpdateStore.save(json: expectedConfiguration, for: profile.id)
            try preUpdateStore.select(profile.id)
            profileID = profile.id
        }

        let postUpdateStore = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keyProvider
        )
        XCTAssertEqual(try postUpdateStore.listProfiles().map(\.id), [profileID])
        XCTAssertEqual(try postUpdateStore.selectedProfileID(), profileID)
        XCTAssertEqual(try postUpdateStore.configurationText(for: profileID), expectedConfiguration)
        XCTAssertEqual(keyProvider.createCount, 0)
    }

    func testConcurrentInitialStoreReadWaitsForAuthenticatedManifestAndSelection() throws {
        let root = try temporaryDirectory()
        let faults = BlockingInitialManifestWriteFault()
        let store = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: TestProfileKeyProvider(),
            storageFaults: faults
        )
        let results = ConcurrentProfileReadResults()
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        addTeardownBlock { faults.release() }

        DispatchQueue.global(qos: .userInitiated).async {
            results.recordFirst(Result { try store.listProfiles() })
            firstFinished.signal()
        }
        XCTAssertEqual(faults.waitUntilManifestWrite(), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            results.recordSecond(Result { try store.listProfiles() })
            secondFinished.signal()
        }
        faults.release()

        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        let firstResult = try XCTUnwrap(results.firstResult)
        let secondResult = try XCTUnwrap(results.secondResult)
        XCTAssertNoThrow(try firstResult.get())
        XCTAssertNoThrow(try secondResult.get())

        let profile = try store.create(name: "Recovered")
        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        XCTAssertEqual(try reopened.selectedProfileID(), profile.id)
        XCTAssertEqual(try reopened.selectedValidVersion().profile.id, profile.id)
        XCTAssertNoThrow(try reopened.configurationText(for: profile.id))
    }
    func testNewStoreEncryptsEveryPersistentRecordAndPreservesMetadataAfterRestart() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider(key: nil)
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let subscription = URL(string: "https://user:subscription-secret@example.invalid/path")!
        let profile = try store.create(name: "Encrypted Name", subscriptionURL: subscription)
        let json = "{\n  \"custom_secret\": \"configuration-secret\",\n  \"inbounds\": [], \"outbounds\": [], \"route\": {}\n}\n"
        try store.save(json: json, for: profile.id)

        let manifest = try store.safeManagedURL("profiles.json")
        let selection = try store.safeManagedURL("selected-profile.json")
        let config = try store.safeManagedURL("\(profile.id.uuidString)/config.json")
        let version = try store.safeManagedURL("\(profile.id.uuidString)/versions/2.json")
        for url in [manifest, selection, config, version] {
            let disk = try Data(contentsOf: url)
            XCTAssertTrue(disk.starts(with: Data([0x54, 0x50, 0x45, 0x31])))
            XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("configuration-secret"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        for directory in [root, root.appending(path: profile.id.uuidString), root.appending(path: "\(profile.id.uuidString)/versions")] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let allBytes = try recursiveData(in: root)
        for value in ["subscription-secret", "configuration-secret", "Encrypted Name"] { XCTAssertFalse(allBytes.contains(Data(value.utf8))) }
        XCTAssertGreaterThan(keys.createCount, 0)

        let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try restored.configurationText(for: profile.id), json)
        let restoredProfile = try XCTUnwrap(try restored.listProfiles().first)
        XCTAssertEqual(restoredProfile.subscription?.url, subscription)
        XCTAssertEqual(try restored.selectedProfileID(), profile.id)
    }

    func testEncryptedStoreFailsClosedForMissingWrongAndTamperedKeyMaterial() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Closed")
        let manifest = try store.safeManagedURL("profiles.json")
        let original = try Data(contentsOf: manifest)
        keys.removeKey()
        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStoreKeyMissing) }
        XCTAssertEqual(keys.createCount, 0)
        keys.replaceKey(Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAuthenticationFailed) }
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        keys.replaceKey(Data(repeating: 7, count: 32))
        var tampered = original
        tampered[tampered.count - 1] ^= 0x01
        try tampered.write(to: manifest, options: .atomic)
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAuthenticationFailed) }
        XCTAssertEqual(profile.id, profile.id)
    }

    func testEncryptedEnvelopeRejectsPathReplacementVersionChangeAndPlaintextDowngrade() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let first = try store.create(name: "One")
        let second = try store.create(name: "Two")
        let firstConfig = try store.safeManagedURL("\(first.id.uuidString)/config.json")
        let secondConfig = try store.safeManagedURL("\(second.id.uuidString)/config.json")
        try FileManager.default.removeItem(at: secondConfig)
        try FileManager.default.copyItem(at: firstConfig, to: secondConfig)
        XCTAssertThrowsError(try store.configurationText(for: second.id)) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAADMismatch) }

        let selection = try store.safeManagedURL("selected-profile.json")
        let manifest = try store.safeManagedURL("profiles.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.copyItem(at: selection, to: manifest)
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAADMismatch) }

        let cleanRoot = try temporaryDirectory()
        let clean = ProfileStore(rootDirectory: cleanRoot, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        _ = try clean.create(name: "Version")
        let cleanManifest = try clean.safeManagedURL("profiles.json")
        var future = try Data(contentsOf: cleanManifest)
        future[4] = 2
        try future.write(to: cleanManifest, options: .atomic)
        XCTAssertThrowsError(try clean.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .unsupportedStorageVersion) }

        let downgradeRoot = try temporaryDirectory()
        let downgrade = ProfileStore(rootDirectory: downgradeRoot, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        _ = try downgrade.create(name: "Downgrade")
        let downgradeManifest = try downgrade.safeManagedURL("profiles.json")
        try Data("[]".utf8).write(to: downgradeManifest, options: .atomic)
        XCTAssertThrowsError(try downgrade.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .mixedOrDowngradedStorage) }

        let pendingRoot = try temporaryDirectory()
        let pending = ProfileStore(rootDirectory: pendingRoot, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let pendingProfile = try pending.create(name: "No Pending")
        try Data("{}".utf8).write(to: pendingRoot.appending(path: "\(pendingProfile.id.uuidString)/.pending-check.json"))
        XCTAssertThrowsError(try pending.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .mixedOrDowngradedStorage) }
    }
    func testListProfilesAuthenticatesNonCurrentProfileConfiguration() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        _ = try store.create(name: "Current")
        let damaged = try store.create(name: "Damaged")
        try tamperLastByte(root.appending(path: "\(damaged.id.uuidString)/config.json"))
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAuthenticationFailed) }
    }

    func testListProfilesAuthenticatesEveryHistoricalRevision() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "History")
        try store.save(json: #"{"inbounds":[],"outbounds":[],"route":{},"revision":2}"#, for: profile.id)
        try tamperLastByte(root.appending(path: "\(profile.id.uuidString)/versions/1.json"))
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAuthenticationFailed) }
    }

    func testListProfilesRejectsMissingRevisionBeforeReturningManifest() throws {
        try assertEncryptedTreeRejected { root, profile in
            try FileManager.default.removeItem(at: root.appending(path: "\(profile.id.uuidString)/versions/1.json"))
        }
    }

    func testListProfilesRejectsUnknownUUIDDirectory() throws {
        try assertEncryptedTreeRejected { root, _ in
            try FileManager.default.createDirectory(at: root.appending(path: UUID().uuidString), withIntermediateDirectories: false)
        }
    }

    func testListProfilesRejectsManifestExternalDirectory() throws {
        try assertEncryptedTreeRejected { root, _ in
            try FileManager.default.createDirectory(at: root.appending(path: "external-profile"), withIntermediateDirectories: false)
        }
    }

    func testListProfilesRejectsUnknownProfileFile() throws {
        try assertEncryptedTreeRejected { root, profile in
            try Data().write(to: root.appending(path: "\(profile.id.uuidString)/unknown.bin"))
        }
    }

    func testListProfilesRejectsUnknownVersionsFile() throws {
        try assertEncryptedTreeRejected { root, profile in
            try Data().write(to: root.appending(path: "\(profile.id.uuidString)/versions/unknown.bin"))
        }
    }

    func testRevisionEnvelopeCannotBeSubstitutedAtAnotherRevisionPath() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "AAD")
        try store.save(json: #"{"inbounds":[],"outbounds":[],"route":{},"revision":2}"#, for: profile.id)
        let first = root.appending(path: "\(profile.id.uuidString)/versions/1.json")
        let second = root.appending(path: "\(profile.id.uuidString)/versions/2.json")
        try FileManager.default.removeItem(at: second)
        try FileManager.default.copyItem(at: first, to: second)
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAADMismatch) }
    }

    func testListProfilesRejectsAuthenticatedCurrentConfigurationMismatch() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, keyProvider: keys)
        let profile = try store.create(name: "Consistency")
        let storage = ProfileEncryptedStorage(root: root, keyProvider: keys)
        try storage.write(
            Data("different".utf8),
            kind: .currentConfiguration,
            logicalPath: "\(profile.id.uuidString)/config.json",
            url: root.appending(path: "\(profile.id.uuidString)/config.json")
        )
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .invalidStoredMetadata) }
    }

    func testEmptyStoreRepairsAuthenticatedStaleSelection() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, keyProvider: keys)
        XCTAssertEqual(try store.listProfiles(), [])
        let storage = ProfileEncryptedStorage(root: root, keyProvider: keys)
        try storage.write(
            try JSONEncoder().encode(UUID().uuidString),
            kind: .selection,
            logicalPath: "selected-profile.json",
            url: root.appending(path: "selected-profile.json")
        )

        let reopened = ProfileStore(rootDirectory: root, keyProvider: keys)
        XCTAssertEqual(try reopened.listProfiles(), [])
        XCTAssertNil(try reopened.selectedProfileID())
    }

    func testListProfilesRejectsAuthenticatedSelectionOutsideManifest() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, keyProvider: keys)
        _ = try store.create(name: "Selection")
        let storage = ProfileEncryptedStorage(root: root, keyProvider: keys)
        try storage.write(
            try JSONEncoder().encode(UUID().uuidString),
            kind: .selection,
            logicalPath: "selected-profile.json",
            url: root.appending(path: "selected-profile.json")
        )
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .invalidStoredSelection) }
    }

    func testListProfilesRejectsAuthenticatedDuplicateProfileIDs() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, keyProvider: keys)
        let profile = try store.create(name: "Duplicate")
        let storage = ProfileEncryptedStorage(root: root, keyProvider: keys)
        try storage.write(
            try JSONEncoder().encode([profile, profile]),
            kind: .manifest,
            logicalPath: "profiles.json",
            url: root.appending(path: "profiles.json")
        )
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .invalidStoredMetadata) }
    }
    func testRawJSONPreservesUnknownFieldsWithoutCodableRoundTrip() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Preservation")
        let source = "{\n  \"inbounds\": [],\n  \"outbounds\": [],\n  \"route\": {},\n  \"future_extension\": { \"new_field\": [1, true, \"unchanged\"] }\n}\n"

        try store.save(json: source, for: profile.id)

        XCTAssertEqual(try store.configurationText(for: profile.id), source)
        let object = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        XCTAssertNotNil((object?["future_extension"] as? [String: Any])?["new_field"])
    }

    func testInvalidConfigurationDoesNotReplaceLastValidVersion() throws {
        let checker = TestChecker(result: .success(()))
        let store = try makeStore(checker: checker)
        let profile = try store.create(name: "Safe")
        let valid = "{\"inbounds\":[],\"outbounds\":[],\"route\":{}}"
        try store.save(json: valid, for: profile.id)
        checker.result = .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: 3, column: 9))

        XCTAssertThrowsError(try store.save(json: "{\"inbounds\": [}", for: profile.id))
        XCTAssertEqual(try store.configurationText(for: profile.id), valid)
        XCTAssertEqual(try store.listProfiles().first?.validation.status, .invalid)
    }

    func testJSONSyntaxDiagnosticHasLineAndColumn() {
        let diagnostic = JSONSyntaxChecker.validate("{\n  \"inbounds\": [\n}")
        XCTAssertNotNil(diagnostic?.line)
        XCTAssertNotNil(diagnostic?.column)
    }

    func testProfileCRUDSelectionAndRemoteSubscriptionModel() throws {
        let store = try makeStore()
        let created = try store.create(name: "Original", subscriptionURL: URL(string: "https://user:secret@example.invalid/sub")!)
        XCTAssertEqual(try store.selectedProfileID(), created.id)
        XCTAssertTrue(try XCTUnwrap(store.listProfiles().first).hasRemoteSubscription)

        let duplicate = try store.duplicate(created.id, name: "Copy")
        try store.rename(duplicate.id, to: "Renamed")
        try store.select(duplicate.id)
        XCTAssertEqual(try store.selectedProfileID(), duplicate.id)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first { $0.id == duplicate.id }).name, "Renamed")
        try store.delete(created.id)
        XCTAssertEqual(try store.listProfiles().map(\.id), [duplicate.id])
    }

    func testDeletingSelectedProfileSelectsRemainingProfileBeforeTreeMutation() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let first = try store.create(name: "First")
        let selected = try store.create(name: "Selected")
        try store.select(selected.id)

        try store.delete(selected.id)

        let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.listProfiles().map(\.id), [first.id])
        XCTAssertEqual(try reopened.selectedProfileID(), first.id)
    }

    func testRedactionNeverReturnsSecretsOrPaths() {
        let input = "url=https://alice:secret@example.invalid/sub uuid=123e4567-e89b-12d3-a456-426614174000 \"password\":\"hunter2\" \"private_key\":\"private\" /Users/person/Library/Application Support/Target/config.json"
        let redacted = String(decoding: EngineLogRedactor.redact(Data(input.utf8)), as: UTF8.self)
        for secret in ["alice", "secret", "123e4567", "hunter2", "\"private\"", "/Users/person"] {
            XCTAssertFalse(redacted.contains(secret))
        }
    }

    func testConfigurationVersionsCanRestorePreviousValidVersion() throws {
        let store = try makeStore()
        let profile = try store.create(name: "History")
        let first = "{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"version\":1}"
        let second = "{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"version\":2}"
        try store.save(json: first, for: profile.id)
        try store.save(json: second, for: profile.id)
        try store.restorePreviousValidVersion(for: profile.id)
        XCTAssertEqual(try store.configurationText(for: profile.id), first)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).validRevision, 2)
    }

    func testPathsAreConfinedToTargetManagedRoot() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.safeManagedURL("../outside.json")) { error in
            XCTAssertEqual(error as? ProfileStoreError, .unsafePath)
        }
        XCTAssertThrowsError(try store.safeManagedURL("/tmp/outside.json"))
        XCTAssertNoThrow(try store.safeManagedURL("metadata.json"))
    }

    func testNoSelectedProfileCannotProvideLaunchVersion() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.selectedValidVersion()) { error in
            XCTAssertEqual(error as? ProfileStoreError, .noSelectedProfile)
        }
    }

    func testMissingRecentValidVersionCannotProvideLaunchVersion() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Missing Version")
        let version = try store.safeManagedURL("\(profile.id.uuidString)/versions/1.json")
        try FileManager.default.removeItem(at: version)
        XCTAssertThrowsError(try store.selectedValidVersion()) { error in
            XCTAssertEqual(error as? ProfileStoreError, .mixedOrDowngradedStorage)
        }
    }

    func testRuntimeCopyReplacesOnlyLocalPortAndLeavesSourceUntouched() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Dynamic Port")
        let source = SafeExampleConfiguration.json(port: 1080)
        try store.save(json: source, for: profile.id)
        let prepared = try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234))
            .prepare(store.selectedValidVersion())
        XCTAssertEqual(try store.configurationText(for: profile.id), source)
        let runtime = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let inbound = try XCTUnwrap((runtime["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["listen_port"] as? Int, 51_234)
        XCTAssertEqual(prepared.primaryPort, 51_234)
    }
    func testUnsafeOrInvalidProfileCannotPrepareRuntimeCopy() throws {
        let profile = Profile(
            id: UUID(), name: "Unsafe", subscription: nil, createdAt: Date(), updatedAt: Date(),
            validation: .notChecked, validRevision: 1
        )
        let version = ProfileConfigurationVersion(
            profile: profile, revision: 1,
            data: Data(#"{"inbounds":[{"type":"tun","listen":"127.0.0.1","listen_port":1}],"outbounds":[]}"#.utf8)
        )
        XCTAssertThrowsError(try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234)).prepare(version)) { error in
            XCTAssertEqual(error as? ProfileRuntimeConfigurationError, .unsafeConfiguration)
        }
    }

    func testRunningProfileCannotBeDeleted() throws {
        let usage = FixedProfileUsage(inUse: true)
        let store = ProfileStore(rootDirectory: try temporaryDirectory(), checker: TestChecker(result: .success(())), runtimeUsage: usage, keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Active")
        XCTAssertThrowsError(try store.delete(profile.id)) { error in
            XCTAssertEqual(error as? ProfileStoreError, .profileInUse)
        }
    }

    func testRuntimeConfigurationCleanupRemovesOnlyEphemeralCopy() throws {
        let root = try temporaryDirectory()
        let runtime = RuntimeConfigurationStore(directory: root.appending(path: "runtime", directoryHint: .isDirectory))
        let temporary = try runtime.write(Data("{}".utf8))
        XCTAssertTrue(runtime.exists(id: temporary.id))
        runtime.remove(id: temporary.id)
        XCTAssertFalse(runtime.exists(id: temporary.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testSingBoxCheckSubcommandIntegration() throws {
        let root = try temporaryDirectory()
        let executable = root.appending(path: "sing-box")
        let script = "#!/bin/sh\n[ \"$1\" = \"check\" ] && [ \"$2\" = \"-c\" ] && [ -f \"$3\" ]\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let configuration = root.appending(path: "config.json")
        try Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}".utf8).write(to: configuration)
        let checker = SingBoxConfigurationChecker(executableURL: executable)
        if case .failure(let diagnostic) = checker.check(configurationURL: configuration) {
            XCTFail("check unexpectedly failed with \(diagnostic.messageKey)")
        }
    }

    func testInstalledSingBoxChecksSafeExampleConfigurationWhenRequested() throws {
        guard FileManager.default.isExecutableFile(atPath: singBoxExecutable.path) else {
            throw XCTSkip("sing-box is not installed for localhost integration testing.")
        }
        let root = try temporaryDirectory()
        let configuration = root.appending(path: "safe-example.json")
        try Data(SafeExampleConfiguration.json().utf8).write(to: configuration)
        if case .failure(let diagnostic) = SingBoxConfigurationChecker().check(configurationURL: configuration) {
            XCTFail("sing-box check failed with \(diagnostic.messageKey)")
        }
    }

    private func assertEncryptedTreeRejected(_ damage: (URL, Profile) throws -> Void) throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Integrity")
        try damage(root, profile)
        XCTAssertThrowsError(try store.listProfiles())
    }

    private func tamperLastByte(_ url: URL) throws {
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0x01
        try data.write(to: url, options: .atomic)
    }


    private struct FixedProfileUsage: ProfileRuntimeUsageChecking {
        let inUse: Bool
        func isProfileInUse(_ id: UUID) -> Bool { inUse }
    }
}
