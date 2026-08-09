import Foundation
import XCTest

@testable import Target

@MainActor
final class ProfileWorkspaceInteractionTests: XCTestCase {
    func testImportPanelResultSelectsOnlyAcceptedURL() {
        let url = URL(fileURLWithPath: "/tmp/Profile.json")

        XCTAssertEqual(ProfileImportPanelResult.resolve(response: .OK, selectedURL: url), .selected(url))
        XCTAssertEqual(ProfileImportPanelResult.resolve(response: .cancel, selectedURL: url), .cancelled)
        XCTAssertEqual(ProfileImportPanelResult.resolve(response: .OK, selectedURL: nil), .cancelled)
    }

    func testWorkspacePresentationMapsLocalValidationStates() {
        let profile = makePresentationProfile(subscription: nil, validation: .notChecked)

        let presentation = ProfileWorkspacePresentation(profile: profile)

        XCTAssertEqual(presentation.source, ProfileWorkspacePresentation.Source.local)
        XCTAssertEqual(presentation.validationTitleKey, "profile.validation.not-checked")
        XCTAssertEqual(presentation.validationLevel, ProfileWorkspaceStatusLevel.neutral)
        XCTAssertNil(presentation.subscriptionTitleKey)
        XCTAssertNil(presentation.subscriptionLevel)
        XCTAssertFalse(presentation.hasSubscriptionError)
    }

    func testWorkspacePresentationMapsRemoteStatusAndError() {
        let subscription = RemoteSubscription(
            url: URL(string: "https://example.invalid/subscription")!,
            cacheStatus: .failed,
            lastErrorKey: "profile.subscription.error.timeout"
        )
        let profile = makePresentationProfile(
            subscription: subscription,
            validation: .init(status: .valid, checkedAt: Date(), error: nil)
        )

        let presentation = ProfileWorkspacePresentation(profile: profile)

        XCTAssertEqual(presentation.source, ProfileWorkspacePresentation.Source.remote)
        XCTAssertEqual(presentation.validationTitleKey, "profile.validation.valid")
        XCTAssertEqual(presentation.validationLevel, ProfileWorkspaceStatusLevel.positive)
        XCTAssertEqual(presentation.subscriptionTitleKey, "profile.subscription.cache.failed")
        XCTAssertEqual(presentation.subscriptionLevel, ProfileWorkspaceStatusLevel.critical)
        XCTAssertTrue(presentation.hasSubscriptionError)
    }

    func testWorkspacePresentationMapsInvalidAndSubscriptionUpdateStates() {
        let subscription = RemoteSubscription(
            url: URL(string: "https://example.invalid/subscription")!,
            cacheStatus: .updated
        )
        let profile = makePresentationProfile(subscription: subscription, validation: .init(status: .invalid, checkedAt: Date(), error: nil))

        let presentation = ProfileWorkspacePresentation(profile: profile)

        XCTAssertEqual(presentation.validationTitleKey, "profile.validation.invalid")
        XCTAssertEqual(presentation.validationLevel, ProfileWorkspaceStatusLevel.critical)
        XCTAssertEqual(presentation.subscriptionLevel, ProfileWorkspaceStatusLevel.positive)
    }

    func testWorkspaceLayoutDefinesEditorAndSidebarBounds() {
        XCTAssertEqual(ProfileWorkspaceLayout.minimumEditorHeight, 180)
        XCTAssertGreaterThan(ProfileWorkspaceLayout.preferredEditorHeight, ProfileWorkspaceLayout.minimumEditorHeight)
        XCTAssertLessThanOrEqual(
            ProfileWorkspaceLayout.sidebarMinimumWidth,
            ProfileWorkspaceLayout.sidebarIdealWidth
        )
        XCTAssertLessThanOrEqual(
            ProfileWorkspaceLayout.sidebarIdealWidth,
            ProfileWorkspaceLayout.sidebarMaximumWidth
        )
    }

