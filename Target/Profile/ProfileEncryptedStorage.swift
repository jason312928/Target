import CryptoKit
import Foundation
import Security

/// The production key provider deliberately exposes only key existence and creation.
/// Callers never receive Keychain attributes or error payloads that could contain data.
protocol ProfileEncryptionKeyProviding: AnyObject {
    func loadMasterKey() throws -> Data?
    func createMasterKey() throws -> Data
}

enum ProfileEncryptionKeyProviderError: Error, Equatable {
    case queryFailed(OSStatus)
    case creationFailed(OSStatus)
    case invalidKeyMaterial
}

final class KeychainProfileEncryptionKeyProvider: ProfileEncryptionKeyProviding {
    private static let service = "com.jason312928.Target.profile-storage.v1"
    private static let account = "master-key-v1"

    func loadMasterKey() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProfileEncryptionKeyProviderError.queryFailed(status)
        }
        guard data.count == 32 else { throw ProfileEncryptionKeyProviderError.invalidKeyMaterial }
        return data
    }

    func createMasterKey() throws -> Data {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return try loadMasterKey() ?? { throw ProfileEncryptionKeyProviderError.invalidKeyMaterial }() }
        guard status == errSecSuccess else { throw ProfileEncryptionKeyProviderError.creationFailed(status) }
        return data
    }
}

enum ProfilePersistentRecordKind: String, Sendable {
    case manifest
    case selection
    case currentConfiguration
    case version
}

enum ProfileStorageFaultPoint: Sendable {
    case stagingWrite
    case beforeStagingVerification
    case beforeCommit
    case afterBackupRename
    case afterLiveSwap
}

protocol ProfileStorageFaultInjecting {
    func check(_ point: ProfileStorageFaultPoint) throws
}

struct NoProfileStorageFaults: ProfileStorageFaultInjecting {
    func check(_ point: ProfileStorageFaultPoint) throws {}
}

/// Versioned, authenticated disk storage for all Profile-domain records.
/// The cleartext binding digest gives a deterministic path/type mismatch error before
/// AES-GCM authentication; the same binding is also passed as AAD to AES-GCM.
final class ProfileEncryptedStorage {
    static let markerName = "storage-format.json"
    private static let manifestName = "profiles.json"
    private static let selectionName = "selected-profile.json"
    private static let magic = Data([0x54, 0x50, 0x45, 0x31]) // TPE1
    private static let formatVersion: UInt8 = 1
    private static let bindingDigestLength = 32
    private static let nonceLength = 12
    private static let tagLength = 16

    private let root: URL
    private let fileManager: FileManager
    private let keyProvider: any ProfileEncryptionKeyProviding
    private let faults: any ProfileStorageFaultInjecting
    private var key: SymmetricKey?

