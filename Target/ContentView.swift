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
                    Text("backend.status.mock")
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
                if let errorKey = lifecycle.errorKey {
                    GridRow {
                        Text("backend.label.error")
                        Text(LocalizedStringKey(errorKey))
                            .foregroundStyle(.red)
                    }
                }
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
