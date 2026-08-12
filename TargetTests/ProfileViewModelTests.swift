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

    func testPolicyWorkspacePresentationSeparatesStoppedConvergedRestartAndUnavailableRuntime() {
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .notRunning)).titleKey, "policy.workspace.runtime.not-running")
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .converged)).titleKey, "policy.workspace.runtime.converged")
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .restartRequired)).titleKey, "policy.catalog.restart-required")
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .unavailable)).titleKey, "policy.workspace.runtime.unavailable")
    }

    func testPolicyWorkspacePresentationSearchesCredentialSafeTagAndTypeFacts() {
        let catalog = PolicyCatalog(
            formatVersion: 1,
            profileID: nil,
            profileRevision: nil,
            sourceFingerprint: nil,
            storedOverrideCount: 1,
            selectors: [selector(runtime: .restartRequired)]
        )
        let presentation = PolicyWorkspacePresentation(catalog: catalog, unavailable: false)

        XCTAssertEqual(presentation.selectors(matching: "fast", filter: .all).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "vmess", filter: .all).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "missing", filter: .all).count, 0)
        XCTAssertEqual(presentation.selectors(matching: "", filter: .selected).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "", filter: .needsRestart).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "", filter: .issues).count, 0)
    }

    func testPolicyWorkspacePresentationTreatsStructuralMembersAsIssuesAndNotSelectable() {
        let invalidMember = PolicyCatalogMember(identity: 0, tag: "broken", type: nil, status: .missingReference)
        let invalidSelector = PolicyCatalogSelector(
            identity: 0,
            tag: "group",
            status: .available,
            configuredDefault: "broken",
            targetOverride: nil,
            overrideValid: false,
            effectiveDesired: "broken",
            runningSelection: nil,
            runtimeConvergence: .notRunning,
            restartRequired: false,
            members: [invalidMember]
        )
        let presentation = PolicySelectorPresentation(invalidSelector)

        XCTAssertTrue(presentation.hasIssue)
        XCTAssertFalse(presentation.isMutable)
        XCTAssertFalse(presentation.members[0].isSelectable)
    }

    private func selector(runtime: PolicyRuntimeConvergenceState) -> PolicyCatalogSelector {
        PolicyCatalogSelector(
            identity: 0,
            tag: "Fast Group",
            status: .available,
            configuredDefault: "direct",
            targetOverride: "fast",
            overrideValid: true,
            effectiveDesired: "fast",
            runningSelection: runtime == .notRunning ? nil : (runtime == .converged ? "fast" : "direct"),
            runtimeConvergence: runtime,
            restartRequired: runtime == .restartRequired,
            members: [
                PolicyCatalogMember(identity: 0, tag: "fast", type: "vmess", status: .available),
                PolicyCatalogMember(identity: 1, tag: "direct", type: "direct", status: .available)
            ]
        )
    }
}
