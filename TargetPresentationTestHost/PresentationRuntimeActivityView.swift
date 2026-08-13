import SwiftUI

/// The isolated presentation host does not construct runtime adapters. It keeps
/// newly routable destinations compilable without pretending to show live facts.
struct RuntimeActivityDestinationView: View {
    let destination: AppDestination
    let lifecycle: BackendLifecycleModel

    var body: some View {
        TargetPageLayout {
            switch destination {
            case .connections:
                TargetPageHeader("connections.title", subtitleKey: "connections.subtitle")
            case .traffic:
                TargetPageHeader("traffic.title", subtitleKey: "traffic.subtitle")
            case .logs:
                TargetPageHeader("logs.title", subtitleKey: "logs.subtitle")
            case .dashboard, .profiles:
                EmptyView()
            }
        }
    }
}
