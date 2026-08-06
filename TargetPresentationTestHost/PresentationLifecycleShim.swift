/// The real workspace accepts an optional lifecycle solely to refresh Dashboard
/// readiness. The presentation host always supplies nil, so this minimal
/// test-target symbol is never instantiated and cannot reach backend/service code.
@MainActor
final class BackendLifecycleModel {
    func refresh() {}
}
