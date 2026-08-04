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
        }
        try setDirectoryPermissions(root)
        let entries = try fileManager.contentsOfDirectory(atPath: root.path)
        let marker = root.appending(path: Self.markerName)
        if fileManager.fileExists(atPath: marker.path) {
            try verifyMarker(marker)
            try requireExistingKey()
            try rejectPlaintextOrMixedFiles()
            return
        }
        if entries.isEmpty {
            try createNewEncryptedStore()
            return
        }
        guard isRecognizedPlaintextLayout(entries) else { throw ProfileStoreError.mixedOrDowngradedStorage }
        try migratePlaintextStore()
    }

    func read(kind: ProfilePersistentRecordKind, logicalPath: String, url: URL) throws -> Data {
        try prepare()
        guard fileManager.fileExists(atPath: url.path) else { throw ProfileStoreError.missingEncryptedRecord }
        return try decrypt(Data(contentsOf: url), kind: kind, logicalPath: logicalPath)
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

    func encryptedURLIsValid(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        return data.starts(with: Self.magic)
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

    private func rejectPlaintextOrMixedFiles() throws {
        let manifest = root.appending(path: Self.manifestName)
        let selection = root.appending(path: Self.selectionName)
        guard fileManager.fileExists(atPath: manifest.path), fileManager.fileExists(atPath: selection.path),
              try encryptedURLIsValid(manifest), try encryptedURLIsValid(selection) else { throw ProfileStoreError.mixedOrDowngradedStorage }
        let children = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for child in children where child.lastPathComponent != Self.markerName && child.lastPathComponent != Self.manifestName && child.lastPathComponent != Self.selectionName {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  UUID(uuidString: child.lastPathComponent) != nil else { throw ProfileStoreError.mixedOrDowngradedStorage }
            let config = child.appending(path: "config.json")
            let versions = child.appending(path: "versions", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: config.path), try encryptedURLIsValid(config), fileManager.fileExists(atPath: versions.path) else { throw ProfileStoreError.mixedOrDowngradedStorage }
            let versionFiles = try fileManager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
            for version in versionFiles {
                guard version.pathExtension == "json", try encryptedURLIsValid(version) else { throw ProfileStoreError.mixedOrDowngradedStorage }
            }
        }
    }

    private func isRecognizedPlaintextLayout(_ entries: [String]) -> Bool {
        entries.contains(Self.manifestName) && !entries.contains(Self.markerName)
    }

    private func migratePlaintextStore() throws {
        try createKeyIfAllowed()
        let manifestURL = root.appending(path: Self.manifestName)
        let manifestData = try Data(contentsOf: manifestURL)
        let profiles: [Profile]
        do { profiles = try JSONDecoder().decode([Profile].self, from: manifestData) }
        catch { throw ProfileStoreError.plaintextMigrationValidationFailed }
        let selectionURL = root.appending(path: Self.selectionName)
        let selectionData = fileManager.fileExists(atPath: selectionURL.path) ? try Data(contentsOf: selectionURL) : try JSONEncoder().encode(String?.none)
        let selected: String?
        do { selected = try JSONDecoder().decode(String?.self, from: selectionData) }
        catch { throw ProfileStoreError.plaintextMigrationValidationFailed }
        if let selected, UUID(uuidString: selected) == nil { throw ProfileStoreError.plaintextMigrationValidationFailed }
        try removeLegacyPendingFiles()
        let staging = stagingRoot
        let backup = backupRoot
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try setDirectoryPermissions(staging)
        let staged = ProfileEncryptedStorage(root: staging, fileManager: fileManager, keyProvider: keyProvider, faults: faults)
        staged.key = key
        try staged.writeMarker(to: staging)
        try staged.write(manifestData, kind: .manifest, logicalPath: Self.manifestName, url: staging.appending(path: Self.manifestName))
        try staged.write(selectionData, kind: .selection, logicalPath: Self.selectionName, url: staging.appending(path: Self.selectionName))
        for profile in profiles {
            let sourceDirectory = root.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
            let sourceConfig = sourceDirectory.appending(path: "config.json")
            guard fileManager.fileExists(atPath: sourceConfig.path) else { throw ProfileStoreError.plaintextMigrationValidationFailed }
            try staged.createProfileDirectory(staging.appending(path: profile.id.uuidString, directoryHint: .isDirectory))
            try checkFault(.stagingWrite, as: .plaintextMigrationValidationFailed)
            try staged.write(Data(contentsOf: sourceConfig), kind: .currentConfiguration, logicalPath: "\(profile.id.uuidString)/config.json", url: staging.appending(path: "\(profile.id.uuidString)/config.json"))
            for revision in 1...max(profile.validRevision, 1) {
                let source = sourceDirectory.appending(path: "versions/\(revision).json")
                guard fileManager.fileExists(atPath: source.path) else { throw ProfileStoreError.plaintextMigrationValidationFailed }
                try staged.write(Data(contentsOf: source), kind: .version, logicalPath: "\(profile.id.uuidString)/versions/\(revision).json", url: staging.appending(path: "\(profile.id.uuidString)/versions/\(revision).json"))
            }
        }
        try checkFault(.beforeStagingVerification, as: .plaintextMigrationValidationFailed)
        try staged.verifyMigratedTree(profiles: profiles, selectionData: selectionData)
        try checkFault(.beforeCommit, as: .plaintextMigrationCommitFailed)
        try? fileManager.removeItem(at: backup)
        do {
            try fileManager.moveItem(at: root, to: backup)
            try checkFault(.afterBackupRename, as: .plaintextMigrationCommitFailed)
            try fileManager.moveItem(at: staging, to: root)
            try checkFault(.afterLiveSwap, as: .plaintextMigrationCommitFailed)
            try fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: root.path), fileManager.fileExists(atPath: backup.path) {
                do { try fileManager.moveItem(at: backup, to: root) }
                catch { throw ProfileStoreError.plaintextMigrationRecoveryFailed }
            }
            throw ProfileStoreError.plaintextMigrationCommitFailed
        }
    }

    private func verifyMigratedTree(profiles: [Profile], selectionData: Data) throws {
        try requireExistingKey()
        let manifest = try decrypt(Data(contentsOf: root.appending(path: Self.manifestName)), kind: .manifest, logicalPath: Self.manifestName)
        guard (try? JSONDecoder().decode([Profile].self, from: manifest)) == profiles else { throw ProfileStoreError.plaintextMigrationValidationFailed }
        let selection = try decrypt(Data(contentsOf: root.appending(path: Self.selectionName)), kind: .selection, logicalPath: Self.selectionName)
        guard selection == selectionData else { throw ProfileStoreError.plaintextMigrationValidationFailed }
        for profile in profiles {
            _ = try decrypt(Data(contentsOf: root.appending(path: "\(profile.id.uuidString)/config.json")), kind: .currentConfiguration, logicalPath: "\(profile.id.uuidString)/config.json")
            for revision in 1...max(profile.validRevision, 1) {
                _ = try decrypt(Data(contentsOf: root.appending(path: "\(profile.id.uuidString)/versions/\(revision).json")), kind: .version, logicalPath: "\(profile.id.uuidString)/versions/\(revision).json")
            }
        }
    }

    private func removeLegacyPendingFiles() throws {
        for profileDirectory in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) where UUID(uuidString: profileDirectory.lastPathComponent) != nil {
            let pending = profileDirectory.appending(path: ".pending-check.json")
            if fileManager.fileExists(atPath: pending.path) { try fileManager.removeItem(at: pending) }
        }
    }

    private func checkFault(_ point: ProfileStorageFaultPoint, as error: ProfileStoreError) throws {
        do { try faults.check(point) }
        catch { throw error }
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
            let marker = root.appending(path: Self.markerName)
            guard fileManager.fileExists(atPath: marker.path) else { throw ProfileStoreError.mixedOrDowngradedStorage }
            do {
                if stagingExists { try fileManager.removeItem(at: staging) }
                try fileManager.removeItem(at: backup)
            } catch { throw ProfileStoreError.plaintextMigrationRecoveryFailed }
        }
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

    init(profileRoot: URL, fileManager: FileManager = .default) {
        directory = profileRoot.deletingLastPathComponent().appending(path: ".TargetProfileValidation", directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    func prepare() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("validation-") {
            try? fileManager.removeItem(at: url)
        }
    }

    func withTemporaryConfiguration<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        try prepare()
        let file = directory.appending(path: "validation-\(UUID().uuidString).json")
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? fileManager.removeItem(at: file) }
        return try body(file)
    }

    var managedDirectory: URL { directory }
}
