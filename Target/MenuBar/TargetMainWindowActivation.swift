import AppKit

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
