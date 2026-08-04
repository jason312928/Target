import Foundation

enum ServiceInstallationState: String, Codable, Equatable, Sendable {
    case notInstalled
    case installed

    var localizedKey: String {
        switch self {
        case .notInstalled: "service.status.not-installed"
        case .installed: "service.status.installed"
        }
    }
}

enum EngineState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping

    var localizedKey: String {
        switch self {
        case .stopped: "engine.status.stopped"
        case .starting: "engine.status.starting"
        case .running: "engine.status.running"
        case .stopping: "engine.status.stopping"
        }
    }
}

struct BackendStatus: Codable, Equatable, Sendable {
    var serviceInstallation: ServiceInstallationState
    var engineState: EngineState

    static let mockDefault = BackendStatus(serviceInstallation: .notInstalled, engineState: .stopped)
}

enum BackendOperation: Sendable {
    case start
    case stop
}

enum BackendLifecycleState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed(BackendError)

    static func begin(_ operation: BackendOperation, from state: BackendLifecycleState) throws -> BackendLifecycleState {
        switch (operation, state) {
        case (.start, .stopped), (.start, .failed(_)):
            return .starting
        case (.stop, .running):
            return .stopping
        default:
            throw BackendError.invalidLifecycleTransition
        }
    }

    static func settled(from status: BackendStatus) -> BackendLifecycleState {
        switch status.engineState {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .stopping: .stopping
        }
    }
}

enum ConfigurationValidationError: Error, Equatable, Sendable {
    case malformedRequest
    case unsupportedVersion
    case invalidProfileName
}

enum BackendError: Error, Equatable, Sendable {
    case serviceNotInstalled
    case invalidConfiguration(ConfigurationValidationError)
    case invalidLifecycleTransition
    case operationCancelled
    case serviceUnavailable

    var localizedKey: String {
        switch self {
        case .serviceNotInstalled: "backend.error.service-not-installed"
        case .invalidConfiguration: "backend.error.invalid-configuration"
        case .invalidLifecycleTransition: "backend.error.invalid-lifecycle"
        case .operationCancelled: "backend.error.cancelled"
        case .serviceUnavailable: "backend.error.service-unavailable"
        }
    }
}

/// The only configuration shape accepted by the service boundary in this phase.
/// It intentionally contains no command, executable, file-system, or process fields.
struct XPCConfigurationRequest: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    static let maximumProfileNameLength = 64

    let version: Int
    let profileName: String

    init(version: Int = Self.supportedVersion, profileName: String) {
        self.version = version
        self.profileName = profileName
    }

    func validated() throws -> XPCConfigurationRequest {
        guard version == Self.supportedVersion else {
            throw BackendError.invalidConfiguration(.unsupportedVersion)
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let isValidName = !profileName.isEmpty
            && profileName.count <= Self.maximumProfileNameLength
            && profileName.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        guard isValidName else {
            throw BackendError.invalidConfiguration(.invalidProfileName)
        }

        return self
    }

    static func decodeAndValidate(_ data: Data) throws -> XPCConfigurationRequest {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["version", "profileName"]) else {
                throw BackendError.invalidConfiguration(.malformedRequest)
            }
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.invalidConfiguration(.malformedRequest)
        }
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

protocol TunnelBackend: Sendable {
    func queryStatus() async throws -> BackendStatus
}

protocol EngineBackend: TunnelBackend {
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws
    func startEngine() async throws -> BackendStatus
    func stopEngine() async throws -> BackendStatus
}
