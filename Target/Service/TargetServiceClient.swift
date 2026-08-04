import Foundation
import ServiceManagement

/// Future service-backed backend entry point. It only describes the connection;
/// this phase neither registers the daemon nor sends privileged requests.
@available(macOS 13.0, *)
enum TargetServiceRegistration {
    static var installationState: ServiceInstallationState {
        let service = SMAppService.daemon(plistName: TargetServiceIdentifiers.launchDaemonPlistName)
        switch service.status {
        case .enabled, .requiresApproval:
            return .installed
        case .notRegistered, .notFound:
            return .notInstalled
        @unknown default:
            return .notInstalled
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
}
