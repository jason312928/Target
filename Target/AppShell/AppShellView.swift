import SwiftUI

enum AppShellLayout {
    static let minimumWindowWidth: CGFloat = 740
    static let minimumWindowHeight: CGFloat = 460
}

struct AppShellView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    @SceneStorage("app-shell.destination") private var persistedDestinationRawValue: String?
    @State private var profileModel = ProfileViewModel()

    var body: some View {
        NavigationSplitView {
            AppSidebarView(selection: destination)
        } detail: {
            switch AppDestination.destination(for: persistedDestinationRawValue) {
            case .dashboard:
                DashboardView(lifecycle: lifecycle, onRoute: handle)
            case .profiles:
                ProfileWorkspaceView(lifecycle: lifecycle, model: profileModel)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: AppShellLayout.minimumWindowWidth,
            minHeight: AppShellLayout.minimumWindowHeight
        )
        .task {
            normalizePersistedDestination()
            lifecycle.refresh()
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
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("app.title")
        .accessibilityLabel(Text("navigation.accessibility.label"))
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
    }
}
