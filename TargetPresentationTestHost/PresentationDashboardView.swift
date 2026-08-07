import SwiftUI

/// The host compiles the real AppShellView but substitutes its non-profile
/// destination so no production backend, service, or Keychain dependency enters
/// an isolated layout test.
enum DashboardPrimaryAction {
    case profileRequired
}

struct DashboardView: View {
    let lifecycle: BackendLifecycleModel
    let onRoute: (DashboardRouteIntent) -> Void

    var body: some View {
        TargetPageLayout {
            TargetPageHeader("dashboard.title", subtitleKey: "dashboard.subtitle")
        }
        .navigationTitle("dashboard.title")
        .accessibilityIdentifier("dashboard.workspace")
    }
}
