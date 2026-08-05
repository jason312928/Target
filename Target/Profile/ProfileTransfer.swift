import Darwin
import Foundation

/// The only supported interchange format is one raw sing-box JSON document. This
/// boundary intentionally never serializes Target metadata or logs external paths.
struct ProfileImportCandidate: Sendable {
    let data: Data
    let suggestedName: String
    let fileSize: Int
    let validation: ProfileValidation
}

enum ProfileTransferError: LocalizedError, Equatable {
    case unreadableImport
    case importTooLarge
    case importInvalidUTF8
    case importInvalidJSON
    case importValidationFailed
    case unsafeExportDestination
    case exportFailed
    case exportCleanupFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImport: "The selected file could not be imported safely."
        case .importTooLarge: "The selected file is too large to import."
        case .importInvalidUTF8, .importInvalidJSON, .importValidationFailed:
            "The selected configuration could not be validated."
        case .unsafeExportDestination, .exportFailed, .exportCleanupFailed:
            "The configuration could not be exported safely."
        }
    }
}

enum ProfileTransferFaultPoint: Sendable, Hashable {
    case importDirectoryCreation
    case importCurrentConfigurationWrite
    case importRevisionWrite
    case importManifestWrite
    case importSelectionWrite
    case importRollbackCleanup
    case importAfterDirectoryMove
    case importAfterManifestCommit
    case importAfterSelectionCommit
    case exportAfterDirectoryOpen
    case exportAfterTemporaryCreate
    case exportAfterWrite
    case exportAfterPermissionValidation
    case exportAfterFileSync
    case exportBeforeCommit
}

protocol ProfileTransferFaultInjecting {
    func check(_ point: ProfileTransferFaultPoint) throws
}

struct NoProfileTransferFaults: ProfileTransferFaultInjecting {
    func check(_ point: ProfileTransferFaultPoint) throws {}
}

enum ProfileExportDestinationKind {
    case missing
    case regularFile
    case unsafe
}

protocol ProfileExportFileOperating {
    func openDirectory(atPath path: String) throws -> Int32
    func createExclusiveFile(named name: String, in directoryDescriptor: Int32) throws -> Int32
    func write(_ data: Data, to descriptor: Int32) throws
    func setOwnerOnlyPermissions(on descriptor: Int32) throws
    func verifyOwnerOnlyRegularFile(_ descriptor: Int32) throws
    func truncateAndVerifyEmpty(_ descriptor: Int32) throws
    func synchronize(_ descriptor: Int32) throws
    func destinationKind(named name: String, in directoryDescriptor: Int32) throws -> ProfileExportDestinationKind
    func rename(_ sourceName: String, to destinationName: String, in directoryDescriptor: Int32) throws
    func remove(named name: String, in directoryDescriptor: Int32) throws
    func close(_ descriptor: Int32) throws
}

struct ProfileExportFileOperations: ProfileExportFileOperating {
    func openDirectory(atPath path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProfileTransferError.unsafeExportDestination }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw ProfileTransferError.unsafeExportDestination
        }
        return descriptor
    }

    func createExclusiveFile(named name: String, in directoryDescriptor: Int32) throws -> Int32 {
        let descriptor = Darwin.openat(
            directoryDescriptor, name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ProfileTransferError.exportFailed }
        return descriptor
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                guard written > 0 else { throw ProfileTransferError.exportFailed }
                remaining -= Int(written)
                address = address.advanced(by: Int(written))
            }
        }
    }

    func setOwnerOnlyPermissions(on descriptor: Int32) throws {
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw ProfileTransferError.exportFailed }
    }

    func verifyOwnerOnlyRegularFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_mode & 0o777) == 0o600 else {
            throw ProfileTransferError.exportFailed
        }
    }

    func truncateAndVerifyEmpty(_ descriptor: Int32) throws {
        while Darwin.ftruncate(descriptor, 0) != 0 {
            guard errno == EINTR else { throw ProfileTransferError.exportCleanupFailed }
        }
        var metadata = stat()
        while Darwin.fstat(descriptor, &metadata) != 0 {
            guard errno == EINTR else { throw ProfileTransferError.exportCleanupFailed }
        }
        guard metadata.st_size == 0 else { throw ProfileTransferError.exportCleanupFailed }
    }

    func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else { throw ProfileTransferError.exportFailed }
        }
    }

    func destinationKind(named name: String, in directoryDescriptor: Int32) throws -> ProfileExportDestinationKind {
        var metadata = stat()
        if Darwin.fstatat(directoryDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return (metadata.st_mode & S_IFMT) == S_IFREG ? .regularFile : .unsafe
        }
        guard errno == ENOENT else { throw ProfileTransferError.exportFailed }
        return .missing
    }

    func rename(_ sourceName: String, to destinationName: String, in directoryDescriptor: Int32) throws {
        guard Darwin.renameat(directoryDescriptor, sourceName, directoryDescriptor, destinationName) == 0 else {
            throw ProfileTransferError.exportFailed
        }
    }

    func remove(named name: String, in directoryDescriptor: Int32) throws {
        while Darwin.unlinkat(directoryDescriptor, name, 0) != 0 {
            guard errno == EINTR else {
                if errno == ENOENT { return }
                throw ProfileTransferError.exportCleanupFailed
            }
        }
    }

    func close(_ descriptor: Int32) throws {
        while Darwin.close(descriptor) != 0 {
            guard errno == EINTR else { throw ProfileTransferError.exportCleanupFailed }
        }
    }
}

