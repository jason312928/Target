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
                    Text("backend.label.service")
                    Text(LocalizedStringKey(lifecycle.serviceStateKey))
                }
                GridRow {
                    Text("backend.label.engine")
                    Text(LocalizedStringKey(lifecycle.engineStateKey))
                }
                GridRow {
                    Text("service.label.ping")
                    Text(lifecycle.pingResult ?? "—")
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
                Button("service.action.install") {
                    lifecycle.installService()
                }
                .disabled(!lifecycle.canInstall)

                Button("service.action.remove") {
                    lifecycle.removeService()
                }
                .disabled(!lifecycle.canRemove)

                Button("service.action.refresh") {
                    lifecycle.refresh()
                }
                .disabled(lifecycle.isBusy)

                Button("service.action.ping") {
                    lifecycle.pingService()
                }
                .disabled(!lifecycle.canPing)
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
