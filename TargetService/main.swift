import Foundation
import SystemConfiguration

private final class TargetServiceServer: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: TargetServiceIdentifiers.machService)

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
        let endpoint = TargetServiceEndpoint(runtimeOwnership: ownership)
        connection.exportedInterface = NSXPCInterface(with: TargetServiceXPCProtocol.self)
        connection.exportedObject = endpoint
        endpoint.start()
        connection.resume()
        return true
    }
}

private let server = TargetServiceServer()
server.run()

private final class TargetServiceEndpoint: NSObject, TargetServiceXPCProtocol {
    private let systemProxy: SystemProxyCoordinator

    init(runtimeOwnership: EngineRuntimeOwnership) {
        systemProxy = SystemProxyCoordinator(
            portProbe: TargetOwnedPortProbe(runtimeOwnership: runtimeOwnership),
            endpointProvider: { await runtimeOwnership.ownedEndpoint() }
        )
    }

    func start() {
        Task { await systemProxy.start() }
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
