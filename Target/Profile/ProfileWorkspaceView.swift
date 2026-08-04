import SwiftUI
import UniformTypeIdentifiers

struct ProfileWorkspaceView: View {
    var lifecycle: BackendLifecycleModel? = nil
    @State private var model = ProfileViewModel()
    @State private var sheet: ProfileSheet?
    @State private var isImporting = false
    @State private var pendingImport = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.profiles) { profile in
                    ProfileRow(profile: profile)
                        .tag(profile.id)
                        .contextMenu {
                            Button("profile.action.duplicate") { model.selectedID = profile.id; model.duplicateSelected() }
                            Button("profile.action.rename") { model.selectedID = profile.id; sheet = .rename(profile.name) }
                            Divider()
                            Button("profile.action.delete", role: .destructive) { model.selectedID = profile.id; showDeleteConfirmation = true }
                        }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("profile.title")
            .toolbar {
                ToolbarItemGroup {
                    Button("profile.action.create", systemImage: "plus") { sheet = .create }
                    Button("profile.action.import", systemImage: "square.and.arrow.down") { isImporting = true }
                }
            }
        } detail: {
            if let profile = model.selectedProfile {
                editor(for: profile)
            } else {
                ContentUnavailableView("profile.empty.title", systemImage: "doc.text", description: Text("profile.empty.description"))
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            pendingImport = text
            sheet = .importConfiguration
        }
        .sheet(item: $sheet) { sheet in
            ProfileNameSheet(sheet: sheet) { name, url in
                switch sheet {
                case .create: model.create(name: name, subscriptionURL: url)
                case .rename: model.renameSelected(to: name)
                case .importConfiguration: model.importConfiguration(name: name, json: pendingImport)
                }
            }
        }
        .onChange(of: model.selectedID) { _, _ in lifecycle?.refresh() }
        .alert("profile.delete.title", isPresented: $showDeleteConfirmation) {
            Button("profile.action.delete", role: .destructive) { model.deleteSelected(); lifecycle?.refresh() }
            Button("profile.action.cancel", role: .cancel) { }
        } message: {
            Text("profile.delete.message")
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
                Button("profile.action.restore") { model.restorePreviousVersion(); lifecycle?.refresh() }
                    .disabled(profile.validRevision <= 1)
                Spacer()
                Button("profile.action.rename") { sheet = .rename(profile.name) }
                Button("profile.action.duplicate") { model.duplicateSelected() }
                Button("profile.action.delete", role: .destructive) { showDeleteConfirmation = true }
                Button("profile.action.save") { model.save(); lifecycle?.refresh() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
            }
        }
        .padding(20)
        .navigationTitle("profile.editor.title")
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
        let key: LocalizedStringKey = validation.status == .valid ? "profile.validation.valid" : validation.status == .invalid ? "profile.validation.invalid" : "profile.validation.not-checked"
        Text(key).font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
    }
}

private enum ProfileSheet: Identifiable {
    case create
    case rename(String)
    case importConfiguration
    var id: String { switch self { case .create: "create"; case .rename: "rename"; case .importConfiguration: "import" } }
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
        .onAppear { if case .rename(let current) = sheet { name = current } }
    }

    private var titleKey: LocalizedStringKey {
        switch sheet { case .create: "profile.create.title"; case .rename: "profile.rename.title"; case .importConfiguration: "profile.import.title" }
    }
}
