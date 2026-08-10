import SwiftUI

enum AppShellLayout {
    static let minimumWindowWidth: CGFloat = 740
    static let minimumWindowHeight: CGFloat = 460
}

struct AppShellView: View {
    let lifecycle: BackendLifecycleModel
    @SceneStorage("app-shell.destination") private var persistedDestinationRawValue: String?
    @State private var profileModel: ProfileViewModel
    @State private var outerColumnVisibility: NavigationSplitViewVisibility = .all
    private let refreshOnTask: Bool
    private let restoredDestination: AppDestination?

    /// The injected model is also the production dependency-injection seam: the
    /// App owns one Profile model so GUI and automation can share domain operations.
    init(
        lifecycle: BackendLifecycleModel,
        profileModel: ProfileViewModel? = nil,
        refreshOnTask: Bool = true,
        restoredDestination: AppDestination? = nil
    ) {
        self.lifecycle = lifecycle
        _profileModel = State(initialValue: profileModel ?? ProfileViewModel())
        self.refreshOnTask = refreshOnTask
        self.restoredDestination = restoredDestination
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $outerColumnVisibility) {
            AppSidebarView(selection: destination)
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
    }

    private var destination: Binding<AppDestination> {
        Binding(
            get: { AppDestination.destination(for: persistedDestinationRawValue) },
            set: { persistedDestinationRawValue = $0.rawValue }
        )
    }

    private func normalizePersistedDestination() {
        persistedDestinationRawValue = AppDestination.destination(for: persistedDestinationRawValue).rawValue
    }

    private func handle(_ intent: DashboardRouteIntent) {
        switch intent {
        case .selectDestination(let destination):
            persistedDestinationRawValue = destination.rawValue
        }
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
            ProfileWorkspaceView(lifecycle: lifecycle, model: profileModel)
        }
    }
}

struct AppSidebarView: View {
    @Binding var selection: AppDestination

    var body: some View {
        List(selection: $selection) {
            ForEach(AppNavigationSection.ordered) { section in
                Section(section.title) {
                    ForEach(AppDestination.metadata(in: section)) { metadata in
                        Label {
                            Text(metadata.title)
                        } icon: {
                            Image(systemName: metadata.symbolName)
                        }
                        .tag(metadata.destination)
                        .accessibilityLabel(Text(metadata.title))
                        .accessibilityIdentifier("app-shell.destination.\(metadata.destination.rawValue)")
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
}