    func testImportedProfileActivationLoadsExactBytesAndStartsClean() async throws {
        let fixture = try makeFixture()
        let source = "{\n  \"inbounds\": [],\n  \"outbounds\": [{\"type\":\"direct\",\"tag\":\"direct\"}],\n  \"route\": {\"final\":\"direct\"},\n  \"unknown\": [true, 7]\n}\n"
        let importURL = FileManager.default.temporaryDirectory
            .appending(path: "TargetProfileActivationImport-\(UUID().uuidString).json")
        try Data(source.utf8).write(to: importURL)
        defer { try? FileManager.default.removeItem(at: importURL) }

        fixture.model.prepareImport(from: importURL)
        for _ in 0..<1_000 where fixture.model.pendingImportCandidate == nil {
            await Task.yield()
        }
        XCTAssertNotNil(fixture.model.pendingImportCandidate)

        fixture.model.commitPreparedImport(name: "Imported")

        let selectedID = try XCTUnwrap(fixture.model.selectedID)
        XCTAssertEqual(fixture.model.editorText.data(using: .utf8), Data(source.utf8))
        XCTAssertEqual(try fixture.store.configurationText(for: selectedID).data(using: .utf8), Data(source.utf8))
        XCTAssertTrue(fixture.model.isConfigurationLoaded)
        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertNil(fixture.model.diagnostic)
    }

    func testConfigurationReadFailureIsUnavailableAndCannotOverwriteLastValidRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TargetProfileReadFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ProfileStore(
            rootDirectory: root,
            checker: InteractionChecker(result: .success(())),
            runtimeUsage: CountingProfileUsage(inUse: false),
            keyProvider: InteractionKeyProvider()
        )
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        try store.select(first.id)
        let model = ProfileViewModel(
            store: store,
            subscriptionFetcher: ControlledSubscriptionFetcher(),
            configurationLoader: { id in
                if id == second.id { throw ProfileStoreError.invalidStoredMetadata }
                return try store.configurationText(for: id)
            }
        )
        let lastValid = try store.validVersion(for: second.id, revision: 1).data

