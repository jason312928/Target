import AppKit
import Foundation

enum HostNetworkSafetyMode: Equatable, Sendable {
    /// Development-machine default. Network writes are never enabled by application
    /// state alone in this mode.
    case safe
    /// Normal-user operation. Network writes remain gated by an explicit user action
    /// and the existing ownership/environment checks.
    case normalUser
    /// Explicitly authorized VM validation. This is only selected by the dedicated
    /// debug compilation condition and is never the normal-user default.
    case authorizedNetworkTest

    var permitsNetworkWrites: Bool { self != .safe }

    var automationValue: String {
        switch self {
        case .safe: "safe"
        case .normalUser: "normalUser"
        case .authorizedNetworkTest: "authorizedValidation"
        }
    }
}

enum TargetValidationPolicy {
#if DEBUG && TARGET_UTM_VALIDATION
    static let hostNetworkSafetyMode = HostNetworkSafetyMode.authorizedNetworkTest
    static let isUTMValidation = true
#elseif DEBUG
    static let hostNetworkSafetyMode = HostNetworkSafetyMode.safe
    static let isUTMValidation = false
#else
    static let hostNetworkSafetyMode = HostNetworkSafetyMode.normalUser
    static let isUTMValidation = false
#endif

    static var isHostSafeMode: Bool { !hostNetworkSafetyMode.permitsNetworkWrites }
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
