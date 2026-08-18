import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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
            isBusy: lifecycle.isBusy,
            isHostSafeMode: lifecycle.isHostSafeMode
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

        Button(LocalizedStringKey(MenuBarNavigationAction.openTarget.titleKey)) {
            performNavigation(.openTarget)
        }
            .accessibilityLabel(Text(MenuBarNavigationAction.openTarget.titleKey))
            .accessibilityIdentifier("menu-bar.open-target")

        Button(LocalizedStringKey(MenuBarNavigationAction.openSettings.titleKey)) {
            performNavigation(.openSettings)
        }
            .accessibilityLabel(Text(MenuBarNavigationAction.openSettings.titleKey))
            .accessibilityIdentifier("menu-bar.settings")

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

    private func performNavigation(_ action: MenuBarNavigationAction) {
        switch action {
        case .openTarget:
            openTargetWindow()
        case .openSettings:
            openSettings()
        }
    }
}

enum MenuBarNavigationAction: CaseIterable, Equatable {
    case openTarget
    case openSettings

    var titleKey: String {
        switch self {
        case .openTarget: "menu-bar.open-target"
        case .openSettings: "menu-bar.settings"
        }
    }
}

enum TargetMainWindowActivation {
    static let windowID = "target-main-window"
    static let windowIdentifier = NSUserInterfaceItemIdentifier(windowID)

    enum Decision: Equatable {
        case activateExistingMainWindow(index: Int)
        case openMainWindow
    }

    static func decision(for windowIdentifiers: [NSUserInterfaceItemIdentifier?]) -> Decision {
        guard let index = windowIdentifiers.firstIndex(of: windowIdentifier) else {
            return .openMainWindow
        }
        return .activateExistingMainWindow(index: index)
    }

    @MainActor
    static func activateExistingWindow() -> Bool {
        let windows = NSApp.windows
        guard case let .activateExistingMainWindow(index) = decision(for: windows.map(\.identifier)),
              windows.indices.contains(index) else {
            return false
        }

        let window = windows[index]
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

struct TargetMainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TargetMainWindowMarkerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TargetMainWindowMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = TargetMainWindowActivation.windowIdentifier
    }
}
