import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    @Environment(\.openWindow) private var openWindow

    init(lifecycle: BackendLifecycleModel) {
        self.lifecycle = lifecycle
    }

    private var presentation: MenuBarPresentation {
        MenuBarPresentation(
            status: lifecycle.status,
            lifecycleState: lifecycle.lifecycleState,
            error: lifecycle.error,
            systemProxyStatus: lifecycle.systemProxyStatus,
            canStart: lifecycle.canStart,
            canStop: lifecycle.canStop,
            canRestart: lifecycle.canRestart,
            canEnableSystemProxy: lifecycle.canEnableSystemProxy,
            canDisableSystemProxy: lifecycle.canDisableSystemProxy,
            isBusy: lifecycle.isBusy
        )
    }

    var body: some View {
        Text("app.title")
        Text(LocalizedStringKey(presentation.statusKey))

        if let errorKey = presentation.errorKey {
            Text(LocalizedStringKey(errorKey))
        }

        Divider()

        Button(LocalizedStringKey(presentation.primaryAction.titleKey), action: performPrimaryAction)
            .disabled(presentation.primaryAction == .unavailable)
            .accessibilityLabel(Text(LocalizedStringKey(presentation.primaryAction.titleKey)))
            .accessibilityIdentifier("menu-bar.primary-action")

        Text("menu-bar.proxy.label")
        Text(LocalizedStringKey(presentation.systemProxyStateKey))
        Button(LocalizedStringKey(presentation.systemProxyAction.titleKey), action: performSystemProxyAction)
            .disabled(presentation.systemProxyAction == .unavailable)
            .accessibilityLabel(Text(LocalizedStringKey(presentation.systemProxyAction.titleKey)))
            .accessibilityIdentifier("menu-bar.proxy-action")

        Divider()

        Button("menu-bar.refresh", action: lifecycle.refresh)
            .disabled(lifecycle.isBusy)
            .accessibilityLabel(Text("menu-bar.refresh"))
            .accessibilityIdentifier("menu-bar.refresh")

        Button("menu-bar.open-target", action: openTargetWindow)
            .accessibilityLabel(Text("menu-bar.open-target"))
            .accessibilityIdentifier("menu-bar.open-target")

        Divider()

        Button("menu-bar.quit") {
            NSApp.terminate(nil)
        }
    }

    private func performPrimaryAction() {
        switch presentation.primaryAction {
        case .start: lifecycle.start()
        case .stop: lifecycle.stop()
        case .restart: lifecycle.restartWithCurrentProfile()
        case .unavailable: break
        }
    }

    private func performSystemProxyAction() {
        switch presentation.systemProxyAction {
        case .enable: lifecycle.enableSystemProxy()
        case .disable: lifecycle.disableSystemProxy()
        case .unavailable: break
        }
    }

    private func openTargetWindow() {
        if !TargetMainWindowActivation.activateExistingWindow() {
            openWindow(id: TargetMainWindowActivation.windowID)
        }
    }
}

@MainActor
enum TargetMainWindowActivation {
    static let windowID = "target-main-window"

    static func activateExistingWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
