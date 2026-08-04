import Foundation
import Network
import XCTest

@testable import Target

final class ProfileStoreTests: XCTestCase {
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
    }

    func testPlaintextLayoutMigratesAtomicallyAndRetainsRawBytes() throws {
        let root = try temporaryDirectory()
        let fixture = try writeLegacyFixture(root: root)
        let keys = TestProfileKeyProvider(key: nil)
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profiles = try store.listProfiles()
        XCTAssertEqual(Set(profiles.map(\.id)), Set([fixture.first.id, fixture.second.id]))
        XCTAssertEqual(try store.selectedProfileID(), fixture.second.id)
        XCTAssertEqual(try store.configurationText(for: fixture.first.id), fixture.firstConfig)
        XCTAssertEqual(try store.validVersion(for: fixture.first.id, revision: 1).data, Data(fixture.firstVersion.utf8))
        XCTAssertEqual(try store.validVersion(for: fixture.first.id, revision: 2).data, Data(fixture.firstConfig.utf8))
        XCTAssertEqual(try XCTUnwrap(try store.listProfiles().first { $0.id == fixture.first.id }).subscription?.etag, "fixture-etag")
        XCTAssertTrue((try Data(contentsOf: root.appending(path: "profiles.json"))).starts(with: Data([0x54, 0x50, 0x45, 0x31])))
        XCTAssertFalse(try recursiveData(in: root).contains(Data("fixture-subscription-secret".utf8)))
        XCTAssertNoThrow(try ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys).listProfiles())
    }

    func testMigrationFailuresLeaveRecoverableStateAndCanRetry() throws {
        for point in [ProfileStorageFaultPoint.stagingWrite, .beforeStagingVerification, .beforeCommit, .afterBackupRename] {
            let root = try temporaryDirectory()
            _ = try writeLegacyFixture(root: root)
            let legacyManifest = try Data(contentsOf: root.appending(path: "profiles.json"))
            let keys = TestProfileKeyProvider(key: nil)
            XCTAssertThrowsError(try ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: TestStorageFaults(failing: point)).listProfiles())
            XCTAssertEqual(try Data(contentsOf: root.appending(path: "profiles.json")), legacyManifest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "storage-format.json").path))
            XCTAssertEqual(try ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys).listProfiles().count, 2)
        }
        let committedRoot = try temporaryDirectory()
        _ = try writeLegacyFixture(root: committedRoot)
        let committedKeys = TestProfileKeyProvider(key: nil)
        XCTAssertThrowsError(try ProfileStore(rootDirectory: committedRoot, checker: TestChecker(result: .success(())), keyProvider: committedKeys, storageFaults: TestStorageFaults(failing: .afterLiveSwap)).listProfiles())
        XCTAssertEqual(try ProfileStore(rootDirectory: committedRoot, checker: TestChecker(result: .success(())), keyProvider: committedKeys).listProfiles().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedRoot.appending(path: "storage-format.json").path))
    }

    func testValidationTemporaryFilesAreRemovedWithoutTouchingNeighborFiles() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Temporary")
        try store.save(json: "{\"inbounds\":[],\"outbounds\":[],\"route\":{}}", for: profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.validationTemporaryDirectory.appending(path: "validation-orphan.json").path))
        let neighbor = root.deletingLastPathComponent().appending(path: "unrelated-neighbor.txt")
        try Data("keep".utf8).write(to: neighbor)
        _ = try ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider()).listProfiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
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
            XCTAssertEqual(error as? ProfileStoreError, .noValidVersion)
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

    func testSubscriptionETagAnd304WithLocalMockServer() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 200, headers: ["ETag": "v1", "Last-Modified": "Wed, 01 Jan 2025 00:00:00 GMT"], body: Data("{\"inbounds\":[]}".utf8)),
            .init(status: 304, headers: ["ETag": "v1"], body: Data())
        ])
        defer { server.stop() }
        let fetcher = SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 1, retryCount: 0)
        let initial = RemoteSubscription(url: server.url)
        let first = try await fetcher.fetch(subscription: initial)
        XCTAssertEqual(first.cacheStatus, .updated)
        let cached = RemoteSubscription(url: server.url, etag: first.etag, lastModified: first.lastModified)
        let second = try await fetcher.fetch(subscription: cached)
        XCTAssertEqual(second.cacheStatus, .notModified)
        XCTAssertTrue(server.requests.contains { $0.contains("If-None-Match: v1") })
    }

    func testSubscriptionTimeoutAndCancellationWithLocalMockServer() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 200, headers: [:], body: Data("{}".utf8), delay: 0.35),
            .init(status: 200, headers: [:], body: Data("{}".utf8), delay: 0.35)
        ])
        defer { server.stop() }
        let slow = SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 0.05, retryCount: 0)
        do {
            _ = try await slow.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected timeout")
        } catch let error as SubscriptionUpdateError {
            XCTAssertEqual(error, .timedOut)
        }

        let task = Task { try await SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 2, retryCount: 0).fetch(subscription: RemoteSubscription(url: server.url)) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as SubscriptionUpdateError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testSubscriptionRedirectAndPrivateOriginsAreRejected() async throws {
        let server = try MockHTTPServer(responses: [.init(status: 302, headers: ["Location": "http://example.com/redirect"], body: Data())])
        defer { server.stop() }
        let fetcher = SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 1, retryCount: 0)
        do {
            _ = try await fetcher.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected redirect rejection")
        } catch let error as SubscriptionUpdateError {
            XCTAssertEqual(error, .unsafeRedirect)
        }
        for string in ["file:///tmp/sub.json", "http://example.com/sub", "https://localhost/sub", "https://127.0.0.1/sub", "https://10.0.0.1/sub", "https://[::1]/sub"] {
            XCTAssertThrowsError(try SubscriptionURLPolicy.production.validate(try XCTUnwrap(URL(string: string))))
        }
    }

    func testSubscriptionRejectsLargeResponseFromLocalMockServer() async throws {
        let server = try MockHTTPServer(responses: [.init(status: 200, headers: [:], body: Data(repeating: 65, count: 2048))])
        defer { server.stop() }
        let fetcher = SecureSubscriptionFetcher(policy: .localMockTesting, maximumResponseBytes: 128, timeout: 1, retryCount: 0)
        do {
            _ = try await fetcher.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected response size rejection")
        } catch let error as SubscriptionUpdateError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testInvalidSubscriptionPreviewDoesNotReplaceCurrentVersion() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Subscription", subscriptionURL: URL(string: "https://example.com/sub")!)
        let original = try store.configurationText(for: profile.id)
        XCTAssertThrowsError(try store.previewSubscriptionUpdate(.init(data: Data("{\"inbounds\":[}".utf8), cacheStatus: .updated, etag: nil, lastModified: nil), for: profile.id))
        XCTAssertEqual(try store.configurationText(for: profile.id), original)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).subscription?.cacheStatus, .failed)
    }

    func testStructuredDiffAndRedactionNeverExposeSensitiveValues() throws {
        let old = Data(#"{"outbounds":[{"tag":"old","type":"direct"},{"tag":"removed","type":"direct"}],"route":{"final":"old"},"dns":{"servers":[{"address":"https://secret.example"}]},"inbounds":[{"tag":"in","type":"mixed"}],"custom":{"password":"old-secret"}}"#.utf8)
        let new = Data(#"{"outbounds":[{"tag":"new","type":"direct"},{"tag":"old","type":"block"}],"route":{"final":"new","rules":[{}]},"dns":{"servers":[{"address":"https://new-secret.example"}]},"inbounds":[{"tag":"in","type":"socks"}],"custom":{"password":"new-secret"}}"#.utf8)
        let diff = ProfileConfigurationDiff.make(current: old, candidate: new)
        XCTAssertEqual(diff.outbounds.added, ["new"])
        XCTAssertEqual(diff.outbounds.removed, ["removed"])
        XCTAssertEqual(diff.outbounds.modified, ["old"])
        XCTAssertTrue(diff.routeRules.hasChanges)
        XCTAssertTrue(diff.dns.hasChanges)
        XCTAssertTrue(diff.inbounds.hasChanges)
        XCTAssertTrue(diff.unknown.hasChanges)
        let redacted = SensitiveConfigurationRedactor.redactedJSON(new)
        XCTAssertFalse(redacted.contains("new-secret"))
        XCTAssertFalse(redacted.contains("https://new-secret"))
    }

    func testUserCancelsPreviewAndRunningProfileUpdateRequiresRestart() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Subscription", subscriptionURL: URL(string: "https://example.com/sub")!)
        let before = try store.configurationText(for: profile.id)
        let pending = try XCTUnwrap(try store.previewSubscriptionUpdate(.init(data: Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"version\":2}".utf8), cacheStatus: .updated, etag: "v2", lastModified: nil), for: profile.id))
        XCTAssertEqual(try store.configurationText(for: profile.id), before, "A preview must not save before confirmation")
        try store.recordSubscriptionCancellation(for: profile.id)
        XCTAssertEqual(try store.configurationText(for: profile.id), before)
        try store.applySubscriptionUpdate(pending)
        let updated = try XCTUnwrap(store.listProfiles().first)
        XCTAssertEqual(updated.subscription?.cacheStatus, .updated)
        XCTAssertGreaterThan(updated.validRevision, profile.validRevision)

        let record = EngineRuntimeRecord(pid: 42, executablePath: "/tmp/target", executableFingerprint: "x", endpoint: LocalEngineEndpoint(port: 51_234), profileID: profile.id, profileRevision: profile.validRevision, sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(Data(before.utf8)), configurationFingerprint: "runtime", startedAt: Date(), runtimeConfigurationID: UUID())
        XCTAssertTrue(EngineRuntimeProfileState.requiresRestart(record: record, selected: try store.selectedValidVersion()))
    }

    private func makeStore(checker: TestChecker = TestChecker(result: .success(()))) throws -> ProfileStore {
        ProfileStore(rootDirectory: try temporaryDirectory(), checker: checker, keyProvider: TestProfileKeyProvider())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var singBoxExecutable: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/sing-box/bin/sing-box")
    }

    private func recursiveData(in root: URL) throws -> Data {
        let urls = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        return try urls.reduce(into: Data()) { result, relative in
            let url = root.appending(path: relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { result += try Data(contentsOf: url) }
        }
    }

    private func writeLegacyFixture(root: URL) throws -> (first: Profile, second: Profile, firstConfig: String, firstVersion: String) {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Profile(id: UUID(), name: "Legacy One", subscription: RemoteSubscription(url: URL(string: "https://fixture-subscription-secret@example.invalid/sub")!, etag: "fixture-etag", lastModified: "fixture-last-modified", cacheStatus: .updated), createdAt: time, updatedAt: time, validation: ProfileValidation(status: .valid, checkedAt: time, error: nil), validRevision: 2)
        let second = Profile(id: UUID(), name: "Legacy Two", subscription: nil, createdAt: time, updatedAt: time, validation: .notChecked, validRevision: 1)
        let firstVersion = "{ \"z\": 1, \"unknown\": [ true ] }\n"
        let firstConfig = "{\n  \"unknown\" : [ true ], \"z\": 2\n}\n"
        let secondConfig = "{\"inbounds\":[],\"outbounds\":[],\"route\":{}}\n"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([first, second]).write(to: root.appending(path: "profiles.json"))
        try JSONEncoder().encode(second.id.uuidString).write(to: root.appending(path: "selected-profile.json"))
        for (profile, config, versions) in [(first, firstConfig, [firstVersion, firstConfig]), (second, secondConfig, [secondConfig])] {
            let directory = root.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory.appending(path: "versions"), withIntermediateDirectories: true)
            try Data(config.utf8).write(to: directory.appending(path: "config.json"))
            for (index, version) in versions.enumerated() { try Data(version.utf8).write(to: directory.appending(path: "versions/\(index + 1).json")) }
        }
        try Data("discard".utf8).write(to: root.appending(path: "\(first.id.uuidString)/.pending-check.json"))
        return (first, second, firstConfig, firstVersion)
    }
}

