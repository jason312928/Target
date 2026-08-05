import SwiftUI

struct DashboardView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    private var presentation: DashboardPresentation {
        DashboardPresentation(
            status: lifecycle.status,
            lifecycleState: lifecycle.lifecycleState,
            serviceInstallation: lifecycle.serviceInstallation,
            xpcState: lifecycle.xpcState,
            error: lifecycle.error,
            systemProxyStatus: lifecycle.systemProxyStatus,
            isBusy: lifecycle.isBusy,
            isHostSafeMode: lifecycle.isHostSafeMode
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                if let errorKey = presentation.backendErrorKey {
                    DashboardNotice(level: .critical, messageKey: errorKey)
                }
                if presentation.showsRestartNotice {
                    DashboardNotice(level: .warning, messageKey: "engine.restart.required")
                }
                HStack(alignment: .top, spacing: 20) {
                    runtimeCard
                    serviceCard
                }
                safetyCard
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("service.action.refresh", systemImage: "arrow.clockwise") { lifecycle.refresh() }
                    .disabled(lifecycle.isBusy)
                    .accessibilityLabel(Text("service.action.refresh"))
                    .accessibilityHint(Text("dashboard.refresh.hint"))
            }
        }
        .onAppear { lifecycle.refresh() }
    }

    private var statusCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                DashboardStatusBadge(level: presentation.statusLevel, titleKey: presentation.titleKey)
                Text(LocalizedStringKey(presentation.descriptionKey))
                    .font(.title2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    primaryActionButton
                    if presentation.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("dashboard.status.working"))
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch presentation.primaryAction {
        case .installEngine:
            Button { lifecycle.installEngine() } label: { Text(LocalizedStringKey(presentation.primaryAction.titleKey)) }
                .buttonStyle(.borderedProminent)
                .disabled(!lifecycle.canInstallEngine)
                .accessibilityHint(Text("dashboard.action.install-engine.hint"))
        case .start:
            Button { lifecycle.start() } label: { Text(LocalizedStringKey(presentation.primaryAction.titleKey)) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!lifecycle.canStart || lifecycle.status.engineInstallation != .installed)
                .accessibilityHint(Text("dashboard.action.start.hint"))
        case .stop:
            Button { lifecycle.stop() } label: { Text(LocalizedStringKey(presentation.primaryAction.titleKey)) }
                .buttonStyle(.borderedProminent)
                .disabled(!lifecycle.canStop)
                .accessibilityHint(Text("dashboard.action.stop.hint"))
        case .restart:
            Button { lifecycle.restartWithCurrentProfile() } label: { Text(LocalizedStringKey(presentation.primaryAction.titleKey)) }
                .buttonStyle(.borderedProminent)
                .disabled(!lifecycle.canRestart)
                .accessibilityHint(Text("dashboard.action.restart.hint"))
        case .unavailable:
            Button { } label: { Text(LocalizedStringKey(presentation.primaryAction.titleKey)) }
                .disabled(true)
                .accessibilityHint(Text("dashboard.action.busy.hint"))
        }
    }

    private var runtimeCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("dashboard.section.runtime", systemImage: "bolt")
                    .font(.headline)
                DashboardStatusRow(labelKey: "engine.label.installation", valueKey: presentation.engineInstallationKey, value: nil)
                DashboardStatusRow(labelKey: "engine.label.version", valueKey: nil, value: presentation.engineVersion)
                DashboardStatusRow(labelKey: "backend.label.engine", valueKey: presentation.engineStateKey, value: nil)
                DashboardStatusRow(labelKey: "dashboard.label.endpoint", valueKey: nil, value: presentation.endpoint)
                DashboardStatusRow(labelKey: "dashboard.label.revision", valueKey: nil, value: presentation.runningRevision.map(String.init))
                Button("engine.action.validate") { lifecycle.validateConfiguration() }
                    .disabled(lifecycle.isBusy || lifecycle.status.engineInstallation != .installed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var serviceCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("dashboard.section.service", systemImage: "shield")
                    .font(.headline)
                DashboardStatusRow(labelKey: "backend.label.service", valueKey: presentation.serviceInstallationKey, value: nil)
                DashboardStatusRow(labelKey: "xpc.label.status", valueKey: presentation.xpcStateKey, value: nil)
                HStack {
                    Button("service.action.install") { lifecycle.installService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .enabled)
                    Button("service.action.remove", role: .destructive) { lifecycle.removeService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .notRegistered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var safetyCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("dashboard.section.network", systemImage: "lock")
                    .font(.headline)
                if presentation.isHostSafeMode {
                    DashboardNotice(level: .warning, messageKey: "host-safety.status.safe")
                }
                DashboardStatusRow(labelKey: "system-proxy.label.status", valueKey: presentation.systemProxyStateKey, value: nil)
                DashboardStatusRow(labelKey: "system-proxy.label.engine", valueKey: presentation.systemProxyEngineKey, value: nil)
                if let errorKey = presentation.systemProxyErrorKey {
                    DashboardNotice(level: .critical, messageKey: errorKey)
                }
                HStack {
                    Toggle("system-proxy.action.toggle", isOn: Binding(
                        get: { lifecycle.systemProxyStatus.state == .enabled },
                        set: { $0 ? lifecycle.enableSystemProxy() : lifecycle.disableSystemProxy() }
                    ))
                    .disabled(!lifecycle.canEnableSystemProxy && !lifecycle.canDisableSystemProxy)
                    .accessibilityHint(Text(presentation.isHostSafeMode ? "dashboard.proxy.safe-mode.hint" : "dashboard.proxy.hint"))
                    Spacer()
                    Button("system-proxy.action.refresh") { lifecycle.refreshSystemProxyStatus() }
                        .disabled(lifecycle.isBusy)
                    Button("system-proxy.action.recover") { lifecycle.recoverSystemProxy() }
                        .disabled(!lifecycle.canRecoverSystemProxy)
                }
            }
        }
    }
}
