import Foundation

enum TargetServiceIdentifiers {
    static let machService = "com.jason312928.Target.TargetService"
    static let launchDaemonPlistName = "com.jason312928.Target.TargetService.plist"
}

/// Deliberately narrow XPC contract. No shell, command, path, or process APIs are exposed.
@objc(TargetServiceXPCProtocol)
protocol TargetServiceXPCProtocol: NSObjectProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void)
    func validateConfiguration(_ request: Data, withReply reply: @escaping (NSError?) -> Void)
    func startEngine(withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopEngine(withReply reply: @escaping (Data?, NSError?) -> Void)
}

enum XPCPayloadCodec {
    static func encodeStatus(_ status: BackendStatus) throws -> Data {
        try JSONEncoder().encode(status)
    }

    static func decodeStatus(_ data: Data) throws -> BackendStatus {
        try JSONDecoder().decode(BackendStatus.self, from: data)
    }
}

func xpcError(_ error: Error) -> NSError {
    let backendError = (error as? BackendError) ?? .serviceUnavailable
    return NSError(
        domain: "com.jason312928.Target.TargetService",
        code: errorCode(for: backendError),
        userInfo: [NSLocalizedDescriptionKey: backendError.localizedKey]
    )
}

private func errorCode(for error: BackendError) -> Int {
    switch error {
    case .serviceNotInstalled: 1
    case .serviceRegistrationFailed: 2
    case .invalidConfiguration: 3
    case .invalidLifecycleTransition: 4
    case .operationCancelled: 5
    case .serviceUnavailable: 6
    case .notImplemented: 7
    case .engineNotInstalled: 8
    case .engineInstallationFailed: 9
    case .configurationCheckFailed: 10
    case .engineLaunchFailed: 11
    }
}
