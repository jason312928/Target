import Foundation
import ServiceManagement

@available(macOS 13.0, *)
enum TargetServiceRegistration {
    static var isStableInstallation: Bool {
        TargetServiceBundleLocation.isStable(Bundle.main.bundleURL)
    }

    static var status: ServiceInstallationState {
        let service = SMAppService.daemon(plistName: TargetServiceIdentifiers.launchDaemonPlistName)
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
        let service = SMAppService.daemon(plistName: TargetServiceIdentifiers.launchDaemonPlistName)
        do {
            try service.register()
        } catch {
            if status == .requiresApproval {
                return
            }
            throw BackendError.serviceRegistrationFailed
        }
    }

    static func unregister() throws {
        let service = SMAppService.daemon(plistName: TargetServiceIdentifiers.launchDaemonPlistName)
        do {
            try service.unregister()
        } catch {
            throw BackendError.serviceRegistrationFailed
        }
    }
}

enum TargetServiceBundleLocation {
    static func isStable(_ bundleURL: URL) -> Bool {
        let bundlePath = bundleURL.resolvingSymlinksInPath().path
        guard !bundlePath.contains("/DerivedData/"),
              FileManager.default.fileExists(atPath: bundleURL.appending(path: "Contents/Library/HelperTools/TargetService").path),
              FileManager.default.fileExists(atPath: bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(TargetServiceIdentifiers.launchDaemonPlistName)").path) else {
            return false
        }

        let systemApplications = "/Applications/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications", directoryHint: .isDirectory).path + "/"
        return bundlePath.hasPrefix(systemApplications) || bundlePath.hasPrefix(userApplications)
    }
}

final class TargetServiceXPCClient: SystemProxyClient, @unchecked Sendable {
    func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: TargetServiceIdentifiers.machService,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: TargetServiceXPCProtocol.self)
        return connection
    }

    func ping() async throws -> String {
        let connection = makeConnection()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
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
        let connection = makeConnection()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
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
        try await callSystemProxy { service, reply in
            service.querySystemProxyStatus(withReply: reply)
        }
    }

    func enableSystemProxy() async throws -> SystemProxyStatus {
        try await callSystemProxy { service, reply in
            service.enableSystemProxy(withReply: reply)
        }
    }

    func disableSystemProxy() async throws -> SystemProxyStatus {
        try await callSystemProxy { service, reply in
            service.disableSystemProxy(withReply: reply)
        }
    }

    func recoverSystemProxy() async throws -> SystemProxyStatus {
        try await callSystemProxy { service, reply in
            service.recoverSystemProxy(withReply: reply)
        }
    }

    private func callSystemProxy(
        _ action: @escaping (TargetServiceXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> SystemProxyStatus {
        let connection = makeConnection()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyOnce(continuation)
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
                    reply.fail(error)
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
}

private final class XPCReplyOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error = BackendError.serviceUnavailable) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@available(macOS 13.0, *)
actor TargetServiceBackend: ServiceLifecycleManaging, ServiceConnectionTesting {
    private let client = TargetServiceXPCClient()

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
        do {
            try TargetServiceRegistration.unregister()
            return try await queryStatus()
        } catch {
            throw error
        }
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
