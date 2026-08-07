import Foundation

enum TargetServiceIdentifiers {
    static let machService = "com.jason312928.Target.TargetService"
    static let launchDaemonPlistName = "com.jason312928.Target.TargetService.plist"
    static let snapshotOwner = "com.jason312928.Target.system-proxy-snapshot.v1"
}

enum TargetServicePeerAuthorization {
    static func allows(peerUID: uid_t, consoleUID: uid_t) -> Bool {
        peerUID != 0 && peerUID == consoleUID
    }
}

/// Deliberately narrow XPC contract. No shell, command, path, or process APIs are exposed.
@objc(TargetServiceXPCProtocol)
protocol TargetServiceXPCProtocol: NSObjectProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void)
    func validateConfiguration(_ request: Data, withReply reply: @escaping (NSError?) -> Void)
    func startEngine(withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopEngine(withReply reply: @escaping (Data?, NSError?) -> Void)
    func querySystemProxyStatus(withReply reply: @escaping (Data?, NSError?) -> Void)
    func enableSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void)
    func disableSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void)
    func recoverSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void)
}

enum XPCPayloadCodec {
    static func encodeStatus(_ status: BackendStatus) throws -> Data {
        try JSONEncoder().encode(status)
    }

    static func decodeStatus(_ data: Data) throws -> BackendStatus {
        try JSONDecoder().decode(BackendStatus.self, from: data)
    }

    static func encodeSystemProxyStatus(_ status: SystemProxyStatus) throws -> Data {
        try JSONEncoder().encode(status)
    }

    static func decodeSystemProxyStatus(_ data: Data) throws -> SystemProxyStatus {
        try JSONDecoder().decode(SystemProxyStatus.self, from: data)
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

func xpcError(_ error: SystemProxyError) -> NSError {
    let code: Int
    switch error {
    case .safeModeBlocked: code = 100
    case .existingNetworkController: code = 101
    case .noActiveNetworkService: code = 102
    case .localProxyUnavailable: code = 103
    case .snapshotFailed: code = 104
    case .invalidSnapshotOwner: code = 105
    case .externalModificationConflict: code = 106
    case .applyFailed: code = 107
    case .verificationFailed: code = 108
    case .recoveryFailed: code = 109
    }
    return NSError(
        domain: "com.jason312928.Target.TargetService",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: error.localizedKey]
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
    case .enginePortUnavailable: 12
    case .profileNotSelected: 13
    case .profileNoValidVersion: 14
    case .profileConfigurationUnsafe: 15
    case .profileConfigurationInvalid: 16
    }
}
