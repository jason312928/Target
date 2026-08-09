import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private let store: ProfileStore
    private let policyCatalogOperation: PolicyCatalogOperation
    private let configurationLoader: (UUID) throws -> String
    private let subscriptionFetcher: any ProfileSubscriptionFetching
    private var subscriptionTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    private(set) var profiles: [Profile] = []
    private(set) var selectedID: UUID?
    var editorText = ""
    private(set) var diagnostic: ConfigurationDiagnostic?
    private(set) var isDirty = false
    private(set) var isConfigurationLoaded = false
    private(set) var messageKey: String?
    private(set) var pendingSubscriptionUpdate: PendingSubscriptionUpdate?
    private(set) var isUpdatingSubscription = false
    private(set) var pendingImportCandidate: ProfileImportCandidate?
    private(set) var isPreparingImport = false
    private(set) var isCommittingImport = false
    private(set) var isShowingExportWarning = false
    private(set) var isExporting = false
    private(set) var pendingOperation: ProfileWorkspaceOperation?
    /// Presentation ownership is separate from the typed pending intent, but
    /// its active state is kept consistent with that intent by decision result.
    private(set) var unsavedChangesPresentation = ProfileUnsavedChangesPresentation()
    /// Changes that affect selected configuration readiness. The view observes
    /// this rather than refreshing lifecycle state for cancelled actions or
    /// subscription-cache metadata updates.
    private(set) var readinessChangeGeneration = 0
    private(set) var policyCatalog: PolicyCatalog?
    private(set) var isPolicyCatalogUnavailable = false

    init(
        store: ProfileStore = ProfileStore(),
        subscriptionFetcher: any ProfileSubscriptionFetching = SecureSubscriptionFetcher(),
        configurationLoader: ((UUID) throws -> String)? = nil
    ) {
        self.store = store
        self.policyCatalogOperation = PolicyCatalogOperation(profileStore: store)
        self.subscriptionFetcher = subscriptionFetcher
        self.configurationLoader = configurationLoader ?? { try store.configurationText(for: $0) }
        reloadInitialState()
    }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }
    var canEditConfiguration: Bool { selectedProfile != nil && isConfigurationLoaded }
    var canExport: Bool { canEditConfiguration && !isDirty && !isExporting }
    var defaultExportFileName: String { store.defaultExportFileNameForSelectedProfile() ?? "Profile.json" }
    var shouldPresentImportConfirmation: Bool { pendingImportCandidate != nil && pendingOperation == nil }
    var shouldPresentSubscriptionPreview: Bool { pendingSubscriptionUpdate != nil && pendingOperation == nil }

    func requestSelection(_ id: UUID?) {
        guard id != selectedID else { return }
        guard let id else { return }
        request(.select(id))
    }

    func requestCreate(name: String, subscriptionURL: URL? = nil) {
        request(.create(name: name, subscriptionURL: subscriptionURL))
    }

    func requestDuplicate(_ id: UUID) {
        request(.duplicate(id))
    }

    func requestDelete(_ id: UUID) {
        request(.delete(id))
    }

    func requestRestore(_ id: UUID) {
        request(.restore(id))
    }

    @discardableResult
    func resolveUnsavedChanges(_ decision: ProfileUnsavedChangesDecision) -> ProfileUnsavedChangesDecisionResult {
        guard let operation = pendingOperation else { return .noPendingOperation }
        switch decision {
        case .cancel:
            pendingOperation = nil
            unsavedChangesPresentation.resolve(.cancelled)
            return .cancelled
        case .discardChanges:
            guard discardCurrentEditorToPersistedState() else {
                unsavedChangesPresentation.resolve(.failedAndStillPending)
                return .failedAndStillPending
            }
            pendingOperation = nil
            unsavedChangesPresentation.resolve(.resolved)
            execute(operation)
            return .resolved
        case .saveAndContinue:
            guard saveCurrentEditor() else {
                unsavedChangesPresentation.resolve(.failedAndStillPending)
                return .failedAndStillPending
            }
            pendingOperation = nil
            unsavedChangesPresentation.resolve(.resolved)
            execute(operation)
            return .resolved
        }
    }

    func cancelUnsavedChangesConfirmation() {
        _ = resolveUnsavedChanges(.cancel)
    }

    func unsavedChangesAlertPresentationDidChange(_ isPresented: Bool) {
        unsavedChangesPresentation.alertPresentationDidChange(isPresented)
    }

    private func reloadInitialState() {
        do {
            profiles = try store.listProfiles()
            selectedID = try store.selectedProfileID() ?? profiles.first?.id
            loadSelectedText()
            refreshPolicyCatalog()
        } catch {
            profiles = []
            selectedID = nil
            editorText = ""
            isConfigurationLoaded = false
            messageKey = "profile.message.load-failed"
            policyCatalog = nil
            isPolicyCatalogUnavailable = true
        }
    }

    func prepareImport(from url: URL) {
        cancelPreparedImport()
        isPreparingImport = true
        messageKey = nil
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importTask = nil
                self.isPreparingImport = false
            }
            do {
                let candidate = try self.store.prepareImportCandidate(from: url)
                guard !Task.isCancelled else { return }
                self.pendingImportCandidate = candidate
            } catch let error as ProfileTransferError {
                guard !Task.isCancelled else { return }
                self.messageKey = self.transferMessageKey(for: error)
            } catch {
                guard !Task.isCancelled else { return }
                self.messageKey = "profile.import.error.unreadable"
            }
        }
    }

    func commitPreparedImport(name: String) {
        guard let candidate = pendingImportCandidate, !isCommittingImport else { return }
        request(.importCandidate(candidate, name: name))
    }

    func cancelPreparedImport() {
        importTask?.cancel()
        importTask = nil
        isPreparingImport = false
        pendingImportCandidate = nil
    }

    func importPickerCancelled() {
        cancelPreparedImport()
        messageKey = "profile.import.cancelled"
    }

    func requestExport() {
        guard canExport else {
            if isDirty { messageKey = "profile.export.unsaved-changes" }
            return
        }
        isShowingExportWarning = true
    }

    func dismissExportWarning() {
        isShowingExportWarning = false
    }

    func exportSelectedProfile(to destination: URL) {
        guard canExport else { return }
        isShowingExportWarning = false
        isExporting = true
        defer { isExporting = false }
        do {
            try store.exportSelectedProfile(to: destination)
            messageKey = "profile.export.success"
        } catch let error as ProfileTransferError {
            messageKey = transferMessageKey(for: error)
        } catch {
            messageKey = "profile.export.error.failed"
        }
    }

    func exportCancelled() {
        isShowingExportWarning = false
        messageKey = "profile.export.cancelled"
    }

    func rename(_ id: UUID, to name: String) {
        do {
            try store.rename(id, to: name)
            refreshMetadataPreservingEditor()
            refreshPolicyCatalog()
        } catch { messageKey = "profile.message.operation-failed" }
    }

    func updateEditor(_ text: String) {
        guard canEditConfiguration else { return }
        editorText = text
        isDirty = true
        diagnostic = JSONSyntaxChecker.validate(text)
        messageKey = nil
    }

    func format() {
        guard canEditConfiguration else { return }
        guard JSONSyntaxChecker.validate(editorText) == nil,
              let object = try? JSONSerialization.jsonObject(with: Data(editorText.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            diagnostic = JSONSyntaxChecker.validate(editorText)
            return
        }
        editorText = text + "\n"
        isDirty = true
    }

    func save() {
        if pendingOperation != nil {
            _ = resolveUnsavedChanges(.saveAndContinue)
        } else {
            _ = saveCurrentEditor()
        }
    }

    @discardableResult
    private func saveCurrentEditor() -> Bool {
        guard let selectedID, isConfigurationLoaded else {
            messageKey = "profile.message.configuration-read-failed"
            return false
        }
        do {
            try store.save(json: editorText, for: selectedID)
            diagnostic = nil
            isDirty = false
            messageKey = "profile.message.saved"
            refreshMetadataPreservingEditor()
            markReadinessChanged()
            return true
        } catch let error as ProfileStoreError {
            present(error)
        } catch { messageKey = "profile.message.operation-failed" }
        return false
    }

    func updateSubscription() {
        guard let profile = selectedProfile, let subscription = profile.subscription, subscriptionTask == nil else { return }
        messageKey = nil
        pendingSubscriptionUpdate = nil
        isUpdatingSubscription = true
        let profileID = profile.id
        let store = store
        let fetcher = subscriptionFetcher
        subscriptionTask = Task { [weak self] in
            defer {
                self?.subscriptionTask = nil
                self?.isUpdatingSubscription = false
            }
            do {
                let response = try await fetcher.fetch(subscription: subscription)
                guard !Task.isCancelled else { throw SubscriptionUpdateError.cancelled }
                let pending = try store.previewSubscriptionUpdate(response, for: profileID)
                guard !Task.isCancelled else { throw SubscriptionUpdateError.cancelled }
                self?.pendingSubscriptionUpdate = pending
                self?.refreshMetadataPreservingEditor()
                if pending == nil { self?.messageKey = "profile.subscription.not-modified" }
            } catch let error as SubscriptionUpdateError {
                if error == .cancelled { try? store.recordSubscriptionCancellation(for: profileID) }
                else { try? store.recordSubscriptionFailure(for: profileID, messageKey: error.messageKey) }
                self?.refreshMetadataPreservingEditor()
                self?.messageKey = error.messageKey
            } catch let error as ProfileStoreError {
                self?.refreshMetadataPreservingEditor()
                self?.present(error)
            } catch {
                try? store.recordSubscriptionFailure(for: profileID, messageKey: "profile.subscription.error.download-failed")
                self?.refreshMetadataPreservingEditor()
                self?.messageKey = "profile.subscription.error.download-failed"
            }
        }
    }

    func cancelSubscriptionUpdate() {
        subscriptionTask?.cancel()
    }

    func confirmSubscriptionUpdate() {
        guard let pending = pendingSubscriptionUpdate else { return }
        request(.applySubscription(pending))
    }

    func discardSubscriptionPreview() {
        pendingSubscriptionUpdate = nil
        messageKey = "profile.subscription.preview-dismissed"
    }

    private func request(_ operation: ProfileWorkspaceOperation) {
        // A recovery decision owns the next replacement action. This also
        // prevents a clean editor from overwriting a recoverable older intent.
        guard pendingOperation == nil else { return }
        guard !isDirty else {
            pendingOperation = operation
            unsavedChangesPresentation.requestPresentation()
            return
        }
        execute(operation)
    }

    private func execute(_ operation: ProfileWorkspaceOperation) {
        do {
            switch operation {
            case .select(let id):
                try store.select(id)
                selectedID = id
                cancelPreparedImport()
                loadSelectedText()
                markReadinessChanged()
            case .create(let name, let subscriptionURL):
                let profile = try store.create(name: name, subscriptionURL: subscriptionURL)
                try selectAndActivate(profile.id)
                markReadinessChanged()
            case .duplicate(let id):
                let profile = try store.duplicate(id)
                try selectAndActivate(profile.id)
                markReadinessChanged()
            case .delete(let id):
                try store.delete(id)
                activate(try store.selectedProfileID() ?? profiles.first(where: { $0.id != id })?.id)
                markReadinessChanged()
            case .restore(let id):
                try store.restorePreviousValidVersion(for: id)
                activate(id)
                messageKey = "profile.message.restored"
                markReadinessChanged()
            case .importCandidate(let candidate, let name):
                isCommittingImport = true
                defer { isCommittingImport = false }
                let profile = try store.importCandidate(candidate, name: name)
                pendingImportCandidate = nil
                activate(profile.id)
                messageKey = "profile.import.success"
                markReadinessChanged()
            case .applySubscription(let pending):
                try store.applySubscriptionUpdate(pending)
                pendingSubscriptionUpdate = nil
                activate(pending.profileID)
                messageKey = "profile.subscription.applied"
                markReadinessChanged()
            }
        } catch let error as ProfileStoreError {
            present(error)
        } catch {
            messageKey = "profile.message.operation-failed"
        }
    }

    private func activate(_ id: UUID?) {
        profiles = (try? store.listProfiles()) ?? []
        selectedID = id
        loadSelectedText()
    }

    private func selectAndActivate(_ id: UUID) throws {
        try store.select(id)
        activate(id)
    }

    /// For remote subscription state and metadata-only actions. Never invokes
    /// loadSelectedText(), so a task completing after the user edits cannot
    /// replace the current editing buffer or clear its dirty state.
    private func refreshMetadataPreservingEditor() {
        do { profiles = try store.listProfiles() }
        catch { messageKey = "profile.message.load-failed" }
    }

    /// Restores the currently selected editor from authenticated persistent
    /// storage before any replacement operation may run. This is deliberately
    /// fail-closed: a read failure leaves the user's buffer and dirty state
    /// untouched, and the requested operation remains pending.
    @discardableResult
    private func discardCurrentEditorToPersistedState() -> Bool {
        guard let selectedID else {
            messageKey = "profile.message.operation-failed"
            return false
        }
        do {
            let persistedText = try configurationLoader(selectedID)
            editorText = persistedText
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = true
            return true
        } catch is ProfileStoreError {
            messageKey = "profile.message.configuration-read-failed"
            return false
        } catch {
            messageKey = "profile.message.configuration-read-failed"
            return false
        }
    }

    private func loadSelectedText() {
        guard let selectedID else {
            editorText = ""
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = false
            policyCatalog = nil
            isPolicyCatalogUnavailable = false
            return
        }
        do {
            editorText = try configurationLoader(selectedID)
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = true
            messageKey = nil
        } catch {
            if !isDirty {
                editorText = ""
                diagnostic = nil
            }
            isConfigurationLoaded = false
            messageKey = "profile.message.configuration-read-failed"
        }
        refreshPolicyCatalog()
    }

    private func markReadinessChanged() {
        readinessChangeGeneration &+= 1
    }

    /// Catalog state is fail-closed. A storage read error clears prior data rather
    /// than retaining the previous Profile's catalog in the UI.
    private func refreshPolicyCatalog() {
        do {
            policyCatalog = try policyCatalogOperation.read()
            isPolicyCatalogUnavailable = false
        } catch {
            policyCatalog = nil
            isPolicyCatalogUnavailable = true
        }
    }

    private func present(_ error: ProfileStoreError) {
        switch error {
        case .invalidJSON(let diagnostic), .validationFailed(let diagnostic):
            self.diagnostic = diagnostic
            self.messageKey = diagnostic.messageKey
        case .profileInUse:
            self.messageKey = "profile.message.stop-before-delete"
        default:
            self.messageKey = "profile.message.operation-failed"
        }
    }

    private func transferMessageKey(for error: ProfileTransferError) -> String {
        switch error {
        case .unreadableImport: "profile.import.error.unreadable"
        case .importTooLarge: "profile.import.error.too-large"
        case .importInvalidUTF8: "profile.import.error.invalid-utf8"
        case .importInvalidJSON: "profile.import.error.invalid-json"
        case .importValidationFailed: "profile.import.error.validation"
        case .unsafeExportDestination: "profile.export.error.unsafe-destination"
        case .exportFailed, .exportCleanupFailed: "profile.export.error.failed"
        }
    }
}
