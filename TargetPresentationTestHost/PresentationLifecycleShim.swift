/// The real workspace accepts an optional lifecycle solely to refresh Dashboard
/// readiness. The presentation host always supplies nil, so this minimal
/// test-target symbol is never instantiated and cannot reach backend/service code.
@MainActor
final class BackendLifecycleModel {
    var status: Int { 0 }
    var isBusy: Bool { false }
    var isEngineRunning: Bool { false }
    var runtimeChangeGeneration: Int { 0 }
    var canRestart: Bool { false }
    func refresh() {}
    func restartWithCurrentProfile() {}
}
