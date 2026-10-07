import Foundation
import ServiceManagement

@available(macOS 13.0, *)
enum TargetServiceRegistration {
    static var isStableInstallation: Bool {
        TargetServiceBundleLocation.isStable(Bundle.main.bundleURL)
    }

    static var status: ServiceInstallationState {
        installationState(for: currentService)
    }

    private static var currentService: SMAppService {
        SMAppService.daemon(plistName: TargetServiceIdentifiers.launchDaemonPlistName)
    }

    private static var legacyService: SMAppService {
        SMAppService.daemon(plistName: TargetServiceIdentifiers.legacyLaunchDaemonPlistName)
    }

    private static func installationState(for service: SMAppService) -> ServiceInstallationState {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .enabled:
            return .enabled
        case .notFound:
            return .unavailable
        @unknown default:
            return .error
        }
    }

    static func register() throws {
        guard isStableInstallation else { throw BackendError.serviceRegistrationFailed }
        // Retire the original registration before enabling v2. This prevents an
        // old root daemon and the replacement daemon from observing the same
        // recovery record concurrently. The legacy plist points at the relocated
        // executable so macOS 26 can resolve the stale record while unregistering
        // it; the application never registers that legacy definition again.
        try unregisterIfRegistered(legacyService)
        do {
            try currentService.register()
        } catch {
            if status == .requiresApproval {
                return
            }
            throw BackendError.serviceRegistrationFailed
        }
    }

    static func unregister() throws {
        do {
            try unregisterIfRegistered(currentService)
            try unregisterIfRegistered(legacyService)
        } catch {
            throw BackendError.serviceRegistrationFailed
        }
    }

    private static func unregisterIfRegistered(_ service: SMAppService) throws {
        switch service.status {
        case .notRegistered, .notFound:
            return
        case .enabled, .requiresApproval:
            try service.unregister()
        @unknown default:
            try service.unregister()
        }
    }
}

enum TargetServiceBundleLocation {
    static func isStable(_ bundleURL: URL) -> Bool {
        let bundlePath = bundleURL.resolvingSymlinksInPath().path
        guard !bundlePath.contains("/DerivedData/"),
              FileManager.default.fileExists(atPath: bundleURL.appending(path: TargetServiceIdentifiers.executableBundlePath).path),
              FileManager.default.fileExists(atPath: bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(TargetServiceIdentifiers.launchDaemonPlistName)").path),
              FileManager.default.fileExists(atPath: bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(TargetServiceIdentifiers.legacyLaunchDaemonPlistName)").path) else {
            return false
        }

        let systemApplications = "/Applications/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications", directoryHint: .isDirectory).path + "/"
        return bundlePath.hasPrefix(systemApplications) || bundlePath.hasPrefix(userApplications)
    }
}

struct TargetServiceXPCTimeouts: Equatable, Sendable {
    static let production = TargetServiceXPCTimeouts(read: 2.5, mutation: 5)

    let read: TimeInterval
    let mutation: TimeInterval
}

protocol TargetServiceXPCConnecting: AnyObject {
    var interruptionHandler: (() -> Void)? { get set }
    var invalidationHandler: (() -> Void)? { get set }
    func resume()
    func invalidate()
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any
}

extension NSXPCConnection: TargetServiceXPCConnecting {}

final class TargetServiceXPCClient: SystemProxyClient, TargetServiceRemovalClient, @unchecked Sendable {
    private let timeouts: TargetServiceXPCTimeouts
    private let connectionFactory: () -> any TargetServiceXPCConnecting
    private let removalConnectionState = RemovalConnectionState()

    init(
        timeouts: TargetServiceXPCTimeouts = .production,
        connectionFactory: (() -> any TargetServiceXPCConnecting)? = nil
    ) {
        self.timeouts = timeouts
        self.connectionFactory = connectionFactory ?? Self.makeProductionConnection
    }

    private static func makeProductionConnection() -> any TargetServiceXPCConnecting {
        let connection = NSXPCConnection(
            machServiceName: TargetServiceIdentifiers.machService,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: TargetServiceXPCProtocol.self)
        return connection
    }