        model.requestSelection(second.id)

        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertFalse(model.isConfigurationLoaded)
        XCTAssertFalse(model.canEditConfiguration)
        XCTAssertEqual(model.editorText, "")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.messageKey, "profile.message.configuration-read-failed")

        model.updateEditor("")
        model.save()

        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.messageKey, "profile.message.configuration-read-failed")
        XCTAssertEqual(try store.validVersion(for: second.id, revision: 1).data, lastValid)
        XCTAssertEqual(try store.availableValidVersions(for: second.id).map(\.revision), [1])
    }

    func testPolicyCatalogUsesPersistedRevisionAndRefreshesOnlyAfterSave() throws {
        let fixture = try makeFixture()
        let catalogA = #"{"outbounds":[{"type":"selector","tag":"A","outbounds":["a"]},{"type":"direct","tag":"a"}]}"#
        let catalogB = #"{"outbounds":[{"type":"selector","tag":"B","outbounds":["b"]},{"type":"block","tag":"b"}]}"#
        try fixture.store.save(json: catalogA, for: fixture.first.id)
        let model = ProfileViewModel(store: fixture.store, subscriptionFetcher: ControlledSubscriptionFetcher())
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "A")

        model.updateEditor(catalogB)
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "A")
        model.save()
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "B")

        model.updateEditor("{")
        model.save()
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "B")
    }

    func testPolicyCatalogClearsStaleDataWhenPostSaveReadFailsWithoutReplacingEditor() throws {
        let fixture = try makeFixture()
        let catalogA = #"{"outbounds":[{"type":"selector","tag":"A","outbounds":[]}]}"#
        let catalogB = #"{"outbounds":[{"type":"selector","tag":"B","outbounds":[]}]}"#
        try fixture.store.save(json: catalogA, for: fixture.first.id)
        var shouldFailCatalogRead = false
        let model = ProfileViewModel(
            store: fixture.store,
            subscriptionFetcher: ControlledSubscriptionFetcher(),
            policyCatalogLoader: {
                if shouldFailCatalogRead { throw ProfileStoreError.invalidStoredMetadata }
                return try PolicyCatalogOperation(profileStore: fixture.store).read()
            }
        )
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "A")
        model.updateEditor(catalogB)
        shouldFailCatalogRead = true
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.editorText, catalogB)
        XCTAssertNil(model.policyCatalog)
        XCTAssertTrue(model.isPolicyCatalogUnavailable)
    }

    func testPolicyCatalogSaveAndContinuePersistsBeforeSelection() throws {
        let fixture = try makeFixture()
        let catalogB = #"{"outbounds":[{"type":"selector","tag":"B","outbounds":[]}]}"#
        fixture.model.updateEditor(catalogB)
        fixture.model.requestSelection(fixture.second.id)
        XCTAssertEqual(fixture.model.resolveUnsavedChanges(.saveAndContinue), .resolved)
        XCTAssertEqual(fixture.model.selectedID, fixture.second.id)
        fixture.model.requestSelection(fixture.first.id)
        XCTAssertEqual(fixture.model.policyCatalog?.selectors.first?.tag, "B")
    }

    func testPolicyCatalogRefreshesOnCleanProfileSelection() throws {
        let fixture = try makeFixture()
        try fixture.store.save(json: #"{"outbounds":[{"type":"selector","tag":"A","outbounds":[]}]}"#, for: fixture.first.id)
        try fixture.store.save(json: #"{"outbounds":[{"type":"selector","tag":"B","outbounds":[]}]}"#, for: fixture.second.id)
        let model = ProfileViewModel(store: fixture.store, subscriptionFetcher: ControlledSubscriptionFetcher())
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "A")
        model.requestSelection(fixture.second.id)
        XCTAssertEqual(model.policyCatalog?.selectors.first?.tag, "B")
    }

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
        let result = fixture.model.resolveUnsavedChanges(.saveAndContinue)

        XCTAssertEqual(result, .resolved)
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
        let presentationGeneration = fixture.model.unsavedChangesPresentation.generation
        let result = fixture.model.resolveUnsavedChanges(.saveAndContinue)

        XCTAssertEqual(fixture.model.selectedID, fixture.first.id)
        XCTAssertEqual(try fixture.store.selectedProfileID(), fixture.first.id)
        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertEqual(fixture.model.diagnostic?.messageKey, "profile.validation.check-failed")
        XCTAssertEqual(result, .failedAndStillPending)
        guard case .select(let id)? = fixture.model.pendingOperation else {
            return XCTFail("The failed save must retain the pending action")
        }
        XCTAssertEqual(id, fixture.second.id)
        XCTAssertTrue(fixture.model.unsavedChangesPresentation.isPresented)
        XCTAssertEqual(fixture.model.unsavedChangesPresentation.generation, presentationGeneration + 1)
        fixture.model.unsavedChangesAlertPresentationDidChange(false)
        XCTAssertEqual(fixture.model.unsavedChangesPresentation.generation, presentationGeneration + 1)
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

    func testDiscardBeforeFailedDeleteRestoresPersistedEditorAndExecutesOnlyOnce() throws {
        let usage = CountingProfileUsage(inUse: true)
        let fixture = try makeFixture(runtimeUsage: usage)
        let persistedText = try fixture.store.configurationText(for: fixture.first.id)
        fixture.model.updateEditor("{\"discarded\":true}")
        fixture.model.requestDelete(fixture.first.id)

        let result = fixture.model.resolveUnsavedChanges(.discardChanges)

        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(usage.checkCount, 1)
        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertEqual(fixture.model.selectedID, fixture.first.id)
        XCTAssertEqual(fixture.model.editorText, persistedText)
        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertEqual(fixture.model.messageKey, "profile.message.stop-before-delete")
        XCTAssertNotEqual(fixture.model.editorText, "{\"discarded\":true}")

        fixture.model.resolveUnsavedChanges(.discardChanges)
        XCTAssertEqual(usage.checkCount, 1)
    }

    func testDiscardDoesNotExecuteOperationWhenPersistedEditorCannotBeRestored() throws {
        let usage = CountingProfileUsage(inUse: true)
        let fixture = try makeFixture(runtimeUsage: usage)
        try FileManager.default.removeItem(at: fixture.store.safeManagedURL("\(fixture.first.id.uuidString)/config.json"))
        fixture.model.updateEditor("{\"keep\":true}")
        fixture.model.requestDelete(fixture.first.id)

        fixture.model.resolveUnsavedChanges(.discardChanges)

        XCTAssertEqual(usage.checkCount, 0)
        XCTAssertEqual(fixture.model.editorText, "{\"keep\":true}")
        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertNotNil(fixture.model.pendingOperation)
        XCTAssertEqual(fixture.model.messageKey, "profile.message.configuration-read-failed")
        XCTAssertTrue(fixture.model.unsavedChangesPresentation.isPresented)
    }

    func testDecisionResultsRetirePresentationOnlyAfterSuccessOrExplicitCancel() throws {
        let fixture = try makeFixture()
        fixture.model.updateEditor("{\"edited\":true}")
        fixture.model.requestSelection(fixture.second.id)
        XCTAssertTrue(fixture.model.unsavedChangesPresentation.isPresented)

        XCTAssertEqual(fixture.model.resolveUnsavedChanges(.cancel), .cancelled)
        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertFalse(fixture.model.unsavedChangesPresentation.isPresented)

        fixture.model.updateEditor("{\"edited\":true}")
        fixture.model.requestSelection(fixture.second.id)
        XCTAssertEqual(fixture.model.resolveUnsavedChanges(.discardChanges), .resolved)
        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertFalse(fixture.model.unsavedChangesPresentation.isPresented)
        XCTAssertEqual(fixture.model.selectedID, fixture.second.id)
    }

    func testOrdinaryAlertDismissalCannotHidePendingOperationAndMainSaveResolvesIt() throws {
        let fixture = try makeFixture()
        let saved = "{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"saved\":true}"
        fixture.model.updateEditor(saved)
        fixture.model.requestSelection(fixture.second.id)
        let initialGeneration = fixture.model.unsavedChangesPresentation.generation

        fixture.model.unsavedChangesAlertPresentationDidChange(false)
        XCTAssertNotNil(fixture.model.pendingOperation)
        XCTAssertTrue(fixture.model.unsavedChangesPresentation.isPresented)
        XCTAssertEqual(fixture.model.unsavedChangesPresentation.generation, initialGeneration)

        fixture.model.save()
        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertFalse(fixture.model.unsavedChangesPresentation.isPresented)
        XCTAssertEqual(fixture.model.selectedID, fixture.second.id)
        XCTAssertEqual(try fixture.store.configurationText(for: fixture.first.id), saved)
    }

    func testCancelRestoresImportAndSubscriptionCandidatePresentationAfterFailure() async throws {
        let importChecker = SequenceInteractionChecker(results: [.success(()), .failure(.init(messageKey: "profile.validation.check-failed", line: nil, column: nil))])
        let importFixture = try makeFixture(checker: importChecker)
        let importURL = FileManager.default.temporaryDirectory.appending(path: "TargetProfilePresentationImport-\(UUID().uuidString).json")
        try Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}".utf8).write(to: importURL)
        defer { try? FileManager.default.removeItem(at: importURL) }
        importFixture.model.prepareImport(from: importURL)
        for _ in 0..<100 where importFixture.model.pendingImportCandidate == nil { await Task.yield() }
        XCTAssertTrue(importFixture.model.shouldPresentImportConfirmation)
        importFixture.model.updateEditor("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}")
        importFixture.model.commitPreparedImport(name: "Imported")
        XCTAssertFalse(importFixture.model.shouldPresentImportConfirmation)
        XCTAssertEqual(importFixture.model.resolveUnsavedChanges(.saveAndContinue), .failedAndStillPending)
        XCTAssertTrue(importFixture.model.unsavedChangesPresentation.isPresented)
        XCTAssertEqual(importFixture.model.resolveUnsavedChanges(.cancel), .cancelled)
        XCTAssertNil(importFixture.model.pendingOperation)
        XCTAssertTrue(importFixture.model.shouldPresentImportConfirmation)

        let fetcher = ControlledSubscriptionFetcher()
        let subscriptionChecker = SequenceInteractionChecker(results: [.success(()), .failure(.init(messageKey: "profile.validation.check-failed", line: nil, column: nil))])
        let subscriptionFixture = try makeFixture(checker: subscriptionChecker, subscriptionFetcher: fetcher)
        subscriptionFixture.model.updateSubscription()
        await fetcher.waitUntilStarted()
        await fetcher.complete(.updated)
        try await waitForSubscriptionCompletion(subscriptionFixture.model)
        XCTAssertTrue(subscriptionFixture.model.shouldPresentSubscriptionPreview)
        subscriptionFixture.model.updateEditor("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}")
        subscriptionFixture.model.confirmSubscriptionUpdate()
        XCTAssertFalse(subscriptionFixture.model.shouldPresentSubscriptionPreview)
        XCTAssertEqual(subscriptionFixture.model.resolveUnsavedChanges(.saveAndContinue), .failedAndStillPending)
        XCTAssertTrue(subscriptionFixture.model.unsavedChangesPresentation.isPresented)
        XCTAssertEqual(subscriptionFixture.model.resolveUnsavedChanges(.cancel), .cancelled)
        XCTAssertNil(subscriptionFixture.model.pendingOperation)
        XCTAssertTrue(subscriptionFixture.model.shouldPresentSubscriptionPreview)
    }

    func testSubscriptionCompletionAfterEditingPreservesEditorForAllFetcherOutcomes() async throws {
        for outcome in SubscriptionRaceOutcome.allCases {
            let fetcher = ControlledSubscriptionFetcher()
            let fixture = try makeFixture(subscriptionFetcher: fetcher)
            let editedText = "{\"inbounds\":["
            fixture.model.updateSubscription()
            await fetcher.waitUntilStarted()
            XCTAssertTrue(fixture.model.isUpdatingSubscription)

            fixture.model.updateEditor(editedText)
            let expectedDiagnostic = fixture.model.diagnostic
            XCTAssertEqual(expectedDiagnostic?.messageKey, "profile.validation.json-syntax")

            switch outcome {
            case .updated:
                await fetcher.complete(.updated)
            case .notModified:
                await fetcher.complete(.notModified)
            case .transportFailure:
                await fetcher.complete(.transportFailure)
            case .userCancelled:
                fixture.model.cancelSubscriptionUpdate()
                await fetcher.waitUntilCancelled()
            }
            try await waitForSubscriptionCompletion(fixture.model)

            XCTAssertEqual(fixture.model.editorText, editedText, "\(outcome) must not overwrite editor text")
            XCTAssertTrue(fixture.model.isDirty, "\(outcome) must retain dirty state")
            XCTAssertEqual(fixture.model.diagnostic, expectedDiagnostic, "\(outcome) must not clear an editor diagnostic")
            XCTAssertEqual(fixture.model.selectedID, fixture.first.id, "\(outcome) must not change selection")
            XCTAssertEqual(try fixture.store.selectedProfileID(), fixture.first.id)

            switch outcome {
            case .updated:
                XCTAssertNotNil(fixture.model.pendingSubscriptionUpdate)
                fixture.model.confirmSubscriptionUpdate()
                guard case .applySubscription? = fixture.model.pendingOperation else {
                    return XCTFail("Applying a candidate after an in-flight edit must ask first")
                }
            case .notModified, .transportFailure, .userCancelled:
                XCTAssertNil(fixture.model.pendingSubscriptionUpdate)
            }
        }
    }

    func testDiscardBeforeFailedSubscriptionApplyKeepsPersistedEditorClean() async throws {
        let fetcher = ControlledSubscriptionFetcher()
        let checker = SequenceInteractionChecker(results: [.success(()), .failure(.init(messageKey: "profile.validation.check-failed", line: nil, column: nil))])
        let fixture = try makeFixture(checker: checker, subscriptionFetcher: fetcher)
        let persistedText = try fixture.store.configurationText(for: fixture.first.id)
        fixture.model.updateSubscription()
        await fetcher.waitUntilStarted()
        await fetcher.complete(.updated)
        try await waitForSubscriptionCompletion(fixture.model)
        XCTAssertNotNil(fixture.model.pendingSubscriptionUpdate)

        fixture.model.updateEditor("{\"discarded\":true}")
        fixture.model.confirmSubscriptionUpdate()
        fixture.model.resolveUnsavedChanges(.discardChanges)

        XCTAssertEqual(checker.checkCount, 2)
        XCTAssertNil(fixture.model.pendingOperation)
        XCTAssertEqual(fixture.model.editorText, persistedText)
        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertEqual(fixture.model.diagnostic?.messageKey, "profile.validation.check-failed")
        XCTAssertNotNil(fixture.model.pendingSubscriptionUpdate)
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
        for _ in 0..<1_000 where model.isUpdatingSubscription {
            await Task.yield()
        }
        XCTAssertFalse(model.isUpdatingSubscription)
    }

    private func makeFixture(
        checker: any SingBoxConfigurationChecking = InteractionChecker(result: .success(())),
        subscriptionFetcher: any ProfileSubscriptionFetching = ControlledSubscriptionFetcher(),
        runtimeUsage: any ProfileRuntimeUsageChecking = CountingProfileUsage(inUse: false)
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "TargetProfileInteraction-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ProfileStore(rootDirectory: root, checker: checker, runtimeUsage: runtimeUsage, keyProvider: InteractionKeyProvider())
        let first = try store.create(name: "First", subscriptionURL: URL(string: "https://example.invalid/sub")!)
        let second = try store.create(name: "Second")
        try store.select(first.id)
        return Fixture(store: store, model: ProfileViewModel(store: store, subscriptionFetcher: subscriptionFetcher), first: first, second: second)
    }

    private func makePresentationProfile(subscription: RemoteSubscription?, validation: ProfileValidation) -> Profile {
        Profile(
            id: UUID(),
            name: "Presentation",
            subscription: subscription,
            createdAt: Date(),
            updatedAt: Date(),
            validation: validation,
            validRevision: 1
        )
    }
}

