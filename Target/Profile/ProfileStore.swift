import Darwin
import Foundation

protocol ProfileImportFileOperating {
    func createDirectory(at url: URL) throws
    func readFile(at url: URL) throws -> Data
    func writeOwnerOnly(_ data: Data, to url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func directoryContents(at url: URL) throws -> [URL]
}

struct ProfileImportFileOperations: ProfileImportFileOperating {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func readFile(at url: URL) throws -> Data { try Data(contentsOf: url) }

    func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        let temporaryName = ".import-write-\(UUID().uuidString)"
        let temporary = url.deletingLastPathComponent().appending(path: temporaryName)
        var descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ProfileStoreError.profileImportTransactionFailed }
        var temporaryExists = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if temporaryExists { _ = Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                guard count > 0 else { throw ProfileStoreError.profileImportTransactionFailed }
                address = address.advanced(by: Int(count))
                remaining -= Int(count)
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.close(descriptor) == 0 else {
            throw ProfileStoreError.profileImportTransactionFailed
        }
        descriptor = -1
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw ProfileStoreError.profileImportTransactionFailed
        }
        temporaryExists = false
        let parentDescriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard parentDescriptor >= 0 else { throw ProfileStoreError.profileImportTransactionFailed }
        defer { _ = Darwin.close(parentDescriptor) }
        guard Darwin.fsync(parentDescriptor) == 0 else { throw ProfileStoreError.profileImportTransactionFailed }
    }

    func moveItem(at source: URL, to destination: URL) throws { try fileManager.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try fileManager.removeItem(at: url) }
    func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
    func directoryContents(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

enum ProfileImportInterruption: Error {
    case simulated
}

private enum ProfileImportTransactionStage: String, Codable {
    case stagingPrepared
    case profileDirectoryMoved
    case manifestCommitted
    case selectionCommitted
    case completed
}

private struct ProfileImportTransactionJournal: Codable {
    let formatVersion: Int
    let profileID: UUID
    var stage: ProfileImportTransactionStage
}

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
    private let transferService: ProfileTransferService
    private let transferFaults: any ProfileTransferFaultInjecting
    private let importFileOperations: any ProfileImportFileOperating

    init(
        rootDirectory: URL = ProfileStore.defaultRootDirectory(),
        checker: any SingBoxConfigurationChecking = SingBoxConfigurationChecker(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        runtimeUsage: any ProfileRuntimeUsageChecking = EngineRuntimeOwnership(),
        keyProvider: any ProfileEncryptionKeyProviding = KeychainProfileEncryptionKeyProvider(),
        storageFaults: any ProfileStorageFaultInjecting = NoProfileStorageFaults(),
        transferFaults: any ProfileTransferFaultInjecting = NoProfileTransferFaults(),
        importFileOperations: (any ProfileImportFileOperating)? = nil
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.checker = checker
        self.fileManager = fileManager
        self.now = now
        self.runtimeUsage = runtimeUsage
        encryptedStorage = ProfileEncryptedStorage(root: rootDirectory, fileManager: fileManager, keyProvider: keyProvider, faults: storageFaults)
        validationTemporaryStorage = ProfileValidationTemporaryStorage(profileRoot: rootDirectory, fileManager: fileManager)
        transferService = ProfileTransferService(profileRoot: rootDirectory, checker: checker, fileManager: fileManager, faults: transferFaults)
        self.transferFaults = transferFaults
        self.importFileOperations = importFileOperations ?? ProfileImportFileOperations(fileManager: fileManager)
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
        guard subscriptionURL == nil else { throw ProfileStoreError.invalidStoredMetadata }
        let candidate = try transferService.prepareImport(data: Data(json.utf8), suggestedName: name)
        return try importCandidate(candidate, name: name)
    }

    /// Performs all external-file checks before it changes Profile persistence.
    func prepareImportCandidate(from url: URL) throws -> ProfileImportCandidate {
        try transferService.prepareImport(from: url)
    }

    /// A preflighted import becomes revision 1 directly; no example configuration or
    /// RemoteSubscription metadata is created as part of this transaction.
    @discardableResult
    func importCandidate(_ candidate: ProfileImportCandidate, name: String) throws -> Profile {
        let normalizedName = try validatedName(name)
        try ensureRoot()
        let originalProfiles = try loadManifest()
        let originalManifestEnvelope = try importFileOperations.readFile(at: safeRootFile(Self.manifestName))
        let originalSelectionEnvelope = try importFileOperations.readFile(at: safeRootFile(Self.selectionName))
        let timestamp = now()
        let profile = Profile(
            id: UUID(), name: normalizedName, subscription: nil,
            createdAt: timestamp, updatedAt: timestamp,
            validation: candidate.validation, validRevision: 1
        )
        let transaction = importTransactionDirectory(for: profile.id)
        let staging = transaction.appending(path: "staging", directoryHint: .isDirectory)
        let finalDirectory = try safeProfileDirectory(profile.id)
        var journal = ProfileImportTransactionJournal(formatVersion: 1, profileID: profile.id, stage: .stagingPrepared)
        var journalPersisted = false

        do {
            try transferFaults.check(.importDirectoryCreation)
            try importFileOperations.createDirectory(at: importTransactionRoot)
            try importFileOperations.createDirectory(at: transaction)
            try encryptedStorage.createProfileDirectory(staging)
            try transferFaults.check(.importCurrentConfigurationWrite)
            try encryptedStorage.write(
                candidate.data,
                kind: .currentConfiguration,
                logicalPath: "\(profile.id.uuidString)/\(Self.configurationName)",
                url: staging.appending(path: Self.configurationName)
            )
            try transferFaults.check(.importRevisionWrite)
            try encryptedStorage.write(
                candidate.data,
                kind: .version,
                logicalPath: "\(profile.id.uuidString)/versions/1.json",
                url: staging.appending(path: "versions/1.json")
            )
            try importFileOperations.writeOwnerOnly(originalManifestEnvelope, to: transaction.appending(path: "manifest.envelope"))
            try importFileOperations.writeOwnerOnly(originalSelectionEnvelope, to: transaction.appending(path: "selection.envelope"))
            try persistImportJournal(journal, in: transaction)
            journalPersisted = true

            try importFileOperations.moveItem(at: staging, to: finalDirectory)
            journal.stage = .profileDirectoryMoved
            try persistImportJournal(journal, in: transaction)
            try transferFaults.check(.importAfterDirectoryMove)

            var updatedProfiles = originalProfiles
            updatedProfiles.append(profile)
            try transferFaults.check(.importManifestWrite)
            try saveManifest(updatedProfiles)
            journal.stage = .manifestCommitted
            try persistImportJournal(journal, in: transaction)
            try transferFaults.check(.importAfterManifestCommit)
            try transferFaults.check(.importSelectionWrite)
            try encryptedStorage.write(
                try JSONEncoder().encode(profile.id.uuidString),
                kind: .selection,
                logicalPath: Self.selectionName,
                url: safeRootFile(Self.selectionName)
            )
            journal.stage = .selectionCommitted
            try persistImportJournal(journal, in: transaction)
            try transferFaults.check(.importAfterSelectionCommit)
            try encryptedStorage.authenticateExistingTree()
            journal.stage = .completed
            try persistImportJournal(journal, in: transaction)
            do { try cleanupImportTransaction(transaction) }
            catch { throw ProfileStoreError.profileImportRecoveryFailed }
            return profile
        } catch is ProfileImportInterruption {
            throw ProfileStoreError.profileImportTransactionFailed
        } catch {
            if journal.stage == .completed {
                throw ProfileStoreError.profileImportRecoveryFailed
            }
            if journalPersisted {
                do { try recoverImportTransaction(in: transaction, journal: journal) }
                catch { throw ProfileStoreError.profileImportRecoveryFailed }
            } else {
                do {
                    if importFileOperations.fileExists(at: transaction) {
                        try importFileOperations.removeItem(at: transaction)
                    }
                    try removeImportContainerIfEmpty()
                } catch {
                    throw ProfileStoreError.profileImportTransactionFailed
                }
            }
            throw ProfileStoreError.profileImportTransactionFailed
        }
    }

    /// Exports only the selected Profile's last persisted valid revision.
    func exportSelectedProfile(to destination: URL) throws {
        try transferService.writeExport(try selectedValidVersion().data, to: destination)
    }

    func defaultExportFileNameForSelectedProfile() -> String? {
        selectedProfile().map { ProfileTransferService.defaultExportFileName(for: $0.name) }
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
        var profiles = try loadManifest()
        guard profiles.contains(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound }
        guard !runtimeUsage.isProfileInUse(id) else { throw ProfileStoreError.profileInUse }
        try fileManager.removeItem(at: try safeProfileDirectory(id))
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

    func selectedProfile() -> Profile? {
        do {
            guard let id = try selectedProfileID() else { return nil }
            return try profile(id)
        } catch {
            return nil
        }
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
        var profiles = try loadManifest()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound }
        if let syntaxError = JSONSyntaxChecker.validate(json) { try markInvalid(id, diagnostic: syntaxError); throw ProfileStoreError.invalidJSON(syntaxError) }
        let data = Data(json.utf8)
        let result = try validationTemporaryStorage.withTemporaryConfiguration(data) { checker.check(configurationURL: $0) }
        switch result {
        case .failure(let diagnostic): try markInvalid(id, diagnostic: diagnostic); throw ProfileStoreError.validationFailed(diagnostic)
        case .success:
            let nextRevision = profiles[index].validRevision + 1
            try writeConfiguration(data, for: id)
            try writeVersion(data, for: id, revision: nextRevision)
            profiles[index].validation = ProfileValidation(status: .valid, checkedAt: now(), error: nil)
            profiles[index].validRevision = nextRevision
            profiles[index].updatedAt = now()
            try saveManifest(profiles)
        }
    }

    func restorePreviousValidVersion(for id: UUID) throws {
        var profiles = try loadManifest()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.profileNotFound }
        guard profiles[index].validRevision > 1 else { return }
        let previousRevision = profiles[index].validRevision - 1
        let previous = try versionData(for: id, revision: previousRevision)
        try writeConfiguration(previous, for: id)
        profiles[index].validRevision = previousRevision
        profiles[index].validation = ProfileValidation(status: .valid, checkedAt: now(), error: nil)
        profiles[index].updatedAt = now()
        try saveManifest(profiles)
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
    private func ensureRoot() throws {
        try recoverInterruptedImports()
        try encryptedStorage.prepare()
        try validationTemporaryStorage.prepare()
    }
    private func validatedName(_ name: String) throws -> String { let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !normalized.isEmpty, normalized.count <= 80 else { throw ProfileStoreError.invalidName }; return normalized }
    private func configurationURL(for id: UUID) throws -> URL { try safeProfileDirectory(id).appending(path: Self.configurationName) }
    private func versionURL(for id: UUID, revision: Int) throws -> URL { guard revision > 0 else { throw ProfileStoreError.unsafePath }; return try safeProfileDirectory(id).appending(path: "versions/\(revision).json") }
    private func safeProfileDirectory(_ id: UUID) throws -> URL { try safeRootFile(id.uuidString, directory: true) }
    private var importTransactionRoot: URL {
        rootDirectory.deletingLastPathComponent().appending(path: ".TargetProfileImport", directoryHint: .isDirectory)
    }
    private func importTransactionDirectory(for id: UUID) -> URL {
        importTransactionRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    private func persistImportJournal(_ journal: ProfileImportTransactionJournal, in transaction: URL) throws {
        try importFileOperations.writeOwnerOnly(
            try JSONEncoder().encode(journal),
            to: transaction.appending(path: "journal.json")
        )
    }
    private func recoverInterruptedImports() throws {
        guard importFileOperations.fileExists(at: importTransactionRoot) else { return }
        let transactions: [URL]
        do { transactions = try importFileOperations.directoryContents(at: importTransactionRoot).sorted { $0.lastPathComponent < $1.lastPathComponent } }
        catch { throw ProfileStoreError.profileImportRecoveryFailed }
        for transaction in transactions {
            let journalURL = transaction.appending(path: "journal.json")
            guard importFileOperations.fileExists(at: journalURL) else {
                do { try importFileOperations.removeItem(at: transaction) }
                catch { throw ProfileStoreError.profileImportRecoveryFailed }
                continue
            }
            let journal: ProfileImportTransactionJournal
            do {
                journal = try JSONDecoder().decode(ProfileImportTransactionJournal.self, from: importFileOperations.readFile(at: journalURL))
                guard journal.formatVersion == 1, transaction.lastPathComponent == journal.profileID.uuidString else {
                    throw ProfileStoreError.profileImportRecoveryFailed
                }
                try recoverImportTransaction(in: transaction, journal: journal)
            } catch {
                throw ProfileStoreError.profileImportRecoveryFailed
            }
        }
        do { try removeImportContainerIfEmpty() }
        catch { throw ProfileStoreError.profileImportRecoveryFailed }
    }
    private func recoverImportTransaction(in transaction: URL, journal: ProfileImportTransactionJournal) throws {
        if journal.stage != .completed {
            let manifest = try importFileOperations.readFile(at: transaction.appending(path: "manifest.envelope"))
            let selection = try importFileOperations.readFile(at: transaction.appending(path: "selection.envelope"))
            try importFileOperations.writeOwnerOnly(manifest, to: safeRootFile(Self.manifestName))
            try importFileOperations.writeOwnerOnly(selection, to: safeRootFile(Self.selectionName))
            let finalDirectory = try safeProfileDirectory(journal.profileID)
            if importFileOperations.fileExists(at: finalDirectory) {
                try transferFaults.check(.importRollbackCleanup)
                try importFileOperations.removeItem(at: finalDirectory)
            }
        }
        try encryptedStorage.authenticateExistingTree()
        try cleanupImportTransaction(transaction)
    }
    private func cleanupImportTransaction(_ transaction: URL) throws {
        for name in ["staging", "manifest.envelope", "selection.envelope"] {
            let item = transaction.appending(path: name)
            if importFileOperations.fileExists(at: item) { try importFileOperations.removeItem(at: item) }
        }
        let journal = transaction.appending(path: "journal.json")
        if importFileOperations.fileExists(at: journal) { try importFileOperations.removeItem(at: journal) }
        if importFileOperations.fileExists(at: transaction) { try importFileOperations.removeItem(at: transaction) }
        try removeImportContainerIfEmpty()
    }
    private func removeImportContainerIfEmpty() throws {
        guard importFileOperations.fileExists(at: importTransactionRoot),
              try importFileOperations.directoryContents(at: importTransactionRoot).isEmpty else { return }
        try importFileOperations.removeItem(at: importTransactionRoot)
    }
    private func safeRootFile(_ relativePath: String, directory: Bool = false) throws -> URL { guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw ProfileStoreError.unsafePath }; let url = rootDirectory.appending(path: relativePath, directoryHint: directory ? .isDirectory : .notDirectory).standardizedFileURL; guard url.path.hasPrefix(rootDirectory.path + "/") else { throw ProfileStoreError.unsafePath }; return url }
    private func recordSubscriptionResult(for id: UUID, response: SubscriptionResponse, error: String?) throws { try update(id) { guard var subscription = $0.subscription else { return }; let timestamp = now(); subscription.lastCheckedAt = timestamp; if response.cacheStatus == .updated { subscription.lastUpdatedAt = timestamp }; subscription.etag = response.etag; subscription.lastModified = response.lastModified; subscription.cacheStatus = response.cacheStatus; subscription.lastErrorKey = error; $0.subscription = subscription } }
}
