import SwiftUI

struct DashboardView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    let onRoute: (DashboardRouteIntent) -> Void
    @State private var showsAdvanced = false

    init(lifecycle: BackendLifecycleModel, onRoute: @escaping (DashboardRouteIntent) -> Void = { _ in }) {
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
            isHostSafeMode: lifecycle.isHostSafeMode,
            isUTMValidation: lifecycle.isUTMValidationMode
        )
    }

    var body: some View {
        TargetPageLayout {
            dashboardContent
        }
        .frame(minWidth: 500, minHeight: 460)
        .navigationTitle("dashboard.title")
        .accessibilityIdentifier("dashboard.workspace")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("service.action.refresh", systemImage: "arrow.clockwise") { lifecycle.refresh() }
                    .disabled(lifecycle.isBusy)
                    .accessibilityLabel(Text("service.action.refresh"))
                    .accessibilityHint(Text("dashboard.refresh.hint"))
            }
        }
    }

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TargetPageHeader("dashboard.title")
            mainControl
            notices
            if lifecycle.runtimeObservation.state == .available { liveActivity }
            if shouldOfferServiceSetup { serviceSetup }
            if presentation.isHostSafeMode {
                TargetNotice(level: .warning, messageKey: presentation.hostSafetyNoticeKey)
            }
            advancedDiagnostics
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var mainControl: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 18) {
                connectionStatus
                Divider()
                systemProxyControl
            }
        }
        .accessibilityIdentifier("dashboard.main-control")
    }

    private var connectionStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                statusSymbol
                statusSummary
                Spacer(minLength: 20)
                HStack(spacing: 10) {
                    busyIndicator
                    primaryActionButton
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    statusSymbol
                    statusSummary
                }
                HStack(spacing: 10) {
                    primaryActionButton
                    busyIndicator
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.connection-status")
    }

    private var statusSymbol: some View {
        Image(systemName: connectionSymbolName)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(connectionSymbolTint)
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }

    private var connectionSymbolName: String {
        switch presentation.primaryAction {
        case .installEngine: "arrow.down.circle.fill"
        case .start: "power.circle.fill"
        case .stop: presentation.statusLevel == .positive ? "checkmark.circle.fill" : "power.circle.fill"
        case .restart: "arrow.clockwise.circle.fill"
        case .profileRequired: "doc.badge.plus"
        case .unavailable: "ellipsis.circle.fill"
        }
    }

    private var connectionSymbolTint: Color {
        presentation.primaryAction == .start && presentation.statusLevel == .neutral
            ? .blue
            : presentation.statusLevel.tint
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(presentation.titleKey))
                .font(.title3.weight(.semibold))
            Text(LocalizedStringKey(presentation.descriptionKey))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let errorKey = presentation.backendErrorKey {
            TargetNotice(level: .critical, messageKey: errorKey)
        }
        if let errorKey = presentation.systemProxyErrorKey {
            TargetNotice(level: .critical, messageKey: errorKey)
        }
        if presentation.showsRestartNotice {
            TargetNotice(level: .warning, messageKey: "engine.restart.required")
        }
    }

    private var liveActivity: some View {
        let observation = RuntimeObservationPresentation(observation: lifecycle.runtimeObservation)
        return DashboardPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    activityMetric("dashboard.observation.download-rate", observation.downloadRate, "arrow.down")
                    Divider().padding(.horizontal, 18)
                    activityMetric("dashboard.observation.upload-rate", observation.uploadRate, "arrow.up")
                    Divider().padding(.horizontal, 18)
                    activityMetric("dashboard.observation.connections", observation.activeConnections, "point.3.connected.trianglepath.dotted")
                }
                VStack(alignment: .leading, spacing: 14) {
                    activityMetric("dashboard.observation.download-rate", observation.downloadRate, "arrow.down")
                    activityMetric("dashboard.observation.upload-rate", observation.uploadRate, "arrow.up")
                    activityMetric("dashboard.observation.connections", observation.activeConnections, "point.3.connected.trianglepath.dotted")
                }
            }
        }
        .accessibilityIdentifier("dashboard.live-activity")
    }

    private func activityMetric(_ titleKey: String, _ value: String?, _ symbol: String) -> some View {
        DashboardActivityMetric(titleKey: titleKey, value: value, symbol: symbol)
    }

    private var systemProxyControl: some View {
        Toggle(isOn: Binding(
            get: { presentation.isSystemProxyToggleOn },
            set: { $0 ? lifecycle.enableSystemProxy() : lifecycle.disableSystemProxy() }
        )) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(presentation.isSystemProxyToggleOn ? Color.green : Color.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("system-proxy.action.toggle").font(.headline)
                    Text(LocalizedStringKey(presentation.systemProxyStateKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(!lifecycle.canEnableSystemProxy && !lifecycle.canDisableSystemProxy)
        .accessibilityHint(Text(presentation.isHostSafeMode
            ? "dashboard.proxy.safe-mode.hint"
            : "dashboard.proxy.hint"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("dashboard.system-proxy")
    }

    private var shouldOfferServiceSetup: Bool {
        !presentation.isHostSafeMode && lifecycle.serviceInstallation != .enabled
    }

    private var serviceSetup: some View {
        DashboardPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    setupSummary
                    Spacer(minLength: 20)
                    installServiceButton
                }
                VStack(alignment: .leading, spacing: 14) {
                    setupSummary
                    installServiceButton
                }
            }
        }
        .accessibilityIdentifier("dashboard.service-setup")
    }

    private var setupSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("dashboard.setup.title").font(.headline)
                Text("dashboard.setup.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var installServiceButton: some View {
        Button("service.action.install") { lifecycle.installService() }
            .buttonStyle(.borderedProminent)
            .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .enabled)
    }

    private var advancedDiagnostics: some View {
        DisclosureGroup(isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                TargetSectionTitle("dashboard.section.runtime", systemImage: "bolt")
                TargetStatusRow(labelKey: "engine.label.installation", valueKey: presentation.engineInstallationKey, value: nil)
                TargetStatusRow(labelKey: "engine.label.version", valueKey: nil, value: presentation.engineVersion)
                TargetStatusRow(labelKey: "backend.label.engine", valueKey: presentation.engineStateKey, value: nil)
                if presentation.endpoint != nil {
                    TargetStatusRow(labelKey: "dashboard.label.endpoint", valueKey: nil, value: presentation.endpoint)
                }
                if presentation.runningRevision != nil {
                    TargetStatusRow(labelKey: "dashboard.label.revision", valueKey: nil, value: presentation.runningRevision.map(String.init))
                }
                Button("engine.action.validate") { lifecycle.validateConfiguration() }
                    .disabled(lifecycle.isBusy || lifecycle.status.engineInstallation != .installed)

                Divider()
                TargetSectionTitle("dashboard.section.service", systemImage: "shield")
                TargetStatusRow(labelKey: "backend.label.service", valueKey: presentation.serviceInstallationKey, value: nil)
                TargetStatusRow(labelKey: "xpc.label.status", valueKey: presentation.xpcStateKey, value: nil)
                HStack(spacing: 10) {
                    Button("service.action.install") { lifecycle.installService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .enabled)
                    Button("service.action.remove", role: .destructive) { lifecycle.removeService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .notRegistered)
                }

                Divider()
                TargetSectionTitle("dashboard.section.network", systemImage: "network")
                TargetStatusRow(labelKey: "system-proxy.label.status", valueKey: presentation.systemProxyStateKey, value: nil)
                TargetStatusRow(labelKey: "system-proxy.label.engine", valueKey: presentation.systemProxyEngineKey, value: nil)
                HStack(spacing: 10) {
                    Button("system-proxy.action.refresh") { lifecycle.refreshSystemProxyStatus() }
                        .disabled(lifecycle.isBusy)
                    Button("system-proxy.action.recover") { lifecycle.recoverSystemProxy() }
                        .disabled(!lifecycle.canRecoverSystemProxy)
                }
            }
            .padding(.top, 10)
        } label: {
            Label("dashboard.section.advanced", systemImage: "gearshape.2")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .accessibilityIdentifier("dashboard.advanced")
    }

    @ViewBuilder
    private var busyIndicator: some View {
        if presentation.isBusy {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("dashboard.status.working"))
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch presentation.primaryAction {
        case .installEngine:
            Button("dashboard.action.install-component") { lifecycle.installEngine() }
                .buttonStyle(.borderedProminent)
                .disabled(!lifecycle.canInstallEngine)
                .accessibilityHint(Text("dashboard.action.install-engine.hint"))
        case .start:
            Button("dashboard.action.connect") { lifecycle.start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!lifecycle.canStart || lifecycle.status.engineInstallation != .installed)
                .accessibilityHint(Text("dashboard.action.start.hint"))
        case .stop:
            Button("dashboard.action.disconnect") { lifecycle.stop() }
                .buttonStyle(.borderedProminent)
                .disabled(!lifecycle.canStop)
                .accessibilityHint(Text("dashboard.action.stop.hint"))
        case .restart:
            Button("dashboard.action.restart") { lifecycle.restartWithCurrentProfile() }
                .buttonStyle(.borderedProminent)
                .disabled(!lifecycle.canRestart)
                .accessibilityHint(Text("dashboard.action.restart.hint"))
        case .profileRequired:
            Button("dashboard.action.open-profiles") {
                if let route = DashboardActionRouter.route(for: presentation.primaryAction) { onRoute(route) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(Text("dashboard.action.open-profiles.hint"))
        case .unavailable:
            Button("dashboard.action.unavailable") {}
                .disabled(true)
                .accessibilityHint(Text("dashboard.action.busy.hint"))
        }
    }
}

private struct DashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: TargetUI.cardCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TargetUI.cardCornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
            }
    }
}

private struct DashboardActivityMetric: View {
    let titleKey: String
    let value: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(value ?? "—").font(.title3.weight(.semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
