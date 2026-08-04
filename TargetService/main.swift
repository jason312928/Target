import Foundation

private final class TargetServiceServer: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: TargetServiceIdentifiers.machService)
    private let endpoint = TargetServiceEndpoint()

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TargetServiceXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

private let server = TargetServiceServer()
server.run()

private final class TargetServiceEndpoint: NSObject, TargetServiceXPCProtocol {
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
}