private final class TestChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    var result: Result<Void, ConfigurationDiagnostic>
    init(result: Result<Void, ConfigurationDiagnostic>) { self.result = result }
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { result }
}

final class TestProfileKeyProvider: ProfileEncryptionKeyProviding {
    private var key: Data?
    private(set) var createCount = 0
    init(key: Data? = Data(repeating: 7, count: 32)) { self.key = key }
    func loadMasterKey() throws -> Data? { key }
    func createMasterKey() throws -> Data {
        createCount += 1
        if key == nil { key = Data(repeating: 9, count: 32) }
        return key!
    }
    func removeKey() { key = nil }
    func replaceKey(_ value: Data) { key = value }
}

private final class TestStorageFaults: ProfileStorageFaultInjecting {
    let failing: ProfileStorageFaultPoint
    init(failing: ProfileStorageFaultPoint) { self.failing = failing }
    func check(_ point: ProfileStorageFaultPoint) throws { if point == failing { throw NSError(domain: "TestStorageFaults", code: 1) } }
}

private struct FixedPortSelector: LocalEnginePortSelecting {
    let port: UInt16
    func selectAvailablePort() throws -> UInt16 { port }
}

private struct FixedProfileUsage: ProfileRuntimeUsageChecking {
    let inUse: Bool
    func isProfileInUse(_ id: UUID) -> Bool { inUse }
}

private final class MockHTTPServer: @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: TimeInterval

        init(status: Int, headers: [String: String], body: Data, delay: TimeInterval = 0) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delay = delay
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TargetTests.MockHTTPServer")
    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requests: [String] = []
    private var port: UInt16 = 0

    init(responses: [Response]) throws {
        self.responses = responses
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let value = self?.listener.port?.rawValue {
                self?.port = value
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, port > 0 else {
            listener.cancel()
            throw NSError(domain: "MockHTTPServer", code: 1)
        }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/subscription")! }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            self.lock.lock()
            self.requests.append(request)
            let response = self.responses.isEmpty ? Response(status: 500, headers: [:], body: Data()) : self.responses.removeFirst()
            self.lock.unlock()
            self.queue.asyncAfter(deadline: .now() + response.delay) {
                var header = "HTTP/1.1 \(response.status) Test\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                for (name, value) in response.headers { header += "\(name): \(value)\r\n" }
                header += "\r\n"
                connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
