import AppKit
import SwiftUI

@main
struct TargetApp: App {
    @State private var lifecycle: BackendLifecycleModel

    init() {
        let profileStore = ProfileStore()
        let backend = SingBoxBackend(profileStore: profileStore)
        let systemProxyClient = TargetServiceXPCClient()
        let runtimeOperations = TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: systemProxyClient
        )
        let lifecycle = BackendLifecycleModel(
            backend: backend,
            systemProxyClient: systemProxyClient,
            runtimeOperations: runtimeOperations
        )
        _lifecycle = State(initialValue: lifecycle)
        let operations = TargetAutomationOperations(
            profileStore: profileStore,
            backend: backend,
            serviceClient: systemProxyClient,
            runtimeOperations: runtimeOperations,
            engineStatusObserver: { status in
                await MainActor.run { lifecycle.applyAutomationEngineStatus(status) }
            }
        )
        TargetApplicationDelegate.shared.configure(lifecycle: lifecycle, automationOperations: operations)
        NSApplication.shared.delegate = TargetApplicationDelegate.shared
        TargetApplicationDelegate.shared.startAutomationServerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(lifecycle: lifecycle)
                .onAppear { TargetApplicationDelegate.shared.lifecycle = lifecycle }
        }
    }
}

@MainActor
final class TargetApplicationDelegate: NSObject, NSApplicationDelegate {
    static let shared = TargetApplicationDelegate()
    weak var lifecycle: BackendLifecycleModel?
    private var automationOperations: TargetAutomationOperations?
    private var automationServer: LocalAutomationServer?

    func configure(lifecycle: BackendLifecycleModel, automationOperations: TargetAutomationOperations) {
        self.lifecycle = lifecycle
        self.automationOperations = automationOperations
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startAutomationServerIfNeeded()
    }

    func startAutomationServerIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              automationServer == nil, let operations = automationOperations else { return }
        let server = LocalAutomationServer { request in
            await operations.handle(request)
        }
        do {
            try server.start()
            automationServer = server
        } catch {
            automationServer = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        automationServer?.stop()
        lifecycle?.stopOnApplicationTermination()
    }
}
