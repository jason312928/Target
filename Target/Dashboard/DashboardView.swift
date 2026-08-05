import SwiftUI

struct DashboardView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    let onRoute: (DashboardRouteIntent) -> Void

    init(
        lifecycle: BackendLifecycleModel,
        onRoute: @escaping (DashboardRouteIntent) -> Void = { _ in }
    ) {
        self.lifecycle = lifecycle
        self.onRoute = onRoute
    }

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
                Text("dashboard.title")
                    .font(.largeTitle.weight(.semibold))
                Text("dashboard.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                statusCard
                if let errorKey = presentation.backendErrorKey {
                    TargetNotice(level: .critical, messageKey: errorKey)
                }
                if presentation.showsRestartNotice {
                    TargetNotice(level: .warning, messageKey: "engine.restart.required")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        runtimeCard
                        serviceCard
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        runtimeCard
                        serviceCard
                    }
                }
                safetyCard
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 460)
        .navigationTitle("dashboard.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("service.action.refresh", systemImage: "arrow.clockwise") { lifecycle.refresh() }
                    .disabled(lifecycle.isBusy)
                    .accessibilityLabel(Text("service.action.refresh"))
                    .accessibilityHint(Text("dashboard.refresh.hint"))
            }
        }
    }

    private var statusCard: some View {
        TargetCard {
            VStack(alignment: .leading, spacing: 14) {
                TargetStatusBadge(level: presentation.statusLevel, titleKey: presentation.titleKey)
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
        case .profileRequired:
            Button("dashboard.action.open-profiles") {
                if let route = DashboardActionRouter.route(for: presentation.primaryAction) {
                    onRoute(route)
                }
            }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Text("dashboard.action.open-profiles.hint"))
        case .unavailable:
            Button { } label: { Text(LocalizedStringKey(presentation.primaryAction.titleKey)) }
                .disabled(true)
                .accessibilityHint(Text("dashboard.action.busy.hint"))
        }
    }

    private var runtimeCard: some View {
        TargetCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("dashboard.section.runtime", systemImage: "bolt")
                    .font(.headline)
                TargetStatusRow(labelKey: "engine.label.installation", valueKey: presentation.engineInstallationKey, value: nil)
                TargetStatusRow(labelKey: "engine.label.version", valueKey: nil, value: presentation.engineVersion)
                TargetStatusRow(labelKey: "backend.label.engine", valueKey: presentation.engineStateKey, value: nil)
                TargetStatusRow(labelKey: "dashboard.label.endpoint", valueKey: nil, value: presentation.endpoint)
                TargetStatusRow(labelKey: "dashboard.label.revision", valueKey: nil, value: presentation.runningRevision.map(String.init))
                Button("engine.action.validate") { lifecycle.validateConfiguration() }
                    .disabled(lifecycle.isBusy || lifecycle.status.engineInstallation != .installed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280, maxWidth: .infinity)
    }

    private var serviceCard: some View {
        TargetCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("dashboard.section.service", systemImage: "shield")
                    .font(.headline)
                TargetStatusRow(labelKey: "backend.label.service", valueKey: presentation.serviceInstallationKey, value: nil)
                TargetStatusRow(labelKey: "xpc.label.status", valueKey: presentation.xpcStateKey, value: nil)
                HStack {
                    Button("service.action.install") { lifecycle.installService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .enabled)
                    Button("service.action.remove", role: .destructive) { lifecycle.removeService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .notRegistered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280, maxWidth: .infinity)
    }

    private var safetyCard: some View {
        TargetCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("dashboard.section.network", systemImage: "lock")
                    .font(.headline)
                if presentation.isHostSafeMode {
                    TargetNotice(level: .warning, messageKey: "host-safety.status.safe")
                }
                TargetStatusRow(labelKey: "system-proxy.label.status", valueKey: presentation.systemProxyStateKey, value: nil)
                TargetStatusRow(labelKey: "system-proxy.label.engine", valueKey: presentation.systemProxyEngineKey, value: nil)
                if let errorKey = presentation.systemProxyErrorKey {
                    TargetNotice(level: .critical, messageKey: errorKey)
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
