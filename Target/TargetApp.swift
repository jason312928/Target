import AppKit
import SwiftUI
import TargetCore

@main
struct TargetApp: App {
    @State private var lifecycle: BackendLifecycleModel
    @State private var profileModel: ProfileViewModel

    init() {
        let profileStore = ProfileStore()
        let backend = SingBoxBackend(profileStore: profileStore)
        let runtimeObservationOperations = TargetRuntimeObservationOperations(provider: backend)
        let policyOperations = TargetPolicyOperations(
            profileStore: profileStore,
            runtimeEvidenceProvider: backend
        )
        let systemProxyClient = TargetServiceXPCClient()
        let systemProxyOperations = TargetSystemProxyOperations(client: systemProxyClient)
        let runtimeOperations = TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: systemProxyClient,
            systemProxyOperations: systemProxyOperations
        )
        let lifecycle = BackendLifecycleModel(
            backend: backend,
            systemProxyClient: systemProxyClient,
            systemProxyOperations: systemProxyOperations,
            runtimeOperations: runtimeOperations,
            runtimeObservationOperations: runtimeObservationOperations
        )
        _lifecycle = State(initialValue: lifecycle)
        _profileModel = State(initialValue: ProfileViewModel(
            store: profileStore,
            policyOperations: policyOperations
        ))
        let operations = TargetAutomationOperations(
            profileStore: profileStore,
            policyOperations: policyOperations,
            backend: backend,
            serviceClient: systemProxyClient,
            systemProxyOperations: systemProxyOperations,
            runtimeOperations: runtimeOperations,
            runtimeObservationOperations: runtimeObservationOperations,
            engineStatusObserver: { status in
                await MainActor.run { lifecycle.applyAutomationEngineStatus(status) }
            },
            systemProxyStatusObserver: { status in
                await MainActor.run { lifecycle.applyAutomationSystemProxyStatus(status) }
            }
        )
        TargetApplicationDelegate.shared.configure(lifecycle: lifecycle, automationOperations: operations)
        NSApplication.shared.delegate = TargetApplicationDelegate.shared
        TargetApplicationDelegate.shared.startAutomationServerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(lifecycle: lifecycle, profileModel: profileModel)
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
