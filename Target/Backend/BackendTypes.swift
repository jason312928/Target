import Foundation

enum ServiceInstallationState: String, Codable, Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case unavailable
    case error

    var localizedKey: String {
        switch self {
        case .notRegistered: "service.status.not-registered"
        case .requiresApproval: "service.status.requires-approval"
        case .enabled: "service.status.enabled"
        case .unavailable: "service.status.unavailable"
        case .error: "service.status.error"
        }
    }
}

enum XPCConnectionState: String, Codable, Equatable, Sendable {
    case unknown
    case connected
    case unavailable

    var localizedKey: String { "xpc.status.\(rawValue)" }
}

enum ServiceConnectionAssessment {
    static func xpcState(
        registration: ServiceInstallationState,
        xpcReachable: Bool?
    ) -> XPCConnectionState {
        guard registration == .enabled else { return .unknown }
        guard let xpcReachable else { return .unknown }
        return xpcReachable ? .connected : .unavailable
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

enum EngineInstallationState: String, Codable, Equatable, Sendable {
    case notInstalled
    case installed
    case invalid

    var localizedKey: String {
        switch self {
        case .notInstalled: "engine.installation.not-installed"
        case .installed: "engine.installation.installed"
        case .invalid: "engine.installation.invalid"
        }
    }
}

struct BackendStatus: Codable, Equatable, Sendable {
    var serviceInstallation: ServiceInstallationState
    var engineState: EngineState
    var engineInstallation: EngineInstallationState = .notInstalled
    /// A non-sensitive readiness fact for UI consumers. It deliberately does not
    /// disclose Profile content, identifiers, storage locations, or credentials.
    var hasSelectedValidProfile = false
    var engineVersion: String?
    var enginePort: Int?
    var runningProfileID: UUID?
    var runningProfileRevision: Int?
    var restartRequired = false

    init(
        serviceInstallation: ServiceInstallationState,
        engineState: EngineState,
        engineInstallation: EngineInstallationState = .notInstalled,
        hasSelectedValidProfile: Bool = false,
        engineVersion: String? = nil,
        enginePort: Int? = nil,
        runningProfileID: UUID? = nil,
        runningProfileRevision: Int? = nil,
        restartRequired: Bool = false
    ) {
        self.serviceInstallation = serviceInstallation
        self.engineState = engineState
        self.engineInstallation = engineInstallation
        self.hasSelectedValidProfile = hasSelectedValidProfile
        self.engineVersion = engineVersion
        self.enginePort = enginePort
        self.runningProfileID = runningProfileID
        self.runningProfileRevision = runningProfileRevision
        self.restartRequired = restartRequired
    }

    private enum CodingKeys: String, CodingKey {
        case serviceInstallation
        case engineState
        case engineInstallation
        case hasSelectedValidProfile
        case engineVersion
        case enginePort
        case runningProfileID
        case runningProfileRevision
        case restartRequired
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serviceInstallation: try container.decodeIfPresent(ServiceInstallationState.self, forKey: .serviceInstallation) ?? .notRegistered,
            engineState: try container.decodeIfPresent(EngineState.self, forKey: .engineState) ?? .stopped,
            engineInstallation: try container.decodeIfPresent(EngineInstallationState.self, forKey: .engineInstallation) ?? .notInstalled,
            hasSelectedValidProfile: try container.decodeIfPresent(Bool.self, forKey: .hasSelectedValidProfile) ?? false,
            engineVersion: try container.decodeIfPresent(String.self, forKey: .engineVersion),
            enginePort: try container.decodeIfPresent(Int.self, forKey: .enginePort),
            runningProfileID: try container.decodeIfPresent(UUID.self, forKey: .runningProfileID),
            runningProfileRevision: try container.decodeIfPresent(Int.self, forKey: .runningProfileRevision),
            restartRequired: try container.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
        )
    }

    static let mockDefault = BackendStatus(serviceInstallation: .notRegistered, engineState: .stopped)
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
    case serviceRegistrationFailed
    case invalidConfiguration(ConfigurationValidationError)
    case invalidLifecycleTransition
    case operationCancelled
    case serviceUnavailable
    case notImplemented
    case engineNotInstalled
    case engineInstallationFailed
    case configurationCheckFailed
    case engineLaunchFailed
    case enginePortUnavailable
    case profileNotSelected
    case profileNoValidVersion
    case profileConfigurationUnsafe
    case profileConfigurationInvalid

    var localizedKey: String {
        switch self {
        case .serviceNotInstalled: "backend.error.service-not-installed"
        case .serviceRegistrationFailed: "backend.error.service-registration-failed"
        case .invalidConfiguration: "backend.error.invalid-configuration"
        case .invalidLifecycleTransition: "backend.error.invalid-lifecycle"
        case .operationCancelled: "backend.error.cancelled"
        case .serviceUnavailable: "backend.error.service-unavailable"
        case .notImplemented: "backend.error.not-implemented"
        case .engineNotInstalled: "backend.error.engine-not-installed"
        case .engineInstallationFailed: "backend.error.engine-installation-failed"
        case .configurationCheckFailed: "backend.error.configuration-check-failed"
        case .engineLaunchFailed: "backend.error.engine-launch-failed"
        case .enginePortUnavailable: "backend.error.engine-port-unavailable"
        case .profileNotSelected: "backend.error.profile-not-selected"
        case .profileNoValidVersion: "backend.error.profile-no-valid-version"
        case .profileConfigurationUnsafe: "backend.error.profile-unsafe-configuration"
        case .profileConfigurationInvalid: "backend.error.profile-invalid-configuration"
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

protocol EngineInstalling: EngineBackend {
    func installEngine() async throws -> BackendStatus
}

protocol ServiceLifecycleManaging: EngineBackend {
    func installService() async throws -> BackendStatus
    func removeService() async throws -> BackendStatus
}

protocol ServiceConnectionTesting: EngineBackend {
    func pingService() async throws -> String
}
