import AppKit

enum ProfileImportPanelResult: Equatable {
    case selected(URL)
    case cancelled

    static func resolve(response: NSApplication.ModalResponse, selectedURL: URL?) -> Self {
        guard response == .OK, let selectedURL else { return .cancelled }
        return .selected(selectedURL)
    }
}