final class ProfileTransferService {
    /// A single Profile is intentionally bounded so user-selected input is never
    /// read without a known limit. Ten MiB accommodates ordinary sing-box files.
    static let maximumImportBytes = 10 * 1024 * 1024

    private let checker: any SingBoxConfigurationChecking
    private let validationStorage: ProfileValidationTemporaryStorage
    private let faults: any ProfileTransferFaultInjecting
    private let exportFileOperations: any ProfileExportFileOperating

    init(
        profileRoot: URL,
        checker: any SingBoxConfigurationChecking,
        fileManager: FileManager = .default,
        faults: any ProfileTransferFaultInjecting = NoProfileTransferFaults(),
        exportFileOperations: any ProfileExportFileOperating = ProfileExportFileOperations()
    ) {
        self.checker = checker
        validationStorage = ProfileValidationTemporaryStorage(profileRoot: profileRoot, fileManager: fileManager)
        self.faults = faults
        self.exportFileOperations = exportFileOperations
    }

    func prepareImport(from url: URL) throws -> ProfileImportCandidate {
        let didAccessScope = url.startAccessingSecurityScopedResource()
        defer { if didAccessScope { url.stopAccessingSecurityScopedResource() } }
        let data = try readRegularFileWithoutFollowingSymlink(at: url)
        return try prepareImport(data: data, suggestedName: suggestedName(for: url))
    }

    func prepareImport(data: Data, suggestedName: String) throws -> ProfileImportCandidate {
        guard data.count <= Self.maximumImportBytes else { throw ProfileTransferError.importTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ProfileTransferError.importInvalidUTF8 }
        guard JSONSyntaxChecker.validate(text) == nil else { throw ProfileTransferError.importInvalidJSON }
        let result = try validationStorage.withTemporaryConfiguration(data) { checker.check(configurationURL: $0) }
        guard case .success = result else { throw ProfileTransferError.importValidationFailed }
        return ProfileImportCandidate(
            data: data,
            suggestedName: safeSuggestedName(suggestedName),
            fileSize: data.count,
            validation: ProfileValidation(status: .valid, checkedAt: Date(), error: nil)
        )
    }

    func writeExport(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent().standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != ".." else {
            throw ProfileTransferError.unsafeExportDestination
        }
        var directoryDescriptor = try exportFileOperations.openDirectory(atPath: directory.path)
        let temporaryName = ".target-profile-export-\(UUID().uuidString)"
        var fileDescriptor: Int32 = -1
        var temporaryExists = false
        var renamed = false

        do {
            try checkExportFault(.exportAfterDirectoryOpen)
            fileDescriptor = try exportFileOperations.createExclusiveFile(named: temporaryName, in: directoryDescriptor)
            temporaryExists = true
            try exportFileOperations.setOwnerOnlyPermissions(on: fileDescriptor)
            try exportFileOperations.verifyOwnerOnlyRegularFile(fileDescriptor)
            try checkExportFault(.exportAfterTemporaryCreate)
            try exportFileOperations.write(data, to: fileDescriptor)
            try checkExportFault(.exportAfterWrite)
            try checkExportFault(.exportAfterPermissionValidation)
            try exportFileOperations.synchronize(fileDescriptor)
            try checkExportFault(.exportAfterFileSync)
            try checkExportFault(.exportBeforeCommit)
            guard try exportFileOperations.destinationKind(named: destinationName, in: directoryDescriptor) != .unsafe else {
                throw ProfileTransferError.unsafeExportDestination
            }
            try exportFileOperations.rename(temporaryName, to: destinationName, in: directoryDescriptor)
            temporaryExists = false
            renamed = true
            try exportFileOperations.synchronize(directoryDescriptor)
            try exportFileOperations.close(fileDescriptor)
            fileDescriptor = -1
            try exportFileOperations.close(directoryDescriptor)
            directoryDescriptor = -1
        } catch {
            let originalError = normalizedExportError(error)
            var cleanupFailed = false
            if !renamed, temporaryExists {
                do {
                    try cleanFailedExport(
                        temporaryName: temporaryName,
                        fileDescriptor: &fileDescriptor,
                        directoryDescriptor: directoryDescriptor
                    )
                    temporaryExists = false
                } catch {
                    cleanupFailed = true
                }
            } else if fileDescriptor >= 0 {
                do { try closeWithRetry(&fileDescriptor) }
                catch { cleanupFailed = true }
            }
            if directoryDescriptor >= 0 {
                do { try closeWithRetry(&directoryDescriptor) }
                catch { cleanupFailed = true }
            }
            if cleanupFailed { throw ProfileTransferError.exportCleanupFailed }
            throw originalError
        }
    }

