import SwiftUI

/// Compatibility entry point for the existing app shell.
struct ContentView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    var body: some View {
        DashboardView(lifecycle: lifecycle)
    }
}

#Preview("Dashboard") {
    DashboardView(lifecycle: TargetPreviewFixtures.lifecycle())
        .environment(\.locale, .init(identifier: "zh-Hans"))
        .frame(width: 820, height: 620)
}

#Preview("Profiles") {
    ProfileWorkspaceView(
        lifecycle: nil,
        model: TargetPreviewFixtures.profileModel(withProfile: true),
        showsProfileList: true
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 980, height: 680)
}

#Preview("Profiles Empty") {
    ProfileWorkspaceView(
        lifecycle: nil,
        model: TargetPreviewFixtures.profileModel(withProfile: false),
        showsProfileList: true
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 980, height: 680)
}

#Preview("Full App Shell") {
    AppShellView(
        lifecycle: TargetPreviewFixtures.lifecycle(),
        profileModel: TargetPreviewFixtures.profileModel(withProfile: true),
        preferences: TargetPreviewFixtures.preferences(),
        refreshOnTask: false,
        restoredDestination: .dashboard
    )
    .environment(\.locale, .init(identifier: "zh-Hans"))
    .frame(width: 980, height: 680)
}

@MainActor
private enum TargetPreviewFixtures {
    static func lifecycle() -> BackendLifecycleModel {
        BackendLifecycleModel(
            backend: MockBackend(
                initialStatus: BackendStatus(
                    serviceInstallation: .enabled,
                    engineState: .stopped,
                    engineInstallation: .installed,
                    hasSelectedValidProfile: true
                )
            ),
            hostNetworkSafetyMode: .safe,
            serviceRegistrationStatusProvider: { .enabled }
        )
    }

    static func profileModel(withProfile: Bool) -> ProfileViewModel {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Target-SwiftUIPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ProfileStore(rootDirectory: root, keyProvider: TargetPreviewKeyProvider())
        if withProfile {
            _ = try? store.create(name: "Home Profile")
        }
        return ProfileViewModel(store: store)
    }

    static func preferences() -> ApplicationPreferencesModel {
        ApplicationPreferencesModel(
            onboardingPreferences: TargetPreviewOnboardingPreferences(),
            loginItemManager: TargetPreviewLoginItemManager()
        )
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
