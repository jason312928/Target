import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileWorkspaceView: View {
    var lifecycle: BackendLifecycleModel? = nil
    @Bindable var model: ProfileViewModel
    @Environment(\.openWindow) private var openWindow
    private let connectionSidebar: AnyView?
    @State private var sheet: ProfileSheet?
    @State private var deleteTarget: UUID?
    @State private var participatingRoutes: [PolicyCountryRoute] = []
    @State private var section: ProfileWorkspaceSection = .proxies
    @State private var inspectedCountryCode: String?
    @AppStorage("profiles.smart-participants") private var participationRawValue = "*"

    init(
        lifecycle: BackendLifecycleModel?,
        model: ProfileViewModel,
        connectionSidebar: AnyView? = nil
    ) {
        self.lifecycle = lifecycle
        self.model = model
        self.connectionSidebar = connectionSidebar
    }

    var body: some View {
        configuredWorkspace
            .safeAreaInset(edge: .top, spacing: 0) {
                if let lifecycle, lifecycle.isEngineRunning, lifecycle.canRestart {
                    HStack {
                        Label("profile.runtime.pending", systemImage: "arrow.clockwise")
                            .font(.callout)
                        Spacer()
                        Button("profile.runtime.apply") { lifecycle.restartWithCurrentProfile() }
                            .disabled(model.isDirty || model.isPerformingPersistence || lifecycle.isBusy)
                    }
                    .padding(12)
                    .background(.background.secondary)
                    Divider()
                }
            }
            .toolbar { profileToolbar }
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
            .task {
                model.refreshPolicyState()
                normalizeParticipation()
                refreshParticipatingRoutes()
            }
            .onChange(of: participationRawValue) { _, _ in refreshParticipatingRoutes() }
            .onChange(of: model.selectedID) { _, _ in
                section = .proxies
                inspectedCountryCode = nil
            }
            .onChange(of: model.profiles.map { "\($0.id.uuidString):\($0.validRevision)" }) { _, _ in
                normalizeParticipation()
                refreshParticipatingRoutes()
            }
            .onChange(of: model.policyHealthBySelector) { _, _ in refreshParticipatingRoutes() }
            .onChange(of: participatingRoutes.map(\.id)) { _, routeIDs in
                if inspectedCountryCode.map({ routeIDs.contains($0) }) != true {
                    inspectedCountryCode = nil
                }
            }
            .onChange(of: model.readinessChangeGeneration) { _, _ in
                lifecycle?.refresh()
                refreshParticipatingRoutes()
            }
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
                    Task { _ = await model.resolveUnsavedChanges(.saveAndContinue) }
                }
                .accessibilityIdentifier("profile.unsaved.save-and-continue")
                .keyboardShortcut(.defaultAction)
                Button("profile.unsaved.discard", role: .destructive) {
                    Task { _ = await model.resolveUnsavedChanges(.discardChanges) }
                }
                .accessibilityIdentifier("profile.unsaved.discard")
                Button("profile.action.cancel", role: .cancel) {
                    Task { _ = await model.resolveUnsavedChanges(.cancel) }
                }
                .accessibilityIdentifier("profile.unsaved.cancel")
            } message: {
                Text("profile.unsaved.message")
            }
    }

    private var configuredWorkspace: some View {
        HStack(spacing: 0) {
            workspaceSidebar
                .frame(
                    minWidth: ProfileWorkspaceLayout.connectionSidebarMinimumWidth,
                    idealWidth: ProfileWorkspaceLayout.connectionSidebarIdealWidth,
                    maxWidth: ProfileWorkspaceLayout.connectionSidebarMaximumWidth
                )
            Divider()
            workspaceDetail
                .disabled(model.isPerformingPersistence)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var workspaceSidebar: some View {
        if let inspectedCountryRoute {
            CountryRouteInspector(
                route: inspectedCountryRoute,
                bindings: model.selectedProfile?.routeBindings.filter {
                    $0.countryCode == inspectedCountryRoute.country.code
                } ?? [],
                availableRouteOutboundTags: Set(
                    participatingRoutes.flatMap(\.members).filter(\.isSelectable).map(\.tag)
                ),
                close: { inspectedCountryCode = nil }
            )
        } else if let connectionSidebar {
            connectionSidebar
        } else {
            ProfileConnectionsSidebarPlaceholder()
        }
    }

    private var inspectedCountryRoute: PolicyCountryRoute? {
        guard let inspectedCountryCode else { return nil }
        return participatingRoutes.first { $0.id == inspectedCountryCode }
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        if let profile = model.selectedProfile {
            ProfileWorkspaceDetailView(
                profile: profile,
                model: model,
                lifecycle: lifecycle,
                section: $section,
                participatingProfileCount: participatingProfileIDs.count,
                participatingCountryRoutes: participatingRoutes,
                inspectCountry: { inspectedCountryCode = $0 },
                chooseParticipatingCountry: { countryCode in
                    model.requestCountrySelection(
                        countryCode,
                        participatingProfileIDs: participatingProfileIDs
                    )
                },
                bindRoute: { url, countryCode, outboundTag in
                    Task { _ = await model.bindRoute(
                        url: url,
                        countryCode: countryCode,
                        outboundTag: outboundTag,
                        participatingProfileIDs: participatingProfileIDs
                    ) }
                }
            )
        } else {
            ProfileWorkspaceEmptyState(
                isPreparingImport: model.isPreparingImport,
                messageKey: model.messageKey
            )
        }
    }

    @ToolbarContentBuilder
    private var profileToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("diagnostics.open", systemImage: "waveform.path.ecg") { openWindow(id: "target-diagnostics") }
            participationMenu
            profileLibraryMenu.disabled(model.isPerformingPersistence)
        }
    }

    private var profileLibraryMenu: some View {
        Menu {
            Button("profile.subscription.add", systemImage: "link.badge.plus") { sheet = .subscription }
                .disabled(model.isUpdatingSubscription)
                .accessibilityIdentifier("profile.action.add-subscription")
            Button("profile.action.import", systemImage: "square.and.arrow.down") { presentImportPanel() }
                .disabled(model.isPreparingImport || model.isCommittingImport)
                .accessibilityIdentifier("profile.action.import")
            Button("profile.action.create", systemImage: "doc.badge.plus") { sheet = .create }
                .accessibilityIdentifier("profile.action.create")
            if let profile = model.selectedProfile {
                Divider()
                Menu(profile.name, systemImage: "doc.text") {
                    Button("profile.workspace.section.overview", systemImage: "info.circle") {
                        section = .overview
                    }
                    Button("profile.action.edit-configuration", systemImage: "curlybraces") {
                        section = .configuration
                    }
                    Divider()
                    Button("profile.action.rename", systemImage: "pencil") {
                        sheet = .rename(profile.id, profile.name)
                    }
                    Button("profile.action.duplicate", systemImage: "plus.square.on.square") {
                        model.requestDuplicate(profile.id)
                    }
                    Button("profile.action.restore", systemImage: "clock.arrow.circlepath") {
                        model.requestRestore(profile.id)
                    }
                    .disabled(profile.validRevision <= 1)
                    Button("profile.action.export", systemImage: "square.and.arrow.up") {
                        model.requestExport()
                    }
                    .disabled(!model.canExport)
                    Divider()
                    Button("profile.action.delete", systemImage: "trash", role: .destructive) {
                        deleteTarget = profile.id
                    }
                }
            }
        } label: {
            Label("profile.library.short", systemImage: "folder")
        }
        .help(Text("profile.actions.title"))
        .accessibilityLabel(Text("profile.actions.title"))
        .accessibilityIdentifier("profile.library.menu")
    }

    private var participationMenu: some View {
        Menu {
            ForEach(eligibleProfiles) { profile in
                Toggle(profile.name, isOn: participationBinding(for: profile.id))
            }
            if !eligibleProfiles.isEmpty {
                Divider()
                Button("profile.participation.all") { participationRawValue = "*" }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text("profile.participation.short")
                Text("\(participatingProfileIDs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .help(Text("profile.participation.help"))
        .accessibilityLabel(Text("profile.participation.title"))
        .accessibilityIdentifier("profile.participation.menu")
    }

    private var eligibleProfiles: [Profile] {
        model.profiles.filter { $0.validation.status != .invalid }
    }

    private var participatingProfileIDs: Set<UUID> {
        if participationRawValue == "*" { return Set(eligibleProfiles.map(\.id)) }
        return Set(participationRawValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func participationBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { participatingProfileIDs.contains(id) },
            set: { participates in
                var ids = participatingProfileIDs
                if participates { ids.insert(id) } else { ids.remove(id) }
                guard !ids.isEmpty else { return }
                participationRawValue = ids.map(\.uuidString).sorted().joined(separator: ",")
            }
        )
    }

    private func normalizeParticipation() {
        guard !eligibleProfiles.isEmpty else { return }
        let eligibleIDs = Set(eligibleProfiles.map(\.id))
        guard participationRawValue != "*",
              participatingProfileIDs.intersection(eligibleIDs).isEmpty else { return }
        participationRawValue = "*"
    }

    private func refreshParticipatingRoutes() {
        participatingRoutes = model.participatingCountryRoutes(profileIDs: participatingProfileIDs)
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
