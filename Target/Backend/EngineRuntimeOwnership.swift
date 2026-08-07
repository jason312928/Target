import Darwin
import Foundation
import Network
import CryptoKit

protocol ProfileRuntimeUsageChecking: Sendable {
    func isProfileInUse(_ id: UUID) -> Bool
}

struct LocalEngineEndpoint: Codable, Equatable, Sendable {
    static let host = "127.0.0.1"
    static let minimumDynamicPort: UInt16 = 49_152

    let port: UInt16

    var isDynamicHighPort: Bool { port >= Self.minimumDynamicPort }
}

struct EngineRuntimeRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let executablePath: String
    let executableFingerprint: String
    let endpoint: LocalEngineEndpoint
    let profileID: UUID
    let profileRevision: Int
    let sourceConfigurationFingerprint: String
    let configurationFingerprint: String
    let startedAt: Date
    let runtimeConfigurationID: UUID

    var isValid: Bool {
        pid > 0 && endpoint.isDynamicHighPort && !executablePath.isEmpty
            && !executableFingerprint.isEmpty && profileRevision > 0
            && !sourceConfigurationFingerprint.isEmpty && !configurationFingerprint.isEmpty
    }
}

enum EngineRuntimeRecordDisposition: Sendable {
    case noRecord
    case ownedRunning(EngineRuntimeRecord)
    case processExited(EngineRuntimeRecord)
    case liveUnproven(EngineRuntimeRecord)
}

protocol EngineRuntimeStoring: Sendable {
    func load() throws -> EngineRuntimeRecord?
    func save(_ record: EngineRuntimeRecord) throws
    func clear() throws
}

enum UserEngineRuntimeStoreError: Error {
    case invalidUser
    case unsafePath
    case unsupportedMutation
}

/// Root-side, read-only view of one authenticated XPC user's fixed Target runtime.
/// No path, PID, port, or executable location is accepted from the caller.
final class UserEngineRuntimeStore: EngineRuntimeStoring, @unchecked Sendable {
    static let maximumRecordSize: off_t = 64 * 1_024

    private let uid: uid_t
    private let homeDirectory: URL
    private let runtimeDirectory: URL
    private let recordURL: URL
    private let executableURL: URL

    convenience init?(uid: uid_t) {
        guard uid != 0, let home = Self.homeDirectory(for: uid) else { return nil }
        self.init(uid: uid, homeDirectory: home)
    }

    init(uid: uid_t, homeDirectory: URL) {
        self.uid = uid
        self.homeDirectory = homeDirectory
        runtimeDirectory = homeDirectory
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Target", directoryHint: .isDirectory)
            .appending(path: "sing-box", directoryHint: .isDirectory)
        recordURL = runtimeDirectory.appending(path: "runtime.json")
        executableURL = runtimeDirectory.appending(path: "bin/sing-box")
    }

    func load() throws -> EngineRuntimeRecord? {
        let runtimeDescriptor = try openRuntimeDirectory()
        defer { close(runtimeDescriptor) }
        let descriptor = openat(runtimeDescriptor, "runtime.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw UserEngineRuntimeStoreError.unsafePath }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == uid,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumRecordSize else {
            throw UserEngineRuntimeStoreError.unsafePath
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
        guard let data, data.count <= Self.maximumRecordSize else {
            throw UserEngineRuntimeStoreError.unsafePath
        }
        let record = try JSONDecoder().decode(EngineRuntimeRecord.self, from: data)
        guard record.executablePath == executableURL.path else {
            throw UserEngineRuntimeStoreError.unsafePath
        }
        let binDescriptor = try openOwnedDirectory(named: "bin", relativeTo: runtimeDescriptor)
        defer { close(binDescriptor) }
        let executableDescriptor = openat(binDescriptor, "sing-box", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard executableDescriptor >= 0 else { throw UserEngineRuntimeStoreError.unsafePath }
        defer { close(executableDescriptor) }
        var executable = stat()
        guard fstat(executableDescriptor, &executable) == 0,
              executable.st_uid == uid,
              executable.st_mode & S_IFMT == S_IFREG,
              executable.st_mode & 0o022 == 0 else {
            throw UserEngineRuntimeStoreError.unsafePath
        }
        return record
    }

    func save(_ record: EngineRuntimeRecord) throws {
        throw UserEngineRuntimeStoreError.unsupportedMutation
    }

    func clear() throws {
        throw UserEngineRuntimeStoreError.unsupportedMutation
    }

    private func openRuntimeDirectory() throws -> Int32 {
        var descriptor = open(homeDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UserEngineRuntimeStoreError.unsafePath }
        do {
            try validateOwnedDirectory(descriptor)
            for component in ["Library", "Application Support", "Target", "sing-box"] {
                let next = try openOwnedDirectory(named: component, relativeTo: descriptor)
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openOwnedDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UserEngineRuntimeStoreError.unsafePath }
        do {
            try validateOwnedDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateOwnedDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == uid,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o022 == 0 else {
            throw UserEngineRuntimeStoreError.unsafePath
        }
    }

    private static func homeDirectory(for uid: uid_t) -> URL? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: Int(sysconf(_SC_GETPW_R_SIZE_MAX) > 0 ? sysconf(_SC_GETPW_R_SIZE_MAX) : 16_384))
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0,
              result != nil,
              let home = entry.pw_dir else { return nil }
        let path = String(cString: home)
        guard path.hasPrefix("/Users/"), !path.contains("/../") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

final class FileEngineRuntimeStore: EngineRuntimeStoring, @unchecked Sendable {
    private let fileURL: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Target/sing-box", directoryHint: .isDirectory)) {
        self.fileURL = directory.appending(path: "runtime.json")
    }

    func load() throws -> EngineRuntimeRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(EngineRuntimeRecord.self, from: Data(contentsOf: fileURL))
    }

    func save(_ record: EngineRuntimeRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

protocol EngineProcessInspecting: Sendable {
    func matches(pid: Int32, executablePath: String) -> Bool
}

struct DarwinEngineProcessInspector: EngineProcessInspecting {
    func matches(pid: Int32, executablePath: String) -> Bool {
        guard pid > 0, kill(pid_t(pid), 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return false }
        let actual = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        return actual == expected
    }
}

protocol LocalEnginePortProbing: Sendable {
    func isListening(on port: UInt16) async -> Bool
}

struct LocalTCPPortProbe: LocalEnginePortProbing {
    func isListening(on port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(LocalEngineEndpoint.host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let completion = EnginePortProbeCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                    connection.cancel()
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                completion.finish(false)
                connection.cancel()
            }
        }
    }
}

protocol LocalEnginePortSelecting: Sendable {
    func selectAvailablePort() throws -> UInt16
}

struct DynamicHighLocalPortSelector: LocalEnginePortSelecting {
    func selectAvailablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BackendError.engineLaunchFailed }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw BackendError.engineLaunchFailed }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = UInt16(bigEndian: assigned.sin_port)
        guard nameResult == 0, port >= LocalEngineEndpoint.minimumDynamicPort else {
            throw BackendError.engineLaunchFailed
        }
        return port
    }
}