    func ping() async throws -> String {
        let connection = connectionFactory()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
            reply.armTimeout(after: timeouts.read) { connection.invalidate() }
            connection.interruptionHandler = { reply.fail() }
            connection.invalidationHandler = { reply.fail() }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.fail() }
            guard let service = proxy as? TargetServiceXPCProtocol else {
                reply.fail()
                return
            }
            service.ping { reply.succeed($0) }
        }
    }

    func queryStatus() async throws -> BackendStatus {
        let connection = connectionFactory()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
            reply.armTimeout(after: timeouts.read) { connection.invalidate() }
            connection.interruptionHandler = { reply.fail() }
            connection.invalidationHandler = { reply.fail() }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.fail() }
            guard let service = proxy as? TargetServiceXPCProtocol else {
                reply.fail()
                return
            }
            service.queryStatus { data, error in
                if let error {
                    reply.fail(error)
                    return
                }
                guard let data else {
                    reply.fail()
                    return
                }
                do {
                    reply.succeed(try XPCPayloadCodec.decodeStatus(data))
                } catch {
                    reply.fail(error)
                }
            }
        }
    }

    func querySystemProxyStatus() async throws -> SystemProxyStatus {
        try await callSystemProxy(timeout: timeouts.read) { service, reply in
            service.querySystemProxyStatus(withReply: reply)
        }
    }

    func enableSystemProxy() async throws -> SystemProxyStatus {
        try await callSystemProxy(timeout: timeouts.mutation) { service, reply in
            service.enableSystemProxy(withReply: reply)
        }
    }

    func disableSystemProxy() async throws -> SystemProxyStatus {
        try await callSystemProxy(timeout: timeouts.mutation) { service, reply in
            service.disableSystemProxy(withReply: reply)
        }
    }

    func recoverSystemProxy() async throws -> SystemProxyStatus {
        try await callSystemProxy(timeout: timeouts.mutation) { service, reply in
            service.recoverSystemProxy(withReply: reply)
        }
    }

    func prepareServiceRemoval() async throws -> TargetServiceRemovalLease {
        // Keep this connection alive for the whole unregister transaction. The
        // service binds the lease to the connection's server-side session; it
        // must not be reduced to another short-lived request/response call.
        guard let connection = removalConnectionState.install(connectionFactory()) else {
            throw SystemProxyError.serviceRemovalInProgress
        }

        do {
            let data = try await callData(on: connection, timeout: timeouts.mutation) { service, reply in
                service.prepareServiceRemoval(withReply: reply)
            }
            return try JSONDecoder().decode(TargetServiceRemovalLease.self, from: data)
        } catch {
            clearRemovalConnection(connection)
            connection.invalidate()
            throw error
        }
    }

    func cancelServiceRemoval(_ token: Data) async throws {
        try await finishRemoval(token: token) { service, reply in
            service.cancelServiceRemoval(token, withReply: reply)
        }
    }

    func completeServiceRemoval(_ token: Data) async throws {
        try await finishRemoval(token: token) { service, reply in
            service.completeServiceRemoval(token, withReply: reply)
        }
    }

    private func finishRemoval(
        token: Data,
        _ action: @escaping (TargetServiceXPCProtocol, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        let connection = removalConnectionState.current
        guard let connection else {
            throw SystemProxyError.invalidServiceRemovalSession
        }
        do {
            try await callVoid(on: connection, timeout: timeouts.mutation, resume: false, action)
            clearRemovalConnection(connection)
            connection.invalidate()
        } catch let error as SystemProxyError where error == .invalidServiceRemovalSession {
            // A stale or foreign token must not turn into an implicit release by
            // invalidating the connection that owns a different active lease.
            throw error
        } catch {
            // Transport failure still invalidates the session, allowing the
            // server-side connection handler to release its owned lease.
            clearRemovalConnection(connection)
            connection.invalidate()
            throw error
        }
    }

    private func clearRemovalConnection(_ connection: any TargetServiceXPCConnecting) {
        removalConnectionState.clear(connection)
    }

    private func callSystemProxy(
        timeout: TimeInterval,
        _ action: @escaping (TargetServiceXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> SystemProxyStatus {
        let connection = connectionFactory()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
            reply.armTimeout(after: timeout) { connection.invalidate() }
            connection.interruptionHandler = { reply.fail() }
            connection.invalidationHandler = { reply.fail() }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in reply.fail(error) }
            guard let service = proxy as? TargetServiceXPCProtocol else {
                reply.fail()
                return
            }
            action(service) { data, error in
                if let error {
                    reply.fail(Self.decodeError(error))
                    return
                }
                guard let data else {
                    reply.fail()
                    return
                }
                do {
                    reply.succeed(try XPCPayloadCodec.decodeSystemProxyStatus(data))
                } catch {
                    reply.fail(error)
                }
            }
        }
    }

    private func callData(
        on connection: any TargetServiceXPCConnecting,
        timeout: TimeInterval,
        resume: Bool = true,
        _ action: @escaping (TargetServiceXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
            reply.armTimeout(after: timeout) { connection.invalidate() }
            connection.interruptionHandler = { reply.fail() }
            connection.invalidationHandler = { reply.fail() }
            if resume { connection.resume() }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in reply.fail(error) }
            guard let service = proxy as? TargetServiceXPCProtocol else {
                reply.fail()
                return
            }
            action(service) { data, error in
                if let error {
                    reply.fail(Self.decodeError(error))
                    return
                }
                guard let data else {
                    reply.fail()
                    return
                }
                reply.succeed(data)
            }
        }
    }

    private func callVoid(
        on connection: any TargetServiceXPCConnecting,
        timeout: TimeInterval,
        resume: Bool = true,
        _ action: @escaping (TargetServiceXPCProtocol, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = XPCReplyOnce(continuation)
            reply.armTimeout(after: timeout) { connection.invalidate() }
            connection.interruptionHandler = { reply.fail() }
            connection.invalidationHandler = { reply.fail() }
            if resume { connection.resume() }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in reply.fail(error) }
            guard let service = proxy as? TargetServiceXPCProtocol else {
                reply.fail()
                return
            }
            action(service) { error in
                if let error {
                    reply.fail(Self.decodeError(error))
                } else {
                    reply.succeed(())
                }
            }
        }
    }

    private static func decodeError(_ error: NSError) -> Error {
        SystemProxyError(serviceError: error) ?? error
    }
}

