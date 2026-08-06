import Darwin
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

        let pendingRoot = try temporaryDirectory()
        let pending = ProfileStore(rootDirectory: pendingRoot, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let pendingProfile = try pending.create(name: "No Pending")
        try Data("{}".utf8).write(to: pendingRoot.appending(path: "\(pendingProfile.id.uuidString)/.pending-check.json"))
        XCTAssertThrowsError(try pending.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .mixedOrDowngradedStorage) }
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

    func testBackupIsPreservedWhenEncryptedLiveKeyIsMissing() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        _ = try store.create(name: "Recovery")
        let backup = try installPlaintextBackup(for: root)
        let backupSnapshot = try treeSnapshot(backup)
        let createCount = keys.createCount
        keys.removeKey()

        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles()) {
            XCTAssertEqual($0 as? ProfileStoreError, .encryptedStoreKeyMissing)
        }
        XCTAssertEqual(try treeSnapshot(backup), backupSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(keys.createCount, createCount)
    }

    func testBackupIsPreservedWhenEncryptedLiveConfigurationTagIsDamaged() throws {
        try assertBackupPreservedAfterEncryptedLiveDamage { root, profile in
            try self.tamperLastByte(root.appending(path: "\(profile.id.uuidString)/config.json"))
        }
    }

    func testBackupIsPreservedWhenEncryptedLiveRevisionTagIsDamaged() throws {
        try assertBackupPreservedAfterEncryptedLiveDamage { root, profile in
            try self.tamperLastByte(root.appending(path: "\(profile.id.uuidString)/versions/1.json"))
        }
    }

    func testBackupIsPreservedWhenEncryptedLiveStructureIsInconsistent() throws {
        try assertBackupPreservedAfterEncryptedLiveDamage { root, _ in
            try Data("unknown".utf8).write(to: root.appending(path: "unknown.bin"))
        }
    }

    func testBackupIsDeletedOnlyAfterEncryptedLiveFullyValidates() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Recovery")
        let backup = try installPlaintextBackup(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        XCTAssertEqual(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles().map(\.id), [profile.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testBackupIsPreservedWhenEncryptedLiveUsesWrongKey() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        _ = try store.create(name: "Recovery")
        let backup = try installPlaintextBackup(for: root)
        let backupSnapshot = try treeSnapshot(backup)
        keys.replaceKey(Data(repeating: 4, count: 32))

        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles()) {
            XCTAssertEqual($0 as? ProfileStoreError, .encryptedStorageAuthenticationFailed)
        }
        XCTAssertEqual(try treeSnapshot(backup), backupSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testMissingLiveRestoresPlaintextBackupBeforeDiscardingStaging() throws {
        let root = try temporaryDirectory()
        let fixture = try writeLegacyFixture(root: root)
        let backup = plaintextBackupURL(for: root)
        let staging = root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).encrypted-staging")
        try FileManager.default.moveItem(at: root, to: backup)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: staging.appending(path: "stale.bin"))

        let store = ProfileStore(rootDirectory: root, keyProvider: TestProfileKeyProvider(key: nil))
        XCTAssertEqual(try store.configurationText(for: fixture.first.id), fixture.firstConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: ProfileEncryptedStorage.markerName).path))
    }

    func testValidEncryptedLiveIsAuthoritativeBeforeStaleStagingCleanup() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, keyProvider: keys)
        let profile = try store.create(name: "Authoritative")
        let staging = root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).encrypted-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: staging.appending(path: "stale.bin"))

        XCTAssertEqual(try store.listProfiles().map(\.id), [profile.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
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
        XCTAssertThrowsError(try store.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .invalidStoredMetadata) }
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

    func testMigrationRetainsRevisionsAboveValidRevisionByteForByte() throws {
        let root = try temporaryDirectory()
        let fixture = try writeLegacyFixture(root: root)
        let third = Data("{\"revision\":3,\"opaque\":true}\n".utf8)
        try third.write(to: root.appending(path: "\(fixture.first.id.uuidString)/versions/3.json"))
        let keys = TestProfileKeyProvider(key: nil)
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)

        let migrated = try XCTUnwrap(try store.listProfiles().first(where: { $0.id == fixture.first.id }))
        XCTAssertEqual(migrated.validRevision, 2)
        XCTAssertEqual(try store.configurationText(for: fixture.first.id), fixture.firstConfig)
        XCTAssertEqual(try store.validVersion(for: fixture.first.id, revision: 1).data, Data(fixture.firstVersion.utf8))
        XCTAssertEqual(try store.validVersion(for: fixture.first.id, revision: 2).data, Data(fixture.firstConfig.utf8))
        XCTAssertEqual(try store.validVersion(for: fixture.first.id, revision: 3).data, third)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plaintextBackupURL(for: root).path))
    }

    func testLegacyUnknownRootFileFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, _ in try Data("keep".utf8).write(to: root.appending(path: "unknown.bin")) }
    }

    func testLegacyUnknownRootDirectoryFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, _ in try FileManager.default.createDirectory(at: root.appending(path: "unknown"), withIntermediateDirectories: false) }
    }

    func testLegacyExtraUUIDProfileDirectoryFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, _ in try FileManager.default.createDirectory(at: root.appending(path: UUID().uuidString), withIntermediateDirectories: false) }
    }

    func testLegacyMissingManifestProfileDirectoryFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try FileManager.default.removeItem(at: root.appending(path: fixture.first.id.uuidString)) }
    }

    func testLegacyUnknownProfileFileFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try Data().write(to: root.appending(path: "\(fixture.first.id.uuidString)/unknown.bin")) }
    }

    func testLegacyUnknownProfileDirectoryFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try FileManager.default.createDirectory(at: root.appending(path: "\(fixture.first.id.uuidString)/unknown"), withIntermediateDirectories: false) }
    }

    func testLegacyNonJSONVersionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try Data().write(to: root.appending(path: "\(fixture.first.id.uuidString)/versions/3.txt")) }
    }

    func testLegacyNonnumericRevisionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try Data().write(to: root.appending(path: "\(fixture.first.id.uuidString)/versions/latest.json")) }
    }

    func testLegacyZeroRevisionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try Data().write(to: root.appending(path: "\(fixture.first.id.uuidString)/versions/0.json")) }
    }

    func testLegacyNegativeRevisionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try Data().write(to: root.appending(path: "\(fixture.first.id.uuidString)/versions/-1.json")) }
    }

    func testLegacyRevisionGapFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in try FileManager.default.removeItem(at: root.appending(path: "\(fixture.first.id.uuidString)/versions/1.json")) }
    }

    func testLegacyMissingValidRevisionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in
            var profiles = [fixture.first, fixture.second]
            profiles[0].validRevision = 3
            try JSONEncoder().encode(profiles).write(to: root.appending(path: "profiles.json"))
        }
    }

    func testLegacyNonpositiveValidRevisionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in
            var profiles = [fixture.first, fixture.second]
            profiles[0].validRevision = 0
            try JSONEncoder().encode(profiles).write(to: root.appending(path: "profiles.json"))
        }
    }

    func testLegacyCurrentConfigurationMismatchFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in
            try Data("different".utf8).write(to: root.appending(path: "\(fixture.first.id.uuidString)/config.json"))
        }
    }

    func testLegacyDuplicateProfileIDFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, fixture in
            try JSONEncoder().encode([fixture.first, fixture.first]).write(to: root.appending(path: "profiles.json"))
        }
    }

    func testLegacyInvalidSelectionUUIDFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, _ in try JSONEncoder().encode("not-a-uuid").write(to: root.appending(path: "selected-profile.json")) }
    }

    func testLegacySelectionOutsideManifestFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, _ in try JSONEncoder().encode(UUID().uuidString).write(to: root.appending(path: "selected-profile.json")) }
    }

    func testLegacyUndecodableSelectionFailsClosedBeforeMigration() throws {
        try assertLegacyMigrationRejected { root, _ in try Data("{".utf8).write(to: root.appending(path: "selected-profile.json")) }
    }

    func testPendingCheckRemainsWhenMigrationFailsBeforeCommit() throws {
        let root = try temporaryDirectory()
        let fixture = try writeLegacyFixture(root: root)
        let pending = root.appending(path: "\(fixture.first.id.uuidString)/.pending-check.json")
        let original = try Data(contentsOf: pending)
        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: TestProfileKeyProvider(key: nil), storageFaults: TestStorageFaults(failing: .beforeCommit)).listProfiles())
        XCTAssertEqual(try Data(contentsOf: pending), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ProfileEncryptedStorage.markerName).path))
    }

    func testSuccessfulMigrationExcludesPendingCheckAndKeepsLegalData() throws {
        let root = try temporaryDirectory()
        let fixture = try writeLegacyFixture(root: root)
        let store = ProfileStore(rootDirectory: root, keyProvider: TestProfileKeyProvider(key: nil))
        XCTAssertEqual(try store.configurationText(for: fixture.first.id), fixture.firstConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "\(fixture.first.id.uuidString)/.pending-check.json").path))
    }

    func testValidationTemporaryFileIsRemovedWhenPermissionSettingFails() throws {
        let root = try temporaryDirectory()
        let storage = ProfileValidationTemporaryStorage(profileRoot: root) { attributes, path in
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("validation-") { throw TemporaryTestError.expected }
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        }
        try installValidationNeighbor(in: storage.managedDirectory)
        XCTAssertThrowsError(try storage.withTemporaryConfiguration(Data("secret".utf8)) { _ in XCTFail("Body must not run") })
        try assertValidationDirectoryClean(storage.managedDirectory)
    }

    func testValidationTemporaryFileIsRemovedWhenBodyThrows() throws {
        try assertTemporaryCleanupAfterBodyError(TemporaryTestError.expected)
    }

    func testValidationTemporaryFileIsRemovedWhenBodyIsCancelled() throws {
        try assertTemporaryCleanupAfterBodyError(CancellationError())
    }

    func testValidationTemporaryFileIsRemovedWhenCheckerReturnsFailure() throws {
        let root = try temporaryDirectory()
        let storage = ProfileValidationTemporaryStorage(profileRoot: root)
        try installValidationNeighbor(in: storage.managedDirectory)
        let result: Result<Void, ConfigurationDiagnostic> = try storage.withTemporaryConfiguration(Data("secret".utf8)) { _ in
            .failure(ConfigurationDiagnostic(messageKey: "test", line: nil, column: nil))
        }
        if case .success = result { XCTFail("Expected checker failure") }
        try assertValidationDirectoryClean(storage.managedDirectory)
    }

    func testValidationTemporaryFileIsRemovedAfterSuccess() throws {
        let root = try temporaryDirectory()
        let storage = ProfileValidationTemporaryStorage(profileRoot: root)
        try installValidationNeighbor(in: storage.managedDirectory)
        XCTAssertEqual(try storage.withTemporaryConfiguration(Data("secret".utf8)) { _ in 42 }, 42)
        try assertValidationDirectoryClean(storage.managedDirectory)
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

    func testPreflightedImportBecomesRevisionOneAndPreservesRawBytes() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let existing = try store.create(name: "Existing")
        let source = Data("{\n  \"unknown_field\" : [ true, 7 ],\n  \"inbounds\" : [], \"outbounds\" : [], \"route\" : {}\n}\n".utf8)
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: source, suggestedName: "  Imported  ")

        let profile = try store.importCandidate(candidate, name: "  Imported  ")
        let restored = try ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider()).validVersion(for: profile.id, revision: 1)

        XCTAssertEqual(profile.validRevision, 1)
        XCTAssertEqual(profile.validation.status, .valid)
        XCTAssertNil(profile.subscription)
        XCTAssertEqual(restored.data, source)
        XCTAssertEqual(try store.configurationText(for: profile.id).data(using: .utf8), source)
        XCTAssertEqual(try store.availableValidVersions(for: profile.id).map(\.revision), [1])
        XCTAssertEqual(try store.selectedProfileID(), profile.id)
        XCTAssertNotEqual(try store.selectedProfileID(), existing.id)
    }

    func testImportPreflightRejectsInvalidInputsWithoutChangingProfileTree() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        _ = try store.create(name: "Existing")
        let before = try treeSnapshot(root)
        let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())))

        XCTAssertThrowsError(try service.prepareImport(data: Data([0xFF]), suggestedName: "bad")) { XCTAssertEqual($0 as? ProfileTransferError, .importInvalidUTF8) }
        XCTAssertThrowsError(try service.prepareImport(data: Data("{\"inbounds\":[}".utf8), suggestedName: "bad")) { XCTAssertEqual($0 as? ProfileTransferError, .importInvalidJSON) }
        XCTAssertEqual(try treeSnapshot(root), before)

        let failing = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: nil, column: nil))))
        XCTAssertThrowsError(try failing.prepareImport(data: Data("{}".utf8), suggestedName: "bad")) { XCTAssertEqual($0 as? ProfileTransferError, .importValidationFailed) }
        XCTAssertEqual(try treeSnapshot(root), before)
    }

    func testImportFileRejectsDirectorySymlinkAndSizeBoundary() throws {
        let root = try temporaryDirectory()
        let inputDirectory = root.deletingLastPathComponent().appending(path: "Input", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())))
        XCTAssertThrowsError(try service.prepareImport(from: inputDirectory)) { XCTAssertEqual($0 as? ProfileTransferError, .unreadableImport) }

        let source = inputDirectory.appending(path: "source.json")
        try Data("{}".utf8).write(to: source)
        let link = inputDirectory.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try service.prepareImport(from: link)) { XCTAssertEqual($0 as? ProfileTransferError, .unreadableImport) }

        let exact = Data("{}".utf8) + Data(repeating: 0x20, count: ProfileTransferService.maximumImportBytes - 2)
        let exactFile = inputDirectory.appending(path: "exact.json")
        try exact.write(to: exactFile)
        XCTAssertEqual(try service.prepareImport(from: exactFile).fileSize, ProfileTransferService.maximumImportBytes)

        let oversized = inputDirectory.appending(path: "oversized.json")
        try (exact + Data([0x20])).write(to: oversized)
        XCTAssertThrowsError(try service.prepareImport(from: oversized)) { XCTAssertEqual($0 as? ProfileTransferError, .importTooLarge) }
    }

    func testImportTransactionFailuresRestoreExistingTreeAndSelection() throws {
        for point in [
            ProfileTransferFaultPoint.importDirectoryCreation,
            .importCurrentConfigurationWrite,
            .importRevisionWrite,
            .importManifestWrite,
            .importSelectionWrite
        ] {
            let root = try temporaryDirectory()
            let keys = TestProfileKeyProvider()
            let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, transferFaults: TestTransferFaults(points: [point]))
            let existing = try store.create(name: "Existing")
            if point == .importSelectionWrite { try store.select(nil) }
            let before = try treeSnapshot(root)
            let selection = try store.selectedProfileID()
            let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: Data("{}".utf8), suggestedName: "Imported")

            XCTAssertThrowsError(try store.importCandidate(candidate, name: "Imported"))
            XCTAssertEqual(try treeSnapshot(root), before)
            let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
            XCTAssertEqual(try restored.listProfiles().map(\.id), [existing.id])
            XCTAssertEqual(try restored.selectedProfileID(), selection)
        }
    }

    func testManifestEnvelopeRestoreFailureKeepsJournalAndRecoversOnRestart() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let faults = ActionTransferFaults { point in
            if point == .importManifestWrite {
                operations.failingWriteName = "profiles.json"
                throw TemporaryTestError.expected
            }
        }
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, transferFaults: faults, importFileOperations: operations)
        let existing = try store.create(name: "Existing")
        let before = try treeSnapshot(root)
        let selection = try store.selectedProfileID()
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: Data("{}".utf8), suggestedName: "Imported")

        XCTAssertThrowsError(try store.importCandidate(candidate, name: "Imported")) {
            XCTAssertEqual($0 as? ProfileStoreError, .profileImportRecoveryFailed)
        }
        XCTAssertTrue(importJournalExists(for: root))
        operations.failingWriteName = nil
        let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertEqual(try restored.listProfiles().map(\.id), [existing.id])
        XCTAssertEqual(try restored.selectedProfileID(), selection)
        XCTAssertEqual(try treeSnapshot(root), before)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    func testSelectionEnvelopeRestoreFailureKeepsJournalAndRecoversOnRestart() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let faults = ActionTransferFaults { point in
            if point == .importSelectionWrite {
                operations.failingWriteName = "selected-profile.json"
                throw TemporaryTestError.expected
            }
        }
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, transferFaults: faults, importFileOperations: operations)
        let existing = try store.create(name: "Existing")
        try store.select(nil)
        let before = try treeSnapshot(root)
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: Data("{}".utf8), suggestedName: "Imported")

        XCTAssertThrowsError(try store.importCandidate(candidate, name: "Imported")) {
            XCTAssertEqual($0 as? ProfileStoreError, .profileImportRecoveryFailed)
        }
        XCTAssertTrue(importJournalExists(for: root))
        operations.failingWriteName = nil
        let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertEqual(try restored.listProfiles().map(\.id), [existing.id])
        XCTAssertNil(try restored.selectedProfileID())
        XCTAssertEqual(try treeSnapshot(root), before)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    func testProfileDirectoryRemovalFailureKeepsJournalAndRecoversOnRestart() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let faults = ActionTransferFaults { point in
            if point == .importManifestWrite {
                operations.failProfileDirectoryRemoval = true
                throw TemporaryTestError.expected
            }
        }
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, transferFaults: faults, importFileOperations: operations)
        let existing = try store.create(name: "Existing")
        let before = try treeSnapshot(root)
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: Data("{}".utf8), suggestedName: "Imported")

        XCTAssertThrowsError(try store.importCandidate(candidate, name: "Imported")) {
            XCTAssertEqual($0 as? ProfileStoreError, .profileImportRecoveryFailed)
        }
        XCTAssertTrue(importJournalExists(for: root))
        operations.failProfileDirectoryRemoval = false
        let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertEqual(try restored.listProfiles().map(\.id), [existing.id])
        XCTAssertEqual(try treeSnapshot(root), before)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    func testInterruptedImportStagesRollbackDeterministicallyOnNewStore() throws {
        for point in [
            ProfileTransferFaultPoint.importAfterDirectoryMove,
            .importAfterManifestCommit,
            .importAfterSelectionCommit
        ] {
            let root = try temporaryDirectory()
            let keys = TestProfileKeyProvider()
            let existingStore = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
            let existing = try existingStore.create(name: "Existing")
            let original = Data("{ \"preserved\" : true }\n".utf8)
            try existingStore.save(json: String(decoding: original, as: UTF8.self), for: existing.id)
            let selection = try existingStore.selectedProfileID()
            let before = try treeSnapshot(root)
            let faults = ActionTransferFaults { current in
                if current == point { throw ProfileImportInterruption.simulated }
            }
            let interrupted = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, transferFaults: faults)
            let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: Data("{\"imported\":true}".utf8), suggestedName: "Imported")

            XCTAssertThrowsError(try interrupted.importCandidate(candidate, name: "Imported")) {
                XCTAssertEqual($0 as? ProfileStoreError, .profileImportTransactionFailed)
            }
            XCTAssertTrue(importJournalExists(for: root))
            try assertImportTransactionIsOwnerOnlyAndJournalOmits(candidate.data, profileRoot: root)
            let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
            XCTAssertEqual(try restored.listProfiles().map(\.id), [existing.id])
            XCTAssertEqual(try restored.selectedProfileID(), selection)
            XCTAssertEqual(try restored.validVersion(for: existing.id, revision: 2).data, original)
            XCTAssertEqual(try treeSnapshot(root), before)
            XCTAssertFalse(importTransactionContainerExists(for: root))
        }
    }

    func testCompletedImportJournalRollsForwardAfterCleanupFailure() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let faults = ActionTransferFaults { point in
            if point == .importAfterSelectionCommit {
                operations.failingRemoveName = "manifest.envelope"
            }
        }
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, transferFaults: faults, importFileOperations: operations)
        _ = try store.create(name: "Existing")
        let importedBytes = Data("{\"completed\":true}".utf8)
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: importedBytes, suggestedName: "Imported")

        XCTAssertThrowsError(try store.importCandidate(candidate, name: "Imported")) {
            XCTAssertEqual($0 as? ProfileStoreError, .profileImportRecoveryFailed)
        }
        XCTAssertTrue(importJournalExists(for: root))
        operations.failingRemoveName = nil
        let restored = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        let profiles = try restored.listProfiles()
        let imported = try XCTUnwrap(profiles.first { $0.name == "Imported" })
        XCTAssertEqual(try restored.selectedProfileID(), imported.id)
        XCTAssertEqual(try restored.validVersion(for: imported.id, revision: 1).data, importedBytes)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    func testRollbackAuthenticatedCleanupDoesNotRequireDeletedManifestEnvelopeOnRestart() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let originalStore = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let existing = try originalStore.create(name: "Existing")
        let originalBytes = Data("{ \"preserved\" : true }\n".utf8)
        try originalStore.save(json: String(decoding: originalBytes, as: UTF8.self), for: existing.id)
        try originalStore.select(nil)
        let liveSnapshot = try treeSnapshot(root)
        let interrupted = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keys,
            transferFaults: ActionTransferFaults { point in
                if point == .importAfterSelectionCommit { throw ProfileImportInterruption.simulated }
            },
            importFileOperations: operations
        )
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())))
            .prepareImport(data: Data("{\"imported\":true}".utf8), suggestedName: "Imported")
        XCTAssertThrowsError(try interrupted.importCandidate(candidate, name: "Imported"))

        operations.failingRemoveName = "selection.envelope"
        let firstRecovery = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertThrowsError(try firstRecovery.listProfiles()) {
            XCTAssertEqual($0 as? ProfileStoreError, .profileImportRecoveryFailed)
        }
        let transaction = try XCTUnwrap(importTransactionDirectories(for: root).first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.appending(path: "manifest.envelope").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.appending(path: "selection.envelope").path))
        XCTAssertEqual(try importJournalStage(in: transaction), "rollbackAuthenticated")
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)

        let repeatedRecovery = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertThrowsError(try repeatedRecovery.listProfiles())
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)
        operations.failingRemoveName = nil

        let recovered = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertEqual(try recovered.listProfiles().map(\.id), [existing.id])
        XCTAssertNil(try recovered.selectedProfileID())
        XCTAssertEqual(try recovered.validVersion(for: existing.id, revision: 2).data, originalBytes)
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    func testRollbackAuthenticatedJournalWriteFailurePreservesBothEnvelopesForRetry() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let originalStore = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let existing = try originalStore.create(name: "Existing")
        let liveSnapshot = try treeSnapshot(root)
        let interrupted = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keys,
            transferFaults: ActionTransferFaults { point in
                if point == .importAfterManifestCommit { throw ProfileImportInterruption.simulated }
            },
            importFileOperations: operations
        )
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())))
            .prepareImport(data: Data("{\"imported\":true}".utf8), suggestedName: "Imported")
        XCTAssertThrowsError(try interrupted.importCandidate(candidate, name: "Imported"))

        operations.failingWriteName = "journal.json"
        let failedRecovery = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertThrowsError(try failedRecovery.listProfiles())
        let transaction = try XCTUnwrap(importTransactionDirectories(for: root).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.appending(path: "manifest.envelope").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.appending(path: "selection.envelope").path))
        XCTAssertNotEqual(try importJournalStage(in: transaction), "rollbackAuthenticated")
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)

        operations.failingWriteName = nil
        let recovered = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertEqual(try recovered.listProfiles().map(\.id), [existing.id])
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    func testRollbackAuthenticatedCleanupRetriesAfterJournalRemovalFailure() throws {
        try assertRollbackCleanupRecoversAfterRemovalFailure(named: "journal.json")
    }

    func testRollbackAuthenticatedCleanupRetriesAfterTransactionDirectoryRemovalFailure() throws {
        try assertRollbackCleanupRecoversAfterRemovalFailure(named: nil)
    }

    func testConfirmedImportCanExportIdenticalInputBytesWithoutResidue() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let input = Data("{\n \"unknown\": [3, true], \"secret\": \"synthetic\"\n}\n".utf8)
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(()))).prepareImport(data: input, suggestedName: "Round Trip")
        _ = try store.importCandidate(candidate, name: "Round Trip")
        let destinationDirectory = root.deletingLastPathComponent().appending(path: "RoundTripExport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appending(path: "profile.json")

        try store.exportSelectedProfile(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), input)
        XCTAssertFalse(importTransactionContainerExists(for: root))
        XCTAssertFalse(try containsExportTemporaryFile(in: destinationDirectory))
    }

    func testExportUsesLastPersistedRevisionAndCreatesOwnerOnlyFile() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Export / Test")
        let persisted = Data("{ \"inbounds\" : [], \"outbounds\" : [], \"route\" : {}, \"secret\" : \"synthetic\" }\n".utf8)
        try store.save(json: String(decoding: persisted, as: UTF8.self), for: profile.id)
        let directory = root.deletingLastPathComponent().appending(path: "Export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "profile.json")

        try store.exportSelectedProfile(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), persisted)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777, 0o600)
        XCTAssertEqual(ProfileTransferService.defaultExportFileName(for: " /Unsafe:\\Name\u{0000} "), "UnsafeName.json")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".target-profile-export-") }))
    }

    func testExportRejectsUnsafeDestinationsAndPreservesExistingFileOnFailure() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "Export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("{\"synthetic\":true}".utf8)
        let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())))
        XCTAssertThrowsError(try service.writeExport(data, to: directory)) { XCTAssertEqual($0 as? ProfileTransferError, .unsafeExportDestination) }

        let target = directory.appending(path: "target.json")
        let linked = directory.appending(path: "linked.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        XCTAssertThrowsError(try service.writeExport(data, to: linked)) { XCTAssertEqual($0 as? ProfileTransferError, .unsafeExportDestination) }
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))

        let existing = directory.appending(path: "existing.json")
        try Data("unchanged".utf8).write(to: existing)
        let failing = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())), faults: TestTransferFaults(points: [.exportBeforeCommit]))
        XCTAssertThrowsError(try failing.writeExport(data, to: existing)) { XCTAssertEqual($0 as? ProfileTransferError, .exportFailed) }
        XCTAssertEqual(try Data(contentsOf: existing), Data("unchanged".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".target-profile-export-") }))
    }

    func testExportRejectsDestinationReplacedBySymlinkWithoutTouchingLinkTarget() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "SymlinkRace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "profile.json")
        let linkTarget = directory.appending(path: "link-target.json")
        try Data("target-bytes".utf8).write(to: linkTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: linkTarget.path)
        let originalPermissions = (try FileManager.default.attributesOfItem(atPath: linkTarget.path)[.posixPermissions] as? NSNumber)?.intValue
        let faults = ActionTransferFaults { point in
            if point == .exportBeforeCommit {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: linkTarget)
            }
        }
        let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())), faults: faults)

        XCTAssertThrowsError(try service.writeExport(Data("new".utf8), to: destination)) {
            XCTAssertEqual($0 as? ProfileTransferError, .unsafeExportDestination)
        }
        XCTAssertEqual(try Data(contentsOf: linkTarget), Data("target-bytes".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: linkTarget.path)[.posixPermissions] as? NSNumber)?.intValue, originalPermissions)
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testExportRejectsDestinationReplacedByDirectory() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "DirectoryRace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "profile.json")
        let faults = ActionTransferFaults { point in
            if point == .exportBeforeCommit {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
        }
        let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())), faults: faults)

        XCTAssertThrowsError(try service.writeExport(Data("new".utf8), to: destination)) {
            XCTAssertEqual($0 as? ProfileTransferError, .unsafeExportDestination)
        }
        XCTAssertTrue((try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testExportRemainsBoundToOpenedDirectoryWhenParentPathIsReplaced() throws {
        let root = try temporaryDirectory()
        let parent = root.deletingLastPathComponent()
        let directory = parent.appending(path: "PinnedExport", directoryHint: .isDirectory)
        let openedDirectory = parent.appending(path: "PinnedExportOpened", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "profile.json")
        let faults = ActionTransferFaults { point in
            if point == .exportAfterDirectoryOpen {
                try FileManager.default.moveItem(at: directory, to: openedDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())), faults: faults)

        try service.writeExport(Data("pinned".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: openedDirectory.appending(path: "profile.json")), Data("pinned".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsExportTemporaryFile(in: openedDirectory))
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testEveryInjectedPreRenameFailurePreservesExistingTargetAndCleansTemporaryFile() throws {
        for point in [
            ProfileTransferFaultPoint.exportAfterDirectoryOpen,
            .exportAfterTemporaryCreate,
            .exportAfterWrite,
            .exportAfterPermissionValidation,
            .exportAfterFileSync,
            .exportBeforeCommit
        ] {
            let root = try temporaryDirectory()
            let directory = root.deletingLastPathComponent().appending(path: "ExportFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "profile.json")
            try Data("unchanged".utf8).write(to: destination)
            let faults = ActionTransferFaults { current in
                if current == point { throw TemporaryTestError.expected }
            }
            let service = ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())), faults: faults)

            XCTAssertThrowsError(try service.writeExport(Data("replacement".utf8), to: destination)) {
                XCTAssertEqual($0 as? ProfileTransferError, .exportFailed)
            }
            XCTAssertEqual(try Data(contentsOf: destination), Data("unchanged".utf8))
            XCTAssertFalse(try containsExportTemporaryFile(in: directory))
        }
    }

    func testPreRenameFailureRetriesTemporaryUnlinkAndLeavesNoPlaintextFile() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "RetryUnlink", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = ControllableExportFileOperations()
        operations.removeFailuresRemaining = 1
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(Data("plaintext-profile-json".utf8), to: directory.appending(path: "profile.json"))) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportFailed)
        }
        XCTAssertEqual(operations.removeAttempts, 2)
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testTruncateFailureStillRemovesTemporaryProfileJSONAndPreservesTarget() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "TruncateFailureRemoves", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "profile.json")
        try Data("unchanged-target".utf8).write(to: destination)
        let operations = ControllableExportFileOperations()
        operations.failTruncateBeforeEmptyVerification = true
        let plaintext = Data("{\"secret\":\"synthetic-truncate-failure\"}".utf8)
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(plaintext, to: destination)) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportCleanupFailed)
        }
        XCTAssertEqual(operations.truncateAttempts, 1)
        XCTAssertEqual(operations.removeAttempts, 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data("unchanged-target".utf8))
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testTruncateFailureRetriesTemporaryUnlinkUntilProfileJSONIsRemoved() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "TruncateFailureRetry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = ControllableExportFileOperations()
        operations.failTruncateBeforeEmptyVerification = true
        operations.removeFailuresRemaining = 1
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(Data("{\"secret\":\"synthetic-retry\"}".utf8), to: directory.appending(path: "profile.json"))) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportCleanupFailed)
        }
        XCTAssertEqual(operations.removeAttempts, 2)
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testTruncateAndUnlinkFailuresReportUnclearedProfileJSONResidueRisk() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "TruncateAndUnlinkFailure", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = ControllableExportFileOperations()
        operations.failTruncateBeforeEmptyVerification = true
        operations.alwaysFailRemove = true
        let plaintext = Data("{\"secret\":\"synthetic-uncleared-residue\"}".utf8)
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(plaintext, to: directory.appending(path: "profile.json"))) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportCleanupFailed)
        }
        XCTAssertEqual(operations.removeAttempts, 3)
        let temporary = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first {
            $0.lastPathComponent.hasPrefix(".target-profile-export-")
        })
        let residual = try Data(contentsOf: temporary)
        XCTAssertEqual(residual, plaintext)
        XCTAssertNotEqual(residual.count, 0)
        XCTAssertNotNil(residual.range(of: plaintext))
    }

    func testZeroLengthVerificationFailureStillRemovesTemporaryFile() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "EmptyVerificationFailure", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = ControllableExportFileOperations()
        operations.failZeroLengthVerificationAfterTruncate = true
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(Data("{\"secret\":\"synthetic-empty-verification\"}".utf8), to: directory.appending(path: "profile.json"))) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportCleanupFailed)
        }
        XCTAssertEqual(operations.truncateAttempts, 1)
        XCTAssertEqual(operations.removeAttempts, 1)
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testPersistentTemporaryUnlinkFailureReturnsCleanupErrorAndLeavesZeroByteOwnerOnlyFile() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "PersistentUnlink", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = ControllableExportFileOperations()
        operations.alwaysFailRemove = true
        let plaintext = Data("{\"secret\":\"synthetic\"}".utf8)
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(plaintext, to: directory.appending(path: "profile.json"))) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportCleanupFailed)
        }
        XCTAssertEqual(operations.removeAttempts, 3)
        let temporary = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first {
            $0.lastPathComponent.hasPrefix(".target-profile-export-")
        })
        let residual = try Data(contentsOf: temporary)
        XCTAssertEqual(residual.count, 0)
        XCTAssertNil(residual.range(of: plaintext))
        let permissions = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((permissions ?? 0) & 0o777, 0o600)
    }

    func testPreRenameCleanupRetriesTemporaryDescriptorCloseFailure() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "RetryClose", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = ControllableExportFileOperations()
        operations.fileCloseFailuresRemaining = 1
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            faults: TestTransferFaults(points: [.exportAfterWrite]),
            exportFileOperations: operations
        )

        XCTAssertThrowsError(try service.writeExport(Data("plaintext-profile-json".utf8), to: directory.appending(path: "profile.json"))) {
            XCTAssertEqual($0 as? ProfileTransferError, .exportFailed)
        }
        XCTAssertEqual(operations.fileCloseAttempts, 2)
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    func testExportPerformsNoTargetOperationAfterDescriptorRelativeRename() throws {
        let root = try temporaryDirectory()
        let directory = root.deletingLastPathComponent().appending(path: "RecordedExport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let operations = RecordingExportFileOperations()
        let service = ProfileTransferService(
            profileRoot: root,
            checker: TestChecker(result: .success(())),
            exportFileOperations: operations
        )

        try service.writeExport(Data("recorded".utf8), to: directory.appending(path: "profile.json"))
        guard let renameIndex = operations.events.lastIndex(of: .rename) else {
            return XCTFail("Expected descriptor-relative rename")
        }
        XCTAssertEqual(Array(operations.events.suffix(from: operations.events.index(after: renameIndex))), [.synchronize, .close, .close])
        XCTAssertFalse(try containsExportTemporaryFile(in: directory))
    }

    @MainActor
    func testViewModelDisablesExportForUnsavedEditorChanges() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Editor")
        let model = ProfileViewModel(store: store)

        XCTAssertEqual(model.selectedProfile?.id, profile.id)
        XCTAssertTrue(model.canExport)
        model.updateEditor("{\"changed\":true}")
        XCTAssertFalse(model.canExport)
        model.requestExport()
        XCTAssertEqual(model.messageKey, "profile.export.unsaved-changes")
    }

    @MainActor
    func testViewModelCancelsPreflightAndSelectionChangeDiscardsPreparedCandidate() async throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        let input = root.deletingLastPathComponent().appending(path: "candidate.json")
        try Data("{}".utf8).write(to: input)
        let model = ProfileViewModel(store: store)
        let beforeCancellation = try treeSnapshot(root)

        model.prepareImport(from: input)
        model.cancelPreparedImport()
        await Task.yield()
        XCTAssertNil(model.pendingImportCandidate)
        XCTAssertEqual(try treeSnapshot(root), beforeCancellation)

        model.prepareImport(from: input)
        for _ in 0..<100 where model.pendingImportCandidate == nil { await Task.yield() }
        XCTAssertNotNil(model.pendingImportCandidate)
        model.requestSelection(model.selectedID == first.id ? second.id : first.id)
        XCTAssertNil(model.pendingImportCandidate)
    }

    @MainActor
    func testViewModelExportSuccessCancellationAndFailureMessages() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        _ = try store.create(name: "Messages")
        let model = ProfileViewModel(store: store)
        let directory = root.deletingLastPathComponent().appending(path: "MessageExport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        model.requestExport()
        model.exportCancelled()
        XCTAssertEqual(model.messageKey, "profile.export.cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "cancelled.json").path))

        model.requestExport()
        model.exportSelectedProfile(to: directory.appending(path: "success.json"))
        XCTAssertEqual(model.messageKey, "profile.export.success")

        model.requestExport()
        model.exportSelectedProfile(to: directory)
        XCTAssertEqual(model.messageKey, "profile.export.error.unsafe-destination")
    }

    private func importTransactionRoot(for profileRoot: URL) -> URL {
        profileRoot.deletingLastPathComponent().appending(path: ".TargetProfileImport", directoryHint: .isDirectory)
    }

    private func importTransactionContainerExists(for profileRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: importTransactionRoot(for: profileRoot).path)
    }

    private func importJournalExists(for profileRoot: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: importTransactionRoot(for: profileRoot), includingPropertiesForKeys: nil) else { return false }
        return enumerator.compactMap { ($0 as? URL)?.lastPathComponent }.contains("journal.json")
    }

    private func importTransactionDirectories(for profileRoot: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: importTransactionRoot(for: profileRoot), includingPropertiesForKeys: nil)
    }

    private func importJournalStage(in transaction: URL) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: transaction.appending(path: "journal.json"))) as? [String: Any])
        return try XCTUnwrap(object["stage"] as? String)
    }

    private func assertRollbackCleanupRecoversAfterRemovalFailure(named failureName: String?) throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let operations = ControllableImportFileOperations(profileRoot: root)
        let originalStore = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let existing = try originalStore.create(name: "Existing")
        let liveSnapshot = try treeSnapshot(root)
        let interrupted = ProfileStore(
            rootDirectory: root,
            checker: TestChecker(result: .success(())),
            keyProvider: keys,
            transferFaults: ActionTransferFaults { point in
                if point == .importAfterDirectoryMove { throw ProfileImportInterruption.simulated }
            },
            importFileOperations: operations
        )
        let candidate = try ProfileTransferService(profileRoot: root, checker: TestChecker(result: .success(())))
            .prepareImport(data: Data("{\"imported\":true}".utf8), suggestedName: "Imported")
        XCTAssertThrowsError(try interrupted.importCandidate(candidate, name: "Imported"))
        let transaction = try XCTUnwrap(importTransactionDirectories(for: root).first)
        if let failureName {
            operations.failingRemoveName = failureName
        } else {
            operations.failingRemoveURL = transaction
        }

        let failedRecovery = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertThrowsError(try failedRecovery.listProfiles())
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.appending(path: "manifest.envelope").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.appending(path: "selection.envelope").path))
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)

        operations.failingRemoveName = nil
        operations.failingRemoveURL = nil
        let recovered = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, importFileOperations: operations)
        XCTAssertEqual(try recovered.listProfiles().map(\.id), [existing.id])
        XCTAssertEqual(try treeSnapshot(root), liveSnapshot)
        XCTAssertFalse(importTransactionContainerExists(for: root))
    }

    private func containsExportTemporaryFile(in directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".target-profile-export-") }
    }

    private func assertImportTransactionIsOwnerOnlyAndJournalOmits(_ plaintext: Data, profileRoot: URL) throws {
        let transactionRoot = importTransactionRoot(for: profileRoot)
        let transaction = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: transactionRoot, includingPropertiesForKeys: nil).first)
        for directory in [transactionRoot, transaction] {
            let permissions = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual((permissions ?? 0) & 0o777, 0o700)
        }
        for name in ["journal.json", "manifest.envelope", "selection.envelope"] {
            let file = transaction.appending(path: name)
            let permissions = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual((permissions ?? 0) & 0o777, 0o600)
        }
        XCTAssertNil(try Data(contentsOf: transaction.appending(path: "journal.json")).range(of: plaintext))
    }

    private func makeStore(checker: TestChecker = TestChecker(result: .success(()))) throws -> ProfileStore {
        ProfileStore(rootDirectory: try temporaryDirectory(), checker: checker, keyProvider: TestProfileKeyProvider())
    }

    private func assertBackupPreservedAfterEncryptedLiveDamage(
        _ damage: (URL, Profile) throws -> Void
    ) throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Recovery")
        let backup = try installPlaintextBackup(for: root)
        let backupSnapshot = try treeSnapshot(backup)
        try damage(root, profile)

        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles())
        XCTAssertEqual(try treeSnapshot(backup), backupSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    private func assertEncryptedTreeRejected(_ damage: (URL, Profile) throws -> Void) throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Integrity")
        try damage(root, profile)
        XCTAssertThrowsError(try store.listProfiles())
    }

    private func assertLegacyMigrationRejected(
        _ mutation: (URL, (first: Profile, second: Profile, firstConfig: String, firstVersion: String)) throws -> Void
    ) throws {
        let root = try temporaryDirectory()
        let fixture = try writeLegacyFixture(root: root)
        try mutation(root, fixture)
        let before = try treeSnapshot(root)
        let manifest = try Data(contentsOf: root.appending(path: "profiles.json"))
        let keys = TestProfileKeyProvider(key: nil)

        XCTAssertThrowsError(try ProfileStore(rootDirectory: root, keyProvider: keys).listProfiles()) {
            XCTAssertEqual($0 as? ProfileStoreError, .plaintextMigrationValidationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "profiles.json")), manifest)
        XCTAssertEqual(try treeSnapshot(root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ProfileEncryptedStorage.markerName).path))
        XCTAssertEqual(keys.createCount, 0)
    }

    private func installPlaintextBackup(for liveRoot: URL) throws -> URL {
        let source = try temporaryDirectory()
        _ = try writeLegacyFixture(root: source)
        let backup = plaintextBackupURL(for: liveRoot)
        try FileManager.default.copyItem(at: source, to: backup)
        return backup
    }

    private func plaintextBackupURL(for root: URL) -> URL {
        root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).plaintext-backup", directoryHint: .isDirectory)
    }

    private func tamperLastByte(_ url: URL) throws {
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0x01
        try data.write(to: url, options: .atomic)
    }

    private func treeSnapshot(_ root: URL) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appending(path: relative)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                snapshot[relative] = "directory"
            } else if values.isRegularFile == true {
                snapshot[relative] = try Data(contentsOf: url).base64EncodedString()
            }
        }
        return snapshot
    }

    private func installValidationNeighbor(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: directory.appending(path: "neighbor.txt"))
    }

    private func assertValidationDirectoryClean(_ directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("validation-") }))
        XCTAssertTrue(names.contains("neighbor.txt"))
    }

    private func assertTemporaryCleanupAfterBodyError(_ error: any Error) throws {
        let root = try temporaryDirectory()
        let storage = ProfileValidationTemporaryStorage(profileRoot: root)
        try installValidationNeighbor(in: storage.managedDirectory)
        XCTAssertThrowsError(try storage.withTemporaryConfiguration(Data("secret".utf8)) { _ -> Void in throw error })
        try assertValidationDirectoryClean(storage.managedDirectory)
    }

    private func temporaryDirectory() throws -> URL {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = container.appending(path: "Workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
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

private enum TemporaryTestError: Error {
    case expected
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

private final class TestTransferFaults: ProfileTransferFaultInjecting {
    let points: Set<ProfileTransferFaultPoint>
    init(points: Set<ProfileTransferFaultPoint>) { self.points = points }
    func check(_ point: ProfileTransferFaultPoint) throws {
        if points.contains(point) { throw NSError(domain: "TestTransferFaults", code: 1) }
    }
}

private final class ActionTransferFaults: ProfileTransferFaultInjecting {
    private let action: (ProfileTransferFaultPoint) throws -> Void
    init(_ action: @escaping (ProfileTransferFaultPoint) throws -> Void) { self.action = action }
    func check(_ point: ProfileTransferFaultPoint) throws { try action(point) }
}

private final class ControllableImportFileOperations: ProfileImportFileOperating {
    private let base = ProfileImportFileOperations()
    private let profileRoot: URL
    var failingWriteName: String?
    var failingRemoveName: String?
    var failingRemoveURL: URL?
    var failProfileDirectoryRemoval = false

    init(profileRoot: URL) { self.profileRoot = profileRoot.standardizedFileURL }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func readFile(at url: URL) throws -> Data { try base.readFile(at: url) }
    func writeOwnerOnly(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == failingWriteName { throw TemporaryTestError.expected }
        try base.writeOwnerOnly(data, to: url)
    }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws {
        if url.standardizedFileURL == failingRemoveURL?.standardizedFileURL { throw TemporaryTestError.expected }
        if url.lastPathComponent == failingRemoveName { throw TemporaryTestError.expected }
        if failProfileDirectoryRemoval,
           url.deletingLastPathComponent().standardizedFileURL == profileRoot,
           UUID(uuidString: url.lastPathComponent) != nil {
            throw TemporaryTestError.expected
        }
        try base.removeItem(at: url)
    }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func directoryContents(at url: URL) throws -> [URL] { try base.directoryContents(at: url) }
}

private final class RecordingExportFileOperations: ProfileExportFileOperating {
    enum Event: Equatable {
        case openDirectory
        case create
        case write
        case setPermissions
        case verify
        case truncate
        case synchronize
        case destinationInspection
        case rename
        case remove
        case close
    }

    private let base = ProfileExportFileOperations()
    private(set) var events: [Event] = []

    func openDirectory(atPath path: String) throws -> Int32 {
        events.append(.openDirectory)
        return try base.openDirectory(atPath: path)
    }
    func createExclusiveFile(named name: String, in directoryDescriptor: Int32) throws -> Int32 {
        events.append(.create)
        return try base.createExclusiveFile(named: name, in: directoryDescriptor)
    }
    func write(_ data: Data, to descriptor: Int32) throws {
        events.append(.write)
        try base.write(data, to: descriptor)
    }
    func setOwnerOnlyPermissions(on descriptor: Int32) throws {
        events.append(.setPermissions)
        try base.setOwnerOnlyPermissions(on: descriptor)
    }
    func verifyOwnerOnlyRegularFile(_ descriptor: Int32) throws {
        events.append(.verify)
        try base.verifyOwnerOnlyRegularFile(descriptor)
    }
    func truncateAndVerifyEmpty(_ descriptor: Int32) throws {
        events.append(.truncate)
        try base.truncateAndVerifyEmpty(descriptor)
    }
    func synchronize(_ descriptor: Int32) throws {
        events.append(.synchronize)
        try base.synchronize(descriptor)
    }
    func destinationKind(named name: String, in directoryDescriptor: Int32) throws -> ProfileExportDestinationKind {
        events.append(.destinationInspection)
        return try base.destinationKind(named: name, in: directoryDescriptor)
    }
    func rename(_ sourceName: String, to destinationName: String, in directoryDescriptor: Int32) throws {
        events.append(.rename)
        try base.rename(sourceName, to: destinationName, in: directoryDescriptor)
    }
    func remove(named name: String, in directoryDescriptor: Int32) throws {
        events.append(.remove)
        try base.remove(named: name, in: directoryDescriptor)
    }
    func close(_ descriptor: Int32) throws {
        events.append(.close)
        try base.close(descriptor)
    }
}

private final class ControllableExportFileOperations: ProfileExportFileOperating {
    private let base = ProfileExportFileOperations()
    var removeFailuresRemaining = 0
    var alwaysFailRemove = false
    var fileCloseFailuresRemaining = 0
    var failTruncateBeforeEmptyVerification = false
    var failZeroLengthVerificationAfterTruncate = false
    private(set) var removeAttempts = 0
    private(set) var fileCloseAttempts = 0
    private(set) var truncateAttempts = 0
    private var temporaryDescriptor: Int32 = -1

    func openDirectory(atPath path: String) throws -> Int32 {
        try base.openDirectory(atPath: path)
    }

    func createExclusiveFile(named name: String, in directoryDescriptor: Int32) throws -> Int32 {
        let descriptor = try base.createExclusiveFile(named: name, in: directoryDescriptor)
        temporaryDescriptor = descriptor
        return descriptor
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try base.write(data, to: descriptor)
    }

    func setOwnerOnlyPermissions(on descriptor: Int32) throws {
        try base.setOwnerOnlyPermissions(on: descriptor)
    }

    func verifyOwnerOnlyRegularFile(_ descriptor: Int32) throws {
        try base.verifyOwnerOnlyRegularFile(descriptor)
    }

    func truncateAndVerifyEmpty(_ descriptor: Int32) throws {
        truncateAttempts += 1
        if failTruncateBeforeEmptyVerification { throw TemporaryTestError.expected }
        if failZeroLengthVerificationAfterTruncate {
            guard Darwin.ftruncate(descriptor, 0) == 0 else { throw TemporaryTestError.expected }
            throw TemporaryTestError.expected
        }
        try base.truncateAndVerifyEmpty(descriptor)
    }

    func synchronize(_ descriptor: Int32) throws {
        try base.synchronize(descriptor)
    }

    func destinationKind(named name: String, in directoryDescriptor: Int32) throws -> ProfileExportDestinationKind {
        try base.destinationKind(named: name, in: directoryDescriptor)
    }

    func rename(_ sourceName: String, to destinationName: String, in directoryDescriptor: Int32) throws {
        try base.rename(sourceName, to: destinationName, in: directoryDescriptor)
    }

    func remove(named name: String, in directoryDescriptor: Int32) throws {
        removeAttempts += 1
        if alwaysFailRemove { throw TemporaryTestError.expected }
        if removeFailuresRemaining > 0 {
            removeFailuresRemaining -= 1
            throw TemporaryTestError.expected
        }
        try base.remove(named: name, in: directoryDescriptor)
    }

    func close(_ descriptor: Int32) throws {
        if descriptor == temporaryDescriptor {
            fileCloseAttempts += 1
            if fileCloseFailuresRemaining > 0 {
                fileCloseFailuresRemaining -= 1
                throw TemporaryTestError.expected
            }
            temporaryDescriptor = -1
        }
        try base.close(descriptor)
    }
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
