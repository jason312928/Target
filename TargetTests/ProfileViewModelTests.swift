import Foundation
import XCTest

@testable import Target

final class ProfileViewModelTests: XCTestCase, ProfileTestCaseSupport {
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
}
