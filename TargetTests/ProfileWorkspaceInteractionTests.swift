import Foundation
import XCTest

@testable import Target

@MainActor
final class ProfileWorkspaceInteractionTests: XCTestCase {
    func testDirtySelectionRequestRecordsOperationWithoutChangingCommittedEditorState() throws {
        let fixture = try makeFixture()
        fixture.model.updateEditor("{\"edited\":true}")

        fixture.model.requestSelection(fixture.second.id)

        XCTAssertEqual(fixture.model.selectedID, fixture.first.id)
        XCTAssertEqual(fixture.model.editorText, "{\"edited\":true}")
        XCTAssertTrue(fixture.model.isDirty)
        guard case .select(let id)? = fixture.model.pendingOperation else {
            return XCTFail("Expected a pending selection")
        }
        XCTAssertEqual(id, fixture.second.id)
    }

    func testCancellingDirtySelectionLeavesPersistentAndEditorStateUntouched() throws {
        let fixture = try makeFixture()
        fixture.model.updateEditor("{\"edited\":true}")
        fixture.model.requestSelection(fixture.second.id)
        fixture.model.resolveUnsavedChanges(.cancel)

        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertEqual(fixture.model.selectedID, fixture.first.id)
        XCTAssertEqual(try fixture.store.selectedProfileID(), fixture.first.id)
        XCTAssertEqual(fixture.model.editorText, "{\"edited\":true}")
        XCTAssertTrue(fixture.model.isDirty)
    }

    func testDiscardingDirtySelectionLoadsTargetOnce() throws {
        let fixture = try makeFixture()
        let targetText = try fixture.store.configurationText(for: fixture.second.id)
        fixture.model.updateEditor("{\"edited\":true}")
        fixture.model.requestSelection(fixture.second.id)
        fixture.model.resolveUnsavedChanges(.discardChanges)

        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertEqual(fixture.model.selectedID, fixture.second.id)
        XCTAssertEqual(try fixture.store.selectedProfileID(), fixture.second.id)
        XCTAssertEqual(fixture.model.editorText, targetText)
        XCTAssertFalse(fixture.model.isDirty)
    }

    func testSavingDirtySelectionPersistsBeforeSwitching() throws {
        let fixture = try makeFixture()
        let saved = "{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"saved\":true}"
        fixture.model.updateEditor(saved)
        fixture.model.requestSelection(fixture.second.id)
        fixture.model.resolveUnsavedChanges(.saveAndContinue)

        XCTAssertEqual(try fixture.store.configurationText(for: fixture.first.id), saved)
        XCTAssertEqual(fixture.model.selectedID, fixture.second.id)
        XCTAssertFalse(fixture.model.isDirty)
    }

    func testDiscardingPendingCreationExecutesOnlyOnce() throws {
        let fixture = try makeFixture()
        fixture.model.updateEditor("{\"edited\":true}")
        fixture.model.requestCreate(name: "Created")
        fixture.model.resolveUnsavedChanges(.discardChanges)

        XCTAssertEqual(fixture.model.profiles.count, 3)
        XCTAssertEqual(fixture.model.selectedProfile?.name, "Created")
        fixture.model.resolveUnsavedChanges(.discardChanges)
        XCTAssertEqual(fixture.model.profiles.count, 3)
    }

    func testSaveFailureDoesNotExecutePendingOperationOrLoseEditor() throws {
        let fixture = try makeFixture(checker: InteractionChecker(result: .failure(.init(messageKey: "profile.validation.check-failed", line: nil, column: nil))))
        fixture.model.updateEditor("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}")
        fixture.model.requestSelection(fixture.second.id)
        fixture.model.resolveUnsavedChanges(.saveAndContinue)

        XCTAssertEqual(fixture.model.selectedID, fixture.first.id)
        XCTAssertEqual(try fixture.store.selectedProfileID(), fixture.first.id)
        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertEqual(fixture.model.diagnostic?.messageKey, "profile.validation.check-failed")
        guard case .select(let id)? = fixture.model.pendingOperation else {
            return XCTFail("The failed save must retain the pending action")
        }
        XCTAssertEqual(id, fixture.second.id)
    }

