import SwiftUI

@main
struct TargetApp: App {
    @State private var lifecycle = TunnelLifecycleModel()

    var body: some Scene {
        WindowGroup {
            ContentView(lifecycle: lifecycle)
        }
    }
}
