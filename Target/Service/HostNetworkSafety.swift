import AppKit
import Foundation

/// Pure build identity shared by updater presentation and host-network policy.
/// Unknown or missing values deliberately resolve to `.local`.
enum TargetBuildChannel: Equatable {
    case local
    case developmentPreview
    case stable

    init(bundleValue: String?) {
        switch bundleValue?.lowercased() {
        case "developmentpreview", "development-preview": self = .developmentPreview
        case "stable", "release": self = .stable
        default: self = .local
        }
    }
}

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
    private static let isDebugBuild = true
    private static let hasUTMValidationCondition = true
    static let isUTMValidation = true
#elseif DEBUG
    private static let isDebugBuild = true
    private static let hasUTMValidationCondition = false
    static let isUTMValidation = false
#else
    private static let isDebugBuild = false
    private static let hasUTMValidationCondition = false
    static let isUTMValidation = false
#endif

#if TARGET_BUILD_CHANNEL_DevelopmentPreview
    static let buildChannel = TargetBuildChannel.developmentPreview
#elseif TARGET_BUILD_CHANNEL_Stable || TARGET_BUILD_CHANNEL_Release
    static let buildChannel = TargetBuildChannel.stable
#else
    static let buildChannel = TargetBuildChannel(
        bundleValue: Bundle.main.object(forInfoDictionaryKey: "TargetBuildChannel") as? String
    )
#endif
    static let hostNetworkSafetyMode = hostNetworkSafetyMode(
        buildChannel: buildChannel,
        isDebugBuild: isDebugBuild,
        hasUTMValidationCondition: hasUTMValidationCondition
    )

    static func hostNetworkSafetyMode(
        buildChannel: TargetBuildChannel,
        isDebugBuild: Bool,
        hasUTMValidationCondition: Bool
    ) -> HostNetworkSafetyMode {
        if isDebugBuild && hasUTMValidationCondition {
            return .authorizedNetworkTest
        }
        switch buildChannel {
        case .local:
            return .safe
        case .developmentPreview, .stable:
            return .normalUser
        }
    }

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
