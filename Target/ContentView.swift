import SwiftUI

struct ContentView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: lifecycle.lifecycleState == .running ? "bolt.circle.fill" : "bolt.slash")
                    .font(.system(size: 42))
                    .accessibilityHidden(true)

                VStack(alignment: .leading) {
                    Text("app.title")
                        .font(.largeTitle)
                    Text(LocalizedStringKey(lifecycle.backendStateKey))
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("engine.label.installation")
                    Text(LocalizedStringKey(lifecycle.engineInstallationKey))
                }
                GridRow {
                    Text("engine.label.version")
                    Text(lifecycle.status.engineVersion ?? "—")
                }
                GridRow {
                    Text("backend.label.engine")
                    Text(LocalizedStringKey(lifecycle.engineStateKey))
                }
                if let errorKey = lifecycle.errorKey {
                    GridRow {
                        Text("backend.label.error")
                        Text(LocalizedStringKey(errorKey))
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Button("engine.action.install") {
                    lifecycle.installEngine()
                }
                .disabled(!lifecycle.canInstallEngine)

                Button("engine.action.validate") {
                    lifecycle.validateConfiguration()
                }
                .disabled(lifecycle.isBusy || lifecycle.status.engineInstallation != .installed)

                Button("service.action.refresh") {
                    lifecycle.refresh()
                }
                .disabled(lifecycle.isBusy)

            }

            HStack {
                Button("backend.action.start") {
                    lifecycle.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!lifecycle.canStart)

                Button("backend.action.stop") {
                    lifecycle.stop()
                }
                .disabled(!lifecycle.canStop)
            }
        }
        .frame(minWidth: 420, minHeight: 260)
        .padding(32)
    }
}