private final class RemovalConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: (any TargetServiceXPCConnecting)?

    var current: (any TargetServiceXPCConnecting)? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    func install(_ newConnection: any TargetServiceXPCConnecting) -> (any TargetServiceXPCConnecting)? {
        lock.lock()
        defer { lock.unlock() }
        guard connection == nil else { return nil }
        connection = newConnection
        return newConnection
    }

    func clear(_ oldConnection: any TargetServiceXPCConnecting) {
        lock.lock()
        defer { lock.unlock() }
        if let connection,
           ObjectIdentifier(connection) == ObjectIdentifier(oldConnection) {
            self.connection = nil
        }
    }
}

private final class XPCReplyOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error = BackendError.serviceUnavailable) {
        finish(.failure(error))
    }

    func armTimeout(after interval: TimeInterval, invalidate: @escaping @Sendable () -> Void) {
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.finish(.failure(BackendError.serviceUnavailable)) == true else { return }
            invalidate()
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + max(0, interval),
            execute: workItem
        )
    }

    @discardableResult
    private func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        continuation?.resume(with: result)
        return continuation != nil
    }
}

@available(macOS 13.0, *)
actor TargetServiceBackend: ServiceLifecycleManaging, ServiceConnectionTesting {
    private let client: TargetServiceXPCClient
    private let systemProxyOperations: TargetSystemProxyOperations

    init(client: TargetServiceXPCClient = TargetServiceXPCClient()) {
        self.client = client
        self.systemProxyOperations = TargetSystemProxyOperations(
            client: client,
            serviceRegistrationStatus: { TargetServiceRegistration.status }
        )
    }

    func queryStatus() async throws -> BackendStatus {
        let installation = TargetServiceRegistration.status
        guard installation == .enabled else {
            return BackendStatus(serviceInstallation: installation, engineState: .stopped)
        }

        do {
            let daemonStatus = try await client.queryStatus()
            return BackendStatus(serviceInstallation: .enabled, engineState: daemonStatus.engineState)
        } catch {
            // Registration remains enabled even when the Mach service is not yet
            // accepting connections. The caller presents XPC availability separately.
            return BackendStatus(serviceInstallation: .enabled, engineState: .stopped)
        }
    }

    func installService() async throws -> BackendStatus {
        do {
            try TargetServiceRegistration.register()
            return try await queryStatus()
        } catch {
            throw error
        }
    }

    func removeService() async throws -> BackendStatus {
        _ = try await systemProxyOperations.removeService(
            unregisterService: { try TargetServiceRegistration.unregister() },
            serviceStatus: { TargetServiceRegistration.status }
        )
        return try await queryStatus()
    }

    func pingService() async throws -> String {
        guard TargetServiceRegistration.status == .enabled else {
            throw BackendError.serviceUnavailable
        }
        return try await client.ping()
    }

    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {
        throw BackendError.notImplemented
    }

    func startEngine() async throws -> BackendStatus {
        throw BackendError.notImplemented
    }

    func stopEngine() async throws -> BackendStatus {
        throw BackendError.notImplemented
    }
}
