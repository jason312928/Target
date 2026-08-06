import AppKit
import SwiftUI

/// A test-only macOS application. Its first and only Profile model is created
/// from `PresentationFixture`; it never constructs TargetApp or ProfileViewModel().
@main
@MainActor
struct TargetPresentationTestHostApp: App {
    @NSApplicationDelegateAdaptor(PresentationTestHostApplicationDelegate.self) private var appDelegate
    @State private var fixture: PresentationFixture

    init() {
        do {
            _fixture = State(initialValue: try PresentationFixture(scenario: .fromLaunchArguments()))
        } catch {
            fatalError("Unable to create presentation fixture: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ProfileWorkspaceView(lifecycle: nil, model: fixture.model)
                .overlay(alignment: .bottomLeading) {
                    PresentationStateProbe(fixture: fixture)
                }
                .frame(minWidth: 760, minHeight: 560)
                .task {
                    appDelegate.fixture = fixture
                    fixture.startScenario()
                }
                .onDisappear { fixture.cleanUp() }
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
