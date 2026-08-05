import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private let store: ProfileStore
    private let subscriptionFetcher: SecureSubscriptionFetcher
    private var subscriptionTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    private(set) var profiles: [Profile] = []
    var selectedID: UUID? {
        didSet {
            if oldValue != selectedID { cancelPreparedImport() }
            selectProfile()
        }
    }
    var editorText = ""
    private(set) var diagnostic: ConfigurationDiagnostic?
    private(set) var isDirty = false
    private(set) var messageKey: String?
    private(set) var pendingSubscriptionUpdate: PendingSubscriptionUpdate?
    private(set) var isUpdatingSubscription = false
    private(set) var pendingImportCandidate: ProfileImportCandidate?
    private(set) var isPreparingImport = false
    private(set) var isCommittingImport = false
    private(set) var isShowingExportWarning = false
    private(set) var isExporting = false

    init(store: ProfileStore = ProfileStore(), subscriptionFetcher: SecureSubscriptionFetcher = SecureSubscriptionFetcher()) {
        self.store = store
        self.subscriptionFetcher = subscriptionFetcher
        reload()
    }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }
    var canExport: Bool { selectedProfile != nil && !isDirty && !isExporting }
    var defaultExportFileName: String { store.defaultExportFileNameForSelectedProfile() ?? "Profile.json" }

    func reload() {
        do {
            profiles = try store.listProfiles()
            selectedID = try store.selectedProfileID() ?? profiles.first?.id
            loadSelectedText()
        } catch {
            profiles = []
            selectedID = nil
            editorText = ""
            messageKey = "profile.message.load-failed"
        }
    }

    func create(name: String, subscriptionURL: URL? = nil) {
        do {
            let profile = try store.create(name: name, subscriptionURL: subscriptionURL)
            reload()
            selectedID = profile.id
        } catch { messageKey = "profile.message.operation-failed" }
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
        isCommittingImport = true
        messageKey = nil
        do {
            let profile = try store.importCandidate(candidate, name: name)
            pendingImportCandidate = nil
            reload()
            selectedID = profile.id
            messageKey = "profile.import.success"
        } catch let error as ProfileStoreError {
            present(error)
        } catch { messageKey = "profile.message.operation-failed" }
        isCommittingImport = false
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

    func duplicateSelected() {
        guard let selectedID else { return }
        do {
            let profile = try store.duplicate(selectedID)
            reload()
            self.selectedID = profile.id
        } catch { messageKey = "profile.message.operation-failed" }
    }

    func renameSelected(to name: String) {
        guard let selectedID else { return }
        do { try store.rename(selectedID, to: name); reload() }
        catch { messageKey = "profile.message.operation-failed" }
    }

    func deleteSelected() {
        guard let selectedID else { return }
        do { try store.delete(selectedID); reload() }
        catch { messageKey = "profile.message.operation-failed" }
    }

    func updateEditor(_ text: String) {
        editorText = text
        isDirty = true
        diagnostic = JSONSyntaxChecker.validate(text)
        messageKey = nil
    }

    func format() {
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
        guard let selectedID else { return }
        do {
            try store.save(json: editorText, for: selectedID)
            diagnostic = nil
            isDirty = false
            messageKey = "profile.message.saved"
            reload()
        } catch let error as ProfileStoreError {
            present(error)
        } catch { messageKey = "profile.message.operation-failed" }
    }

    func restorePreviousVersion() {
        guard let selectedID else { return }
        do {
            try store.restorePreviousValidVersion(for: selectedID)
            reload()
            messageKey = "profile.message.restored"
        } catch { messageKey = "profile.message.operation-failed" }
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
                self?.reload()
                if pending == nil { self?.messageKey = "profile.subscription.not-modified" }
            } catch let error as SubscriptionUpdateError {
                if error == .cancelled { try? store.recordSubscriptionCancellation(for: profileID) }
                else { try? store.recordSubscriptionFailure(for: profileID, messageKey: error.messageKey) }
                self?.reload()
                self?.messageKey = error.messageKey
            } catch let error as ProfileStoreError {
                self?.reload()
                self?.present(error)
            } catch {
                try? store.recordSubscriptionFailure(for: profileID, messageKey: "profile.subscription.error.download-failed")
                self?.reload()
                self?.messageKey = "profile.subscription.error.download-failed"
            }
        }
    }

    func cancelSubscriptionUpdate() {
        subscriptionTask?.cancel()
    }

    func confirmSubscriptionUpdate() {
        guard let pending = pendingSubscriptionUpdate else { return }
        do {
            try store.applySubscriptionUpdate(pending)
            pendingSubscriptionUpdate = nil
            reload()
            messageKey = "profile.subscription.applied"
        } catch let error as ProfileStoreError {
            present(error)
        } catch {
            messageKey = "profile.message.operation-failed"
        }
    }

    func discardSubscriptionPreview() {
        pendingSubscriptionUpdate = nil
        messageKey = "profile.subscription.preview-dismissed"
    }

    private func selectProfile() {
        guard let selectedID else { return }
        do { try store.select(selectedID); loadSelectedText() }
        catch { messageKey = "profile.message.load-failed" }
    }

    private func loadSelectedText() {
        guard let selectedID, let text = try? store.configurationText(for: selectedID) else {
            editorText = ""
            isDirty = false
            return
        }
        editorText = text
        diagnostic = nil
        isDirty = false
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
        case .exportFailed: "profile.export.error.failed"
        }
    }
}