    func testDirtyReplacingOperationsArePendingWhileRenamePreservesEditor() async throws {
        let fixture = try makeFixture()
        fixture.model.updateEditor("{\"edited\":true}")

        fixture.model.rename(fixture.first.id, to: "Renamed")
        XCTAssertEqual(fixture.model.editorText, "{\"edited\":true}")
        XCTAssertTrue(fixture.model.isDirty)

        fixture.model.requestCreate(name: "New")
        assertPending(.create, in: fixture.model)
        fixture.model.resolveUnsavedChanges(.cancel)
        fixture.model.requestDuplicate(fixture.first.id)
        assertPending(.duplicate, in: fixture.model)
        fixture.model.resolveUnsavedChanges(.cancel)
        fixture.model.requestDelete(fixture.first.id)
        assertPending(.delete, in: fixture.model)
        fixture.model.resolveUnsavedChanges(.cancel)
        fixture.model.requestRestore(fixture.first.id)
        assertPending(.restore, in: fixture.model)
        fixture.model.resolveUnsavedChanges(.cancel)

        let importURL = FileManager.default.temporaryDirectory.appending(path: "TargetProfileInteractionImport-\(UUID().uuidString).json")
        try Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}".utf8).write(to: importURL)
        defer { try? FileManager.default.removeItem(at: importURL) }
        fixture.model.prepareImport(from: importURL)
        for _ in 0..<100 where fixture.model.pendingImportCandidate == nil { await Task.yield() }
        XCTAssertNotNil(fixture.model.pendingImportCandidate)
        fixture.model.commitPreparedImport(name: "Imported")
        guard case .importCandidate? = fixture.model.pendingOperation else {
            return XCTFail("Dirty import commit must ask first")
        }
    }

    func testSubscriptionMetadataCompletionsPreserveEditsAndCandidateApplyUsesSameDecision() async throws {
        for outcome in SubscriptionOutcome.allCases {
            let fixture = try makeFixture(subscriptionFetcher: DelayedSubscriptionFetcher(outcome: outcome))
            fixture.model.updateEditor("{\"edited\":true}")
            fixture.model.updateSubscription()
            try await waitForSubscriptionCompletion(fixture.model)

            XCTAssertEqual(fixture.model.editorText, "{\"edited\":true}", "\(outcome) must not overwrite editor text")
            XCTAssertTrue(fixture.model.isDirty, "\(outcome) must retain dirty state")
            switch outcome {
            case .updated:
                XCTAssertNotNil(fixture.model.pendingSubscriptionUpdate)
                fixture.model.confirmSubscriptionUpdate()
                guard case .applySubscription? = fixture.model.pendingOperation else {
                    return XCTFail("Applying a candidate with edits must ask first")
                }
                fixture.model.resolveUnsavedChanges(.discardChanges)
                XCTAssertTrue(fixture.model.editorText.contains("\"updated\":true"))
                let revision = fixture.model.selectedProfile?.validRevision
                fixture.model.resolveUnsavedChanges(.discardChanges)
                XCTAssertEqual(fixture.model.selectedProfile?.validRevision, revision)
            case .notModified, .failure, .cancelled:
                XCTAssertNil(fixture.model.pendingSubscriptionUpdate)
            }
        }
    }

    private func assertPending(_ kind: PendingKind, in model: ProfileViewModel, file: StaticString = #filePath, line: UInt = #line) {
        let matches: Bool
        switch (kind, model.pendingOperation) {
        case (.create, .create?), (.duplicate, .duplicate?), (.delete, .delete?), (.restore, .restore?): matches = true
        default: matches = false
        }
        XCTAssertTrue(matches, "Expected pending \(kind)", file: file, line: line)
    }

    private func waitForSubscriptionCompletion(_ model: ProfileViewModel) async throws {
        for _ in 0..<100 where model.isUpdatingSubscription {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isUpdatingSubscription)
    }

    private func makeFixture(
        checker: InteractionChecker = InteractionChecker(result: .success(())),
        subscriptionFetcher: any ProfileSubscriptionFetching = DelayedSubscriptionFetcher(outcome: .notModified)
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "TargetProfileInteraction-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ProfileStore(rootDirectory: root, checker: checker, keyProvider: InteractionKeyProvider())
        let first = try store.create(name: "First", subscriptionURL: URL(string: "https://example.invalid/sub")!)
        let second = try store.create(name: "Second")
        try store.select(first.id)
        return Fixture(store: store, model: ProfileViewModel(store: store, subscriptionFetcher: subscriptionFetcher), first: first, second: second)
    }
}

private struct Fixture {
    let store: ProfileStore
    let model: ProfileViewModel
    let first: Profile
    let second: Profile
}

private enum PendingKind { case create, duplicate, delete, restore }

private enum SubscriptionOutcome: CaseIterable { case updated, notModified, failure, cancelled }

private final class DelayedSubscriptionFetcher: ProfileSubscriptionFetching, @unchecked Sendable {
    let outcome: SubscriptionOutcome

    init(outcome: SubscriptionOutcome) { self.outcome = outcome }

    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { throw SubscriptionUpdateError.cancelled }
        switch outcome {
        case .updated:
            return SubscriptionResponse(data: Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"updated\":true}".utf8), cacheStatus: .updated, etag: "v2", lastModified: nil)
        case .notModified:
            return SubscriptionResponse(data: Data(), cacheStatus: .notModified, etag: "v1", lastModified: nil)
        case .failure:
            throw SubscriptionUpdateError.transportFailure
        case .cancelled:
            throw SubscriptionUpdateError.cancelled
        }
    }
}

private final class InteractionChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    let result: Result<Void, ConfigurationDiagnostic>

    init(result: Result<Void, ConfigurationDiagnostic>) { self.result = result }

    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { result }
}

private final class InteractionKeyProvider: ProfileEncryptionKeyProviding {
    private let key = Data(repeating: 7, count: 32)

    func loadMasterKey() throws -> Data? { key }
    func createMasterKey() throws -> Data { key }
}
