import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SelectorDetail: View {
    let selector: PolicySelectorPresentation
    let isSelecting: Bool
    let canRestart: Bool
    let lifecycleBusy: Bool
    let query: String
    let exposesSelectorAccessibilityIdentity: Bool
    let participatingCountryRoutes: [PolicyCountryRoute]?
    let chooseParticipatingCountry: ((String) -> Void)?
    let inspectCountry: (PolicyCountryRoute) -> Void
    let routeBindings: [ProfileRouteBinding]
    let availableRouteOutboundTags: Set<String>
    let bindRoute: ((URL, String, String) -> Void)?
    let removeRouteBinding: ((String) -> Void)?
    let select: (String, String) -> Void
    let restart: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var pendingSelection: String?
    @SceneStorage("policy.workspace.countries-expanded") private var countriesExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if selector.members.isEmpty {
                    emptySelectorState
                } else {
                    siteRoutes
                    if selector.restartRequired || selector.runtime.state == .unavailable {
                        runtimeSummary
                    }
                    destinations
                }
            }
            .frame(maxWidth: ProfileWorkspaceLayout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(20)
        }
        .onChange(of: isSelecting) { wasSelecting, selecting in
            if wasSelecting && !selecting {
                pendingSelection = nil
            }
        }
        .onChange(of: query) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    countriesExpanded = true
                }
            }
        }
    }

    private var emptySelectorState: some View {
        ContentUnavailableView(
            "policy.workspace.members.empty.title",
            systemImage: "server.rack",
            description: Text("policy.workspace.members.empty.description")
        )
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.vertical, 30)
        .accessibilityIdentifier("policy.workspace.members.empty")
    }

    @ViewBuilder
    private var runtimeSummary: some View {
        switch selector.runtime.state {
        case .converged:
            EmptyView()
        case .notRunning:
            Label(LocalizedStringKey(selector.runtime.detailKey), systemImage: selector.runtime.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .restartRequired, .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Label(LocalizedStringKey(selector.runtime.titleKey), systemImage: selector.runtime.symbolName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selector.runtime.level.tint)
                Text(LocalizedStringKey(selector.runtime.detailKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if selector.restartRequired && canRestart {
                    Button("policy.workspace.restart-to-apply", action: restart)
                        .buttonStyle(.borderedProminent)
                        .disabled(lifecycleBusy || isSelecting)
                        .accessibilityIdentifier("policy.workspace.restart-to-apply")
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var filteredMembers: [PolicyMemberPresentation] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return selector.members }
        return selector.members.filter {
            $0.tag.lowercased().contains(normalized)
                || ($0.type?.lowercased().contains(normalized) == true)
        }
    }

    private var selectedMemberTag: String? {
        pendingSelection ?? selector.desiredSelection
    }

    private var filteredCountryRoutes: [PolicyCountryRoute] {
        let routes = participatingCountryRoutes ?? selector.countryRoutes
        return routes.filter { $0.matches(query: query) }
    }

    private var filteredMapCountryRoutes: [PolicyCountryRoute] {
        let routes = participatingCountryRoutes ?? selector.countryRoutes
        return routes.filter { $0.matches(query: query) }
    }

    private var filteredUnclassifiedMembers: [PolicyMemberPresentation] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return selector.unclassifiedMembers }
        return selector.unclassifiedMembers.filter {
            $0.tag.lowercased().contains(normalized)
                || ($0.type?.lowercased().contains(normalized) == true)
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selector.members.isEmpty {
                ContentUnavailableView(
                    "policy.workspace.members.empty.title",
                    systemImage: "server.rack",
                    description: Text("policy.workspace.members.empty.description")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityIdentifier("policy.workspace.members.empty")
            } else if filteredMapCountryRoutes.isEmpty && filteredUnclassifiedMembers.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityIdentifier("policy.workspace.members.empty")
            } else if !filteredMapCountryRoutes.isEmpty {
                CountryRouteMap(
                    routes: filteredMapCountryRoutes,
                    selectedMemberTag: selectedMemberTag,
                    bindings: routeBindings,
                    bind: bindURL,
                    inspect: inspectCountry,
                    choose: { route in
                        if let chooseParticipatingCountry {
                            chooseParticipatingCountry(route.id)
                        } else {
                            chooseCountry(route)
                        }
                    }
                )
                if !filteredCountryRoutes.isEmpty {
                    countryRoutesSection
                }
                if !filteredUnclassifiedMembers.isEmpty {
                    unclassifiedMembers
                }
            } else {
                memberGrid(filteredMembers)
            }
        }
    }

    private var countryRoutesSection: some View {
        DisclosureGroup(isExpanded: $countriesExpanded) {
            CountryRouteGrid(
                routes: filteredCountryRoutes,
                selectedMemberTag: selectedMemberTag,
                bindings: routeBindings,
                bind: bindURL,
                inspect: inspectCountry,
                choose: { route in
                    if let chooseParticipatingCountry {
                        chooseParticipatingCountry(route.id)
                    } else {
                        chooseCountry(route)
                    }
                }
            )
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe.europe.africa")
                    .foregroundStyle(Color.accentColor)
                Text("policy.workspace.country-list")
                    .font(.callout.weight(.semibold))
                Text("\(filteredCountryRoutes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .padding(.top, 4)
        .accessibilityIdentifier("policy.workspace.country-list.disclosure")
    }

    private var unclassifiedMembers: some View {
        DisclosureGroup {
            memberGrid(filteredUnclassifiedMembers)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                Text("policy.workspace.other-nodes")
                Text("\(filteredUnclassifiedMembers.count)")
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(.medium))
        }
        .padding(.top, 8)
    }

    private func memberGrid(_ members: [PolicyMemberPresentation]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 430), spacing: 22)],
            alignment: .leading,
            spacing: 2
        ) {
            ForEach(members) { member in
                MemberRow(
                    member: member,
                    selectorID: selector.id,
                    isDesired: selectedMemberTag == member.tag,
                    isSelecting: isSelecting,
                    choose: { chooseMember(member) }
                )
            }
        }
    }

    private func chooseCountry(_ route: PolicyCountryRoute) {
        guard let member = route.bestMember else { return }
        chooseMember(member)
    }

    private func chooseMember(_ member: PolicyMemberPresentation) {
        guard let selectorTag = selector.tag, member.isSelectable else { return }
        pendingSelection = member.tag
        select(selectorTag, member.tag)
    }

    private var siteRoutes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("profile.route.title", systemImage: "link")
                    .font(.headline)
                Text("\(routeBindings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("profile.route.drop-hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if routeBindings.isEmpty {
                Text("profile.route.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(routeBindings) { binding in
                        RouteBindingChip(
                            binding: binding,
                            isAvailable: availableRouteOutboundTags.contains(binding.outboundTag)
                        ) {
                            removeRouteBinding?(binding.domain)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("profile.route.bindings")
    }

    private func bindURL(_ url: URL, to route: PolicyCountryRoute) {
        guard let member = route.bestMember else { return }
        bindRoute?(url, route.country.code, member.tag)
    }

}
