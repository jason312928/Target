import Foundation
import CryptoKit

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
enum SubscriptionCacheStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case updated
    case notModified
    case failed
    case cancelled
}

/// Subscription metadata is private application data (the enclosing manifest is
/// owner-readable only). It is never included in diagnostics or application logs.
struct RemoteSubscription: Codable, Equatable, Sendable {
    let url: URL
    var lastUpdatedAt: Date?
    var lastCheckedAt: Date?
    var etag: String?
    var lastModified: String?
    var cacheStatus: SubscriptionCacheStatus
    var lastErrorKey: String?

    init(
        url: URL,
        lastUpdatedAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        cacheStatus: SubscriptionCacheStatus = .notChecked,
        lastErrorKey: String? = nil
    ) {
        self.url = url
        self.lastUpdatedAt = lastUpdatedAt
        self.lastCheckedAt = lastCheckedAt
        self.etag = etag
        self.lastModified = lastModified
        self.cacheStatus = cacheStatus
        self.lastErrorKey = lastErrorKey
    }

    private enum CodingKeys: String, CodingKey {
        case url, lastUpdatedAt, lastCheckedAt, etag, lastModified, cacheStatus, lastErrorKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        lastUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        etag = try values.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try values.decodeIfPresent(String.self, forKey: .lastModified)
        cacheStatus = try values.decodeIfPresent(SubscriptionCacheStatus.self, forKey: .cacheStatus) ?? .notChecked
        lastErrorKey = try values.decodeIfPresent(String.self, forKey: .lastErrorKey)
    }
}

struct ProfileVersionSummary: Identifiable, Equatable, Sendable {
    let revision: Int
    let savedAt: Date?
    var id: Int { revision }
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
    case noSelectedProfile
    case profileNotFound
    case noValidVersion
    case profileInUse
    case invalidName
    case unsafePath
    case invalidJSON(ConfigurationDiagnostic)
    case validationFailed(ConfigurationDiagnostic)
    case invalidStoredMetadata

    var errorDescription: String? {
        switch self {
        case .noSelectedProfile: "No Profile is selected."
        case .profileNotFound: "Profile not found."
        case .noValidVersion: "The Profile has no valid configuration version."
        case .profileInUse: "Stop the running engine before deleting this Profile."
        case .invalidName: "A profile name is required."
        case .unsafePath: "The requested path is outside Target-managed storage."
        case .invalidJSON, .validationFailed: "The configuration could not be validated."
        case .invalidStoredMetadata: "Profile metadata is invalid."
        }
    }
}

/// A launch always uses an immutable version rather than the editor's working
/// document. The bytes are intentionally opaque so unknown sing-box fields are
/// retained exactly in the user-managed source file.
struct ProfileConfigurationVersion: Sendable {
    let profile: Profile
    let revision: Int
    let data: Data
}

enum TargetConfigurationFingerprint {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
