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
                    Text(LocalizedStringKey(lifecycle.serviceInstallationKey))
                }
                GridRow {
                    Text("xpc.label.status")
                    Text(LocalizedStringKey(lifecycle.xpcStateKey))
                }
                GridRow {
                    Text("host-safety.label.status")
                    Text(LocalizedStringKey(lifecycle.safeModeKey))
                }
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
                GridRow {
                    Text("system-proxy.label.status")
                    Text(LocalizedStringKey(lifecycle.systemProxyStateKey))
                }
                GridRow {
                    Text("system-proxy.label.engine")
                    Text(lifecycle.systemProxyStatus.engineReachable ? "system-proxy.engine.reachable" : "system-proxy.engine.unreachable")
                }
                if let systemProxyErrorKey = lifecycle.systemProxyErrorKey {
                    GridRow {
                        Text("system-proxy.label.error")
                        Text(LocalizedStringKey(systemProxyErrorKey))
                            .foregroundStyle(.red)
                    }
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
                .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .enabled)

                Button("service.action.remove") {
                    lifecycle.removeService()
                }
                .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .notRegistered)

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

            Toggle("system-proxy.action.toggle", isOn: Binding(
                get: { lifecycle.systemProxyStatus.state == .enabled },
                set: { enabled in
                    if enabled {
                        lifecycle.enableSystemProxy()
                    } else {
                        lifecycle.disableSystemProxy()
                    }
                }
            ))
            .disabled(!lifecycle.canEnableSystemProxy && !lifecycle.canDisableSystemProxy)

            HStack {
                Button("system-proxy.action.refresh") {
                    lifecycle.refreshSystemProxyStatus()
                }
                .disabled(lifecycle.isBusy)

                Button("system-proxy.action.recover") {
                    lifecycle.recoverSystemProxy()
                }
                .disabled(!lifecycle.canRecoverSystemProxy)
            }
        }
        .frame(minWidth: 420, minHeight: 260)
        .padding(32)
    }
}
