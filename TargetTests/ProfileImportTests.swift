import Foundation
import XCTest

@testable import Target

final class ProfileImportTests: XCTestCase, ProfileTestCaseSupport {
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
}
