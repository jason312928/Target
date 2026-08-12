import Foundation
import XCTest

@testable import Target

final class ProfileStoreRecoveryTests: XCTestCase, ProfileTestCaseSupport {
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

}
