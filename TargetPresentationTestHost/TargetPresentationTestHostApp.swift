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
                .frame(minWidth: 740, minHeight: 511)
                .task {
                    appDelegate.fixture = fixture
                    PresentationWindowSize.applyRequestedSize()
                    fixture.startScenario()
                }
                .onDisappear { fixture.cleanUp() }
        }
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
