import Foundation

/// Owns the complete on-disk Profile layout. Every configuration and version is
/// constrained to the Target Application Support root. Configuration documents are
/// treated as opaque UTF-8 JSON: no Codable round trip can discard unknown fields.
final class ProfileStore {
    static let profilesDirectoryName = "Profiles"
    private static let manifestName = "profiles.json"
    private static let configurationName = "config.json"
    private static let stagingName = ".pending-check.json"

    private let rootDirectory: URL
    private let checker: any SingBoxConfigurationChecking
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        rootDirectory: URL = ProfileStore.defaultRootDirectory(),
        checker: any SingBoxConfigurationChecking = SingBoxConfigurationChecker(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.checker = checker
        self.fileManager = fileManager
        self.now = now
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/Profiles", directoryHint: .isDirectory)
    }

    func listProfiles() throws -> [Profile] {
        try ensureRoot()
        return try loadManifest().sorted { $0.updatedAt > $1.updatedAt }
    }

    func selectedProfileID() throws -> UUID? {
        try loadSelection()
    }

    func select(_ id: UUID?) throws {
        if let id, try profile(id) == nil { throw ProfileStoreError.profileNotFound }
        try ensureRoot()
        let data = try JSONEncoder().encode(id?.uuidString)
        try write(data, to: safeRootFile("selected-profile.json"))
    }

    @discardableResult
    func create(name: String, subscriptionURL: URL? = nil) throws -> Profile {
        let normalizedName = try validatedName(name)
        try ensureRoot()
        var profiles = try loadManifest()
        let timestamp = now()
        let profile = Profile(
            id: UUID(), name: normalizedName,
            subscription: subscriptionURL.map { RemoteSubscription(url: $0, lastUpdatedAt: nil) },
            createdAt: timestamp, updatedAt: timestamp, validation: .notChecked, validRevision: 1
        )
        let directory = try safeProfileDirectory(profile.id)
        try fileManager.createDirectory(at: directory.appending(path: "versions"), withIntermediateDirectories: true)
        let data = Data(SafeExampleConfiguration.json().utf8)
        try write(data, to: try configurationURL(for: profile.id))
        try write(data, to: try versionURL(for: profile.id, revision: 1))
        profiles.append(profile)
        try saveManifest(profiles)
        if try selectedProfileID() == nil { try select(profile.id) }
        return profile
    }

    @discardableResult
    func `import`(name: String, json: String, subscriptionURL: URL? = nil) throws -> Profile {
        let profile = try create(name: name, subscriptionURL: subscriptionURL)
        do {
            try save(json: json, for: profile.id)
            return try self.profile(profile.id) ?? profile
        } catch {
            // An import must never leave an unvalidated document as a usable profile.
            try? delete(profile.id)
            throw error
        }
    }

    @discardableResult
    func duplicate(_ id: UUID, name: String? = nil) throws -> Profile {
        guard let original = try profile(id) else { throw ProfileStoreError.profileNotFound }
        let copy = try create(name: name ?? "\(original.name) Copy", subscriptionURL: original.subscription?.url)
        let text = try configurationText(for: original.id)
        let data = Data(text.utf8)
        try write(data, to: try configurationURL(for: copy.id))
        try write(data, to: try versionURL(for: copy.id, revision: 1))
        try update(copy.id) { profile in
            profile.validation = original.validation
            profile.validRevision = 1
        }
        return try profile(copy.id) ?? copy
    }

    func rename(_ id: UUID, to name: String) throws {
        let normalizedName = try validatedName(name)
        try update(id) { $0.name = normalizedName }
    }

    func delete(_ id: UUID) throws {
        guard try profile(id) != nil else { throw ProfileStoreError.profileNotFound }
        let directory = try safeProfileDirectory(id)
        try fileManager.removeItem(at: directory)
        var profiles = try loadManifest()
        profiles.removeAll { $0.id == id }
        try saveManifest(profiles)
        if try selectedProfileID() == id { try select(profiles.first?.id) }
    }

    func configurationText(for id: UUID) throws -> String {
        guard try profile(id) != nil else { throw ProfileStoreError.profileNotFound }
        let data = try Data(contentsOf: try configurationURL(for: id))
        guard let text = String(data: data, encoding: .utf8) else { throw ProfileStoreError.invalidStoredMetadata }
        return text
    }

