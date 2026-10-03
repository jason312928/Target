import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileConnectionsSidebarPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Color.accentColor)
                    Text("connections.title")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text("0")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("connections.sidebar.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 15)
            .padding(.bottom, 12)
            Divider()
            Text("connections.empty.message")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(22)
            Spacer()
        }
        .background(.background.secondary)
        .accessibilityIdentifier("connections.sidebar")
    }
}

struct ProfileWorkspaceEmptyState: View {
    let isPreparingImport: Bool
    let messageKey: String?

    var body: some View {
        TargetPageLayout {
            TargetPageHeader("profile.title", subtitleKey: "profile.empty.subtitle")
            ContentUnavailableView(
                "profile.empty.title",
                systemImage: "doc.text",
                description: Text("profile.empty.description")
            )
            .accessibilityIdentifier("profile.workspace.empty")
            if isPreparingImport {
                ProgressView("profile.import.preparing")
                    .accessibilityIdentifier("profile.workspace.busy")
            }
            if let messageKey {
                TargetNotice(level: .warning, messageKey: messageKey)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("profile.workspace")
    }
}

struct ProfileWorkspaceDetailView: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel
    let lifecycle: BackendLifecycleModel?
    @Binding var section: ProfileWorkspaceSection
    let participatingProfileCount: Int
    let participatingCountryRoutes: [PolicyCountryRoute]
    let inspectCountry: (String) -> Void
    let chooseParticipatingCountry: (String) -> Void
    let bindRoute: (URL, String, String) -> Void
    private var presentation: ProfileWorkspacePresentation { ProfileWorkspacePresentation(profile: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSummaryHeader(
                profile: profile,
                lifecycle: lifecycle,
                participatingProfileCount: participatingProfileCount,
                countryCount: participatingCountryRoutes.count
            )
                .frame(maxWidth: ProfileWorkspaceLayout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if section != .proxies {
                auxiliaryNavigation
            }
            sectionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Target")
        .overlay(alignment: .top) {
            if model.isPreparingImport || model.isCommittingImport {
                ProgressView(model.isCommittingImport ? "profile.import.committing" : "profile.import.preparing")
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("profile.workspace.busy")
                }
        }
        .onChange(of: lifecycle?.status) { _, _ in
            model.invalidatePolicyHealth()
        }
    }

    private var auxiliaryNavigation: some View {
        HStack(spacing: 10) {
            Button {
                section = .proxies
            } label: {
                Label("profile.workspace.back-to-nodes", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("profile.workspace.back-to-nodes")
            Spacer()
            Label(LocalizedStringKey(section.titleKey), systemImage: section.symbolName)
                .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: ProfileWorkspaceLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .overview:
            ProfileOverviewView(
                profile: profile,
                model: model,
                presentation: presentation,
                showProxies: { section = .proxies }
            )
        case .proxies:
            ProfilePolicyWorkspaceView(
                catalog: model.policyCatalog,
                unavailable: model.isPolicyCatalogUnavailable,
                isSelecting: model.isSelectingPolicy,
                healthBySelector: model.policyHealthBySelector,
                testingSelectorID: model.testingPolicySelectorID,
                lifecycle: lifecycle,
                participatingCountryRoutes: participatingCountryRoutes,
                inspectCountry: inspectCountry,
                chooseParticipatingCountry: chooseParticipatingCountry,
                routeBindings: profile.routeBindings,
                bindRoute: bindRoute,
                removeRouteBinding: model.removeRouteBinding,
                select: model.selectPolicy,
                probeLatency: model.probePolicyLatency,
                reset: model.resetPolicy,
                refresh: model.refreshPolicyState,
                openConfiguration: { section = .configuration }
            )
        case .configuration:
            ProfileConfigurationView(
                profile: profile,
                model: model
            )
        }
    }
}

enum ProfileWorkspaceSection: String, Identifiable {
    case overview
    case proxies
    case configuration

    var id: String { rawValue }
    var titleKey: String { "profile.workspace.section.\(rawValue)" }
    var symbolName: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .configuration: "curlybraces"
        }
    }
}
