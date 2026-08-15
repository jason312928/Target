import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: ApplicationPreferencesModel
    @Bindable var updateController: TargetUpdateController
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

            Section("settings.software-update") {
                LabeledContent("settings.software-update.current-version") {
                    Text(updateController.presentation.version)
                }
                LabeledContent("settings.software-update.current-build") {
                    Text(updateController.presentation.build)
                }
                LabeledContent("settings.software-update.channel") {
                    Text(LocalizedStringKey(updateController.presentation.channel.localizedKey))
                }

                Button("settings.software-update.check", action: updateController.checkForUpdates)
                    .disabled(!updateController.canCheckForUpdates)
                    .accessibilityIdentifier("settings.software-update.check")

                Toggle("settings.software-update.automatic-checks", isOn: automaticChecksBinding)
                    .accessibilityIdentifier("settings.software-update.automatic-checks")

                if let statusKey = updateController.status.localizedKey {
                    Text(LocalizedStringKey(statusKey))
                        .font(.footnote)
                        .foregroundStyle(updateController.status == .failed ? .red : .secondary)
                        .accessibilityIdentifier("settings.software-update.status")
                }
            }

            Section("settings.onboarding") {
                Button("settings.reopen-onboarding", action: reopenOnboarding)
                    .accessibilityIdentifier("settings.reopen-onboarding")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task {
            preferences.refreshLaunchAtLoginStatus()
            updateController.refreshPreferences()
        }
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updateController.automaticallyChecksForUpdates },
            set: updateController.setAutomaticallyChecksForUpdates
        )
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
