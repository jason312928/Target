import AppKit
import Foundation

enum HostNetworkSafetyMode: Sendable {
    /// The only production default. Network writes require a separate, explicitly
    /// authorized test environment and are never enabled by application state alone.
    case safe
    case authorizedNetworkTest

    var permitsNetworkWrites: Bool { self == .authorizedNetworkTest }
}

struct HostNetworkEnvironmentStatus: Equatable, Sendable {
    let hasConfiguredSystemProxy: Bool
    let hasRunningProxyApplication: Bool

    var mayTakeOverNetwork: Bool {
        !hasConfiguredSystemProxy && !hasRunningProxyApplication
    }
}

protocol HostNetworkEnvironmentChecking: Sendable {
    func inspect() -> HostNetworkEnvironmentStatus
}

/// Read-only host inspection. It reports only aggregate safety facts: it never reads
/// a third-party application's configuration and never changes another process.
final class HostNetworkEnvironmentProbe: HostNetworkEnvironmentChecking, @unchecked Sendable {
    private static let proxyApplicationMarkers = [
        "clash", "shadowrocket", "quantumult", "surge", "mihomo", "v2ray", "xray",
        "hysteria", "trojan", "outline", "proxifier", "charles", "fiddler", "mitmproxy"
    ]

    private let system: any SystemProxySystemManaging
    private let runningBundleIdentifiers: @Sendable () -> [String]

    init(
        system: any SystemProxySystemManaging = SystemConfigurationProxyManager(),
        runningBundleIdentifiers: @escaping @Sendable () -> [String] = {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        }
    ) {
        self.system = system
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }

    func inspect() -> HostNetworkEnvironmentStatus {
        let configured = (try? system.activeServiceIDs().contains { serviceID in
            guard let settings = try? system.proxySettings(for: serviceID) else { return true }
            return Self.hasConfiguredProxy(settings)
        }) ?? true
        let runningProxy = runningBundleIdentifiers().contains { identifier in
            let lowered = identifier.lowercased()
            return Self.proxyApplicationMarkers.contains { lowered.contains($0) }
        }
        return HostNetworkEnvironmentStatus(
            hasConfiguredSystemProxy: configured,
            hasRunningProxyApplication: runningProxy
        )
    }

    private static func hasConfiguredProxy(_ settings: [String: SystemProxyValue]) -> Bool {
        let enabledKeys = [
            "HTTPEnable", "HTTPSEnable", "SOCKSEnable",
            "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"
        ]
        return enabledKeys.contains { settings[$0] == .integer(1) }
    }
}
