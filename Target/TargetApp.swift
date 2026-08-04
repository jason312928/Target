import AppKit
import SwiftUI

@main
struct TargetApp: App {
    @State private var lifecycle = BackendLifecycleModel()

    init() {
        NSApplication.shared.delegate = TargetApplicationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(lifecycle: lifecycle)
                    .tabItem { Label("app.title", systemImage: "bolt") }
                ProfileWorkspaceView()
                    .tabItem { Label("profile.title", systemImage: "doc.text") }
            }
                .onAppear { TargetApplicationDelegate.shared.lifecycle = lifecycle }
        }
    }
}

@MainActor
final class TargetApplicationDelegate: NSObject, NSApplicationDelegate {
    static let shared = TargetApplicationDelegate()
    weak var lifecycle: BackendLifecycleModel?

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle?.stopOnApplicationTermination()
    }
}