private final class EnginePortProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

final class EngineRuntimeOwnership: @unchecked Sendable {
    private let store: any EngineRuntimeStoring
    private let processInspector: any EngineProcessInspecting
    private let portProbe: any LocalEnginePortProbing

    init(
        store: any EngineRuntimeStoring = FileEngineRuntimeStore(),
        processInspector: any EngineProcessInspecting = DarwinEngineProcessInspector(),
        portProbe: any LocalEnginePortProbing = LocalTCPPortProbe()
    ) {
        self.store = store
        self.processInspector = processInspector
        self.portProbe = portProbe
    }

    func recordDisposition() async throws -> EngineRuntimeRecordDisposition {
        guard let record = try store.load() else { return .noRecord }
        guard processExists(record.pid) else { return .processExited(record) }
        guard record.isValid,
              processInspector.matches(pid: record.pid, executablePath: record.executablePath),
              executableFingerprintMatches(record),
              await portProbe.isListening(on: record.endpoint.port) else {
            return .liveUnproven(record)
        }
        return .ownedRunning(record)
    }

    func ownedRecord() async -> EngineRuntimeRecord? {
        guard case let .ownedRunning(record)? = try? await recordDisposition() else { return nil }
        return record
    }

    func ownedEndpoint() async -> LocalEngineEndpoint? { await ownedRecord()?.endpoint }

    func ownsProcess(_ record: EngineRuntimeRecord) -> Bool {
        record.isValid && processInspector.matches(pid: record.pid, executablePath: record.executablePath)
            && executableFingerprintMatches(record)
    }

    func recordLaunchedProcess(
        pid: Int32,
        executableURL: URL,
        port: UInt16,
        profileID: UUID,
        profileRevision: Int,
        sourceConfigurationFingerprint: String,
        configurationFingerprint: String,
        runtimeConfigurationID: UUID
    ) throws {
        let resolvedExecutable = executableURL.resolvingSymlinksInPath()
        let record = EngineRuntimeRecord(
            pid: pid,
            executablePath: resolvedExecutable.path,
            executableFingerprint: try EngineExecutableFingerprint.sha256(of: resolvedExecutable),
            endpoint: LocalEngineEndpoint(port: port),
            profileID: profileID,
            profileRevision: profileRevision,
            sourceConfigurationFingerprint: sourceConfigurationFingerprint,
            configurationFingerprint: configurationFingerprint,
            startedAt: Date(),
            runtimeConfigurationID: runtimeConfigurationID
        )
        guard record.isValid else { throw BackendError.engineLaunchFailed }
        try store.save(record)
    }

    func currentRecord() -> EngineRuntimeRecord? { try? store.load() }
    func clearRecord() { try? store.clear() }

    /// A record is only removable after its recorded PID is confirmed gone.
    /// Live records remain recovery evidence even when ownership proof fails.
    func discardExitedRecord(_ record: EngineRuntimeRecord) -> Bool {
        guard !processExists(record.pid) else { return false }
        do {
            try store.clear()
            return true
        } catch {
            return false
        }
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func executableFingerprintMatches(_ record: EngineRuntimeRecord) -> Bool {
        guard let fingerprint = try? EngineExecutableFingerprint.sha256(of: URL(fileURLWithPath: record.executablePath)) else { return false }
        return fingerprint == record.executableFingerprint
    }
}

extension EngineRuntimeOwnership: ProfileRuntimeUsageChecking {
    func isProfileInUse(_ id: UUID) -> Bool {
        guard let record = currentRecord(), record.profileID == id else { return false }
        return ownsProcess(record)
    }
}

enum EngineExecutableFingerprint {
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct TargetOwnedPortProbe: LocalProxyProbing {
    private let runtimeOwnership: EngineRuntimeOwnership

    init(runtimeOwnership: EngineRuntimeOwnership = EngineRuntimeOwnership()) {
        self.runtimeOwnership = runtimeOwnership
    }

    func isAvailable() async -> Bool {
        await runtimeOwnership.ownedEndpoint() != nil
    }
}
