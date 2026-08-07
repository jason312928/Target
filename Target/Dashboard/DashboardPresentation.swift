import Foundation

enum DashboardPrimaryAction: Equatable {
    case installEngine
    case start
    case stop
    case restart
    case profileRequired
    case unavailable

    var titleKey: String {
        switch self {
        case .installEngine: "engine.action.install"
        case .start: "backend.action.start"
        case .stop: "backend.action.stop"
        case .restart: "dashboard.action.restart"
        case .profileRequired: "dashboard.action.profile-required"
        case .unavailable: "dashboard.action.unavailable"
        }
    }
}

struct DashboardPresentation: Equatable {
    let statusLevel: TargetStatusLevel
    let titleKey: String
    let descriptionKey: String
    let primaryAction: DashboardPrimaryAction
    let isBusy: Bool
    let showsRestartNotice: Bool
    let backendErrorKey: String?
    let systemProxyErrorKey: String?
    let engineInstallationKey: String
    let engineStateKey: String
    let engineVersion: String?
    let endpoint: String?
    let runningRevision: Int?
    let serviceInstallationKey: String
    let xpcStateKey: String
    let systemProxyStateKey: String
    let systemProxyEngineKey: String
    let isHostSafeMode: Bool
    let hostSafetyNoticeKey: String

    init(
        status: BackendStatus,
        lifecycleState: BackendLifecycleState,
        serviceInstallation: ServiceInstallationState,
        xpcState: XPCConnectionState,
        error: BackendError?,
        systemProxyStatus: SystemProxyStatus,
        isBusy: Bool,
        isHostSafeMode: Bool
    ) {
        self.isBusy = isBusy
        self.showsRestartNotice = status.restartRequired
        self.backendErrorKey = error?.localizedKey
        self.systemProxyErrorKey = systemProxyStatus.error?.localizedKey
        self.engineInstallationKey = status.engineInstallation.localizedKey
        self.engineStateKey = status.engineState.localizedKey
        self.engineVersion = status.engineVersion
        self.endpoint = status.engineState == .running ? status.enginePort.map { "127.0.0.1:\($0)" } : nil
        self.runningRevision = status.engineState == .running ? status.runningProfileRevision : nil
        self.serviceInstallationKey = serviceInstallation.localizedKey
        self.xpcStateKey = xpcState.localizedKey
        self.systemProxyStateKey = systemProxyStatus.state.localizedKey
        self.systemProxyEngineKey = systemProxyStatus.engineReachable ? "system-proxy.engine.reachable" : "system-proxy.engine.unreachable"
        self.isHostSafeMode = isHostSafeMode
        self.hostSafetyNoticeKey = isHostSafeMode ? "host-safety.status.safe" : "host-safety.status.utm-validation"

        if isBusy || status.engineState == .starting || status.engineState == .stopping {
            statusLevel = .neutral
            titleKey = "dashboard.status.working"
            descriptionKey = "dashboard.status.working.description"
            primaryAction = .unavailable
        } else if status.engineInstallation != .installed {
            statusLevel = .warning
            titleKey = "dashboard.status.engine-unavailable"
            descriptionKey = "dashboard.status.engine-unavailable.description"
            primaryAction = .installEngine
        } else if status.engineState == .running && status.restartRequired {
            statusLevel = .warning
            titleKey = "dashboard.status.restart-required"
            descriptionKey = "engine.restart.required"
            primaryAction = .restart
        } else if status.engineState == .running {
            statusLevel = .positive
            titleKey = "dashboard.status.running"
            descriptionKey = "dashboard.status.running.description"
            primaryAction = .stop
        } else if !status.hasSelectedValidProfile {
            statusLevel = .warning
            titleKey = "dashboard.status.profile-required"
            descriptionKey = "dashboard.status.profile-required.description"
            primaryAction = .profileRequired
        } else if let error {
            statusLevel = .critical
            titleKey = "dashboard.status.attention"
            descriptionKey = error.localizedKey
            primaryAction = .start
        } else {
            statusLevel = .neutral
            titleKey = "dashboard.status.ready"
            descriptionKey = "dashboard.status.ready.description"
            primaryAction = .start
        }
    }
}
