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

    var errorDescription: String? {
        switch self {
        case .unreadableImport: "The selected file could not be imported safely."
        case .importTooLarge: "The selected file is too large to import."
        case .importInvalidUTF8, .importInvalidJSON, .importValidationFailed:
            "The selected configuration could not be validated."
        case .unsafeExportDestination, .exportFailed:
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
    case exportBeforeCommit
}

protocol ProfileTransferFaultInjecting {
    func check(_ point: ProfileTransferFaultPoint) throws
}

struct NoProfileTransferFaults: ProfileTransferFaultInjecting {
    func check(_ point: ProfileTransferFaultPoint) throws {}
}

final class ProfileTransferService {
    /// A single Profile is intentionally bounded so user-selected input is never
    /// read without a known limit. Ten MiB accommodates ordinary sing-box files.
    static let maximumImportBytes = 10 * 1024 * 1024

    private let checker: any SingBoxConfigurationChecking
    private let validationStorage: ProfileValidationTemporaryStorage
    private let fileManager: FileManager
    private let faults: any ProfileTransferFaultInjecting

    init(
        profileRoot: URL,
        checker: any SingBoxConfigurationChecking,
        fileManager: FileManager = .default,
        faults: any ProfileTransferFaultInjecting = NoProfileTransferFaults()
    ) {
        self.checker = checker
        validationStorage = ProfileValidationTemporaryStorage(profileRoot: profileRoot, fileManager: fileManager)
        self.fileManager = fileManager
        self.faults = faults
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
        guard isDirectory(directory), !isSymlink(destination), !isDirectory(destination) else {
            throw ProfileTransferError.unsafeExportDestination
        }

        let temporary = directory.appending(path: ".target-profile-export-\(UUID().uuidString)")
        var fileDescriptor: Int32 = -1
        var temporaryCreated = false
        defer {
            if fileDescriptor >= 0 { _ = Darwin.close(fileDescriptor) }
            if temporaryCreated { try? fileManager.removeItem(at: temporary) }
        }

        fileDescriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fileDescriptor >= 0 else { throw ProfileTransferError.exportFailed }
        temporaryCreated = true
        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else { throw ProfileTransferError.exportFailed }
        try writeAll(data, to: fileDescriptor)
        guard Darwin.fsync(fileDescriptor) == 0 else { throw ProfileTransferError.exportFailed }
        guard Darwin.close(fileDescriptor) == 0 else { throw ProfileTransferError.exportFailed }
        fileDescriptor = -1

        do {
            try faults.check(.exportBeforeCommit)
        } catch {
            throw ProfileTransferError.exportFailed
        }
        guard !isSymlink(destination), !isDirectory(destination) else { throw ProfileTransferError.unsafeExportDestination }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw ProfileTransferError.exportFailed }
        temporaryCreated = false
        try setOwnerOnlyPermissions(destination)
        try synchronizeDirectory(directory)
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

    private func isDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return Darwin.lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private func isSymlink(_ url: URL) -> Bool {
        var metadata = stat()
        return Darwin.lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
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

    private func setOwnerOnlyPermissions(_ url: URL) throws {
        guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else { throw ProfileTransferError.exportFailed }
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0, (metadata.st_mode & 0o777) == 0o600 else {
            throw ProfileTransferError.exportFailed
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw ProfileTransferError.exportFailed }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ProfileTransferError.exportFailed }
    }
}