    /// Verifies the exact user-provided bytes in a managed staging file before
    /// replacing config.json. This preserves all unknown JSON fields and prevents
    /// a failed check from replacing the last valid version.
    func save(json: String, for id: UUID) throws {
        guard try profile(id) != nil else { throw ProfileStoreError.profileNotFound }
        if let syntaxError = JSONSyntaxChecker.validate(json) {
            try markInvalid(id, diagnostic: syntaxError)
            throw ProfileStoreError.invalidJSON(syntaxError)
        }
        let staging = try stagingURL(for: id)
        try write(Data(json.utf8), to: staging)
        let result = checker.check(configurationURL: staging)
        try? fileManager.removeItem(at: staging)
        switch result {
        case .failure(let diagnostic):
            try markInvalid(id, diagnostic: diagnostic)
            throw ProfileStoreError.validationFailed(diagnostic)
        case .success:
            let previous = try profile(id)!
            let nextRevision = previous.validRevision + 1
            let data = Data(json.utf8)
            try write(data, to: try configurationURL(for: id))
            try write(data, to: try versionURL(for: id, revision: nextRevision))
            try update(id) { profile in
                profile.validation = ProfileValidation(status: .valid, checkedAt: now(), error: nil)
                profile.validRevision = nextRevision
            }
        }
    }

    func restorePreviousValidVersion(for id: UUID) throws {
        guard let current = try profile(id), current.validRevision > 1 else { return }
        let data = try Data(contentsOf: try versionURL(for: id, revision: current.validRevision - 1))
        try write(data, to: try configurationURL(for: id))
        try update(id) { profile in
            profile.validRevision -= 1
            profile.validation = ProfileValidation(status: .valid, checkedAt: now(), error: nil)
        }
    }

    func safeManagedURL(_ relativePath: String) throws -> URL {
        try safeRootFile(relativePath)
    }

    private func profile(_ id: UUID) throws -> Profile? {
        try loadManifest().first { $0.id == id }
    }

    private func update(_ id: UUID, mutate: (inout Profile) -> Void) throws {
        var profiles = try loadManifest()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound }
        mutate(&profiles[index])
        profiles[index].updatedAt = now()
        try saveManifest(profiles)
    }

    private func markInvalid(_ id: UUID, diagnostic: ConfigurationDiagnostic) throws {
        try update(id) { profile in
            profile.validation = ProfileValidation(status: .invalid, checkedAt: now(), error: diagnostic)
        }
    }

    private func loadManifest() throws -> [Profile] {
        try ensureRoot()
        let url = try safeRootFile(Self.manifestName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url)) }
        catch { throw ProfileStoreError.invalidStoredMetadata }
    }

    private func saveManifest(_ profiles: [Profile]) throws {
        try write(JSONEncoder().encode(profiles), to: try safeRootFile(Self.manifestName))
    }

    private func loadSelection() throws -> UUID? {
        try ensureRoot()
        let url = try safeRootFile("selected-profile.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let text = try JSONDecoder().decode(String?.self, from: Data(contentsOf: url))
        return text.flatMap(UUID.init(uuidString:))
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 80 else { throw ProfileStoreError.invalidName }
        return normalized
    }

    private func configurationURL(for id: UUID) throws -> URL { try safeProfileDirectory(id).appending(path: Self.configurationName) }
    private func stagingURL(for id: UUID) throws -> URL { try safeProfileDirectory(id).appending(path: Self.stagingName) }
    private func versionURL(for id: UUID, revision: Int) throws -> URL {
        guard revision > 0 else { throw ProfileStoreError.unsafePath }
        return try safeProfileDirectory(id).appending(path: "versions/\(revision).json")
    }

    private func safeProfileDirectory(_ id: UUID) throws -> URL {
        try safeRootFile(id.uuidString, directory: true)
    }

    private func safeRootFile(_ relativePath: String, directory: Bool = false) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw ProfileStoreError.unsafePath
        }
        let url = rootDirectory.appending(path: relativePath, directoryHint: directory ? .isDirectory : .notDirectory).standardizedFileURL
        guard url.path.hasPrefix(rootDirectory.path + "/") else { throw ProfileStoreError.unsafePath }
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard parent.path == rootDirectory.path || parent.path.hasPrefix(rootDirectory.path + "/") else { throw ProfileStoreError.unsafePath }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
