import Foundation

enum MenuBarPrimaryAction: Equatable {
    case start
    case stop
    case restart
    case unavailable

    var titleKey: String {
        switch self {
        case .start: "backend.action.start"
        case .stop: "backend.action.stop"
        case .restart: "dashboard.action.restart"
        case .unavailable: "menu-bar.action.unavailable"
        }
    }
}

enum MenuBarSystemProxyAction: Equatable {
    case enable
    case disable
    case unavailable

    var titleKey: String {
        switch self {
        case .enable: "system-proxy.action.enable"
        case .disable: "system-proxy.action.disable"
        case .unavailable: "menu-bar.action.unavailable"
        }
    }
}

struct MenuBarPresentation: Equatable {
    let statusKey: String
    let symbolName: String
    let primaryAction: MenuBarPrimaryAction
    let systemProxyStateKey: String
    let systemProxyAction: MenuBarSystemProxyAction
    let isBusy: Bool
    let errorKey: String?

    init(
        status: BackendStatus,
        lifecycleState: BackendLifecycleState,
        error: BackendError?,
        systemProxyStatus: SystemProxyStatus,
        canStart: Bool,
        canStop: Bool,
        canRestart: Bool,
        canEnableSystemProxy: Bool,
        canDisableSystemProxy: Bool,
        isBusy: Bool
    ) {
        self.isBusy = isBusy
        self.errorKey = error?.localizedKey ?? systemProxyStatus.error?.localizedKey
        self.systemProxyStateKey = systemProxyStatus.state.localizedKey

        if isBusy || status.engineState == .starting || status.engineState == .stopping {
            statusKey = "menu-bar.status.working"
            symbolName = "arrow.triangle.2.circlepath"
            primaryAction = .unavailable
        } else if status.engineState == .running && status.restartRequired {
            statusKey = "menu-bar.status.restart-required"
            symbolName = "exclamationmark.circle"
            primaryAction = canRestart ? .restart : .unavailable
        } else if status.engineState == .running {
            statusKey = "menu-bar.status.running"
            symbolName = "circle.fill"
            primaryAction = canStop ? .stop : .unavailable
        } else if error != nil {
            statusKey = "menu-bar.status.error"
            symbolName = "exclamationmark.triangle"
            primaryAction = canStart ? .start : .unavailable
        } else {
            statusKey = "menu-bar.status.stopped"
            symbolName = "circle"
            primaryAction = canStart ? .start : .unavailable
        }

        if isBusy {
            systemProxyAction = .unavailable
        } else if canDisableSystemProxy {
            systemProxyAction = .disable
        } else if canEnableSystemProxy {
            systemProxyAction = .enable
        } else {
            systemProxyAction = .unavailable
        }
    }
}
