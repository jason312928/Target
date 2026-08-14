import ServiceManagement

enum LoginItemManagerError: Error {
    case unavailable
}

final class SMAppLoginItemManager: LoginItemManaging {
    func currentStatus() throws -> LoginItemRegistrationStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            throw LoginItemManagerError.unavailable
        @unknown default:
            throw LoginItemManagerError.unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
