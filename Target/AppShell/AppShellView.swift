import SwiftUI

/// Target's main window is intentionally a single Profiles workspace. App-wide
/// preferences live in Settings; runtime details have a Diagnostics window.
struct AppShellView: View {
    let lifecycle: BackendLifecycleModel
    let preferences: ApplicationPreferencesModel
    @State private var profileModel: ProfileViewModel
    private let refreshOnTask: Bool
    private let connectionSidebar: AnyView?

    init(
        lifecycle: BackendLifecycleModel,
        profileModel: ProfileViewModel? = nil,
        preferences: ApplicationPreferencesModel,
        refreshOnTask: Bool = true,
        connectionSidebar: AnyView? = nil
    ) {
        self.lifecycle = lifecycle
        self.preferences = preferences
        _profileModel = State(initialValue: profileModel ?? ProfileViewModel())
        self.refreshOnTask = refreshOnTask
        self.connectionSidebar = connectionSidebar
    }

    var body: some View {
        ProfileWorkspaceView(
            lifecycle: lifecycle,
            model: profileModel,
            connectionSidebar: connectionSidebar
        )
            .frame(
                minWidth: AppShellLayout.minimumWindowWidth,
                minHeight: AppShellLayout.minimumWindowHeight
            )
            .task {
                await profileModel.loadInitialState()
                if refreshOnTask { lifecycle.refresh() }
            }
            .sheet(isPresented: onboardingPresentationBinding) {
                OnboardingView(
                    onComplete: preferences.completeOnboarding,
                    onOpenProfiles: preferences.dismissOnboarding
                )
            }
    }

    private var onboardingPresentationBinding: Binding<Bool> {
        Binding(
            get: { preferences.shouldPresentOnboarding },
            set: { isPresented in
                if !isPresented { preferences.dismissOnboarding() }
            }
        )
    }
}
