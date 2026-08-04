import Foundation
import ServiceManagement

@available(macOS 13.0, *)
enum TargetServiceRegistration {
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

final class TargetServiceXPCClient {
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
    private var didEncounterRegistrationError = false

    func queryStatus() async throws -> BackendStatus {
        if didEncounterRegistrationError {
            return BackendStatus(serviceInstallation: .error, engineState: .stopped)
        }

        let installation = TargetServiceRegistration.status
        guard installation == .enabled else {
            return BackendStatus(serviceInstallation: installation, engineState: .stopped)
        }

        do {
            let daemonStatus = try await client.queryStatus()
            return BackendStatus(serviceInstallation: .enabled, engineState: daemonStatus.engineState)
        } catch {
            return BackendStatus(serviceInstallation: .unavailable, engineState: .stopped)
        }
    }

    func installService() async throws -> BackendStatus {
        do {
            try TargetServiceRegistration.register()
            didEncounterRegistrationError = false
            return try await queryStatus()
        } catch {
            didEncounterRegistrationError = true
            throw error
        }
    }

    func removeService() async throws -> BackendStatus {
        do {
            try TargetServiceRegistration.unregister()
            didEncounterRegistrationError = false
            return try await queryStatus()
        } catch {
            didEncounterRegistrationError = true
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
