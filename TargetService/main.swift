import Foundation
import SystemConfiguration

private final class TargetServiceServer: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: TargetServiceIdentifiers.machService)
    private let removalBarrier = TargetServiceRemovalBarrier()

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let peerUID = connection.effectiveUserIdentifier
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil,
              TargetServicePeerAuthorization.allows(peerUID: peerUID, consoleUID: consoleUID),
              let store = UserEngineRuntimeStore(uid: peerUID) else { return false }
        let ownership = EngineRuntimeOwnership(store: store)
        let endpoint = TargetServiceEndpoint(runtimeOwnership: ownership, removalBarrier: removalBarrier)
        connection.exportedInterface = NSXPCInterface(with: TargetServiceXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak endpoint] in
            endpoint?.connectionInvalidated()
        }
        endpoint.start()
        connection.resume()
        return true
    }
}

private let server = TargetServiceServer()
server.run()

private final class TargetServiceEndpoint: NSObject, TargetServiceXPCProtocol {
    private let systemProxy: SystemProxyCoordinator

    private let removalBarrier: TargetServiceRemovalBarrier
    private let removalSessionID = UUID()

    init(runtimeOwnership: EngineRuntimeOwnership, removalBarrier: TargetServiceRemovalBarrier) {
        self.removalBarrier = removalBarrier
        systemProxy = SystemProxyCoordinator(
            portProbe: TargetOwnedPortProbe(runtimeOwnership: runtimeOwnership),
            endpointProvider: { await runtimeOwnership.ownedEndpoint() },
            removalBarrier: removalBarrier
        )
    }

    func start() {
        Task { await systemProxy.start() }
    }

    func connectionInvalidated() {
        let sessionID = removalSessionID
        Task { await removalBarrier.invalidate(sessionID: sessionID) }
    }
    func ping(withReply reply: @escaping (String) -> Void) {
        reply("target-service")
    }

    func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped)
            reply(try XPCPayloadCodec.encodeStatus(status), nil)
        } catch {
            reply(nil, xpcError(error))
        }
    }

    func validateConfiguration(_ request: Data, withReply reply: @escaping (NSError?) -> Void) {
        reply(xpcError(BackendError.notImplemented))
    }

    func startEngine(withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, xpcError(BackendError.notImplemented))
    }

    func stopEngine(withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, xpcError(BackendError.notImplemented))
    }

    func querySystemProxyStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        Task {
            let status = await systemProxy.querySystemProxyStatus()
            do {
                reply(try XPCPayloadCodec.encodeSystemProxyStatus(status), nil)
            } catch {
                reply(nil, xpcError(error))
            }
        }
    }

    func enableSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void) {
        performSystemProxyOperation(reply) { try await self.systemProxy.enableSystemProxy() }
    }

    func disableSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void) {
        performSystemProxyOperation(reply) { try await self.systemProxy.disableSystemProxy() }
    }

    func recoverSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void) {
        performSystemProxyOperation(reply) { try await self.systemProxy.recoverSystemProxy() }
    }

    func prepareServiceRemoval(withReply reply: @escaping (Data?, NSError?) -> Void) {
        Task {
            do {
                let lease = try await removalBarrier.prepare(sessionID: removalSessionID) {
                    await self.systemProxy.querySystemProxyStatus()
                }
                reply(try JSONEncoder().encode(lease), nil)
            } catch let error as SystemProxyError {
                reply(nil, xpcError(error))
            } catch {
                reply(nil, xpcError(.statusUnavailable))
            }
        }
    }

    func cancelServiceRemoval(_ token: Data, withReply reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                try await removalBarrier.cancel(token: token, sessionID: removalSessionID)
                reply(nil)
            } catch let error as SystemProxyError {
                reply(xpcError(error))
            } catch {
                reply(xpcError(.invalidServiceRemovalSession))
            }
        }
    }

    func completeServiceRemoval(_ token: Data, withReply reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                try await removalBarrier.complete(token: token, sessionID: removalSessionID)
                reply(nil)
            } catch let error as SystemProxyError {
                reply(xpcError(error))
            } catch {
                reply(xpcError(.invalidServiceRemovalSession))
            }
        }
    }

    private func performSystemProxyOperation(
        _ reply: @escaping (Data?, NSError?) -> Void,
        operation: @escaping () async throws -> SystemProxyStatus
    ) {
        Task {
            do {
                reply(try XPCPayloadCodec.encodeSystemProxyStatus(try await operation()), nil)
            } catch let error as SystemProxyError {
                reply(nil, xpcError(error))
            } catch {
                reply(nil, xpcError(BackendError.serviceUnavailable))
            }
        }
    }
}