private struct Fixture {
    let store: ProfileStore
    let model: ProfileViewModel
    let first: Profile
    let second: Profile
}

private enum PendingKind { case create, duplicate, delete, restore }

private enum SubscriptionRaceOutcome: CaseIterable { case updated, notModified, transportFailure, userCancelled }

private actor ControlledSubscriptionFetcher: ProfileSubscriptionFetching {
    enum Completion {
        case updated
        case notModified
        case transportFailure
    }

    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<SubscriptionResponse, Error>?
    private var queuedCompletion: Completion?

    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled {
                    continuation.resume(throwing: SubscriptionUpdateError.cancelled)
                } else if let queuedCompletion {
                    self.queuedCompletion = nil
                    resume(continuation, with: queuedCompletion)
                } else {
                    responseContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.noteCancellation() }
        })
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func complete(_ completion: Completion) {
        if let continuation = responseContinuation {
            responseContinuation = nil
            resume(continuation, with: completion)
        } else {
            queuedCompletion = completion
        }
    }

    private func noteCancellation() {
        guard !cancelled else { return }
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let continuation = responseContinuation {
            responseContinuation = nil
            continuation.resume(throwing: SubscriptionUpdateError.cancelled)
        }
    }

    private func resume(_ continuation: CheckedContinuation<SubscriptionResponse, Error>, with completion: Completion) {
        switch completion {
        case .updated:
            continuation.resume(returning: SubscriptionResponse(data: Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"updated\":true}".utf8), cacheStatus: .updated, etag: "v2", lastModified: nil))
        case .notModified:
            continuation.resume(returning: SubscriptionResponse(data: Data(), cacheStatus: .notModified, etag: "v1", lastModified: nil))
        case .transportFailure:
            continuation.resume(throwing: SubscriptionUpdateError.transportFailure)
        }
    }
}

private final class InteractionChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    let result: Result<Void, ConfigurationDiagnostic>

    init(result: Result<Void, ConfigurationDiagnostic>) { self.result = result }

    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { result }
}

private final class SequenceInteractionChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    private var results: [Result<Void, ConfigurationDiagnostic>]
    private(set) var checkCount = 0

    init(results: [Result<Void, ConfigurationDiagnostic>]) { self.results = results }

    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> {
        checkCount += 1
        return results.removeFirst()
    }
}

private final class CountingProfileUsage: ProfileRuntimeUsageChecking, @unchecked Sendable {
    private let inUse: Bool
    private(set) var checkCount = 0

    init(inUse: Bool) { self.inUse = inUse }

    func isProfileInUse(_ id: UUID) -> Bool {
        checkCount += 1
        return inUse
    }
}

private final class InteractionKeyProvider: ProfileEncryptionKeyProviding {
    private let key = Data(repeating: 7, count: 32)

    func loadMasterKey() throws -> Data? { key }
    func createMasterKey() throws -> Data { key }
}