    private func cleanFailedExport(
        temporaryName: String,
        fileDescriptor: inout Int32,
        directoryDescriptor: Int32
    ) throws {
        var contentWasVerifiedEmpty = false
        var cleanupPreparationFailed = false
        if fileDescriptor >= 0 {
            do {
                try exportFileOperations.truncateAndVerifyEmpty(fileDescriptor)
                contentWasVerifiedEmpty = true
                try exportFileOperations.setOwnerOnlyPermissions(on: fileDescriptor)
                try exportFileOperations.verifyOwnerOnlyRegularFile(fileDescriptor)
                try exportFileOperations.synchronize(fileDescriptor)
            } catch {
                cleanupPreparationFailed = true
            }
            do { try closeWithRetry(&fileDescriptor) }
            catch {
                cleanupPreparationFailed = true
            }
        }

        var temporaryWasRemoved = false
        for _ in 0..<3 {
            do {
                try exportFileOperations.remove(named: temporaryName, in: directoryDescriptor)
                temporaryWasRemoved = true
                break
            } catch {}
        }

        // A failed truncate or zero-length verification never skips descriptor-relative
        // removal. When removal also fails, a verified-empty residue is bounded to the
        // prior 0600 check; an unverified residue has no de-sensitization guarantee.
        if !temporaryWasRemoved && !contentWasVerifiedEmpty {
            throw ProfileTransferError.exportCleanupFailed
        }
        guard temporaryWasRemoved else { throw ProfileTransferError.exportCleanupFailed }
        if cleanupPreparationFailed { throw ProfileTransferError.exportCleanupFailed }
    }

    private func closeWithRetry(_ descriptor: inout Int32) throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try exportFileOperations.close(descriptor)
                descriptor = -1
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProfileTransferError.exportCleanupFailed
    }

    private func normalizedExportError(_ error: Error) -> ProfileTransferError {
        error as? ProfileTransferError ?? .exportFailed
    }

    static func defaultExportFileName(for profileName: String) -> String {
        let filtered = String(profileName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":"
        })
        let trimming = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let base = filtered.trimmingCharacters(in: trimming)
        let safe = base.isEmpty ? "Profile" : String(base.prefix(80))
        return "\(safe).json"
    }

    private func suggestedName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return safeSuggestedName(name)
    }

    private func safeSuggestedName(_ name: String) -> String {
        let filtered = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let normalized = filtered.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return normalized.isEmpty ? "Imported Profile" : String(normalized.prefix(80))
    }

    private func readRegularFileWithoutFollowingSymlink(at url: URL) throws -> Data {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw ProfileTransferError.unreadableImport
        }
        guard metadata.st_size <= off_t(Self.maximumImportBytes) else { throw ProfileTransferError.importTooLarge }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProfileTransferError.unreadableImport }
        defer { _ = Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= off_t(Self.maximumImportBytes) else {
            throw ProfileTransferError.unreadableImport
        }

        var result = Data()
        result.reserveCapacity(Int(openedMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, Self.maximumImportBytes + 1))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { throw ProfileTransferError.unreadableImport }
            if count == 0 { break }
            let nextCount = result.count + Int(count)
            guard nextCount <= Self.maximumImportBytes else { throw ProfileTransferError.importTooLarge }
            result.append(buffer, count: Int(count))
        }
        return result
    }

    private func checkExportFault(_ point: ProfileTransferFaultPoint) throws {
        do { try faults.check(point) }
        catch { throw ProfileTransferError.exportFailed }
    }
}
