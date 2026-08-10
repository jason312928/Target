import Darwin
import Foundation

struct PreparedProfileConfiguration: Sendable {
    let profileID: UUID
    let profileRevision: Int
    let sourceFingerprint: String
    let configurationFingerprint: String
    let primaryPort: UInt16
    let data: Data
}

enum ProfileRuntimeConfigurationError: Error, Equatable {
    case invalidJSON
    case unsafeConfiguration
    case noLoopbackMixedInbound
    case invalidPort
}

/// Produces an ephemeral launch document. The Profile's source JSON is never
/// written back: only Target-owned selector defaults and loopback listener ports
/// in this copy are replaced.
struct ProfileRuntimeConfigurationPreparer {
    private let portSelector: any LocalEnginePortSelecting

    init(portSelector: any LocalEnginePortSelecting = DynamicHighLocalPortSelector()) {
        self.portSelector = portSelector
    }

    func prepare(_ version: ProfileConfigurationVersion) throws -> PreparedProfileConfiguration {
        guard var root = try JSONSerialization.jsonObject(with: version.data) as? [String: Any] else {
            throw ProfileRuntimeConfigurationError.invalidJSON
        }
        guard !containsSensitivePath(root) else { throw ProfileRuntimeConfigurationError.unsafeConfiguration }
        root = applyValidPolicyOverrides(to: root, version: version)
        guard var inbounds = root["inbounds"] as? [[String: Any]], !inbounds.isEmpty else {
            throw ProfileRuntimeConfigurationError.noLoopbackMixedInbound
        }

        var primaryPort: UInt16?
        var selectedPorts = Set<UInt16>()
        for index in inbounds.indices {
            let inbound = inbounds[index]
            guard let type = inbound["type"] as? String else { throw ProfileRuntimeConfigurationError.unsafeConfiguration }
            // TUN, redirect, and TProxy are capable of influencing host traffic;
            // they are never admitted by the user-mode localhost engine.
            guard !["tun", "redirect", "tproxy"].contains(type.lowercased()) else {
                throw ProfileRuntimeConfigurationError.unsafeConfiguration
            }
            guard inbound["listen"] as? String == LocalEngineEndpoint.host else {
                throw ProfileRuntimeConfigurationError.unsafeConfiguration
            }
            if let rawPort = inbound["listen_port"] as? Int, !(0...65_535).contains(rawPort) {
                throw ProfileRuntimeConfigurationError.invalidPort
            }

            var port: UInt16
            repeat { port = try portSelector.selectAvailablePort() } while selectedPorts.contains(port)
            selectedPorts.insert(port)
            var replacement = inbound
            replacement["listen_port"] = Int(port)
            inbounds[index] = replacement
            if type.lowercased() == "mixed", primaryPort == nil { primaryPort = port }
        }
        guard let primaryPort else { throw ProfileRuntimeConfigurationError.noLoopbackMixedInbound }
        root["inbounds"] = inbounds
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return PreparedProfileConfiguration(
            profileID: version.profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data),
            configurationFingerprint: TargetConfigurationFingerprint.sha256(data),
            primaryPort: primaryPort,
            data: data
        )
    }

    private func containsSensitivePath(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.hasPrefix("/") || string.contains("../") || string.contains("..\\")
        }
        if let array = value as? [Any] { return array.contains(where: containsSensitivePath) }
        if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: containsSensitivePath) }
        return false
    }

    private func applyValidPolicyOverrides(
        to root: [String: Any],
        version: ProfileConfigurationVersion
    ) -> [String: Any] {
        let catalog = PolicyCatalogParser.parse(
            version.data,
            profileID: version.profile.id,
            profileRevision: version.revision,
            overrides: version.profile.policyOverrides
        )
        guard var outbounds = root["outbounds"] as? [Any] else { return root }
        for selector in catalog.selectors where selector.isMutable && selector.overrideValid {
            guard let override = selector.targetOverride,
                  outbounds.indices.contains(selector.identity),
                  var object = outbounds[selector.identity] as? [String: Any] else { continue }
            object["default"] = override
            outbounds[selector.identity] = object
        }
        var result = root
        result["outbounds"] = outbounds
        return result
    }
}

final class RuntimeConfigurationStore: @unchecked Sendable {
    private static let maximumReadableBytes: off_t = 10 * 1_024 * 1_024
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    func write(_ data: Data, id: UUID = UUID()) throws -> (id: UUID, url: URL) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try safeURL(for: id)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (id, url)
    }

    func remove(id: UUID) {
        guard let url = try? safeURL(for: id) else { return }
        try? fileManager.removeItem(at: url)
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? fileManager.removeItem(at: directory)
        }
    }

    func removeAll() {
        guard directory.path != "/", fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func exists(id: UUID) -> Bool {
        guard let url = try? safeURL(for: id) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Narrow read used only after runtime ownership has been proved. It refuses
    /// symlinks, non-regular files, foreign ownership, permissive modes, large
    /// documents, and fingerprint drift.
    func readVerified(id: UUID, fingerprint: String) -> Data? {
        guard let url = try? safeURL(for: id) else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumReadableBytes else {
            return nil
        }
        let data: Data
        do {
            guard let value = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() else {
                return nil
            }
            data = value
        } catch {
            return nil
        }
        guard TargetConfigurationFingerprint.sha256(data) == fingerprint else { return nil }
        return data
    }

    private func safeURL(for id: UUID) throws -> URL {
        let url = directory.appending(path: "\(id.uuidString).json").standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else { throw ProfileStoreError.unsafePath }
        return url
    }
}
