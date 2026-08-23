/// Presentation-only lifecycle surface. It intentionally has no backend or service
/// dependency, so previews can render runtime controls without touching the host.
@MainActor
final class BackendLifecycleModel {
    var status: Int { 0 }
    var isBusy: Bool { false }
    var isEngineRunning: Bool { false }
    var runtimeChangeGeneration: Int { 0 }
    var systemProxyStatus: PresentationSystemProxyStatus { .disabled }
    var canStart: Bool { false }
    var canStop: Bool { false }
    var canRestart: Bool { false }
    var canInstallEngine: Bool { false }
    var canEnableSystemProxy: Bool { false }
    var canDisableSystemProxy: Bool { false }

    func refresh() {}
    func start() {}
    func stop() {}
    func restartWithCurrentProfile() {}
    func installEngine() {}
    func enableSystemProxy() {}
    func disableSystemProxy() {}
}

struct PresentationSystemProxyStatus {
    let state: PresentationSystemProxyState

    static let disabled = PresentationSystemProxyStatus(state: .disabled)
}

enum PresentationSystemProxyState {
    case disabled
    case enabling
    case enabled
}
