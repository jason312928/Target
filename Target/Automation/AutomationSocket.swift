import Darwin
import Foundation

enum AutomationSocketError: Error, Equatable {
    case unsafePath
    case pathTooLong
    case unavailable
    case peerRejected
    case requestTooLarge
}

enum AutomationSocketPath {
    static let directoryName = "Automation"
    static let socketName = "control.sock"

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: socketName)
    }

    static func prepareServerURL(_ socketURL: URL, fileManager: FileManager = .default) throws {
        let directory = socketURL.deletingLastPathComponent().standardizedFileURL
        guard socketURL.standardizedFileURL.deletingLastPathComponent() == directory else {
            throw AutomationSocketError.unsafePath
        }
        try ensurePrivateDirectory(directory, fileManager: fileManager)
        guard socketURL.path.utf8CString.count <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
            throw AutomationSocketError.pathTooLong
        }
        var metadata = stat()
        if lstat(socketURL.path, &metadata) == 0 {
            guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFSOCK else {
                throw AutomationSocketError.unsafePath
            }
            guard !isReachable(socketURL) else { throw AutomationSocketError.unavailable }
            guard unlink(socketURL.path) == 0 else { throw AutomationSocketError.unavailable }
        } else if errno != ENOENT {
            throw AutomationSocketError.unsafePath
        }
    }

    static func validateClientURL(_ socketURL: URL) throws {
        let directory = socketURL.deletingLastPathComponent()
        var directoryMetadata = stat()
        guard lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_mode & 0o077 == 0 else {
            throw AutomationSocketError.unsafePath
        }
        var socketMetadata = stat()
        guard lstat(socketURL.path, &socketMetadata) == 0,
              socketMetadata.st_uid == geteuid(),
              socketMetadata.st_mode & S_IFMT == S_IFSOCK,
              socketMetadata.st_mode & 0o077 == 0 else {
            throw AutomationSocketError.unsafePath
        }
    }

    private static func ensurePrivateDirectory(_ directory: URL, fileManager: FileManager) throws {
        let parent = directory.deletingLastPathComponent()
        var parentMetadata = stat()
        if lstat(parent.path, &parentMetadata) == 0 {
            guard parentMetadata.st_uid == geteuid(), parentMetadata.st_mode & S_IFMT == S_IFDIR else {
                throw AutomationSocketError.unsafePath
            }
        } else if errno == ENOENT {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            throw AutomationSocketError.unsafePath
        }

        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFDIR else {
                throw AutomationSocketError.unsafePath
            }
        } else if errno == ENOENT {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } else {
            throw AutomationSocketError.unsafePath
        }
        guard chmod(directory.path, mode_t(0o700)) == 0 else { throw AutomationSocketError.unsafePath }
    }

    private static func isReachable(_ socketURL: URL) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        guard var address = try? makeUnixAddress(path: socketURL.path) else { return true }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, unixAddressLength(path: socketURL.path)) == 0
            }
        }
    }
}

final class LocalAutomationServer: @unchecked Sendable {
    typealias Handler = @Sendable (AutomationRequest) async -> AutomationResponse

    private let socketURL: URL
    private let expectedUID: uid_t
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.jason312928.Target.automation")
    private var listeningDescriptor: Int32 = -1

    init(socketURL: URL = AutomationSocketPath.defaultURL(), expectedUID: uid_t = geteuid(), handler: @escaping Handler) {
        self.socketURL = socketURL
        self.expectedUID = expectedUID
        self.handler = handler
    }

