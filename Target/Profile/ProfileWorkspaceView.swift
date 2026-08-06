import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileWorkspaceView: View {
    var lifecycle: BackendLifecycleModel? = nil
    @Bindable var model: ProfileViewModel
    @State private var sheet: ProfileSheet?
    @State private var isImporting = false
    @State private var deleteTarget: UUID?
    @State private var isShowingUnsavedChangesAlert = false

    init(lifecycle: BackendLifecycleModel?, model: ProfileViewModel) {
        self.lifecycle = lifecycle
        self.model = model
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedID }, set: model.requestSelection)) {
                ForEach(model.profiles) { profile in
                    ProfileRow(profile: profile)
                        .tag(profile.id)
                        .contextMenu {
                            Button("profile.action.duplicate") { model.requestDuplicate(profile.id) }
                            Button("profile.action.rename") { sheet = .rename(profile.id, profile.name) }
                            Divider()
                            Button("profile.action.delete", role: .destructive) { deleteTarget = profile.id }
                        }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("profile.list.title")
            .toolbar {
                ToolbarItemGroup {
                    Button("profile.action.create", systemImage: "plus") { sheet = .create }
                    Button("profile.action.import", systemImage: "square.and.arrow.down") { isImporting = true }
                        .disabled(model.isPreparingImport || model.isCommittingImport)
                        .accessibilityLabel(Text("profile.accessibility.import"))
                    Button("profile.action.export", systemImage: "square.and.arrow.up") { model.requestExport() }
                        .disabled(!model.canExport)
                        .accessibilityLabel(Text("profile.accessibility.export"))
                }
            }
        } detail: {
            if let profile = model.selectedProfile {
                editor(for: profile)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("profile.empty.title", systemImage: "doc.text", description: Text("profile.empty.description"))
                    if model.isPreparingImport { ProgressView("profile.import.preparing") }
                    if let messageKey = model.messageKey { Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary) }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.prepareImport(from: url)
            case .failure: model.importPickerCancelled()
            }
        }
        .sheet(item: $sheet) { sheet in
            ProfileNameSheet(sheet: sheet) { name, url in
                switch sheet {
                case .create: model.requestCreate(name: name, subscriptionURL: url)
                case .rename(let id, _): model.rename(id, to: name)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingImportCandidate != nil && model.pendingOperation == nil },
            set: {
                if !$0, model.pendingOperation == nil {
                    model.cancelPreparedImport()
                }
            }
        )) {
            if let candidate = model.pendingImportCandidate {
                ProfileImportConfirmation(candidate: candidate, isCommitting: model.isCommittingImport) { name in
                    model.commitPreparedImport(name: name)
                } cancel: {
                    model.cancelPreparedImport()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingSubscriptionUpdate != nil && model.pendingOperation == nil },
            set: {
                if !$0, model.pendingOperation == nil {
                    model.discardSubscriptionPreview()
                }
            }
        )) {
            if let pending = model.pendingSubscriptionUpdate {
                SubscriptionDiffPreview(diff: pending.diff) {
                    model.discardSubscriptionPreview()
                } confirm: {
                    model.confirmSubscriptionUpdate()
                }
            }
        }
        .onChange(of: model.readinessChangeGeneration) { _, _ in lifecycle?.refresh() }
        .onChange(of: model.unsavedChangesDecisionGeneration) { _, _ in
            isShowingUnsavedChangesAlert = model.pendingOperation != nil
        }
        .alert("profile.delete.title", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("profile.action.delete", role: .destructive) {
                if let deleteTarget { model.requestDelete(deleteTarget) }
                deleteTarget = nil
            }
            Button("profile.action.cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("profile.delete.message")
        }
        .alert("profile.export.warning.title", isPresented: Binding(
            get: { model.isShowingExportWarning },
            set: { if !$0 { model.dismissExportWarning() } }
        )) {
            Button("profile.action.cancel", role: .cancel) { model.dismissExportWarning() }
            Button("profile.export.warning.confirm") { presentExportPanel() }
        } message: {
            Text("profile.export.warning.message")
        }
        .alert("profile.unsaved.title", isPresented: Binding(
            get: { isShowingUnsavedChangesAlert },
            // An Alert binding can be set to false as part of ordinary button
            // dismissal. It must not discard the pending intent; only the
            // explicit Cancel action below does that.
            set: { isShowingUnsavedChangesAlert = $0 }
        )) {
            Button("profile.unsaved.save-and-continue") {
                model.resolveUnsavedChanges(.saveAndContinue)
                isShowingUnsavedChangesAlert = false
            }
            .keyboardShortcut(.defaultAction)
            Button("profile.unsaved.discard", role: .destructive) {
                model.resolveUnsavedChanges(.discardChanges)
                isShowingUnsavedChangesAlert = false
            }
            Button("profile.action.cancel", role: .cancel) {
                model.cancelUnsavedChangesConfirmation()
                isShowingUnsavedChangesAlert = false
            }
        } message: {
            Text("profile.unsaved.message")
        }
    }

    @ViewBuilder
    private func editor(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.title2)
                    Text(profile.hasRemoteSubscription ? "profile.source.remote" : "profile.source.local")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ValidationBadge(validation: profile.validation)
            }

            HStack(spacing: 14) {
                Label { Text(profile.updatedAt, style: .relative) } icon: { Image(systemName: "clock") }
                Text("profile.revision") + Text(" \(profile.validRevision)")
                if let checkedAt = profile.validation.checkedAt { Text(checkedAt, style: .relative) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.isDirty {
                Label("profile.unsaved.indicator", systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("profile.unsaved.indicator"))
                    .accessibilityHint(Text("profile.unsaved.accessibility.hint"))
            }

            if let subscription = profile.subscription {
                HStack(spacing: 10) {
                    Label {
                        Text(LocalizedStringKey(subscription.cacheStatus == .notModified ? "profile.subscription.cache.not-modified" : "profile.subscription.cache.\(subscription.cacheStatus.rawValue)"))
                    } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                    if let checked = subscription.lastCheckedAt { Text(checked, style: .relative) }
                    if let error = subscription.lastErrorKey { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
                    Spacer()
                    if model.isUpdatingSubscription {
                        ProgressView().controlSize(.small)
                        Button("profile.subscription.cancel") { model.cancelSubscriptionUpdate() }
                    } else {
                        Button("profile.subscription.update") { model.updateSubscription() }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            JSONCodeEditor(text: Binding(get: { model.editorText }, set: model.updateEditor)) { model.updateEditor($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let diagnostic = model.diagnostic {
                Label {
                    Text(LocalizedStringKey(diagnostic.messageKey))
                    if let line = diagnostic.line, let column = diagnostic.column {
                        Text("profile.validation.location") + Text(" \(line):\(column)")
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(.red)
                .font(.callout)
            } else if let messageKey = model.messageKey {
                Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary).font(.callout)
            }

            HStack {
                Button("profile.action.format") { model.format() }
                Button("profile.action.restore") { model.requestRestore(profile.id) }
                    .disabled(profile.validRevision <= 1)
                Text("profile.history.available") + Text(" \(profile.validRevision)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("profile.action.rename") { sheet = .rename(profile.id, profile.name) }
                Button("profile.action.duplicate") { model.requestDuplicate(profile.id) }
                Button("profile.action.delete", role: .destructive) { deleteTarget = profile.id }
                Button("profile.action.export") { model.requestExport() }
                    .disabled(!model.canExport)
                    .help(model.isDirty ? "profile.export.unsaved-changes" : "")
                    .accessibilityHint(Text(model.isDirty ? "profile.export.unsaved-changes" : "profile.accessibility.export"))
                Button("profile.action.save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
            }
        }
        .padding(20)
        .navigationTitle("profile.editor.title")
        .overlay(alignment: .top) {
            if model.isPreparingImport || model.isCommittingImport {
                ProgressView(model.isCommittingImport ? "profile.import.committing" : "profile.import.preparing")
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.defaultExportFileName
        if panel.runModal() == .OK, let destination = panel.url {
            model.exportSelectedProfile(to: destination)
        } else {
            model.exportCancelled()
        }
    }

}

private struct SubscriptionDiffPreview: View {
    let diff: ProfileConfigurationDiff
    let dismiss: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("profile.subscription.preview.title").font(.headline)
            Text("profile.subscription.preview.description").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DiffSection(section: diff.outbounds)
                    DiffSection(section: diff.routeRules)
                    DiffSection(section: diff.dns)
                    DiffSection(section: diff.inbounds)
                    DiffSection(section: diff.unknown)
                    if !diff.hasChanges {
                        Text("profile.diff.no-changes").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("profile.subscription.discard") { dismiss() }
                Button("profile.subscription.confirm") { confirm() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }
}

private struct DiffSection: View {
    let section: ProfileConfigurationDiff.Section

    var body: some View {
        if section.hasChanges {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(section.id)).font(.subheadline.weight(.semibold))
                ForEach(section.added, id: \.self) { entry in
                    Label {
                        if entry == "profile.diff.added" { Text(LocalizedStringKey(entry)) }
                        else { Text(verbatim: entry) }
                    } icon: { Image(systemName: "plus.circle.fill") }
                        .foregroundStyle(.green)
                }
                ForEach(section.removed, id: \.self) { entry in
                    Label {
                        if entry == "profile.diff.removed" { Text(LocalizedStringKey(entry)) }
                        else { Text(verbatim: entry) }
                    } icon: { Image(systemName: "minus.circle.fill") }
                        .foregroundStyle(.red)
                }
                ForEach(section.modified, id: \.self) { entry in
                    Label {
                        if entry == "profile.diff.changed" { Text(LocalizedStringKey(entry)) }
                        else { Text(verbatim: entry) }
                    } icon: { Image(systemName: "pencil.circle.fill") }
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }
}

private struct ProfileRow: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: profile.hasRemoteSubscription ? "link" : "doc.text")
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1)
                Text(statusKey).font(.caption).foregroundStyle(.secondary)
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

private struct ValidationBadge: View {
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

private enum ProfileSheet: Identifiable {
    case create
    case rename(UUID, String)
    var id: String { switch self { case .create: "create"; case .rename: "rename" } }
}

private struct ProfileNameSheet: View {
    let sheet: ProfileSheet
    var completion: (String, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subscriptionURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleKey).font(.headline)
            TextField("profile.field.name", text: $name)
            if case .create = sheet {
                TextField("profile.field.subscription-url", text: $subscriptionURL)
                Text("profile.subscription.hint").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("profile.action.cancel") { dismiss() }; Button("profile.action.confirm") {
                completion(name, URL(string: subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)))
                dismiss()
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { if case .rename(_, let current) = sheet { name = current } }
    }

    private var titleKey: LocalizedStringKey {
        switch sheet { case .create: "profile.create.title"; case .rename: "profile.rename.title" }
    }
}

private struct ProfileImportConfirmation: View {
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
            Text("profile.import.confirm.title").font(.headline)
            Text("profile.import.confirm.description").foregroundStyle(.secondary)
            Text("profile.import.confirm.size") + Text(" \(candidate.fileSize)")
                .font(.caption).foregroundStyle(.secondary)
            TextField("profile.field.name", text: $name)
                .accessibilityLabel(Text("profile.field.name"))
            HStack {
                Spacer()
                Button("profile.action.cancel") { cancel() }.disabled(isCommitting)
                Button("profile.action.confirm") { confirm(name) }
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
