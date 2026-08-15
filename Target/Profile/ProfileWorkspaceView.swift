import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileWorkspaceView: View {
    var lifecycle: BackendLifecycleModel? = nil
    @Bindable var model: ProfileViewModel
    @State private var sheet: ProfileSheet?
    @State private var deleteTarget: UUID?

    init(lifecycle: BackendLifecycleModel?, model: ProfileViewModel) {
        self.lifecycle = lifecycle
        self.model = model
    }

    var body: some View {
        HStack(spacing: 0) {
            profileList
                .frame(
                    minWidth: ProfileWorkspaceLayout.sidebarMinimumWidth,
                    idealWidth: ProfileWorkspaceLayout.sidebarIdealWidth,
                    maxWidth: ProfileWorkspaceLayout.sidebarMaximumWidth,
                    maxHeight: .infinity
                )
            Divider()
            workspaceDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create:
                ProfileNameSheet(sheet: sheet) { name in model.requestCreate(name: name) }
            case .subscription:
                ProfileSubscriptionSheet(model: model)
            case .rename(let id, _):
                ProfileNameSheet(sheet: sheet) { name in model.rename(id, to: name) }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.shouldPresentImportConfirmation },
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
            get: { model.shouldPresentSubscriptionPreview },
            set: {
                if !$0, model.pendingOperation == nil {
                    model.discardSubscriptionPreview()
                }
            }
        )) {
            if let pending = model.pendingSubscriptionUpdate {
                SubscriptionIntakePreview(pending: pending) {
                    model.discardSubscriptionPreview()
                } confirm: {
                    model.confirmSubscriptionUpdate()
                }
            }
        }
        .task { model.refreshPolicyState() }
        .onChange(of: model.readinessChangeGeneration) { _, _ in lifecycle?.refresh() }
        .onChange(of: lifecycle?.runtimeChangeGeneration) { _, _ in
            model.refreshPolicyState()
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
            get: { model.unsavedChangesPresentation.isPresented },
            // An Alert binding can be set to false as part of ordinary button
            // dismissal. It must not discard the pending intent; only the
            // explicit Cancel action below does that.
            set: { model.unsavedChangesAlertPresentationDidChange($0) }
        )) {
            Button("profile.unsaved.save-and-continue") {
                _ = model.resolveUnsavedChanges(.saveAndContinue)
            }
            .accessibilityIdentifier("profile.unsaved.save-and-continue")
            .keyboardShortcut(.defaultAction)
            Button("profile.unsaved.discard", role: .destructive) {
                _ = model.resolveUnsavedChanges(.discardChanges)
            }
            .accessibilityIdentifier("profile.unsaved.discard")
            Button("profile.action.cancel", role: .cancel) {
                _ = model.resolveUnsavedChanges(.cancel)
            }
            .accessibilityIdentifier("profile.unsaved.cancel")
        } message: {
            Text("profile.unsaved.message")
        }
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        if let profile = model.selectedProfile {
            ProfileWorkspaceDetailView(
                profile: profile,
                model: model,
                showRename: { sheet = .rename(profile.id, profile.name) },
                requestDelete: { deleteTarget = profile.id },
                requestExport: { model.requestExport() },
                lifecycle: lifecycle
            )
        } else {
            ProfileWorkspaceEmptyState(
                isPreparingImport: model.isPreparingImport,
                messageKey: model.messageKey
            )
        }
    }

    private var profileList: some View {
        List(selection: Binding(get: { model.selectedID }, set: model.requestSelection)) {
            Section {
                ForEach(model.profiles) { profile in
                    ProfileRow(profile: profile)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("profile.row.\(profile.id.uuidString)")
                        .tag(profile.id)
                        .contextMenu {
                            Button("profile.action.duplicate") { model.requestDuplicate(profile.id) }
                            Button("profile.action.rename") { sheet = .rename(profile.id, profile.name) }
                            Divider()
                            Button("profile.action.delete", role: .destructive) { deleteTarget = profile.id }
                        }
                }
            } header: {
                Text("profile.list.section")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("profile.list.title")
        .accessibilityIdentifier("profile.list")
        .toolbar {
            ToolbarItemGroup {
                Button("profile.action.create", systemImage: "plus") { sheet = .create }
                    .accessibilityIdentifier("profile.action.create")
                Button("profile.subscription.add", systemImage: "link.badge.plus") { sheet = .subscription }
                    .disabled(model.isUpdatingSubscription)
                    .accessibilityIdentifier("profile.action.add-subscription")
                Button("profile.action.import", systemImage: "square.and.arrow.down") { presentImportPanel() }
                    .disabled(model.isPreparingImport || model.isCommittingImport)
                    .accessibilityIdentifier("profile.action.import")
                    .accessibilityLabel(Text("profile.accessibility.import"))
                Button("profile.action.export", systemImage: "square.and.arrow.up") { model.requestExport() }
                    .disabled(!model.canExport)
                    .accessibilityIdentifier("profile.action.export")
                    .accessibilityLabel(Text("profile.accessibility.export"))
            }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        switch ProfileImportPanelResult.resolve(response: panel.runModal(), selectedURL: panel.url) {
        case .selected(let url):
            model.prepareImport(from: url)
        case .cancelled:
            model.importPickerCancelled()
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

enum ProfileImportPanelResult: Equatable {
    case selected(URL)
    case cancelled

    static func resolve(response: NSApplication.ModalResponse, selectedURL: URL?) -> Self {
        guard response == .OK, let selectedURL else { return .cancelled }
        return .selected(selectedURL)
    }
}

private struct ProfileWorkspaceEmptyState: View {
    let isPreparingImport: Bool
    let messageKey: String?

    var body: some View {
        TargetPageLayout {
            TargetPageHeader("profile.title", subtitleKey: "profile.empty.subtitle")
            ContentUnavailableView(
                "profile.empty.title",
                systemImage: "doc.text",
                description: Text("profile.empty.description")
            )
            .accessibilityIdentifier("profile.workspace.empty")
            if isPreparingImport {
                ProgressView("profile.import.preparing")
                    .accessibilityIdentifier("profile.workspace.busy")
            }
            if let messageKey {
                TargetNotice(level: .warning, messageKey: messageKey)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("profile.workspace")
    }
}

private struct ProfileWorkspaceDetailView: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let showRename: () -> Void
    let requestDelete: () -> Void
    let requestExport: () -> Void
    let lifecycle: BackendLifecycleModel?
    @State private var section: ProfileWorkspaceSection = .overview

    private var presentation: ProfileWorkspacePresentation { ProfileWorkspacePresentation(profile: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSummaryHeader(profile: profile, model: model, presentation: presentation)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Picker("profile.workspace.section", selection: $section) {
                ForEach(ProfileWorkspaceSection.allCases) { item in
                    Label(LocalizedStringKey(item.titleKey), systemImage: item.symbolName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .accessibilityIdentifier("profile.workspace.section-switcher")

            Divider()
            sectionContent
        }
        .navigationTitle("profile.editor.title")
        .overlay(alignment: .top) {
            if model.isPreparingImport || model.isCommittingImport {
                ProgressView(model.isCommittingImport ? "profile.import.committing" : "profile.import.preparing")
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("profile.workspace.busy")
                }
        }
        .onChange(of: lifecycle?.status) { _, _ in
            model.invalidatePolicyHealth()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .overview:
            ProfileOverviewView(
                profile: profile,
                model: model,
                presentation: presentation,
                showRename: showRename,
                requestDelete: requestDelete,
                requestExport: requestExport,
                showProxies: { section = .proxies }
            )
        case .proxies:
            ProfilePolicyWorkspaceView(
                catalog: model.policyCatalog,
                unavailable: model.isPolicyCatalogUnavailable,
                isSelecting: model.isSelectingPolicy,
                healthBySelector: model.policyHealthBySelector,
                testingSelectorID: model.testingPolicySelectorID,
                lifecycle: lifecycle,
                select: model.selectPolicy,
                probeLatency: model.probePolicyLatency,
                reset: model.resetPolicy,
                refresh: model.refreshPolicyState
            )
        case .configuration:
            ProfileConfigurationView(
                profile: profile,
                model: model,
                showRename: showRename,
                requestDelete: requestDelete,
                requestExport: requestExport
            )
        }
    }
}

private enum ProfileWorkspaceSection: String, CaseIterable, Identifiable {
    case overview
    case proxies
    case configuration

    var id: String { rawValue }
    var titleKey: String { "profile.workspace.section.\(rawValue)" }
    var symbolName: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .configuration: "curlybraces"
        }
    }
}

private struct ProfileOverviewView: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let presentation: ProfileWorkspacePresentation
    let showRename: () -> Void
    let requestDelete: () -> Void
    let requestExport: () -> Void
    let showProxies: () -> Void

    private var policyPresentation: PolicyWorkspacePresentation {
        PolicyWorkspacePresentation(catalog: model.policyCatalog, unavailable: model.isPolicyCatalogUnavailable)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let subscription = profile.subscription {
                    ProfileSubscriptionStatus(
                        subscription: subscription,
                        presentation: presentation,
                        isUpdating: model.isUpdatingSubscription,
                        update: model.updateSubscription,
                        cancel: model.cancelSubscriptionUpdate
                    )
                }
                TargetSectionTitle("profile.overview.policy", systemImage: "point.3.connected.trianglepath.dotted")
                policySummary
                ProfileFeedback(
                    diagnostic: model.diagnostic,
                    subscriptionFailure: model.subscriptionFailureDiagnostic,
                    messageKey: model.messageKey
                )
                Divider()
                ProfileOverviewActions(
                    profile: profile,
                    model: model,
                    showRename: showRename,
                    requestDelete: requestDelete,
                    requestExport: requestExport
                )
            }
            .frame(maxWidth: TargetUI.pageContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("profile.workspace.overview")
    }

    private var policySummary: some View {
        Button(action: showProxies) {
            VStack(alignment: .leading, spacing: 9) {
                if model.isPolicyCatalogUnavailable {
                    Label("policy.catalog.unavailable.title", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                } else if policyPresentation.selectorCount == 0 {
                    Label("policy.catalog.empty.title", systemImage: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 22) {
                        ProfilePolicyMetric(labelKey: "profile.overview.selectors", value: "\(policyPresentation.selectorCount)")
                        ProfilePolicyMetric(labelKey: "profile.overview.overrides", value: "\(policyPresentation.overrideCount)")
                        ProfilePolicyMetric(
                            labelKey: "profile.overview.needs-restart",
                            value: "\(policyPresentation.restartRequiredCount)"
                        )
                    }
                    if policyPresentation.restartRequiredCount > 0 {
                        Label("policy.catalog.restart-required", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if policyPresentation.hasIssues {
                        Label("profile.overview.policy.issues", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("profile.overview.policy.ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.overview.policy-summary")
        .accessibilityHint(Text("profile.overview.policy.open.hint"))
    }
}

private struct ProfilePolicyMetric: View {
    let labelKey: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(LocalizedStringKey(labelKey)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileOverviewActions: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let showRename: () -> Void
    let requestDelete: () -> Void
    let requestExport: () -> Void

    var body: some View {
        ProfileMoreActions(
            profile: profile,
            model: model,
            showRename: showRename,
            requestDelete: requestDelete,
            requestExport: requestExport
        )
    }
}

private struct ProfileConfigurationView: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let showRename: () -> Void
    let requestDelete: () -> Void
    let requestExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TargetSectionTitle("profile.editor.section", systemImage: "curlybraces")
                    .accessibilityIdentifier("profile.editor.section")
                Spacer()
                if model.isDirty {
                    Label("profile.unsaved.indicator", systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("profile.unsaved.indicator"))
                        .accessibilityHint(Text("profile.unsaved.accessibility.hint"))
                        .accessibilityIdentifier("profile.editor.dirty")
                }
            }
            ZStack {
                JSONCodeEditor(
                    text: Binding(get: { model.editorText }, set: model.updateEditor),
                    isEditable: model.canEditConfiguration,
                    accessibilityIdentifier: "profile.json-editor",
                    accessibilityLabel: String(localized: "profile.editor.accessibility.label")
                )
                .id(profile.id)
                if !model.isConfigurationLoaded {
                    ContentUnavailableView(
                        "profile.editor.unavailable.title",
                        systemImage: "lock.trianglebadge.exclamationmark",
                        description: Text("profile.editor.unavailable.description")
                    )
                    .accessibilityIdentifier("profile.editor.unavailable")
                }
            }
            .frame(maxWidth: .infinity, minHeight: ProfileWorkspaceLayout.minimumEditorHeight, idealHeight: ProfileWorkspaceLayout.preferredEditorHeight, maxHeight: .infinity)
            .layoutPriority(1)
            ProfileFeedback(
                diagnostic: model.diagnostic,
                subscriptionFailure: model.subscriptionFailureDiagnostic,
                messageKey: model.messageKey
            )
            Divider()
            ProfileEditorActions(
                profile: profile,
                model: model,
                showRename: showRename,
                requestDelete: requestDelete,
                requestExport: requestExport
            )
        }
        // Keep the Configuration workspace's AX frame aligned with its detail
        // pane. Without an explicit expansion, AppKit reports only this
        // VStack's intrinsic content width even when the editor fills the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.workspace.configuration")
    }
}

private struct ProfileSummaryHeader: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let presentation: ProfileWorkspacePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("profile.summary.name")
                    Label(sourceKey, systemImage: sourceSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile.summary.source")
                }
                Spacer(minLength: 8)
                ProfileStatusBadge(level: presentation.validationLevel, titleKey: presentation.validationTitleKey)
                    .accessibilityIdentifier("profile.summary.validation")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    metadata
                }
                VStack(alignment: .leading, spacing: 4) {
                    metadata
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.workspace.summary")
    }

    @ViewBuilder
    private var metadata: some View {
        Label {
            Text("profile.summary.updated") + Text(" ") + Text(profile.updatedAt, style: .relative)
        } icon: {
            Image(systemName: "clock")
        }
        Label {
            Text("profile.revision") + Text(" \(profile.validRevision)")
        } icon: {
            Image(systemName: "number")
        }
        if let checkedAt = profile.validation.checkedAt {
            Label {
                Text("profile.summary.checked") + Text(" ") + Text(checkedAt, style: .relative)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        }
    }

    private var sourceKey: LocalizedStringKey {
        presentation.source == .remote ? "profile.source.remote" : "profile.source.local"
    }

    private var sourceSymbol: String {
        presentation.source == .remote ? "link" : "doc.text"
    }
}

private struct ProfileSubscriptionStatus: View {
    let subscription: RemoteSubscription
    let presentation: ProfileWorkspacePresentation
    let isUpdating: Bool
    let update: () -> Void
    let cancel: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.subscription.summary")
    }

    @ViewBuilder
    private var content: some View {
        Label("profile.subscription.status", systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
        if let titleKey = presentation.subscriptionTitleKey,
           let level = presentation.subscriptionLevel {
            ProfileStatusBadge(level: level, titleKey: titleKey)
        }
        if let checkedAt = subscription.lastCheckedAt {
            Label {
                Text("profile.subscription.last-checked") + Text(" ") + Text(checkedAt, style: .relative)
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(.secondary)
        }
        if let error = subscription.lastErrorKey {
            Label(LocalizedStringKey(error), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        Spacer(minLength: 0)
        if isUpdating {
            ProgressView().controlSize(.small)
            Button("profile.subscription.cancel", action: cancel)
                .accessibilityIdentifier("profile.subscription.cancel")
        } else {
            Button("profile.subscription.update", action: update)
                .accessibilityIdentifier("profile.subscription.update")
        }
    }
}

private struct ProfileFeedback: View {
    let diagnostic: ConfigurationDiagnostic?
    let subscriptionFailure: SubscriptionFailureDiagnostic?
    let messageKey: String?

    var body: some View {
        Group {
            if let subscriptionFailure {
                SubscriptionFailureView(diagnostic: subscriptionFailure)
            } else if let diagnostic {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(diagnostic.messageKey))
                        if let line = diagnostic.line, let column = diagnostic.column {
                            Text("profile.validation.location") + Text(" \(line):\(column)")
                        }
                    }
                }
                .foregroundStyle(.red)
                .font(.callout)
                .accessibilityIdentifier("profile.feedback.diagnostic")
            } else if let messageKey {
                TargetNotice(level: .neutral, messageKey: messageKey)
                    .accessibilityIdentifier("profile.feedback.message")
            }
        }
    }
}

private struct SubscriptionFailureView: View {
    let diagnostic: SubscriptionFailureDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(diagnostic.titleKey), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(LocalizedStringKey(diagnostic.reasonKey))
                .font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("profile.subscription.diagnostic.stage", LocalizedStringKey(diagnostic.stage.titleKey))
                row("profile.subscription.diagnostic.category", LocalizedStringKey(diagnostic.reasonKey))
                if let status = diagnostic.httpStatus {
                    row("profile.subscription.diagnostic.http-status", Text("\(status)"))
                }
                if let domain = diagnostic.transportErrorDomain, let code = diagnostic.transportErrorCode {
                    row("profile.subscription.diagnostic.error-code", Text("\(domain) \(code)"))
                }
                if let attempts = diagnostic.attemptCount {
                    row("profile.subscription.diagnostic.attempts", Text("\(attempts)"))
                }
                if let contentType = diagnostic.contentType {
                    row("profile.subscription.diagnostic.content-type", Text(contentType))
                }
                if let bytes = diagnostic.responseBytes {
                    row("profile.subscription.diagnostic.response-bytes", Text("\(bytes)"))
                }
                if diagnostic.showsSupportedFormats {
                    row("profile.subscription.diagnostic.supported-formats",
                        LocalizedStringKey("profile.subscription.diagnostic.supported-formats.value"))
                }
                if let retryable = diagnostic.isRetryable {
                    row("profile.subscription.diagnostic.retry",
                        LocalizedStringKey(retryable
                            ? "profile.subscription.diagnostic.retry.yes"
                            : "profile.subscription.diagnostic.retry.no"))
                }
            }
            .font(.caption)
            Button("profile.subscription.diagnostic.copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diagnostic.copyableDescription, forType: .string)
            }
            .controlSize(.small)
            .accessibilityIdentifier("profile.subscription.diagnostic.copy")
        }
        .padding(12)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.subscription.failure-diagnostic")
    }

    @ViewBuilder
    private func row(_ titleKey: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        row(titleKey, Text(value))
    }

    @ViewBuilder
    private func row(_ titleKey: LocalizedStringKey, _ value: Text) -> some View {
        GridRow {
            Text(titleKey).foregroundStyle(.secondary)
            value.textSelection(.enabled)
        }
    }
}

private struct ProfileEditorActions: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let showRename: () -> Void
    let requestDelete: () -> Void
    let requestExport: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actions }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("profile.action.format") { model.format() }
                        .accessibilityIdentifier("profile.action.format")
                        .disabled(!model.canEditConfiguration)
                    ProfileMoreActions(
                        profile: profile,
                        model: model,
                        showRename: showRename,
                        requestDelete: requestDelete,
                        requestExport: requestExport
                    )
                    Spacer()
                    saveButton
                }
                Text("profile.history.available") + Text(" \(profile.validRevision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("profile.editor.actions")
    }

    @ViewBuilder
    private var actions: some View {
        Button("profile.action.format") { model.format() }
            .accessibilityIdentifier("profile.action.format")
            .disabled(!model.canEditConfiguration)
        Text("profile.history.available") + Text(" \(profile.validRevision)")
            .font(.caption)
            .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        ProfileMoreActions(
            profile: profile,
            model: model,
            showRename: showRename,
            requestDelete: requestDelete,
            requestExport: requestExport
        )
        saveButton
    }

    private var saveButton: some View {
        Button("profile.action.save") { model.save() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s")
            .disabled(!model.isDirty || !model.canEditConfiguration)
            .accessibilityIdentifier("profile.action.save")
    }
}

private struct ProfileMoreActions: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let showRename: () -> Void
    let requestDelete: () -> Void
    let requestExport: () -> Void

    var body: some View {
        Menu {
            Button("profile.action.rename", action: showRename)
            Button("profile.action.duplicate") { model.requestDuplicate(profile.id) }
            Button("profile.action.restore") { model.requestRestore(profile.id) }
                .disabled(profile.validRevision <= 1)
            Divider()
            Button("profile.action.export", action: requestExport)
                .disabled(!model.canExport)
            Divider()
            Button("profile.action.delete", role: .destructive, action: requestDelete)
        } label: {
            Text("profile.actions.more")
        }
        .accessibilityIdentifier("profile.actions.more")
        .accessibilityHint(Text("profile.actions.more.hint"))
    }
}

private struct ProfileStatusBadge: View {
    let level: ProfileWorkspaceStatusLevel
    let titleKey: String

    var body: some View {
        TargetStatusBadge(level: targetLevel, titleKey: titleKey)
    }

    private var targetLevel: TargetStatusLevel {
        switch level {
        case .neutral: .neutral
        case .positive: .positive
        case .warning: .warning
        case .critical: .critical
        }
    }
}

private struct SubscriptionIntakePreview: View {
    let pending: PendingSubscriptionIntake
    let dismiss: () -> Void
    let confirm: () -> Void

    private var summary: SubscriptionCompatibilitySummary { pending.normalization.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("profile.subscription.preview.title")
                .font(.headline)
                .accessibilityIdentifier("profile.subscription.preview")
            Text("profile.subscription.preview.description").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("profile.subscription.preview.format").foregroundStyle(.secondary)
                    Text(LocalizedStringKey(summary.format.titleKey))
                }
                GridRow {
                    Text("profile.subscription.preview.imported-nodes").foregroundStyle(.secondary)
                    Text("\(summary.nodeCount)")
                }
                if summary.skippedNodeCount > 0 {
                    GridRow {
                        Text("profile.subscription.preview.skipped-nodes").foregroundStyle(.secondary)
                        Text("\(summary.skippedNodeCount) / \(summary.totalNodeCount)")
                    }
                    GridRow {
                        Text("profile.subscription.preview.skipped-protocols").foregroundStyle(.secondary)
                        Text(summary.skippedProtocols.map(\.rawValue).joined(separator: ", "))
                    }
                }
                GridRow {
                    Text("profile.subscription.preview.protocols").foregroundStyle(.secondary)
                    Text(summary.protocols.map(\.rawValue).joined(separator: ", "))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.subscription.compatibility-summary")
            if summary.warnings.contains(.providerSemanticsNotImported) {
                Label("profile.subscription.warning.provider-semantics", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("profile.subscription.compatibility-warning")
            }
            if summary.warnings.contains(.unsupportedNodesSkipped) {
                Label("profile.subscription.warning.unsupported-nodes", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("profile.subscription.compatibility-warning.unsupported-nodes")
            }
            if summary.warnings.contains(.tlsVerificationRequired) {
                Label("profile.subscription.warning.tls-verification", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("profile.subscription.compatibility-warning.tls-verification")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let diff = pending.diff {
                        DiffSection(section: diff.outbounds)
                        DiffSection(section: diff.routeRules)
                        DiffSection(section: diff.dns)
                        DiffSection(section: diff.inbounds)
                        DiffSection(section: diff.unknown)
                        if !diff.hasChanges {
                            Text("profile.diff.no-changes").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("profile.subscription.preview.new-description").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("profile.subscription.discard") { dismiss() }
                Button(confirmTitleKey) { confirm() }
                    .accessibilityIdentifier("profile.subscription.confirm")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }

    private var confirmTitleKey: LocalizedStringKey {
        if case .newProfile = pending.destination { return "profile.subscription.add-confirm" }
        return "profile.subscription.confirm"
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
    case subscription
    case rename(UUID, String)
    var id: String { switch self { case .create: "create"; case .subscription: "subscription"; case .rename: "rename" } }
}

private struct ProfileNameSheet: View {
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

private struct ProfileSubscriptionSheet: View {
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
