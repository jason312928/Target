import CryptoKit
import Darwin
import Foundation

/// One serialization boundary per canonical store, shared by the UI, backend,
/// automation and any second ProfileStore instance in this process.
final class ProfileStorageCoordinator: @unchecked Sendable {
    private static let registryLock = NSLock()
    private final class WeakEntry {
        weak var value: ProfileStorageCoordinator?
        init(_ value: ProfileStorageCoordinator) { self.value = value }
    }
    private static var registry: [String: WeakEntry] = [:]
    let lock = NSRecursiveLock()
    var mutationDepth = 0

    static func shared(for root: URL) -> ProfileStorageCoordinator {
        registryLock.lock()
        defer { registryLock.unlock() }
        let path = canonicalPath(for: root)
        if let existing = registry[path]?.value { return existing }
        registry = registry.filter { $0.value.value != nil }
        let coordinator = ProfileStorageCoordinator()
        registry[path] = WeakEntry(coordinator)
        return coordinator
    }

    static func canonicalPath(for root: URL) -> String {
        // Foundation preserves common aliases such as /tmp on some systems.
        // Resolve existing ancestors through realpath, including a new store.
        var ancestor = root.standardizedFileURL
        var suffix: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return suffix.reversed().reduce(String(cString: resolved)) { $0 + "/" + $1 }
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return root.standardizedFileURL.path }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum ProfileMutationInterruption: Error { case simulated }

/// Encrypted undo snapshot for multi-record mutations. The immutable snapshot
/// survives every rollback step; recovery can therefore restart after a crash.
/// A sealed commit receipt distinguishes committed changes from interrupted ones.
final class ProfileMutationTransaction {
    private struct Receipt: Codable {
        var version = 1
        let snapshotFingerprint: String
        var committed = false
    }

    private let root: URL
    private let storage: ProfileEncryptedStorage
    private let keyProvider: any ProfileEncryptionKeyProviding
    private let fileManager: FileManager
    private let faults: any ProfileStorageFaultInjecting
    private var directory: URL { root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).mutation") }
    private var backup: URL { directory.appending(path: "backup") }
    private var receiptURL: URL { directory.appending(path: "receipt.envelope") }
    private var receiptBinding: String { "mutation|\(ProfileStorageCoordinator.canonicalPath(for: root))" }

    init(
        root: URL, storage: ProfileEncryptedStorage, keyProvider: any ProfileEncryptionKeyProviding,
        fileManager: FileManager, faults: any ProfileStorageFaultInjecting
    ) {
        self.root = root
        self.storage = storage
        self.keyProvider = keyProvider
        self.fileManager = fileManager
        self.faults = faults
    }

    func begin() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { throw ProfileStoreError.profileMutationRecoveryFailed }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.copyItem(at: root, to: backup)
            try snapshotStorage(at: backup).authenticateExistingTree()
            try synchronizeTree(backup)
            try synchronizeDirectory(directory.deletingLastPathComponent())
            try writeReceipt(Receipt(snapshotFingerprint: fingerprint(backup)))
            try faults.check(.mutationAfterSnapshot)
        } catch is ProfileMutationInterruption {
            throw ProfileMutationInterruption.simulated
        } catch {
            // No product write has begun before begin returns.
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func commit() throws {
        try faults.check(.mutationBeforeCommit)
        try storage.authenticateExistingTree()
        var receipt = try readReceipt()
        receipt.committed = true
        try writeReceipt(receipt)
        try faults.check(.mutationAfterCommit)
        // A cleanup failure is retryable; never roll back a sealed commit.
        try? fileManager.removeItem(at: directory)
    }

    func recover() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try requireOwnedDirectory(directory)
            guard fileManager.fileExists(atPath: receiptURL.path) else {
                // Interrupted snapshot preparation precedes all product writes.
                try fileManager.removeItem(at: directory)
                return
            }
            let receipt = try readReceipt()
            guard receipt.version == 1 else { throw ProfileStoreError.profileMutationRecoveryFailed }
            if receipt.committed {
                try storage.authenticateExistingTree()
            } else {
                guard try fingerprint(backup) == receipt.snapshotFingerprint else {
                    throw ProfileStoreError.profileMutationRecoveryFailed
                }
                try snapshotStorage(at: backup).authenticateExistingTree()
                let restored = directory.appending(path: "restored")
                if fileManager.fileExists(atPath: restored.path) { try fileManager.removeItem(at: restored) }
                try fileManager.copyItem(at: backup, to: restored)
                try snapshotStorage(at: restored).authenticateExistingTree()
                if fileManager.fileExists(atPath: root.path) {
                    try requireOwnedDirectory(root)
                    try fileManager.removeItem(at: root)
                }
                try fileManager.moveItem(at: restored, to: root)
                try synchronizeDirectory(root.deletingLastPathComponent())
                try storage.authenticateExistingTree()
            }
            try fileManager.removeItem(at: directory)
        } catch {
            throw ProfileStoreError.profileMutationRecoveryFailed
        }
    }

    private func snapshotStorage(at url: URL) -> ProfileEncryptedStorage {
        ProfileEncryptedStorage(root: url, fileManager: fileManager, keyProvider: keyProvider)
    }

    private func readReceipt() throws -> Receipt {
        try JSONDecoder().decode(
            Receipt.self,
            from: storage.readRecoveryRecord(
                kind: .transaction, logicalPath: receiptBinding, url: receiptURL
            ))
    }

    private func writeReceipt(_ receipt: Receipt) throws {
        try storage.write(JSONEncoder().encode(receipt), kind: .transaction, logicalPath: receiptBinding, url: receiptURL)
        let descriptor = Darwin.open(receiptURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
    }

    private func requireOwnedDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
            info.st_mode & 0o077 == 0
        else { throw ProfileStoreError.profileMutationRecoveryFailed }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(ProfileStorageCoordinator.canonicalPath(for: url), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
    }

    private func synchronizeTree(_ url: URL) throws {
        for relative in try fileManager.subpathsOfDirectory(atPath: url.path) {
            let child = url.appending(path: relative)
            var info = stat()
            guard lstat(child.path, &info) == 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
            if info.st_mode & S_IFMT == S_IFREG {
                let descriptor = Darwin.open(child.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
                defer { _ = Darwin.close(descriptor) }
                guard Darwin.fsync(descriptor) == 0 else { throw ProfileStoreError.profileMutationTransactionFailed }
            } else if info.st_mode & S_IFMT == S_IFDIR {
                try synchronizeDirectory(child)
            }
        }
        try synchronizeDirectory(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func fingerprint(_ directory: URL) throws -> String {
        try requireOwnedDirectory(directory)
        var hash = SHA256()
        for relative in try fileManager.subpathsOfDirectory(atPath: directory.path).sorted() {
            let url = directory.appending(path: relative)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw ProfileStoreError.profileMutationRecoveryFailed
            }
            hash.update(data: Data(relative.utf8) + Data([0]))
            switch info.st_mode & S_IFMT {
            case S_IFDIR: hash.update(data: Data([1]))
            case S_IFREG:
                hash.update(data: Data([2]))
                hash.update(data: try Data(contentsOf: url))
            default: throw ProfileStoreError.profileMutationRecoveryFailed
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
