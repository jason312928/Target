import Darwin
import Foundation
import XCTest

@testable import Target

final class ProfileExportTests: XCTestCase, ProfileTestCaseSupport {
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
}
