import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileOverviewView: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let presentation: ProfileWorkspacePresentation
    let showProxies: () -> Void

    private var policyPresentation: PolicyWorkspacePresentation {
        PolicyWorkspacePresentation(catalog: model.policyCatalog, unavailable: model.isPolicyCatalogUnavailable)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let subscription = profile.subscription {
                    ProfileSubscriptionStatus(
                        subscription: subscription,
                        presentation: presentation,
                        isUpdating: model.isUpdatingSubscription,
                        update: model.updateSubscription,
                        cancel: model.cancelSubscriptionUpdate
                    )
                }
                ProfileFeedback(
                    diagnostic: model.diagnostic,
                    subscriptionFailure: model.subscriptionFailureDiagnostic,
                    messageKey: model.messageKey
                )
                if profile.subscription != nil {
                    Divider()
                }
                policySummary
            }
            .frame(maxWidth: ProfileWorkspaceLayout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(20)
        }
        .accessibilityIdentifier("profile.workspace.overview")
    }

    private var policySummary: some View {
        Button(action: showProxies) {
            HStack(spacing: 12) {
                Image(systemName: policySummarySymbol)
                    .font(.title3)
                    .foregroundStyle(policySummaryTint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("profile.overview.nodes.title")
                        .font(.callout.weight(.medium))
                    Group {
                        if policyPresentation.restartRequiredCount > 0 {
                            Text("policy.catalog.restart-required")
                        } else if policyPresentation.hasIssues {
                            Text("profile.overview.policy.issues")
                        } else if model.isPolicyCatalogUnavailable {
                            Text("policy.catalog.unavailable.title")
                        } else if policyPresentation.selectorCount == 0 {
                            Text("policy.catalog.empty.title")
                        } else {
                            Text("profile.overview.policy.ready")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.overview.policy-summary")
        .accessibilityHint(Text("profile.overview.policy.open.hint"))
    }

    private var policySummarySymbol: String {
        if policyPresentation.restartRequiredCount > 0 { return "arrow.clockwise.circle.fill" }
        if policyPresentation.hasIssues || model.isPolicyCatalogUnavailable { return "exclamationmark.triangle.fill" }
        if policyPresentation.selectorCount == 0 { return "point.3.connected.trianglepath.dotted" }
        return "checkmark.circle.fill"
    }

    private var policySummaryTint: Color {
        if policyPresentation.restartRequiredCount > 0
            || policyPresentation.hasIssues
            || model.isPolicyCatalogUnavailable {
            return .orange
        }
        return policyPresentation.selectorCount == 0 ? .secondary : .green
    }
}

struct ProfileSummaryHeader: View {
    let profile: Profile
    let lifecycle: BackendLifecycleModel?
    let participatingProfileCount: Int
    let countryCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("profile.smart-routing.title")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("profile.summary.name")
                    HStack(spacing: 8) {
                        Text(String(
                            format: String(localized: "profile.smart-routing.summary.format"),
                            participatingProfileCount,
                            countryCount
                        ))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Label(profile.name, systemImage: "point.3.connected.trianglepath.dotted")
                            .lineLimit(1)
                            .help(profile.name)
                            .accessibilityIdentifier("profile.summary.source")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
            }
            if let lifecycle {
                ProfileRuntimeControls(lifecycle: lifecycle)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.workspace.summary")
    }
}

struct ProfileRuntimeControls: View {
    let lifecycle: BackendLifecycleModel

    private var systemProxyEnabled: Bool {
        [.enabling, .enabled].contains(lifecycle.systemProxyStatus.state)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                engineButton
                systemProxyButton
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                engineButton
                systemProxyButton
            }
        }
    }

    private var engineButton: some View {
        Button(action: performEngineAction) {
            HStack(spacing: 11) {
                Image(systemName: engineSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engineActionKey)
                        .font(.callout.weight(.semibold))
                    Text(lifecycle.isEngineRunning ? "engine.status.running" : "engine.status.stopped")
                        .font(.caption)
                        .opacity(0.78)
                }
                Spacer(minLength: 10)
            }
            .frame(minWidth: 190, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 5)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(lifecycle.isBusy || !hasEngineAction)
        .help(Text(engineActionKey))
        .accessibilityIdentifier("profile.engine-action")
    }

    private var systemProxyButton: some View {
        Button(action: toggleSystemProxy) {
            HStack(spacing: 11) {
                Image(systemName: systemProxyEnabled ? "network.badge.shield.half.filled" : "network")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("system-proxy.action.toggle")
                        .font(.callout.weight(.semibold))
                    Text(systemProxyEnabled ? "system-proxy.status.enabled" : "system-proxy.status.disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: systemProxyEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(systemProxyEnabled ? Color.green : Color.secondary)
            }
            .frame(minWidth: 210, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(systemProxyEnabled ? .green : .accentColor)
        .disabled(systemProxyEnabled ? !lifecycle.canDisableSystemProxy : !lifecycle.canEnableSystemProxy)
        .help(Text(systemProxyEnabled ? "system-proxy.action.disable" : "system-proxy.action.enable"))
        .accessibilityIdentifier("profile.system-proxy-action")
    }

    private var hasEngineAction: Bool {
        lifecycle.canStart || lifecycle.canStop || lifecycle.canRestart || lifecycle.canInstallEngine
    }

    private var engineSymbol: String {
        if lifecycle.canStop { return "stop.fill" }
        if lifecycle.canRestart { return "arrow.clockwise" }
        if lifecycle.canInstallEngine { return "arrow.down.circle" }
        return "play.fill"
    }

    private var engineActionKey: LocalizedStringKey {
        if lifecycle.canStop { return "profile.connection.stop" }
        if lifecycle.canRestart { return "dashboard.action.restart" }
        if lifecycle.canInstallEngine { return "engine.action.install" }
        return "profile.connection.start"
    }

    private func performEngineAction() {
        if lifecycle.canStop { lifecycle.stop() }
        else if lifecycle.canRestart { lifecycle.restartWithCurrentProfile() }
        else if lifecycle.canStart { lifecycle.start() }
        else if lifecycle.canInstallEngine { lifecycle.installEngine() }
    }

    private func toggleSystemProxy() {
        if systemProxyEnabled { lifecycle.disableSystemProxy() }
        else { lifecycle.enableSystemProxy() }
    }
}
