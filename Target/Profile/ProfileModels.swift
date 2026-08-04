import Foundation

enum ProfileValidationStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case valid
    case invalid
}

struct ProfileValidation: Codable, Equatable, Sendable {
    var status: ProfileValidationStatus
    var checkedAt: Date?
    var error: ConfigurationDiagnostic?

    static let notChecked = ProfileValidation(status: .notChecked, checkedAt: nil, error: nil)
}

struct ConfigurationDiagnostic: Error, Codable, Equatable, Sendable {
    var messageKey: String
    var line: Int?
    var column: Int?
}

/// Metadata is deliberately separate from the configuration JSON. The URL is never
/// rendered in logs or diagnostics; it exists only so a future explicit refresh can
/// use the source selected by the user.
struct RemoteSubscription: Codable, Equatable, Sendable {
    let url: URL
    var lastUpdatedAt: Date?
}

struct Profile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var subscription: RemoteSubscription?
    let createdAt: Date
    var updatedAt: Date
    var validation: ProfileValidation
    var validRevision: Int

    var hasRemoteSubscription: Bool { subscription != nil }
}

enum ProfileStoreError: LocalizedError, Equatable {
    case profileNotFound
    case invalidName
    case unsafePath
    case invalidJSON(ConfigurationDiagnostic)
    case validationFailed(ConfigurationDiagnostic)
    case invalidStoredMetadata

    var errorDescription: String? {
        switch self {
        case .profileNotFound: "Profile not found."
        case .invalidName: "A profile name is required."
        case .unsafePath: "The requested path is outside Target-managed storage."
        case .invalidJSON, .validationFailed: "The configuration could not be validated."
        case .invalidStoredMetadata: "Profile metadata is invalid."
        }
    }
}

enum SafeExampleConfiguration {
    /// This configuration is intentionally limited to a dynamic loopback listener
    /// and the direct outbound. It does not enable system proxy, DNS, TUN, routes,
    /// or firewall changes.
    static func json(port: Int = 0) -> String {
        """
        {
          "log": { "level": "error" },
          "inbounds": [
            {
              "type": "mixed",
              "tag": "local-mixed",
              "listen": "127.0.0.1",
              "listen_port": \(port)
            }
          ],
          "outbounds": [
            { "type": "direct", "tag": "direct" }
          ],
          "route": { "final": "direct" }
        }
        """
    }
}