    func start() throws {
        guard listeningDescriptor < 0 else { return }
        try AutomationSocketPath.prepareServerURL(socketURL)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AutomationSocketError.unavailable }
        do {
            var address = try makeUnixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, unixAddressLength(path: socketURL.path))
                }
            }
            guard result == 0, chmod(socketURL.path, mode_t(0o600)) == 0, listen(descriptor, 4) == 0 else {
                throw AutomationSocketError.unavailable
            }
        } catch {
            close(descriptor)
            _ = unlink(socketURL.path)
            throw error
        }
        listeningDescriptor = descriptor
        queue.async { [weak self] in self?.acceptLoop(descriptor) }
    }

    func stop() {
        let descriptor = listeningDescriptor
        listeningDescriptor = -1
        if descriptor >= 0 {
            _ = shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        var metadata = stat()
        if lstat(socketURL.path, &metadata) == 0,
           metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFSOCK {
            _ = unlink(socketURL.path)
        }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while listeningDescriptor == descriptor {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handleClient(client)
        }
    }

    private func handleClient(_ descriptor: Int32) {
        defer { close(descriptor) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == expectedUID else {
            writeResponse(.failure(code: "peer_rejected", message: "The local peer is not authorized."), to: descriptor)
            return
        }
        do {
            let data = try readRequest(from: descriptor)
            let request = try AutomationProtocol.decodeRequest(data)
            guard request.protocolVersion == AutomationProtocol.version else {
                writeResponse(.failure(code: "unsupported_version", message: "The protocol version is not supported."), to: descriptor)
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var response = AutomationResponse.failure(code: "internal_error", message: "The request could not be completed.")
            Task {
                response = await handler(request)
                semaphore.signal()
            }
            semaphore.wait()
            writeResponse(response, to: descriptor)
        } catch AutomationSocketError.requestTooLarge {
            writeResponse(.failure(code: "request_too_large", message: "The request exceeds the size limit."), to: descriptor)
        } catch AutomationProtocolError.oversizedRequest {
            writeResponse(.failure(code: "request_too_large", message: "The request exceeds the size limit."), to: descriptor)
        } catch {
            writeResponse(.failure(code: "malformed_request", message: "The request is malformed."), to: descriptor)
        }
    }

    private func readRequest(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AutomationSocketError.unavailable
            }
            data.append(buffer, count: count)
            if data.count > AutomationProtocol.maximumMessageBytes { throw AutomationSocketError.requestTooLarge }
            if data.last == 0x0A { data.removeLast(); break }
        }
        return data
    }

    private func writeResponse(_ response: AutomationResponse, to descriptor: Int32) {
        var data = AutomationProtocol.encodeResponse(response)
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.send(descriptor, address, remaining, MSG_NOSIGNAL)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                address = address.advanced(by: count)
                remaining -= count
            }
        }
    }
}

enum LocalAutomationClient {
    static func send(_ request: AutomationRequest, socketURL: URL = AutomationSocketPath.defaultURL()) throws -> Data {
        try AutomationSocketPath.validateClientURL(socketURL)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AutomationSocketError.unavailable }
        defer { close(descriptor) }
        var address = try makeUnixAddress(path: socketURL.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, unixAddressLength(path: socketURL.path))
            }
        }
        guard result == 0 else { throw AutomationSocketError.unavailable }
        var requestData = try JSONEncoder().encode(request)
        guard requestData.count <= AutomationProtocol.maximumMessageBytes else { throw AutomationSocketError.requestTooLarge }
        requestData.append(0x0A)
        try writeAll(requestData, to: descriptor)
        _ = shutdown(descriptor, SHUT_WR)
        return try readResponse(from: descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.send(descriptor, address, remaining, MSG_NOSIGNAL)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AutomationSocketError.unavailable }
                address = address.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func readResponse(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AutomationSocketError.unavailable
            }
            data.append(buffer, count: count)
            if data.count > AutomationProtocol.maximumMessageBytes { throw AutomationSocketError.requestTooLarge }
            if data.last == 0x0A { data.removeLast(); break }
        }
        guard !data.isEmpty else { throw AutomationSocketError.unavailable }
        return data
    }
}

private func makeUnixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8CString)
    var address = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AutomationSocketError.pathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
            for index in bytes.indices { destination[index] = bytes[index] }
        }
    }
    return address
}

private func unixAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
}
