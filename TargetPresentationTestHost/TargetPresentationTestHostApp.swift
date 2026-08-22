import AppKit
import SwiftUI

/// A test-only macOS application. Its first and only Profile model is created
/// from `PresentationFixture`; it never constructs TargetApp or ProfileViewModel().
@main
@MainActor
struct TargetPresentationTestHostApp: App {
    @NSApplicationDelegateAdaptor(PresentationTestHostApplicationDelegate.self) private var appDelegate
    @State private var fixture: PresentationFixture
    @State private var preferences: ApplicationPreferencesModel

    init() {
        do {
            PresentationShellState.resetDestinationIfRequested()
            _fixture = State(initialValue: try PresentationFixture(scenario: .fromLaunchArguments()))
            _preferences = State(initialValue: ApplicationPreferencesModel(
                onboardingPreferences: PresentationOnboardingPreferences(),
                loginItemManager: PresentationLoginItemManager()
            ))
        } catch {
            fatalError("Unable to create presentation fixture: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            presentationRoot
                .overlay(alignment: .bottomLeading) {
                    PresentationStateProbe(fixture: fixture)
                }
                .frame(minWidth: 740, minHeight: 511)
                .task {
                    appDelegate.fixture = fixture
                    PresentationWindowSize.applyRequestedSize()
                    fixture.startScenario()
                }
                .onDisappear { fixture.cleanUp() }
        }
    }

    @ViewBuilder
    private var presentationRoot: some View {
        if PresentationShellState.usesFullShell {
            AppShellView(
                lifecycle: fixture.lifecycle,
                profileModel: fixture.model,
                preferences: preferences,
                refreshOnTask: false,
                restoredDestination: PresentationShellState.restoredDestination
            )
        } else {
            ProfileWorkspaceView(lifecycle: nil, model: fixture.model)
        }
    }
}

@MainActor
private final class PresentationLoginItemManager: LoginItemManaging {
    func currentStatus() throws -> LoginItemRegistrationStatus { .disabled }
    func register() throws {}
    func unregister() throws {}
}

private final class PresentationOnboardingPreferences: OnboardingPersisting {
    var hasCompletedOnboarding = true
}

private enum PresentationShellState {
    static var usesFullShell: Bool {
        ProcessInfo.processInfo.arguments.contains("--presentation-full-shell")
    }

    static func resetDestinationIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--presentation-reset-shell-destination") else { return }
        UserDefaults.standard.removeObject(forKey: "app-shell.destination")
        UserDefaults.standard.removeObject(forKey: "app-shell.profiles-expanded")
    }

    static var restoredDestination: AppDestination? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--presentation-restored-destination"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return nil }
        return AppDestination(rawValue: ProcessInfo.processInfo.arguments[index + 1])
    }

}

private enum PresentationWindowSize {
    static func applyRequestedSize() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--presentation-window-size"),
              arguments.indices.contains(index + 1) else { return }
        let parts = arguments[index + 1].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else { return }
        DispatchQueue.main.async {
            NSApp.windows.first?.setContentSize(NSSize(width: width, height: height))
        }
    }
}

@MainActor
private final class PresentationTestHostApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var fixture: PresentationFixture?

    func applicationWillTerminate(_ notification: Notification) {
        fixture?.cleanUp()
    }
}
