import SwiftUI

/// Compatibility entry point for the single Profiles workspace.
struct ContentView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    @State private var model = ProfileViewModel()

    var body: some View {
        ProfileWorkspaceView(
            lifecycle: lifecycle,
            model: model,
            connectionSidebar: AnyView(RuntimeConnectionsSidebar(lifecycle: lifecycle))
        )
    }
}

#Preview("Profiles - Single Node") {
    ProfileWorkspaceView(
        lifecycle: nil,
        model: TargetPreviewFixtures.profileModel(.singleNode)
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 980, height: 680)
}

#Preview("Profiles - 36 Nodes") {
    ProfileWorkspaceView(
        lifecycle: nil,
        model: TargetPreviewFixtures.profileModel(.manyNodes)
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 1180, height: 760)
}

#Preview("Profiles - Multiple Groups") {
    ProfileWorkspaceView(
        lifecycle: TargetPreviewFixtures.lifecycle(engineState: .running),
        model: TargetPreviewFixtures.profileModel(.multipleGroups)
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 1180, height: 760)
}

#Preview("Proxies - Country Routing") {
    CountryRoutingPreview()
        .environment(\.locale, .init(identifier: "zh-Hans"))
        .frame(width: 960, height: 680)
}

#Preview("Profiles - Narrow Window") {
    ProfileWorkspaceView(
        lifecycle: nil,
        model: TargetPreviewFixtures.profileModel(.manyNodes)
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 740, height: 620)
}

#Preview("Profiles - Empty") {
    ProfileWorkspaceView(
        lifecycle: nil,
        model: TargetPreviewFixtures.profileModel(.empty)
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 980, height: 680)
}

#Preview("Profiles - Full Window") {
    AppShellView(
        lifecycle: TargetPreviewFixtures.lifecycle(engineState: .running),
        profileModel: TargetPreviewFixtures.profileModel(.severalProfiles),
        preferences: TargetPreviewFixtures.preferences(),
        refreshOnTask: false
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 980, height: 680)
}

@MainActor
private enum TargetPreviewFixtures {
    enum ProfileScenario {
        case empty
        case singleNode
        case manyNodes
        case multipleGroups
        case severalProfiles
    }

    static func lifecycle(engineState: EngineState) -> BackendLifecycleModel {
        let status = BackendStatus(
            serviceInstallation: .enabled,
            engineState: engineState,
            engineInstallation: .installed,
            hasSelectedValidProfile: true,
            engineVersion: "1.11.15",
            enginePort: engineState == .running ? 20_880 : nil
        )
        let model = BackendLifecycleModel(
            backend: MockBackend(initialStatus: status),
            hostNetworkSafetyMode: .safe,
            serviceRegistrationStatusProvider: { .enabled }
        )
        model.applyAutomationEngineStatus(status)
        return model
    }

    static func profileModel(_ scenario: ProfileScenario) -> ProfileViewModel {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Target-SwiftUIPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ProfileStore(
            rootDirectory: root,
            checker: TargetPreviewConfigurationChecker(),
            keyProvider: TargetPreviewKeyProvider()
        )

        switch scenario {
        case .empty:
            break
        case .singleNode:
            addProfile(named: "Home", nodeCount: 1, groupCount: 1, to: store)
        case .manyNodes:
            addProfile(named: "Everyday", nodeCount: 36, groupCount: 1, to: store)
        case .multipleGroups:
            addProfile(named: "Travel", nodeCount: 24, groupCount: 3, to: store)
        case .severalProfiles:
            addProfile(named: "Home", nodeCount: 12, groupCount: 1, to: store)
            addProfile(named: "Travel", nodeCount: 24, groupCount: 3, to: store)
            addProfile(named: "Work", nodeCount: 8, groupCount: 2, to: store)
        }
        return ProfileViewModel(store: store)
    }

    private static func addProfile(
        named name: String,
        nodeCount: Int,
        groupCount: Int,
        to store: ProfileStore
    ) {
        guard let profile = try? store.create(name: name),
              let configuration = previewConfiguration(nodeCount: nodeCount, groupCount: groupCount) else {
            return
        }
        try? store.save(json: configuration, for: profile.id)
    }

