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
            ContentView(lifecycle: lifecycle)
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
