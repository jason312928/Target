import Foundation

/// Owns encrypted Profile persistence. Configuration bytes stay opaque UTF-8 JSON;
/// only the storage boundary encrypts/decrypts them, never Codable round-trips them.
final class ProfileStore {
    static let profilesDirectoryName = "Profiles"
    private static let manifestName = "profiles.json"
    private static let selectionName = "selected-profile.json"
    private static let configurationName = "config.json"

    private let rootDirectory: URL
    private let checker: any SingBoxConfigurationChecking
    private let fileManager: FileManager
    private let now: () -> Date
    private let runtimeUsage: any ProfileRuntimeUsageChecking
    private let encryptedStorage: ProfileEncryptedStorage
    private let validationTemporaryStorage: ProfileValidationTemporaryStorage

    init(
        rootDirectory: URL = ProfileStore.defaultRootDirectory(),
        checker: any SingBoxConfigurationChecking = SingBoxConfigurationChecker(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        runtimeUsage: any ProfileRuntimeUsageChecking = EngineRuntimeOwnership(),
        keyProvider: any ProfileEncryptionKeyProviding = KeychainProfileEncryptionKeyProvider(),
        storageFaults: any ProfileStorageFaultInjecting = NoProfileStorageFaults()
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.checker = checker
        self.fileManager = fileManager
        self.now = now
        self.runtimeUsage = runtimeUsage
        encryptedStorage = ProfileEncryptedStorage(root: rootDirectory, fileManager: fileManager, keyProvider: keyProvider, faults: storageFaults)
        validationTemporaryStorage = ProfileValidationTemporaryStorage(profileRoot: rootDirectory, fileManager: fileManager)
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/Profiles", directoryHint: .isDirectory)
    }

    func listProfiles() throws -> [Profile] { try loadManifest().sorted { $0.updatedAt > $1.updatedAt } }
    func selectedProfileID() throws -> UUID? { try loadSelection() }

    func select(_ id: UUID?) throws {
        if let id, try profile(id) == nil { throw ProfileStoreError.profileNotFound }
        try ensureRoot()
        try encryptedStorage.write(try JSONEncoder().encode(id?.uuidString), kind: .selection, logicalPath: Self.selectionName, url: safeRootFile(Self.selectionName))
    }

    @discardableResult
    func create(name: String, subscriptionURL: URL? = nil) throws -> Profile {
        let normalizedName = try validatedName(name)
        try ensureRoot()
        var profiles = try loadManifest()
        let timestamp = now()
        let profile = Profile(id: UUID(), name: normalizedName, subscription: subscriptionURL.map { RemoteSubscription(url: $0) }, createdAt: timestamp, updatedAt: timestamp, validation: .notChecked, validRevision: 1)
        let directory = try safeProfileDirectory(profile.id)
        try encryptedStorage.createProfileDirectory(directory)
        let data = Data(SafeExampleConfiguration.json().utf8)
        try writeConfiguration(data, for: profile.id)
        try writeVersion(data, for: profile.id, revision: 1)
        profiles.append(profile)
        try saveManifest(profiles)
        if try selectedProfileID() == nil { try select(profile.id) }
        return profile
    }

    @discardableResult
    func `import`(name: String, json: String, subscriptionURL: URL? = nil) throws -> Profile {
        let profile = try create(name: name, subscriptionURL: subscriptionURL)
        do { try save(json: json, for: profile.id); return try self.profile(profile.id) ?? profile }
        catch { try? delete(profile.id); throw error }
    }

    @discardableResult
    func duplicate(_ id: UUID, name: String? = nil) throws -> Profile {
        guard let original = try profile(id) else { throw ProfileStoreError.profileNotFound }
        let copy = try create(name: name ?? "\(original.name) Copy", subscriptionURL: original.subscription?.url)
        let data = try configurationData(for: original.id)
        try writeConfiguration(data, for: copy.id)
        try writeVersion(data, for: copy.id, revision: 1)
        try update(copy.id) { profile in profile.validation = original.validation; profile.validRevision = 1 }
        return try profile(copy.id) ?? copy
    }

    func rename(_ id: UUID, to name: String) throws { let name = try validatedName(name); try update(id) { $0.name = name } }

    func delete(_ id: UUID) throws {
        guard try profile(id) != nil else { throw ProfileStoreError.profileNotFound }
        guard !runtimeUsage.isProfileInUse(id) else { throw ProfileStoreError.profileInUse }
        try fileManager.removeItem(at: try safeProfileDirectory(id))
        var profiles = try loadManifest()
        profiles.removeAll { $0.id == id }
        try saveManifest(profiles)
        if try selectedProfileID() == id { try select(profiles.first?.id) }
    }

    func configurationText(for id: UUID) throws -> String {
        guard try profile(id) != nil else { throw ProfileStoreError.profileNotFound }
        guard let text = String(data: try configurationData(for: id), encoding: .utf8) else { throw ProfileStoreError.invalidStoredMetadata }
        return text
    }

    func selectedValidVersion() throws -> ProfileConfigurationVersion {
        guard let id = try selectedProfileID() else { throw ProfileStoreError.noSelectedProfile }
        guard let profile = try profile(id) else { throw ProfileStoreError.profileNotFound }
        return try validVersion(for: profile, revision: profile.validRevision)
    }

    func validVersion(for id: UUID, revision: Int) throws -> ProfileConfigurationVersion {
        guard let profile = try profile(id) else { throw ProfileStoreError.profileNotFound }
        return try validVersion(for: profile, revision: revision)
    }

    private func validVersion(for profile: Profile, revision: Int) throws -> ProfileConfigurationVersion {
        guard revision > 0, fileManager.fileExists(atPath: (try versionURL(for: profile.id, revision: revision)).path) else { throw ProfileStoreError.noValidVersion }
        return ProfileConfigurationVersion(profile: profile, revision: revision, data: try versionData(for: profile.id, revision: revision))
    }

    func save(json: String, for id: UUID) throws {
        guard try profile(id) != nil else { throw ProfileStoreError.profileNotFound }
        if let syntaxError = JSONSyntaxChecker.validate(json) { try markInvalid(id, diagnostic: syntaxError); throw ProfileStoreError.invalidJSON(syntaxError) }
        let data = Data(json.utf8)
        let result = try validationTemporaryStorage.withTemporaryConfiguration(data) { checker.check(configurationURL: $0) }
        switch result {
        case .failure(let diagnostic): try markInvalid(id, diagnostic: diagnostic); throw ProfileStoreError.validationFailed(diagnostic)
        case .success:
            let previous = try profile(id)!
            let nextRevision = previous.validRevision + 1
            try writeConfiguration(data, for: id)
            try writeVersion(data, for: id, revision: nextRevision)
            try update(id) { $0.validation = ProfileValidation(status: .valid, checkedAt: now(), error: nil); $0.validRevision = nextRevision }
        }
    }

    func restorePreviousValidVersion(for id: UUID) throws {
        guard let current = try profile(id), current.validRevision > 1 else { return }
        try writeConfiguration(try versionData(for: id, revision: current.validRevision - 1), for: id)
        try update(id) { $0.validRevision -= 1; $0.validation = ProfileValidation(status: .valid, checkedAt: now(), error: nil) }
    }

    func availableValidVersions(for id: UUID) throws -> [ProfileVersionSummary] {
        guard let profile = try profile(id) else { throw ProfileStoreError.profileNotFound }
        return (1...profile.validRevision).reversed().compactMap { revision in
            guard let attributes = try? fileManager.attributesOfItem(atPath: (try? versionURL(for: id, revision: revision))?.path ?? "") else { return nil }
            return ProfileVersionSummary(revision: revision, savedAt: attributes[.modificationDate] as? Date)
        }
    }

    func previewSubscriptionUpdate(_ response: SubscriptionResponse, for id: UUID) throws -> PendingSubscriptionUpdate? {
        guard try profile(id)?.subscription != nil else { throw SubscriptionUpdateError.noSubscription }
        if response.cacheStatus == .notModified { try recordSubscriptionResult(for: id, response: response, error: nil); return nil }
        guard let text = String(data: response.data, encoding: .utf8) else { throw ProfileStoreError.invalidJSON(ConfigurationDiagnostic(messageKey: "profile.validation.json-syntax", line: nil, column: nil)) }
        if let syntaxError = JSONSyntaxChecker.validate(text) { try recordSubscriptionFailure(for: id, messageKey: syntaxError.messageKey); throw ProfileStoreError.invalidJSON(syntaxError) }
        let checkResult = try validationTemporaryStorage.withTemporaryConfiguration(response.data) { checker.check(configurationURL: $0) }
        if case .failure(let diagnostic) = checkResult { try recordSubscriptionFailure(for: id, messageKey: diagnostic.messageKey); throw ProfileStoreError.validationFailed(diagnostic) }
        let current = try configurationData(for: id)
        return PendingSubscriptionUpdate(profileID: id, json: text, diff: .make(current: current, candidate: response.data), response: response)
    }

    func applySubscriptionUpdate(_ pending: PendingSubscriptionUpdate) throws { try save(json: pending.json, for: pending.profileID); try recordSubscriptionResult(for: pending.profileID, response: pending.response, error: nil) }
    func recordSubscriptionFailure(for id: UUID, messageKey: String) throws { try update(id) { guard var subscription = $0.subscription else { return }; subscription.lastCheckedAt = now(); subscription.cacheStatus = .failed; subscription.lastErrorKey = messageKey; $0.subscription = subscription } }
    func recordSubscriptionCancellation(for id: UUID) throws { try update(id) { guard var subscription = $0.subscription else { return }; subscription.lastCheckedAt = now(); subscription.cacheStatus = .cancelled; subscription.lastErrorKey = "profile.subscription.error.cancelled"; $0.subscription = subscription } }
    func safeManagedURL(_ relativePath: String) throws -> URL { try safeRootFile(relativePath) }

    // Test-only observation point for the Target-owned validation directory.
    var validationTemporaryDirectory: URL { validationTemporaryStorage.managedDirectory }

    private func profile(_ id: UUID) throws -> Profile? { try loadManifest().first { $0.id == id } }
    private func update(_ id: UUID, mutate: (inout Profile) -> Void) throws { var profiles = try loadManifest(); guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound }; mutate(&profiles[index]); profiles[index].updatedAt = now(); try saveManifest(profiles) }
    private func markInvalid(_ id: UUID, diagnostic: ConfigurationDiagnostic) throws { try update(id) { $0.validation = ProfileValidation(status: .invalid, checkedAt: now(), error: diagnostic) } }

