import SwiftUI

struct SettingsView: View {
    @Bindable var lifecycle: BackendLifecycleModel
    @Bindable var preferences: ApplicationPreferencesModel
    @Bindable var updateController: TargetUpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("settings.general", systemImage: "gearshape") }

            AdvancedSettingsView(lifecycle: lifecycle)
                .tabItem { Label("dashboard.section.advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 580, height: 520)
        .task {
            preferences.refreshLaunchAtLoginStatus()
            updateController.refreshPreferences()
        }
    }

    private var generalSettings: some View {
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
        .scenePadding()
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

private struct AdvancedSettingsView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    private var presentation: DashboardPresentation {
        DashboardPresentation(
            status: lifecycle.status,
            lifecycleState: lifecycle.lifecycleState,
            serviceInstallation: lifecycle.serviceInstallation,
            xpcState: lifecycle.xpcState,
            error: lifecycle.error,
            systemProxyStatus: lifecycle.systemProxyStatus,
            isBusy: lifecycle.isBusy,
            isHostSafeMode: lifecycle.isHostSafeMode,
            isUTMValidation: lifecycle.isUTMValidationMode
        )
    }

    var body: some View {
        Form {
            Section {
                TargetStatusRow(labelKey: "engine.label.installation", valueKey: presentation.engineInstallationKey, value: nil)
                TargetStatusRow(labelKey: "engine.label.version", valueKey: nil, value: presentation.engineVersion)
                TargetStatusRow(labelKey: "backend.label.engine", valueKey: presentation.engineStateKey, value: nil)
                if let endpoint = presentation.endpoint {
                    TargetStatusRow(labelKey: "dashboard.label.endpoint", valueKey: nil, value: endpoint)
                }
                if let revision = presentation.runningRevision {
                    TargetStatusRow(labelKey: "dashboard.label.revision", valueKey: nil, value: String(revision))
                }
                Button("engine.action.validate") { lifecycle.validateConfiguration() }
                    .disabled(lifecycle.isBusy || lifecycle.status.engineInstallation != .installed)
            } header: {
                Label("dashboard.section.runtime", systemImage: "bolt")
            }

            Section {
                TargetStatusRow(labelKey: "backend.label.service", valueKey: presentation.serviceInstallationKey, value: nil)
                TargetStatusRow(labelKey: "xpc.label.status", valueKey: presentation.xpcStateKey, value: nil)
                HStack(spacing: 10) {
                    Button("service.action.install") { lifecycle.installService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .enabled)
                    Button("service.action.remove", role: .destructive) { lifecycle.removeService() }
                        .disabled(!lifecycle.canManageService || lifecycle.serviceInstallation == .notRegistered)
                }
            } header: {
                Label("dashboard.section.service", systemImage: "shield")
            }

            Section {
                TargetStatusRow(labelKey: "system-proxy.label.status", valueKey: presentation.systemProxyStateKey, value: nil)
                TargetStatusRow(labelKey: "system-proxy.label.engine", valueKey: presentation.systemProxyEngineKey, value: nil)
                HStack(spacing: 10) {
                    Button("system-proxy.action.refresh") { lifecycle.refreshSystemProxyStatus() }
                        .disabled(lifecycle.isBusy)
                    Button("system-proxy.action.recover") { lifecycle.recoverSystemProxy() }
                        .disabled(!lifecycle.canRecoverSystemProxy)
                }
            } header: {
                Label("dashboard.section.network", systemImage: "network")
            }

            if presentation.isHostSafeMode {
                Section {
                    TargetNotice(level: .warning, messageKey: presentation.hostSafetyNoticeKey)
                }
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .task { lifecycle.refresh() }
    }
}
