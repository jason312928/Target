import SwiftUI

@main
struct TargetApp: App {
    @State private var lifecycle = BackendLifecycleModel()

    var body: some Scene {
        WindowGroup {
            ContentView(lifecycle: lifecycle)
        }
    }
}
