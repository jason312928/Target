import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private let store: ProfileStore
    private let policyOperations: any TargetPolicyOperating
    private let policyCatalogLoader: () throws -> PolicyCatalog
    private let usesCustomPolicyCatalogLoader: Bool
    private let configurationLoader: (UUID) throws -> String
    private let subscriptionOperations: TargetSubscriptionOperations
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionGeneration = 0
    private var importTask: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    private var policyProbeTask: Task<Void, Never>?
    private var policyRefreshGeneration = 0
    private var policyHealthGeneration = 0

    private(set) var profiles: [Profile] = []
    private(set) var selectedID: UUID?
    var editorText = ""
    private(set) var diagnostic: ConfigurationDiagnostic?
    private(set) var isDirty = false
    private(set) var isConfigurationLoaded = false
    private(set) var messageKey: String?
    private(set) var subscriptionFailureDiagnostic: SubscriptionFailureDiagnostic?
    private(set) var pendingSubscriptionIntake: PendingSubscriptionIntake?
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
    private(set) var isSelectingPolicy = false
    private(set) var testingPolicySelectorID: Int?
    private(set) var policyHealthBySelector: [Int: [String: RuntimeProxyHealth]] = [:]

    init(
        store: ProfileStore = ProfileStore(),
        subscriptionFetcher: any ProfileSubscriptionFetching = SecureSubscriptionFetcher(),
        configurationLoader: ((UUID) throws -> String)? = nil,
        policyOperations: (any TargetPolicyOperating)? = nil,
        policyCatalogLoader: (() throws -> PolicyCatalog)? = nil
    ) {
        self.store = store
        let resolvedPolicyOperations = policyOperations ?? TargetPolicyOperations(profileStore: store)
        self.policyOperations = resolvedPolicyOperations
        self.policyCatalogLoader = policyCatalogLoader ?? resolvedPolicyOperations.readPersisted
        self.usesCustomPolicyCatalogLoader = policyCatalogLoader != nil
        self.subscriptionOperations = TargetSubscriptionOperations(store: store, fetcher: subscriptionFetcher)
        self.configurationLoader = configurationLoader ?? { try store.configurationText(for: $0) }
        reloadInitialState()
    }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }
    var canEditConfiguration: Bool { selectedProfile != nil && isConfigurationLoaded }
    var canExport: Bool { canEditConfiguration && !isDirty && !isExporting }
    var defaultExportFileName: String { store.defaultExportFileNameForSelectedProfile() ?? "Profile.json" }
    var shouldPresentImportConfirmation: Bool { pendingImportCandidate != nil && pendingOperation == nil }
    var pendingSubscriptionUpdate: PendingSubscriptionIntake? { pendingSubscriptionIntake }
    var shouldPresentSubscriptionPreview: Bool { pendingSubscriptionIntake != nil && pendingOperation == nil }

    func requestSelection(_ id: UUID?) {
        guard id != selectedID else { return }
        guard let id else { return }
        request(.select(id))
    }

    func requestCreate(name: String, subscriptionURL: URL? = nil) {
        if let subscriptionURL { prepareSubscription(name: name, url: subscriptionURL) }
        else { request(.create(name: name)) }
    }

    func prepareSubscription(name: String, url: URL) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            messageKey = "profile.message.invalid-name"
            return
        }
        cancelSubscriptionOperation(clearCandidate: true)
        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        messageKey = nil
        subscriptionFailureDiagnostic = nil
        isUpdatingSubscription = true
        let operations = subscriptionOperations
        subscriptionTask = Task { [weak self] in
            defer {
                if let self, self.subscriptionGeneration == generation {
                    self.subscriptionTask = nil
                    self.isUpdatingSubscription = false
                }
            }
            do {
                let pending = try await operations.prepareNew(name: normalizedName, url: url)
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation else { return }
                self.pendingSubscriptionIntake = pending
            } catch {
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation else { return }
                self.presentSubscriptionError(error)
            }
        }
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

    func selectPolicy(selectorTag: String, outboundTag: String) {
        guard !isSelectingPolicy else { return }
        isSelectingPolicy = true
        messageKey = nil
        policyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.policyTask = nil
                self.isSelectingPolicy = false
            }
            do {
                self.policyCatalog = try await self.policyOperations.select(
                    selectorTag: selectorTag,
                    outboundTag: outboundTag
                )
                self.isPolicyCatalogUnavailable = false
                self.messageKey = "policy.catalog.selection.saved"
                self.refreshMetadataPreservingEditor()
                self.markReadinessChanged()
            } catch let error as TargetPolicyOperationError {
                self.messageKey = self.policyMessageKey(for: error)
                self.refreshPolicyCatalog()
            } catch {
                self.messageKey = "policy.catalog.selection.failed"
                self.refreshPolicyCatalog()
            }
        }
    }

    func resetPolicy() {
        guard !isSelectingPolicy else { return }
        isSelectingPolicy = true
        messageKey = nil
        policyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.policyTask = nil
                self.isSelectingPolicy = false
            }
            do {
                self.policyCatalog = try await self.policyOperations.reset().catalog
                self.isPolicyCatalogUnavailable = false
                self.messageKey = "policy.catalog.reset.saved"
                self.refreshMetadataPreservingEditor()
                self.markReadinessChanged()
            } catch let error as TargetPolicyOperationError {
                self.messageKey = self.policyMessageKey(for: error)
                self.refreshPolicyCatalog()
            } catch {
                self.messageKey = "policy.catalog.reset.failed"
                self.refreshPolicyCatalog()
            }
        }
    }

    func refreshPolicyState() {
        invalidatePolicyHealth()
        refreshPolicyCatalog()
    }

    func probePolicyLatency(selectorID: Int, selectorTag: String) {
        guard policyProbeTask == nil,
              let catalog = policyCatalog,
              let profileID = catalog.profileID,
              let profileRevision = catalog.profileRevision,
              let sourceFingerprint = catalog.sourceFingerprint,
              let selector = catalog.selectors.first(where: { $0.id == selectorID && $0.tag == selectorTag }) else {
            return
        }
        let availableMembers = selector.members.filter { $0.status == .available }
        guard !availableMembers.isEmpty else { return }

        policyHealthGeneration &+= 1
        let generation = policyHealthGeneration
        let selectedProfileID = selectedID
        testingPolicySelectorID = selectorID
        policyHealthBySelector[selectorID] = Dictionary(
            uniqueKeysWithValues: availableMembers.map { ($0.tag, .testing(tag: $0.tag)) }
        )

        policyProbeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.policyHealthGeneration {
                    self.policyProbeTask = nil
                    self.testingPolicySelectorID = nil
                }
            }
            do {
                let result = try await self.policyOperations.probeLatency(selectorTag: selectorTag)
                guard !Task.isCancelled,
                      generation == self.policyHealthGeneration,
                      self.selectedID == selectedProfileID,
                      result.profileID == profileID,
                      result.profileRevision == profileRevision,
                      result.sourceFingerprint == sourceFingerprint,
                      result.selector == selectorTag,
                      self.policyCatalog?.profileID == profileID,
                      self.policyCatalog?.profileRevision == profileRevision,
                      self.policyCatalog?.sourceFingerprint == sourceFingerprint else { return }
                self.policyHealthBySelector[selectorID] = Dictionary(
                    uniqueKeysWithValues: result.members.map { ($0.tag, $0) }
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.policyHealthGeneration else { return }
                self.policyHealthBySelector[selectorID] = Dictionary(
                    uniqueKeysWithValues: availableMembers.map { ($0.tag, .runtimeUnavailable(tag: $0.tag)) }
                )
            }
        }
    }

    func invalidatePolicyHealth() {
        policyHealthGeneration &+= 1
        policyProbeTask?.cancel()
        policyProbeTask = nil
        testingPolicySelectorID = nil
        policyHealthBySelector = [:]
    }

    func updateEditor(_ text: String) {
        guard canEditConfiguration else { return }
        subscriptionFailureDiagnostic = nil
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
            invalidatePolicyHealth()
            // Read only the newly persisted valid revision.  Do not reload the
            // editor: formatting and cursor/editor semantics remain unchanged.
            refreshPolicyCatalog()
            markReadinessChanged()
            return true
        } catch let error as ProfileStoreError {
            present(error)
        } catch { messageKey = "profile.message.operation-failed" }
        return false
    }

    func updateSubscription() {
        guard let profile = selectedProfile, let subscription = profile.subscription, subscriptionTask == nil else { return }
        _ = subscription
        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        messageKey = nil
        subscriptionFailureDiagnostic = nil
        pendingSubscriptionIntake = nil
        isUpdatingSubscription = true
        let profileID = profile.id
        let store = store
        let operations = subscriptionOperations
        subscriptionTask = Task { [weak self] in
            defer {
                if let self, self.subscriptionGeneration == generation {
                    self.subscriptionTask = nil
                    self.isUpdatingSubscription = false
                }
            }
            do {
                let prepared = try await operations.prepareUpdate(profileID: profileID)
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation,
                      self.selectedID == profileID else { return }
                if prepared.candidate == nil {
                    do {
                        _ = try operations.commitNotModified(prepared)
                    } catch {
                        throw SubscriptionPersistenceFailure()
                    }
                }
                self.pendingSubscriptionIntake = prepared.candidate
                self.refreshMetadataPreservingEditor()
                if prepared.candidate == nil { self.messageKey = "profile.subscription.not-modified" }
            } catch {
                guard let self, self.subscriptionGeneration == generation else { return }
                if Task.isCancelled || (error as? SubscriptionUpdateError) == .cancelled {
                    try? store.recordSubscriptionCancellation(for: profileID)
                    self.messageKey = SubscriptionUpdateError.cancelled.messageKey
                    self.subscriptionFailureDiagnostic = nil
                } else {
                    let key = self.subscriptionMessageKey(for: error)
                    try? store.recordSubscriptionFailure(for: profileID, messageKey: key)
                    self.presentSubscriptionError(error)
                }
                self.refreshMetadataPreservingEditor()
            }
        }
    }

    func cancelSubscriptionUpdate() {
        let profileID = selectedProfile?.id
        cancelSubscriptionOperation(clearCandidate: false)
        if let profileID { try? store.recordSubscriptionCancellation(for: profileID) }
        subscriptionFailureDiagnostic = nil
        messageKey = SubscriptionUpdateError.cancelled.messageKey
        refreshMetadataPreservingEditor()
    }

    func cancelSubscriptionIntake() {
        cancelSubscriptionOperation(clearCandidate: true)
        messageKey = "profile.subscription.error.cancelled"
        subscriptionFailureDiagnostic = nil
    }

    func confirmSubscriptionUpdate() {
        guard let pending = pendingSubscriptionIntake else { return }
        request(.applySubscription(pending))
    }

    func discardSubscriptionPreview() {
        pendingSubscriptionIntake = nil
        messageKey = "profile.subscription.preview-dismissed"
        subscriptionFailureDiagnostic = nil
    }

    private func cancelSubscriptionOperation(clearCandidate: Bool) {
        subscriptionGeneration &+= 1
        subscriptionTask?.cancel()
        subscriptionTask = nil
        isUpdatingSubscription = false
        if clearCandidate { pendingSubscriptionIntake = nil }
    }

    private func subscriptionMessageKey(for error: Error) -> String {
        if let error = error as? SubscriptionFetchFailure { return error.cause.messageKey }
        if let error = error as? SubscriptionUpdateError { return error.messageKey }
        if let error = error as? SubscriptionIntakeFailure { return error.cause.messageKey }
        if let error = error as? SubscriptionIntakeError { return error.messageKey }
        if error is SubscriptionPersistenceFailure { return "profile.subscription.error.persistence-failed" }
        if let storeError = error as? ProfileStoreError {
            if case .validationFailed = storeError {
                return SubscriptionIntakeError.validationFailed.messageKey
            }
        }
        return "profile.subscription.error.download-failed"
    }

    private func presentSubscriptionError(_ error: Error) {
        messageKey = subscriptionMessageKey(for: error)
        subscriptionFailureDiagnostic = SubscriptionFailureDiagnostic(error: error)
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
                cancelSubscriptionOperation(clearCandidate: true)
                subscriptionFailureDiagnostic = nil
                try store.select(id)
                selectedID = id
                cancelPreparedImport()
                loadSelectedText()
                markReadinessChanged()
            case .create(let name):
                subscriptionFailureDiagnostic = nil
                let profile = try store.create(name: name)
                try selectAndActivate(profile.id)
                markReadinessChanged()
            case .duplicate(let id):
                subscriptionFailureDiagnostic = nil
                let profile = try store.duplicate(id)
                try selectAndActivate(profile.id)
                markReadinessChanged()
            case .delete(let id):
                subscriptionFailureDiagnostic = nil
                try store.delete(id)
                activate(try store.selectedProfileID() ?? profiles.first(where: { $0.id != id })?.id)
                markReadinessChanged()
            case .restore(let id):
                subscriptionFailureDiagnostic = nil
                try store.restorePreviousValidVersion(for: id)
                activate(id)
                messageKey = "profile.message.restored"
                markReadinessChanged()
            case .importCandidate(let candidate, let name):
                subscriptionFailureDiagnostic = nil
                isCommittingImport = true
                defer { isCommittingImport = false }
                let profile = try store.importCandidate(candidate, name: name)
                pendingImportCandidate = nil
                activate(profile.id)
                messageKey = "profile.import.success"
                markReadinessChanged()
            case .applySubscription(let pending):
                let profile = try subscriptionOperations.commit(pending)
                pendingSubscriptionIntake = nil
                subscriptionFailureDiagnostic = nil
                activate(profile.id)
                messageKey = {
                    if case .newProfile = pending.destination { return "profile.subscription.added" }
                    return "profile.subscription.applied"
                }()
                markReadinessChanged()
            }
        } catch let error as ProfileStoreError {
            if case .applySubscription(let pending) = operation {
                if case .validationFailed(let configurationDiagnostic) = error {
                    diagnostic = configurationDiagnostic
                    presentSubscriptionError(SubscriptionIntakeFailure(
                        cause: .validationFailed,
                        response: pending.response.metadata
                    ))
                } else {
                    presentSubscriptionError(SubscriptionPersistenceFailure())
                }
            } else {
                present(error)
            }
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
        invalidatePolicyHealth()
        guard let selectedID else {
            editorText = ""
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = false
            subscriptionFailureDiagnostic = nil
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
        policyRefreshGeneration &+= 1
        let generation = policyRefreshGeneration
        do {
            policyCatalog = try policyCatalogLoader()
            isPolicyCatalogUnavailable = false
        } catch {
            policyCatalog = nil
            isPolicyCatalogUnavailable = true
        }
        guard !usesCustomPolicyCatalogLoader else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reconciled = try await self.policyOperations.read()
                guard generation == self.policyRefreshGeneration else { return }
                self.policyCatalog = reconciled
                self.isPolicyCatalogUnavailable = false
            } catch {
                guard generation == self.policyRefreshGeneration else { return }
                self.policyCatalog = nil
                self.isPolicyCatalogUnavailable = true
            }
        }
    }

    private func policyMessageKey(for error: TargetPolicyOperationError) -> String {
        switch error {
        case .selectorNotFound, .selectorAmbiguous, .selectorUnavailable,
             .outboundNotFound, .outboundUnavailable:
            "policy.catalog.selection.unavailable"
        case .persistenceFailed:
            "policy.catalog.selection.failed"
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
