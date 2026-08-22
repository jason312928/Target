import SwiftUI

enum AppShellLayout {
    static let minimumWindowWidth: CGFloat = 740
    static let minimumWindowHeight: CGFloat = 460
}

struct AppShellView: View {
    let lifecycle: BackendLifecycleModel
    let preferences: ApplicationPreferencesModel
    @SceneStorage("app-shell.destination") private var persistedDestinationRawValue: String?
    @State private var profileModel: ProfileViewModel
    @State private var outerColumnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("app-shell.profiles-expanded") private var profilesExpanded = true
    private let refreshOnTask: Bool
    private let restoredDestination: AppDestination?

    /// The injected model is also the production dependency-injection seam: the
    /// App owns one Profile model so GUI and automation can share domain operations.
    init(
        lifecycle: BackendLifecycleModel,
        profileModel: ProfileViewModel? = nil,
        preferences: ApplicationPreferencesModel,
        refreshOnTask: Bool = true,
        restoredDestination: AppDestination? = nil
    ) {
        self.lifecycle = lifecycle
        self.preferences = preferences
        _profileModel = State(initialValue: profileModel ?? ProfileViewModel())
        self.refreshOnTask = refreshOnTask
        self.restoredDestination = restoredDestination
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $outerColumnVisibility) {
            AppSidebarView(
                selection: sidebarSelection,
                profiles: profileModel.profiles,
                profilesExpanded: $profilesExpanded
            )
        } detail: {
            shellDetail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleOuterSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(Text("app-shell.sidebar-toggle"))
                .accessibilityIdentifier("app-shell.sidebar-toggle")
            }
        }
        .frame(
            minWidth: AppShellLayout.minimumWindowWidth,
            minHeight: AppShellLayout.minimumWindowHeight
        )
        .task {
            if let restoredDestination {
                persistedDestinationRawValue = restoredDestination.rawValue
            }
            normalizePersistedDestination()
            if refreshOnTask {
                lifecycle.refresh()
            }
        }
        .sheet(isPresented: onboardingPresentationBinding) {
            OnboardingView(
                onComplete: preferences.completeOnboarding,
                onOpenProfiles: {
                    handle(OnboardingActionRouter.routeToProfiles())
                }
            )
        }
    }

    private var sidebarSelection: Binding<AppSidebarSelection> {
        Binding(
            get: {
                let destination = AppDestination.destination(for: persistedDestinationRawValue)
                if destination == .profiles, let selectedID = profileModel.selectedID {
                    return .profile(selectedID)
                }
                return .destination(destination)
            },
            set: { selection in
                switch selection {
                case .destination(let destination):
                    persistedDestinationRawValue = destination.rawValue
                case .profile(let profileID):
                    persistedDestinationRawValue = AppDestination.profiles.rawValue
                    profileModel.requestSelection(profileID)
                }
            }
        )
    }

    private func normalizePersistedDestination() {
        persistedDestinationRawValue = AppDestination.destination(for: persistedDestinationRawValue).rawValue
    }

    private func handle(_ intent: AppRouteIntent) {
        switch intent {
        case .selectDestination(let destination):
            persistedDestinationRawValue = destination.rawValue
        }
    }

    private var onboardingPresentationBinding: Binding<Bool> {
        Binding(
            get: { preferences.shouldPresentOnboarding },
            set: { isPresented in
                if !isPresented {
                    preferences.dismissOnboarding()
                }
            }
        )
    }

    private func toggleOuterSidebar() {
        outerColumnVisibility = outerColumnVisibility == .detailOnly ? .all : .detailOnly
    }

    @ViewBuilder
    private var shellDetail: some View {
        switch AppDestination.destination(for: persistedDestinationRawValue) {
        case .dashboard:
            DashboardView(lifecycle: lifecycle, onRoute: handle)
        case .profiles:
            ProfileWorkspaceView(lifecycle: lifecycle, model: profileModel, showsProfileList: false)
        case .connections:
            RuntimeActivityDestinationView(destination: .connections, lifecycle: lifecycle)
        case .traffic:
            RuntimeActivityDestinationView(destination: .traffic, lifecycle: lifecycle)
        case .logs:
            RuntimeActivityDestinationView(destination: .logs, lifecycle: lifecycle)
        }
    }
}

struct AppSidebarView: View {
    @Binding var selection: AppSidebarSelection
    let profiles: [Profile]
    @Binding var profilesExpanded: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(AppNavigationSection.ordered) { section in
                Section(section.title) {
                    ForEach(AppDestination.metadata(in: section)) { metadata in
                        if metadata.destination == .profiles {
                            profilesDestination(metadata)
                            if profilesExpanded {
                                ForEach(profiles) { profile in
                                    AppSidebarProfileRow(
                                        profile: profile,
                                        isSelected: selection == .profile(profile.id)
                                    )
                                        .tag(AppSidebarSelection.profile(profile.id))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selection = .profile(profile.id)
                                        }
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("profile.row.\(profile.id.uuidString)")
                                }
                            }
                        } else {
                            destinationLabel(metadata)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("app.title")
        .accessibilityLabel(Text("navigation.accessibility.label"))
        .accessibilityIdentifier("app-shell.sidebar")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        .toolbar(removing: .sidebarToggle)
    }

    private func destinationLabel(_ metadata: AppDestinationMetadata) -> some View {
        Label {
            Text(metadata.title)
        } icon: {
            Image(systemName: metadata.symbolName)
        }
        .tag(AppSidebarSelection.destination(metadata.destination))
        .accessibilityLabel(Text(metadata.title))
        .accessibilityIdentifier("app-shell.destination.\(metadata.destination.rawValue)")
    }

    private func profilesDestination(_ metadata: AppDestinationMetadata) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(metadata.title)
            } icon: {
                Image(systemName: metadata.symbolName)
            }
            Spacer(minLength: 4)
            Button {
                profilesExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(profilesExpanded ? 90 : 0))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(profilesExpanded
                ? "app-shell.profiles.collapse"
                : "app-shell.profiles.expand"))
            .accessibilityIdentifier("app-shell.profiles.disclosure")
        }
        .tag(AppSidebarSelection.destination(.profiles))
        .accessibilityIdentifier("app-shell.destination.profiles")
    }
}

enum AppSidebarSelection: Hashable {
    case destination(AppDestination)
    case profile(UUID)
}

private struct AppSidebarProfileRow: View {
    let profile: Profile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: profile.hasRemoteSubscription ? "link" : "doc.text")
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
            Text(profile.name)
                .lineLimit(1)
                .help(profile.name)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 4)
            Image(systemName: validationSymbol)
                .foregroundStyle(isSelected ? Color.white : validationColor)
                .accessibilityLabel(Text(validationTitleKey))
        }
        .padding(.leading, 18)
    }

    private var validationTitleKey: LocalizedStringKey {
        switch profile.validation.status {
        case .valid: "profile.validation.valid"
        case .invalid: "profile.validation.invalid"
        case .notChecked: "profile.validation.not-checked"
        }
    }

    private var validationSymbol: String {
        switch profile.validation.status {
        case .valid: "checkmark.circle.fill"
        case .invalid: "xmark.circle.fill"
        case .notChecked: "circle.dashed"
        }
    }

    private var validationColor: Color {
        switch profile.validation.status {
        case .valid: .green
        case .invalid: .red
        case .notChecked: .secondary
        }
    }
}
