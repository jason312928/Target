import SwiftUI

struct RuntimeDiagnosticsView: View {
    static let windowID = "target-diagnostics"
    let lifecycle: BackendLifecycleModel
    @State private var destination: AppDestination = .connections

    var body: some View {
        VStack(spacing: 0) {
            Picker("diagnostics.title", selection: $destination) {
                Text("connections.title").tag(AppDestination.connections)
                Text("traffic.title").tag(AppDestination.traffic)
                Text("logs.title").tag(AppDestination.logs)
            }
            .pickerStyle(.segmented)
            .padding(16)
            Divider()
            RuntimeActivityDestinationView(destination: destination, lifecycle: lifecycle)
                .id(destination)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
