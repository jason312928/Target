import SwiftUI

/// Compatibility entry point for the existing app shell.
struct ContentView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    var body: some View {
        DashboardView(lifecycle: lifecycle)
    }
}
