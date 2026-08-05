import SwiftUI

struct AppShellView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    @State private var destination: AppDestination = .defaultDestination
    @State private var profileModel = ProfileViewModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                ForEach(AppDestination.allCases) { destination in
                    Label {
                        Text(destination.title)
                    } icon: {
                        Image(systemName: destination.symbolName)
                    }
                        .tag(destination)
                        .accessibilityLabel(Text(destination.title))
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("app.title")
            .accessibilityLabel(Text("navigation.accessibility.label"))
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            switch AppDestination.fallback(for: destination) {
            case .dashboard:
                DashboardView(lifecycle: lifecycle, onRoute: handle)
            case .profiles:
                ProfileWorkspaceView(lifecycle: lifecycle, model: profileModel)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 620, minHeight: 460)
        .task { lifecycle.refresh() }
    }

    private func handle(_ intent: DashboardRouteIntent) {
        switch intent {
        case .selectDestination(let destination):
            self.destination = destination
        }
    }
}
