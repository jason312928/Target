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
    private let backend = MockBackend(initialStatus: BackendStatus(serviceInstallation: .installed, engineState: .stopped))

    func ping(withReply reply: @escaping (String) -> Void) {
        reply("target-service")
    }

    func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        Task {
            do {
                let status = try await backend.queryStatus()
                reply(try XPCPayloadCodec.encodeStatus(status), nil)
            } catch {
                reply(nil, xpcError(error))
            }
        }
    }

    func validateConfiguration(_ request: Data, withReply reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                try await backend.validateConfiguration(XPCConfigurationRequest.decodeAndValidate(request))
                reply(nil)
            } catch {
                reply(xpcError(error))
            }
        }
    }

    func startEngine(withReply reply: @escaping (Data?, NSError?) -> Void) {
        Task {
            do {
                let status = try await backend.startEngine()
                reply(try XPCPayloadCodec.encodeStatus(status), nil)
            } catch {
                reply(nil, xpcError(error))
            }
        }
    }

    func stopEngine(withReply reply: @escaping (Data?, NSError?) -> Void) {
        Task {
            do {
                let status = try await backend.stopEngine()
                reply(try XPCPayloadCodec.encodeStatus(status), nil)
            } catch {
                reply(nil, xpcError(error))
            }
        }
    }
}