    private static func previewConfiguration(nodeCount: Int, groupCount: Int) -> String? {
        let regions = ["Hong Kong", "Japan", "Singapore", "United States", "Germany", "Taiwan"]
        let nodeNames = (0..<nodeCount).map { index in
            "\(regions[index % regions.count]) \(String(format: "%02d", (index / regions.count) + 1))"
        }
        let groupNames = ["Proxy", "Streaming", "Work"]
        let selectors: [[String: Any]] = (0..<min(groupCount, groupNames.count)).map { index in
            let members = nodeNames.enumerated().compactMap { memberIndex, name in
                memberIndex % max(groupCount, 1) == index ? name : nil
            }
            return [
                "type": "selector",
                "tag": groupNames[index],
                "outbounds": members,
                "default": members.first ?? ""
            ]
        }
        let nodes = nodeNames.map { ["type": "direct", "tag": $0] }
        let root: [String: Any] = ["outbounds": selectors + nodes]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func preferences() -> ApplicationPreferencesModel {
        ApplicationPreferencesModel(
            onboardingPreferences: TargetPreviewOnboardingPreferences(),
            loginItemManager: TargetPreviewLoginItemManager()
        )
    }
}

@MainActor
private struct CountryRoutingPreview: View {
    @State private var selectedMember = "Japan 02"

    private let nodes: [(tag: String, endpoint: String?, latency: Int?)] = [
        ("Hong Kong 01", "198.51.100.1", 58),
        ("Hong Kong 02", "198.51.100.2", 46),
        ("Tokyo Edge 01", "192.0.2.1", 83),
        ("Tokyo Edge 02", "192.0.2.2", 41),
        ("Singapore 01", "203.0.113.2", 92),
        ("United States West", "203.0.113.1", 138),
        ("Germany 01", nil, 176),
        ("Taiwan 01", "168.95.1.1", 52),
        ("Automatic Route", nil, nil)
    ]

    var body: some View {
        ProfilePolicyWorkspaceView(
            catalog: catalog,
            unavailable: false,
            isSelecting: false,
            healthBySelector: [0: health],
            testingSelectorID: nil,
            lifecycle: TargetPreviewFixtures.lifecycle(engineState: .running),
            select: { _, member in selectedMember = member },
            probeLatency: { _, _ in },
            reset: { selectedMember = "Japan 02" },
            refresh: {},
            openConfiguration: {}
        )
    }

    private var catalog: PolicyCatalog {
        PolicyCatalog(
            formatVersion: 2,
            profileID: UUID(uuidString: "AEB472B0-23E7-472E-86D2-68D4CD9402B1"),
            profileRevision: 3,
            sourceFingerprint: "preview-country-routing",
            storedOverrideCount: selectedMember == "Japan 02" ? 0 : 1,
            selectors: [
                PolicyCatalogSelector(
                    identity: 0,
                    tag: "Proxy",
                    status: .available,
                    configuredDefault: "Japan 02",
                    targetOverride: selectedMember == "Japan 02" ? nil : selectedMember,
                    overrideValid: true,
                    effectiveDesired: selectedMember,
                    runningSelection: selectedMember,
                    runtimeConvergence: .converged,
                    restartRequired: false,
                    members: nodes.enumerated().map { index, node in
                        PolicyCatalogMember(identity: index, tag: node.tag, type: "vmess", status: .available, endpoint: node.endpoint)
                    }
                )
            ]
        )
    }

    private var health: [String: RuntimeProxyHealth] {
        Dictionary(uniqueKeysWithValues: nodes.compactMap { node in
            guard let latency = node.latency,
                  let result = RuntimeProxyHealth.reachable(
                    tag: node.tag,
                    latencyMilliseconds: latency,
                    observedAt: Date(timeIntervalSince1970: 1)
                  ) else { return nil }
            return (node.tag, result)
        })
    }
}

private struct TargetPreviewConfigurationChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> {
        .success(())
    }
}

private final class TargetPreviewKeyProvider: ProfileEncryptionKeyProviding {
    func loadMasterKey() throws -> Data? { Data(repeating: 0x5A, count: 32) }
    func createMasterKey() throws -> Data { Data(repeating: 0x5A, count: 32) }
}

private final class TargetPreviewOnboardingPreferences: OnboardingPersisting {
    var hasCompletedOnboarding = true
}

@MainActor
private final class TargetPreviewLoginItemManager: LoginItemManaging {
    func currentStatus() throws -> LoginItemRegistrationStatus { .disabled }
    func register() throws {}
    func unregister() throws {}
}
