import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileRow: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: profile.hasRemoteSubscription ? "link" : "doc.text")
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text(statusKey)
                    Text("·")
                    Text(profile.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: icon).foregroundStyle(color).accessibilityLabel(Text(statusKey))
        }
    }

    private var statusKey: LocalizedStringKey {
        switch profile.validation.status {
        case .valid: "profile.validation.valid"
        case .invalid: "profile.validation.invalid"
        case .notChecked: "profile.validation.not-checked"
        }
    }
    private var icon: String { profile.validation.status == .valid ? "checkmark.circle.fill" : profile.validation.status == .invalid ? "xmark.circle.fill" : "circle.dashed" }
    private var color: Color { profile.validation.status == .valid ? .green : profile.validation.status == .invalid ? .red : .secondary }
}

struct ValidationBadge: View {
    let validation: ProfileValidation

    var body: some View {
        TargetStatusBadge(level: statusLevel, titleKey: titleKey)
    }

    private var titleKey: String {
        switch validation.status {
        case .valid: "profile.validation.valid"
        case .invalid: "profile.validation.invalid"
        case .notChecked: "profile.validation.not-checked"
        }
    }

    private var statusLevel: TargetStatusLevel {
        switch validation.status {
        case .valid: .positive
        case .invalid: .critical
        case .notChecked: .neutral
        }
    }
}

enum ProfileSheet: Identifiable {
    case create
    case subscription
    case rename(UUID, String)
    var id: String { switch self { case .create: "create"; case .subscription: "subscription"; case .rename: "rename" } }
}

struct ProfileNameSheet: View {
    let sheet: ProfileSheet
    var completion: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleKey).font(.headline)
            TextField("profile.field.name", text: $name)
            HStack { Spacer(); Button("profile.action.cancel") { dismiss() }; Button("profile.action.confirm") {
                completion(name)
                dismiss()
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { if case .rename(_, let current) = sheet { name = current } }
    }

    private var titleKey: LocalizedStringKey {
        switch sheet {
        case .create: "profile.create.title"
        case .subscription: "profile.subscription.add"
        case .rename: "profile.rename.title"
        }
    }
}

struct ProfileSubscriptionSheet: View {
    @Bindable var model: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @State private var submitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("profile.subscription.add").font(.headline)
            Text("profile.subscription.add.description").font(.callout).foregroundStyle(.secondary)
            if !submitted {
                TextField("profile.field.name", text: $name)
                    .accessibilityIdentifier("profile.subscription.name")
                TextField("profile.field.subscription-url", text: $urlText)
                    .accessibilityIdentifier("profile.subscription.url")
                Text("profile.subscription.hint").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("profile.subscription.remote-source", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile.subscription.safe-source")
            }
            if submitted && model.isUpdatingSubscription {
                ProgressView("profile.subscription.preparing")
                    .accessibilityIdentifier("profile.subscription.progress")
            }
            if submitted, let diagnostic = model.subscriptionFailureDiagnostic, !model.isUpdatingSubscription {
                SubscriptionFailureView(diagnostic: diagnostic)
                    .accessibilityIdentifier("profile.subscription.safe-error")
            } else if submitted, let messageKey = model.messageKey, !model.isUpdatingSubscription {
                Label(LocalizedStringKey(messageKey), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("profile.subscription.safe-error")
            }
            HStack {
                Spacer()
                Button("profile.action.cancel") {
                    model.cancelSubscriptionIntake()
                    dismiss()
                }
                .accessibilityIdentifier("profile.subscription.intake-cancel")
                Button("profile.action.continue") { submit() }
                    .accessibilityIdentifier("profile.subscription.continue")
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitted || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.subscription.intake-sheet")
        .onChange(of: model.pendingSubscriptionIntake != nil) { _, ready in
            if ready { dismiss() }
        }
        .onDisappear {
            if model.isUpdatingSubscription, model.pendingSubscriptionIntake == nil {
                model.cancelSubscriptionIntake()
            }
        }
    }

    private var parsedURL: URL? {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8 * 1_024 else { return nil }
        return URL(string: value)
    }

    private func submit() {
        guard let url = parsedURL else { return }
        submitted = true
        let profileName = name
        urlText = ""
        model.prepareSubscription(name: profileName, url: url)
    }
}

struct ProfileImportConfirmation: View {
    let candidate: ProfileImportCandidate
    let isCommitting: Bool
    let confirm: (String) -> Void
    let cancel: () -> Void
    @State private var name: String

    init(candidate: ProfileImportCandidate, isCommitting: Bool, confirm: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.candidate = candidate
        self.isCommitting = isCommitting
        self.confirm = confirm
        self.cancel = cancel
        _name = State(initialValue: candidate.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("profile.import.confirm.title")
                .font(.headline)
                .accessibilityIdentifier("profile.import.confirmation")
            Text("profile.import.confirm.description").foregroundStyle(.secondary)
            Text("profile.import.confirm.size") + Text(" \(candidate.fileSize)")
                .font(.caption).foregroundStyle(.secondary)
            TextField("profile.field.name", text: $name)
                .accessibilityLabel(Text("profile.field.name"))
            HStack {
                Spacer()
                Button("profile.action.cancel") { cancel() }.disabled(isCommitting)
                Button("profile.action.confirm") { confirm(name) }
                    .accessibilityIdentifier("profile.import.confirm")
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCommitting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isCommitting { ProgressView("profile.import.committing") }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("profile.import.confirm.title"))
    }
}
