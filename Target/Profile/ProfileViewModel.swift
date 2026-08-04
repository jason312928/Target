import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private let store: ProfileStore

    private(set) var profiles: [Profile] = []
    var selectedID: UUID? { didSet { selectProfile() } }
    var editorText = ""
    private(set) var diagnostic: ConfigurationDiagnostic?
    private(set) var isDirty = false
    private(set) var messageKey: String?

    init(store: ProfileStore = ProfileStore()) {
        self.store = store
        reload()
    }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }

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

    func importConfiguration(name: String, json: String) {
        do {
            let profile = try store.import(name: name, json: json)
            reload()
            selectedID = profile.id
        } catch let error as ProfileStoreError {
            present(error)
        } catch { messageKey = "profile.message.operation-failed" }
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
        default:
            self.messageKey = "profile.message.operation-failed"
        }
    }
}