    private func loadManifest() throws -> [Profile] { try ensureRoot(); do { return try JSONDecoder().decode([Profile].self, from: encryptedStorage.read(kind: .manifest, logicalPath: Self.manifestName, url: safeRootFile(Self.manifestName))) } catch let error as ProfileStoreError { throw error } catch { throw ProfileStoreError.invalidStoredMetadata } }
    private func saveManifest(_ profiles: [Profile]) throws { try encryptedStorage.write(try JSONEncoder().encode(profiles), kind: .manifest, logicalPath: Self.manifestName, url: safeRootFile(Self.manifestName)) }
    private func loadSelection() throws -> UUID? { try ensureRoot(); do { let text = try JSONDecoder().decode(String?.self, from: encryptedStorage.read(kind: .selection, logicalPath: Self.selectionName, url: safeRootFile(Self.selectionName))); return text.flatMap(UUID.init(uuidString:)) } catch let error as ProfileStoreError { throw error } catch { throw ProfileStoreError.invalidStoredMetadata } }
    private func configurationData(for id: UUID) throws -> Data { try encryptedStorage.read(kind: .currentConfiguration, logicalPath: "\(id.uuidString)/\(Self.configurationName)", url: try configurationURL(for: id)) }
    private func versionData(for id: UUID, revision: Int) throws -> Data { try encryptedStorage.read(kind: .version, logicalPath: "\(id.uuidString)/versions/\(revision).json", url: try versionURL(for: id, revision: revision)) }
    private func writeConfiguration(_ data: Data, for id: UUID) throws { try encryptedStorage.write(data, kind: .currentConfiguration, logicalPath: "\(id.uuidString)/\(Self.configurationName)", url: try configurationURL(for: id)) }
    private func writeVersion(_ data: Data, for id: UUID, revision: Int) throws { try encryptedStorage.write(data, kind: .version, logicalPath: "\(id.uuidString)/versions/\(revision).json", url: try versionURL(for: id, revision: revision)) }
    private func ensureRoot() throws { try encryptedStorage.prepare(); try validationTemporaryStorage.prepare() }
    private func validatedName(_ name: String) throws -> String { let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !normalized.isEmpty, normalized.count <= 80 else { throw ProfileStoreError.invalidName }; return normalized }
    private func configurationURL(for id: UUID) throws -> URL { try safeProfileDirectory(id).appending(path: Self.configurationName) }
    private func versionURL(for id: UUID, revision: Int) throws -> URL { guard revision > 0 else { throw ProfileStoreError.unsafePath }; return try safeProfileDirectory(id).appending(path: "versions/\(revision).json") }
    private func safeProfileDirectory(_ id: UUID) throws -> URL { try safeRootFile(id.uuidString, directory: true) }
    private func safeRootFile(_ relativePath: String, directory: Bool = false) throws -> URL { guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw ProfileStoreError.unsafePath }; let url = rootDirectory.appending(path: relativePath, directoryHint: directory ? .isDirectory : .notDirectory).standardizedFileURL; guard url.path.hasPrefix(rootDirectory.path + "/") else { throw ProfileStoreError.unsafePath }; return url }
    private func recordSubscriptionResult(for id: UUID, response: SubscriptionResponse, error: String?) throws { try update(id) { guard var subscription = $0.subscription else { return }; let timestamp = now(); subscription.lastCheckedAt = timestamp; if response.cacheStatus == .updated { subscription.lastUpdatedAt = timestamp }; subscription.etag = response.etag; subscription.lastModified = response.lastModified; subscription.cacheStatus = response.cacheStatus; subscription.lastErrorKey = error; $0.subscription = subscription } }
}
