import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: ApplicationPreferencesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("settings.general") {
                Toggle("settings.launch-at-login.title", isOn: launchAtLoginBinding)
                    .disabled(!preferences.canChangeLaunchAtLogin)
                    .accessibilityIdentifier("settings.launch-at-login")

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(preferences.launchAtLoginState.statusKey))
                        .foregroundStyle(.secondary)
                    if preferences.launchAtLoginState == .requiresApproval {
                        Text("settings.launch-at-login.requires-approval.detail")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let feedback = preferences.launchAtLoginFeedback {
                        Text(LocalizedStringKey(feedback.messageKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.launch-at-login.error")
                    }
                }
            }

            Section("settings.onboarding") {
                Button("settings.reopen-onboarding", action: reopenOnboarding)
                    .accessibilityIdentifier("settings.reopen-onboarding")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { preferences.refreshLaunchAtLoginStatus() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { preferences.launchAtLoginState.isEnabled },
            set: preferences.setLaunchAtLoginEnabled
        )
    }

    private func reopenOnboarding() {
        preferences.reopenOnboarding()
        if !TargetMainWindowActivation.activateExistingWindow() {
            openWindow(id: TargetMainWindowActivation.windowID)
        }
    }
}