    init(root: URL, fileManager: FileManager = .default, keyProvider: any ProfileEncryptionKeyProviding, faults: any ProfileStorageFaultInjecting = NoProfileStorageFaults()) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.keyProvider = keyProvider
        self.faults = faults
    }

    func prepare() throws {
        try recoverInterruptedMigration()
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try setDirectoryPermissions(root)
        }
        let entries: [String]
        do { entries = try fileManager.contentsOfDirectory(atPath: root.path) }
        catch { throw ProfileStoreError.mixedOrDowngradedStorage }
        let marker = root.appending(path: Self.markerName)
        if fileManager.fileExists(atPath: marker.path) {
            try setDirectoryPermissions(root)
            _ = try validateEncryptedTree()
            try removeStagingAfterAuthoritativeLiveValidation()
            return
        }
        if entries.isEmpty {
            try setDirectoryPermissions(root)
            try createNewEncryptedStore()
            _ = try validateEncryptedTree()
            return
        }
        try migratePlaintextStore()
    }

    func read(kind: ProfilePersistentRecordKind, logicalPath: String, url: URL) throws -> Data {
        try prepare()
        guard fileManager.fileExists(atPath: url.path) else { throw ProfileStoreError.missingEncryptedRecord }
        return try authenticatedRecord(at: url, kind: kind, logicalPath: logicalPath)
    }

    func write(_ plaintext: Data, kind: ProfilePersistentRecordKind, logicalPath: String, url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try setDirectoryPermissions(parent)
        let encrypted = try encrypt(plaintext, kind: kind, logicalPath: logicalPath)
        try encrypted.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func createProfileDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory.appending(path: "versions"), withIntermediateDirectories: true)
        try setDirectoryPermissions(directory)
        try setDirectoryPermissions(directory.appending(path: "versions"))
    }

    /// Used only after an interrupted import has been resolved. Import recovery
    /// runs before `prepare()` so an incomplete live tree is never authenticated
    /// as authoritative state.
    func authenticateExistingTree() throws {
        _ = try validateEncryptedTree()
    }

    private func createNewEncryptedStore() throws {
        try createKeyIfAllowed()
        try writeMarker(to: root)
        try write(Data("[]".utf8), kind: .manifest, logicalPath: Self.manifestName, url: root.appending(path: Self.manifestName))
        try write(try JSONEncoder().encode(String?.none), kind: .selection, logicalPath: Self.selectionName, url: root.appending(path: Self.selectionName))
    }

    private func requireExistingKey() throws {
        do {
            guard let material = try keyProvider.loadMasterKey() else { throw ProfileStoreError.encryptedStoreKeyMissing }
            guard material.count == 32 else { throw ProfileStoreError.invalidEncryptionKey }
            key = SymmetricKey(data: material)
        } catch let error as ProfileStoreError { throw error }
        catch ProfileEncryptionKeyProviderError.invalidKeyMaterial { throw ProfileStoreError.invalidEncryptionKey }
        catch { throw ProfileStoreError.keychainReadFailed }
    }

    private func createKeyIfAllowed() throws {
        do {
            if let material = try keyProvider.loadMasterKey() {
                guard material.count == 32 else { throw ProfileStoreError.invalidEncryptionKey }
                key = SymmetricKey(data: material)
            } else {
                let material = try keyProvider.createMasterKey()
                guard material.count == 32 else { throw ProfileStoreError.invalidEncryptionKey }
                key = SymmetricKey(data: material)
            }
        } catch let error as ProfileStoreError { throw error }
        catch ProfileEncryptionKeyProviderError.invalidKeyMaterial { throw ProfileStoreError.invalidEncryptionKey }
        catch { throw ProfileStoreError.keychainReadFailed }
    }

    private func keyForCipher() throws -> SymmetricKey {
        if let key { return key }
        try requireExistingKey()
        guard let key else { throw ProfileStoreError.encryptedStoreKeyMissing }
        return key
    }

    private func encrypt(_ plaintext: Data, kind: ProfilePersistentRecordKind, logicalPath: String) throws -> Data {
        let aad = additionalAuthenticatedData(kind: kind, logicalPath: logicalPath)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: try keyForCipher(), authenticating: aad)
            guard let combined = sealed.combined else { throw ProfileStoreError.encryptionFailed }
            let nonce = combined.prefix(Self.nonceLength)
            let ciphertext = combined.dropFirst(Self.nonceLength).dropLast(Self.tagLength)
            let tag = combined.suffix(Self.tagLength)
            return Self.magic + Data([Self.formatVersion]) + SHA256.hash(data: aad) + nonce + ciphertext + tag
        } catch let error as ProfileStoreError { throw error }
        catch { throw ProfileStoreError.encryptionFailed }
    }

    private func decrypt(_ envelope: Data, kind: ProfilePersistentRecordKind, logicalPath: String) throws -> Data {
        let minimum = Self.magic.count + 1 + Self.bindingDigestLength + Self.nonceLength + Self.tagLength
        guard envelope.count >= minimum, envelope.prefix(Self.magic.count) == Self.magic else { throw ProfileStoreError.invalidEncryptedEnvelope }
        let versionIndex = Self.magic.count
        guard envelope[versionIndex] == Self.formatVersion else { throw ProfileStoreError.unsupportedStorageVersion }
        let aad = additionalAuthenticatedData(kind: kind, logicalPath: logicalPath)
        let digestStart = versionIndex + 1
        let digestEnd = digestStart + Self.bindingDigestLength
        guard Data(envelope[digestStart..<digestEnd]) == Data(SHA256.hash(data: aad)) else {
            throw ProfileStoreError.encryptedStorageAADMismatch
        }
        let payloadStart = digestEnd
        do {
            let box = try AES.GCM.SealedBox(combined: Data(envelope[payloadStart...]))
            return try AES.GCM.open(box, using: try keyForCipher(), authenticating: aad)
        } catch let error as ProfileStoreError { throw error }
        catch { throw ProfileStoreError.encryptedStorageAuthenticationFailed }
    }

    private func additionalAuthenticatedData(kind: ProfilePersistentRecordKind, logicalPath: String) -> Data {
        Data("Target.ProfileStorage|version=1|kind=\(kind.rawValue)|path=\(logicalPath)".utf8)
    }

    private func writeMarker(to directory: URL) throws {
        let marker = directory.appending(path: Self.markerName)
        let data = try JSONSerialization.data(withJSONObject: ["format": "target-profile-encrypted", "version": Int(Self.formatVersion)], options: [.sortedKeys])
        try data.write(to: marker, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private func verifyMarker(_ marker: URL) throws {
        guard let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              value["format"] as? String == "target-profile-encrypted",
              value["version"] as? Int == Int(Self.formatVersion) else {
            throw ProfileStoreError.unsupportedStorageVersion
        }
    }

    private struct ProfileRecordInventory {
        let profile: Profile
        let currentConfiguration: Data
        let revisions: [(number: Int, data: Data)]
    }

    private struct TreeInventory {
        let manifestData: Data
        let profiles: [Profile]
        let selectionData: Data
        let selectedProfileID: UUID?
        let records: [ProfileRecordInventory]
    }

    /// Authenticates and validates the entire encrypted tree without calling `prepare()`.
    private func validateEncryptedTree() throws -> TreeInventory {
        let marker = root.appending(path: Self.markerName)
        try requireRegularFile(marker, failure: .mixedOrDowngradedStorage)
        try verifyMarker(marker)
        try requireExistingKey()

        let manifestURL = root.appending(path: Self.manifestName)
        let selectionURL = root.appending(path: Self.selectionName)
        try requireRegularFile(manifestURL, failure: .mixedOrDowngradedStorage)
        try requireRegularFile(selectionURL, failure: .mixedOrDowngradedStorage)
        let manifestData = try authenticatedRecord(at: manifestURL, kind: .manifest, logicalPath: Self.manifestName)
        let profiles: [Profile]
        do { profiles = try JSONDecoder().decode([Profile].self, from: manifestData) }
        catch { throw ProfileStoreError.invalidStoredMetadata }
        let profileIDs = profiles.map(\.id)
        guard Set(profileIDs).count == profileIDs.count, profiles.allSatisfy({ $0.validRevision > 0 }) else {
            throw ProfileStoreError.invalidStoredMetadata
        }

        let selectionData = try authenticatedRecord(at: selectionURL, kind: .selection, logicalPath: Self.selectionName)
        let selectedProfileID = try decodeSelection(selectionData, allowedProfileIDs: Set(profileIDs), failure: .invalidStoredMetadata)
        let expectedRootEntries = Set([Self.markerName, Self.manifestName, Self.selectionName] + profileIDs.map(\.uuidString))
        let rootEntries = try directoryEntries(root, failure: .mixedOrDowngradedStorage)
        guard Set(rootEntries.map(\.lastPathComponent)) == expectedRootEntries else {
            throw ProfileStoreError.mixedOrDowngradedStorage
        }

        var records: [ProfileRecordInventory] = []
        for profile in profiles {
            let directory = root.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
            try requireDirectory(directory, failure: .mixedOrDowngradedStorage)
            let profileEntries = try directoryEntries(directory, failure: .mixedOrDowngradedStorage)
            guard Set(profileEntries.map(\.lastPathComponent)) == ["config.json", "versions"] else {
                throw ProfileStoreError.mixedOrDowngradedStorage
            }
            let configURL = directory.appending(path: "config.json")
            let versionsURL = directory.appending(path: "versions", directoryHint: .isDirectory)
            try requireRegularFile(configURL, failure: .mixedOrDowngradedStorage)
            try requireDirectory(versionsURL, failure: .mixedOrDowngradedStorage)
            let revisionURLs = try validatedRevisionURLs(in: versionsURL, failure: .mixedOrDowngradedStorage)
            guard revisionURLs.contains(where: { $0.number == profile.validRevision }) else {
                throw ProfileStoreError.invalidStoredMetadata
            }
            let profilePath = profile.id.uuidString
            let current = try authenticatedRecord(
                at: configURL,
                kind: .currentConfiguration,
                logicalPath: "\(profilePath)/config.json"
            )
            var revisions: [(number: Int, data: Data)] = []
            for revision in revisionURLs {
                let data = try authenticatedRecord(
                    at: revision.url,
                    kind: .version,
                    logicalPath: "\(profilePath)/versions/\(revision.number).json"
                )
                revisions.append((revision.number, data))
            }
            guard revisions.first(where: { $0.number == profile.validRevision })?.data == current else {
                throw ProfileStoreError.invalidStoredMetadata
            }
            records.append(ProfileRecordInventory(profile: profile, currentConfiguration: current, revisions: revisions))
        }
        return TreeInventory(
            manifestData: manifestData,
            profiles: profiles,
            selectionData: selectionData,
            selectedProfileID: selectedProfileID,
            records: records
        )
    }

    private func legacyInventory() throws -> TreeInventory {
        let failure = ProfileStoreError.plaintextMigrationValidationFailed
        do {
            let manifestURL = root.appending(path: Self.manifestName)
            try requireRegularFile(manifestURL, failure: failure)
            let manifestData = try Data(contentsOf: manifestURL)
            let profiles = try JSONDecoder().decode([Profile].self, from: manifestData)
            let profileIDs = profiles.map(\.id)
            guard Set(profileIDs).count == profileIDs.count, profiles.allSatisfy({ $0.validRevision > 0 }) else { throw failure }

            let selectionURL = root.appending(path: Self.selectionName)
            let selectionData: Data
            if fileManager.fileExists(atPath: selectionURL.path) {
                try requireRegularFile(selectionURL, failure: failure)
                selectionData = try Data(contentsOf: selectionURL)
            } else {
                selectionData = try JSONEncoder().encode(String?.none)
            }
            let selectedProfileID = try decodeSelection(selectionData, allowedProfileIDs: Set(profileIDs), failure: failure)
            var expectedRootEntries = Set([Self.manifestName] + profileIDs.map(\.uuidString))
            if fileManager.fileExists(atPath: selectionURL.path) { expectedRootEntries.insert(Self.selectionName) }
            let rootEntries = try directoryEntries(root, failure: failure)
            guard Set(rootEntries.map(\.lastPathComponent)) == expectedRootEntries else { throw failure }

            var records: [ProfileRecordInventory] = []
            for profile in profiles {
                let directory = root.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
                try requireDirectory(directory, failure: failure)
                let entries = try directoryEntries(directory, failure: failure)
                let allowed = Set(["config.json", "versions", ".pending-check.json"])
                guard Set(entries.map(\.lastPathComponent)).isSubset(of: allowed),
                      Set(entries.map(\.lastPathComponent)).isSuperset(of: ["config.json", "versions"]) else { throw failure }
                if let pending = entries.first(where: { $0.lastPathComponent == ".pending-check.json" }) {
                    try requireRegularFile(pending, failure: failure)
                }
                let configURL = directory.appending(path: "config.json")
                let versionsURL = directory.appending(path: "versions", directoryHint: .isDirectory)
                try requireRegularFile(configURL, failure: failure)
                try requireDirectory(versionsURL, failure: failure)
                let revisionURLs = try validatedRevisionURLs(in: versionsURL, failure: failure)
                guard revisionURLs.contains(where: { $0.number == profile.validRevision }) else { throw failure }
                let current = try Data(contentsOf: configURL)
                let revisions = try revisionURLs.map { (number: $0.number, data: try Data(contentsOf: $0.url)) }
                guard revisions.first(where: { $0.number == profile.validRevision })?.data == current else { throw failure }
                records.append(ProfileRecordInventory(profile: profile, currentConfiguration: current, revisions: revisions))
            }
            return TreeInventory(
                manifestData: manifestData,
                profiles: profiles,
                selectionData: selectionData,
                selectedProfileID: selectedProfileID,
                records: records
            )
        } catch let error as ProfileStoreError {
            throw error == failure ? error : failure
        } catch {
            throw failure
        }
    }

    private func migratePlaintextStore() throws {
        let legacy = try legacyInventory()
        try createKeyIfAllowed()
        let staging = stagingRoot
        let backup = backupRoot
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try setDirectoryPermissions(staging)
        let staged = ProfileEncryptedStorage(root: staging, fileManager: fileManager, keyProvider: keyProvider, faults: faults)
        staged.key = key
        try staged.writeMarker(to: staging)
        try staged.write(legacy.manifestData, kind: .manifest, logicalPath: Self.manifestName, url: staging.appending(path: Self.manifestName))
        try staged.write(legacy.selectionData, kind: .selection, logicalPath: Self.selectionName, url: staging.appending(path: Self.selectionName))
        for record in legacy.records {
            let profilePath = record.profile.id.uuidString
            try staged.createProfileDirectory(staging.appending(path: profilePath, directoryHint: .isDirectory))
            try checkFault(.stagingWrite, as: .plaintextMigrationValidationFailed)
            try staged.write(record.currentConfiguration, kind: .currentConfiguration, logicalPath: "\(profilePath)/config.json", url: staging.appending(path: "\(profilePath)/config.json"))
            for revision in record.revisions {
                try staged.write(revision.data, kind: .version, logicalPath: "\(profilePath)/versions/\(revision.number).json", url: staging.appending(path: "\(profilePath)/versions/\(revision.number).json"))
            }
        }
        try checkFault(.beforeStagingVerification, as: .plaintextMigrationValidationFailed)
        try staged.verifyMigratedTree(matches: legacy)
        try checkFault(.beforeCommit, as: .plaintextMigrationCommitFailed)
        do {
            try fileManager.moveItem(at: root, to: backup)
            try checkFault(.afterBackupRename, as: .plaintextMigrationCommitFailed)
            try fileManager.moveItem(at: staging, to: root)
            try checkFault(.afterLiveSwap, as: .plaintextMigrationCommitFailed)
            try verifyMigratedTree(matches: legacy)
            try fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: root.path), fileManager.fileExists(atPath: backup.path) {
                do { try fileManager.moveItem(at: backup, to: root) }
                catch { throw ProfileStoreError.plaintextMigrationRecoveryFailed }
            }
            throw ProfileStoreError.plaintextMigrationCommitFailed
        }
    }

    private func verifyMigratedTree(matches legacy: TreeInventory) throws {
        let encrypted = try validateEncryptedTree()
        guard encrypted.manifestData == legacy.manifestData,
              encrypted.profiles == legacy.profiles,
              encrypted.selectionData == legacy.selectionData,
              encrypted.selectedProfileID == legacy.selectedProfileID,
              encrypted.records.count == legacy.records.count else {
            throw ProfileStoreError.plaintextMigrationValidationFailed
        }
        for (encryptedRecord, legacyRecord) in zip(encrypted.records, legacy.records) {
            guard encryptedRecord.profile == legacyRecord.profile,
                  encryptedRecord.currentConfiguration == legacyRecord.currentConfiguration,
                  encryptedRecord.revisions.count == legacyRecord.revisions.count else {
                throw ProfileStoreError.plaintextMigrationValidationFailed
            }
            for (encryptedRevision, legacyRevision) in zip(encryptedRecord.revisions, legacyRecord.revisions) {
                guard encryptedRevision.number == legacyRevision.number,
                      encryptedRevision.data == legacyRevision.data else {
                    throw ProfileStoreError.plaintextMigrationValidationFailed
                }
            }
        }
    }

    private func checkFault(_ point: ProfileStorageFaultPoint, as error: ProfileStoreError) throws {
        do { try faults.check(point) }
        catch { throw error }
    }

    private func decodeSelection(
        _ data: Data,
        allowedProfileIDs: Set<UUID>,
        failure: ProfileStoreError
    ) throws -> UUID? {
        let selected: String?
        do { selected = try JSONDecoder().decode(String?.self, from: data) }
        catch { throw failure }
        guard let selected else { return nil }
        guard let id = UUID(uuidString: selected), allowedProfileIDs.contains(id) else { throw failure }
        return id
    }

    private func authenticatedRecord(
        at url: URL,
        kind: ProfilePersistentRecordKind,
        logicalPath: String
    ) throws -> Data {
        let envelope: Data
        do { envelope = try Data(contentsOf: url) }
        catch { throw ProfileStoreError.missingEncryptedRecord }
        guard envelope.starts(with: Self.magic) else { throw ProfileStoreError.mixedOrDowngradedStorage }
        return try decrypt(envelope, kind: kind, logicalPath: logicalPath)
    }

    private func directoryEntries(_ directory: URL, failure: ProfileStoreError) throws -> [URL] {
        do { return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch { throw failure }
    }

    private func requireDirectory(_ url: URL, failure: ProfileStoreError) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure }
        } catch let error as ProfileStoreError { throw error }
        catch { throw failure }
    }

    private func requireRegularFile(_ url: URL, failure: ProfileStoreError) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure }
        } catch let error as ProfileStoreError { throw error }
        catch { throw failure }
    }

    private func validatedRevisionURLs(
        in versionsDirectory: URL,
        failure: ProfileStoreError
    ) throws -> [(number: Int, url: URL)] {
        let entries = try directoryEntries(versionsDirectory, failure: failure)
        var revisions: [(number: Int, url: URL)] = []
        for entry in entries {
            try requireRegularFile(entry, failure: failure)
            guard entry.pathExtension == "json" else { throw failure }
            let stem = entry.deletingPathExtension().lastPathComponent
            guard let number = Int(stem), number > 0, stem == String(number) else { throw failure }
            revisions.append((number, entry))
        }
        revisions.sort { $0.number < $1.number }
        guard !revisions.isEmpty,
              revisions.map(\.number) == Array(1...revisions.count) else { throw failure }
        return revisions
    }

    private var stagingRoot: URL { root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).encrypted-staging", directoryHint: .isDirectory) }
    private var backupRoot: URL { root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).plaintext-backup", directoryHint: .isDirectory) }

    private func recoverInterruptedMigration() throws {
        let staging = stagingRoot
        let backup = backupRoot
        let liveExists = fileManager.fileExists(atPath: root.path)
        let backupExists = fileManager.fileExists(atPath: backup.path)
        let stagingExists = fileManager.fileExists(atPath: staging.path)
        if !liveExists && backupExists {
            do {
                try fileManager.moveItem(at: backup, to: root)
                if stagingExists { try? fileManager.removeItem(at: staging) }
            } catch { throw ProfileStoreError.plaintextMigrationRecoveryFailed }
            return
        }
        if liveExists && backupExists {
            _ = try validateEncryptedTree()
            do {
                if stagingExists { try fileManager.removeItem(at: staging) }
                try fileManager.removeItem(at: backup)
            } catch { throw ProfileStoreError.plaintextMigrationRecoveryFailed }
        }
    }

    private func removeStagingAfterAuthoritativeLiveValidation() throws {
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return }
        do { try fileManager.removeItem(at: stagingRoot) }
        catch { throw ProfileStoreError.plaintextMigrationRecoveryFailed }
    }

    private func setDirectoryPermissions(_ directory: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

/// Target-owned short-lived plaintext files for `sing-box check`. They never live
/// under the encrypted Profile root and are removed on every normal/error path.
final class ProfileValidationTemporaryStorage {
    private let directory: URL
    private let fileManager: FileManager
    private let setAttributes: ([FileAttributeKey: Any], String) throws -> Void

    init(
        profileRoot: URL,
        fileManager: FileManager = .default,
        setAttributes: (([FileAttributeKey: Any], String) throws -> Void)? = nil
    ) {
        directory = profileRoot.deletingLastPathComponent().appending(path: ".TargetProfileValidation", directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.setAttributes = setAttributes ?? { attributes, path in
            try fileManager.setAttributes(attributes, ofItemAtPath: path)
        }
    }

    func prepare() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try setAttributes([.posixPermissions: 0o700], directory.path)
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        where url.lastPathComponent.hasPrefix("validation-") && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try? fileManager.removeItem(at: url)
        }
    }

    func withTemporaryConfiguration<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        try prepare()
        let file = directory.appending(path: "validation-\(UUID().uuidString).json")
        try data.write(to: file, options: .atomic)
        defer { try? fileManager.removeItem(at: file) }
        try setAttributes([.posixPermissions: 0o600], file.path)
        return try body(file)
    }

    var managedDirectory: URL { directory }
}
