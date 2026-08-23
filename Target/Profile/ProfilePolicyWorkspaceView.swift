import Foundation
import SwiftUI

struct ProfilePolicyWorkspaceView: View {
    let catalog: PolicyCatalog?
    let unavailable: Bool
    let isSelecting: Bool
    let healthBySelector: [Int: [String: RuntimeProxyHealth]]
    let testingSelectorID: Int?
    let lifecycle: BackendLifecycleModel?
    let select: (String, String) -> Void
    let probeLatency: (Int, String) -> Void
    let reset: () -> Void
    let refresh: () -> Void
    let openConfiguration: () -> Void

    @State private var selectedSelectorID: Int?
    @State private var query = ""

    private var presentation: PolicyWorkspacePresentation {
        PolicyWorkspacePresentation(
            catalog: catalog,
            unavailable: unavailable,
            healthBySelector: healthBySelector
        )
    }

    private var selectedSelector: PolicySelectorPresentation? {
        if let selectedSelectorID,
           let selected = presentation.selectors.first(where: { $0.id == selectedSelectorID }) {
            return selected
        }
        return presentation.selectors.first
    }

    var body: some View {
        Group {
            if unavailable {
                PolicyCatalogState(
                    titleKey: "policy.catalog.unavailable.title",
                    symbol: "lock.trianglebadge.exclamationmark",
                    descriptionKey: "policy.catalog.unavailable.description",
                    accessibilityIdentifier: "policy.catalog.unavailable",
                    actionTitleKey: "policy.workspace.refresh",
                    action: refresh
                )
            } else if presentation.selectors.isEmpty {
                PolicyCatalogState(
                    titleKey: "policy.catalog.empty.title",
                    symbol: "point.3.connected.trianglepath.dotted",
                    descriptionKey: "policy.catalog.empty.description",
                    accessibilityIdentifier: "policy.catalog.empty",
                    actionTitleKey: "profile.action.edit-configuration",
                    actionAccessibilityIdentifier: "policy.catalog.empty.open-configuration",
                    action: openConfiguration
                )
            } else {
                proxyWorkspace
            }
        }
        .onChange(of: presentation.selectors.map(\.id)) { _, ids in
            if selectedSelectorID.map({ ids.contains($0) }) != true {
                selectedSelectorID = ids.first
            }
        }
        .task {
            if selectedSelectorID == nil { selectedSelectorID = presentation.selectors.first?.id }
        }
    }

    private var proxyWorkspace: some View {
        VStack(spacing: 0) {
            routeToolbar
            selectorDetail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var routeToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                selectorMenu
                Spacer(minLength: 12)
                searchField.frame(width: 220)
                latencyButton
                policyActionsMenu
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    selectorMenu
                    Spacer(minLength: 8)
                    latencyButton
                    policyActionsMenu
                }
                searchField.frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: ProfileWorkspaceLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var searchField: some View {
        TextField("policy.workspace.search", text: $query)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("policy.workspace.search")
    }

    @ViewBuilder
    private var latencyButton: some View {
        if let selector = selectedSelector,
           latencyActionIsAvailable(for: selector) || testingSelectorID == selector.id {
            Button {
                guard let tag = selector.tag else { return }
                probeLatency(selector.id, tag)
            } label: {
                Image(systemName: testingSelectorID == selector.id ? "hourglass" : "gauge.with.dots.needle.50percent")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!latencyActionIsAvailable(for: selector))
            .help(Text(selector.hasHealthResults ? "policy.health.probe-again" : "policy.health.test-latency"))
            .accessibilityLabel(Text(selector.hasHealthResults ? "policy.health.probe-again" : "policy.health.test-latency"))
            .accessibilityIdentifier("policy.health.test-latency")
        }
    }

    private var policyActionsMenu: some View {
        Menu {
            Button("policy.workspace.refresh", systemImage: "arrow.clockwise", action: refresh)
                .disabled(isSelecting || lifecycle?.isBusy == true)
                .accessibilityIdentifier("policy.workspace.refresh")
            if presentation.overrideCount > 0 {
                Divider()
                Button("policy.catalog.reset", systemImage: "arrow.uturn.backward", action: reset)
                    .disabled(isSelecting)
                    .accessibilityIdentifier("policy.catalog.reset")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text("policy.workspace.actions"))
        .accessibilityIdentifier("policy.workspace.actions")
    }

    @ViewBuilder
    private var selectorMenu: some View {
        if let selector = selectedSelector {
            Group {
                if presentation.selectors.count > 1 {
                    Menu {
                        ForEach(presentation.selectors) { selector in
                            Button {
                                selectedSelectorID = selector.id
                            } label: {
                                if selectedSelectorID == selector.id {
                                    Label(selector.displayTag, systemImage: "checkmark")
                                } else {
                                    Text(selector.displayTag)
                                }
                            }
                            .accessibilityIdentifier("policy.catalog.selector.\(selector.id)")
                        }
                    } label: {
                        selectorLabel(selector, showsDisclosure: true)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    selectorLabel(selector, showsDisclosure: false)
                }
            }
            .accessibilityIdentifier("policy.workspace.selectors")
            .accessibilityLabel(Text(verbatim: selector.displayTag))
            .accessibilityValue(selector.accessibilityValue(isSelected: true))
        }
    }

    private func selectorLabel(
        _ selector: PolicySelectorPresentation,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Color.accentColor)
            Text(selector.displayTag)
                .font(.headline)
                .lineLimit(1)
            Text("\(selector.memberCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if showsDisclosure {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func latencyActionIsAvailable(for selector: PolicySelectorPresentation) -> Bool {
        PolicyLatencyActionAvailability.isAvailable(
            engineIsRunning: lifecycle?.isEngineRunning == true,
            isTestingLatency: testingSelectorID == selector.id,
            lifecycleBusy: lifecycle?.isBusy == true,
            selectorTag: selector.tag,
            hasSelectableMembers: selector.members.contains(where: \.isSelectable)
        )
    }

    @ViewBuilder
    private var selectorDetail: some View {
        if let selector = selectedSelector {
            SelectorDetail(
                selector: selector,
                isSelecting: isSelecting,
                canRestart: lifecycle?.canRestart == true,
                lifecycleBusy: lifecycle?.isBusy == true,
                query: query,
                exposesSelectorAccessibilityIdentity: presentation.selectors.count == 1,
                select: select,
                restart: { lifecycle?.restartWithCurrentProfile() }
            )
            .id(selector.id)
        } else {
            ContentUnavailableView(
                "policy.workspace.search.empty.title",
                systemImage: "magnifyingglass",
                description: Text("policy.workspace.search.empty.description")
            )
        }
    }
}

private extension PolicySelectorPresentation {
    func accessibilityValue(isSelected: Bool) -> Text {
        var value = Text("policy.workspace.member-count") + Text(verbatim: ": \(memberCount)")
        if isSelected {
            value = value + Text(verbatim: ", ") + Text("policy.workspace.filter.selected")
        }
        if let configuredDefault {
            value = value + Text(verbatim: ", ")
                + Text("policy.catalog.configured-default") + Text(verbatim: ": \(configuredDefault)")
        }
        if let desiredSelection {
            value = value + Text(verbatim: ", ")
                + Text("policy.catalog.desired-selection") + Text(verbatim: ": \(desiredSelection)")
        }
        if let runningSelection, runningSelection != desiredSelection {
            value = value + Text(verbatim: ", ")
                + Text("policy.catalog.running-selection") + Text(verbatim: ": \(runningSelection)")
        }
        if restartRequired {
            value = value + Text(verbatim: ", ") + Text("policy.catalog.restart-required")
        }
        value = value + Text(verbatim: ", ") + Text(LocalizedStringKey(runtime.titleKey))
        if let statusKey {
            value = value + Text(verbatim: ", ") + Text(LocalizedStringKey(statusKey))
        }
        return value
    }
}

private struct SelectorDetail: View {
    let selector: PolicySelectorPresentation
    let isSelecting: Bool
    let canRestart: Bool
    let lifecycleBusy: Bool
    let query: String
    let exposesSelectorAccessibilityIdentity: Bool
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
                    currentRoute
                    runtimeSummary
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

    private var currentRoute: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("policy.workspace.current-selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let currentCountry {
                    HStack(spacing: 7) {
                        Text(currentCountry.flag)
                        Text(currentCountry.displayName(localeIdentifier: locale.identifier))
                    }
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .help(Text(verbatim: selectedMemberTag ?? currentCountry.englishName))
                } else {
                    Text(selectedMemberTag ?? "—")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if isSelecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("policy.catalog.selection.saving"))
            } else if let statusKey = selector.statusKey {
                Label(LocalizedStringKey(statusKey), systemImage: selector.statusSymbol)
                    .font(.caption)
                    .foregroundStyle(selector.statusLevel.tint)
            } else {
                Label(LocalizedStringKey(selector.runtime.titleKey), systemImage: selector.runtime.symbolName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(selector.runtime.level.tint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 34)
                .padding(.leading, 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            exposesSelectorAccessibilityIdentity
                ? "policy.catalog.selector.\(selector.id)"
                : "policy.workspace.selector-detail"
        )
        .accessibilityLabel(Text(verbatim: selector.displayTag))
        .accessibilityValue(selector.accessibilityValue(isSelected: true))
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedMemberTag)
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

    private var currentCountry: PolicyRouteCountry? {
        guard let selectedMemberTag else { return nil }
        let member = selector.members.first(where: { $0.tag == selectedMemberTag })
        return PolicyRouteCountry.recognize(in: selectedMemberTag, endpoint: member?.endpoint)
    }

    private var filteredCountryRoutes: [PolicyCountryRoute] {
        selector.countryRoutes.filter { $0.matches(query: query) }
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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selector.countryRoutes.isEmpty ? "policy.workspace.choose-route" : "policy.workspace.choose-country")
                        .font(.headline)
                    (Text(selector.countryRoutes.isEmpty ? "policy.workspace.nodes" : "policy.workspace.countries")
                        + Text(" · \(selector.countryRoutes.isEmpty ? filteredMembers.count : filteredCountryRoutes.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if selector.members.isEmpty {
                ContentUnavailableView(
                    "policy.workspace.members.empty.title",
                    systemImage: "server.rack",
                    description: Text("policy.workspace.members.empty.description")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityIdentifier("policy.workspace.members.empty")
            } else if filteredCountryRoutes.isEmpty && filteredUnclassifiedMembers.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityIdentifier("policy.workspace.members.empty")
            } else if !filteredCountryRoutes.isEmpty {
                CountryRouteMap(
                    routes: filteredCountryRoutes,
                    selectedMemberTag: selectedMemberTag,
                    choose: chooseCountry
                )
                countryRoutesSection
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
                choose: chooseCountry
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

}

private struct CountryRouteMap: View {
    let routes: [PolicyCountryRoute]
    let selectedMemberTag: String?
    let choose: (PolicyCountryRoute) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hoveredCountryCode: String?

    private var selectedCountryCode: String? {
        routes.first(where: { route in
            route.members.contains(where: { $0.tag == selectedMemberTag })
        })?.id
    }

    private var selectionAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06)
    }

    var body: some View {
        GeometryReader { proxy in
            let focus = FlatMapFocus.world
            let placements = Self.markerPlacements(
                for: routes,
                selectedCountryCode: selectedCountryCode,
                in: proxy.size,
                focus: focus
            )
            ZStack {
                FlatWorldArtwork()
                    .equatable()
                markerConnectors(placements)
                ForEach(routes) { route in
                    countryButton(route)
                        .position(placements[route.id]?.marker ?? Self.point(for: route.country, in: proxy.size, focus: focus))
                        .zIndex(route.id == selectedCountryCode ? 1 : 0)
                }
            }
            .animation(selectionAnimation, value: selectedCountryCode)
        }
        .frame(maxWidth: 860)
        .frame(height: 360)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("policy.workspace.country-map")
    }

    private func markerConnectors(_ placements: [String: MapMarkerPlacement]) -> some View {
        ZStack {
            ForEach(routes) { route in
                if let placement = placements[route.id] {
                    MapMarkerConnector(anchor: placement.anchor, marker: placement.marker)
                        .stroke(Color.primary.opacity(0.13), lineWidth: 0.8)
                    Circle()
                        .fill(Color.primary.opacity(0.24))
                        .frame(width: 3, height: 3)
                        .position(placement.anchor)
                        .opacity(placement.isDisplaced ? 1 : 0)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func countryButton(_ route: PolicyCountryRoute) -> some View {
        let isSelected = route.members.contains(where: { $0.tag == selectedMemberTag })
        let isHovered = hoveredCountryCode == route.id
        return Button {
            choose(route)
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                    .frame(width: isSelected ? 28 : 24, height: isSelected ? 28 : 24)
                    .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: 3, y: 1)
                Text(route.country.flag)
                    .font(.system(size: isSelected ? 14 : 12))
            }
            .frame(width: 34, height: 34)
            .overlay {
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.22 : 0.08), lineWidth: isSelected ? 2 : 1)
                    .frame(width: isSelected ? 34 : 28, height: isSelected ? 34 : 28)
            }
            .animation(selectionAnimation, value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .compositingGroup()
        }
        .buttonStyle(SoftPressButtonStyle(pressedScale: 0.94, reduceMotion: accessibilityReduceMotion))
        .disabled(route.bestMember == nil)
        .onHover { hovering in
            hoveredCountryCode = hovering ? route.id : nil
        }
        .help("\(route.country.displayName(localeIdentifier: locale.identifier)) · \(route.members.count) \(String(localized: "policy.workspace.nodes"))")
        .accessibilityLabel(Text(verbatim: route.country.displayName(localeIdentifier: locale.identifier)))
        .accessibilityValue(countryAccessibilityValue(route, selected: isSelected))
        .accessibilityHint(Text("policy.workspace.country.choose.hint"))
        .accessibilityIdentifier("policy.workspace.country.\(route.id)")
    }

    private func countryAccessibilityValue(_ route: PolicyCountryRoute, selected: Bool) -> Text {
        var value = Text("policy.workspace.member-count") + Text(verbatim: ": \(route.members.count)")
        if let latency = route.bestLatencyMilliseconds {
            value = value + Text(verbatim: ", ") + Text("policy.health.latency")
                + Text(verbatim: ": \(latency) ") + Text("policy.health.milliseconds")
        }
        if selected {
            value = value + Text(verbatim: ", ") + Text("policy.workspace.filter.selected")
        }
        return value
    }

    private static func point(for country: PolicyRouteCountry, in size: CGSize, focus: FlatMapFocus) -> CGPoint {
        FlatMapProjection.point(for: country, in: size, focus: focus)
    }

    private static func markerPlacements(
        for routes: [PolicyCountryRoute],
        selectedCountryCode: String?,
        in size: CGSize,
        focus: FlatMapFocus
    ) -> [String: MapMarkerPlacement] {
        var placed: [CGPoint] = []
        var placements: [String: MapMarkerPlacement] = [:]
        let offsets: [CGSize] = [
            .zero,
            CGSize(width: 30, height: 0), CGSize(width: -30, height: 0),
            CGSize(width: 22, height: -24), CGSize(width: -22, height: -24),
            CGSize(width: 22, height: 24), CGSize(width: -22, height: 24),
            CGSize(width: 0, height: -32), CGSize(width: 0, height: 32),
            CGSize(width: 44, height: -16), CGSize(width: -44, height: -16),
            CGSize(width: 44, height: 16), CGSize(width: -44, height: 16)
        ]
        let mapBounds = FlatMapProjection.rect(in: size)
        let orderedRoutes = routes.sorted { $0.country.englishName < $1.country.englishName }

        // Establish a selection-independent layout first. Changing countries can
        // then move only the markers that actually collide with the new anchor.
        for route in orderedRoutes {
            let base = point(for: route.country, in: size, focus: focus)
            let candidate = markerCandidates(anchor: base, offsets: offsets, bounds: mapBounds)
                .first(where: { isAvailable($0, avoiding: placed) })
                ?? clamped(base, to: mapBounds)
            placements[route.id] = MapMarkerPlacement(anchor: base, marker: candidate)
            placed.append(candidate)
        }

        guard let selectedCountryCode,
              let selectedRoute = orderedRoutes.first(where: { $0.id == selectedCountryCode }) else {
            return placements
        }

        let selectedAnchor = point(for: selectedRoute.country, in: size, focus: focus)
        let affectedRoutes = orderedRoutes.filter { route in
            guard route.id != selectedCountryCode, let placement = placements[route.id] else { return false }
            return distance(placement.marker, selectedAnchor) < 31
        }
        let affectedIDs = Set(affectedRoutes.map(\.id))
        var occupied = [selectedAnchor]
        occupied.append(contentsOf: orderedRoutes.compactMap { route in
            guard route.id != selectedCountryCode,
                  !affectedIDs.contains(route.id) else { return nil }
            return placements[route.id]?.marker
        })

        placements[selectedCountryCode] = MapMarkerPlacement(anchor: selectedAnchor, marker: selectedAnchor)
        for route in affectedRoutes {
            let anchor = point(for: route.country, in: size, focus: focus)
            let previous = placements[route.id]?.marker
            let candidates = (previous.map { [$0] } ?? [])
                + markerCandidates(anchor: anchor, offsets: offsets, bounds: mapBounds)
            let marker = candidates.first(where: { isAvailable($0, avoiding: occupied) })
                ?? clamped(anchor, to: mapBounds)
            placements[route.id] = MapMarkerPlacement(anchor: anchor, marker: marker)
            occupied.append(marker)
        }
        return placements
    }

    private static func markerCandidates(anchor: CGPoint, offsets: [CGSize], bounds: CGRect) -> [CGPoint] {
        offsets.map { offset in
            clamped(CGPoint(x: anchor.x + offset.width, y: anchor.y + offset.height), to: bounds)
        }
    }

    private static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX + 18), bounds.maxX - 18),
            y: min(max(point.y, bounds.minY + 18), bounds.maxY - 18)
        )
    }

    private static func isAvailable(_ point: CGPoint, avoiding occupied: [CGPoint]) -> Bool {
        occupied.allSatisfy { distance($0, point) >= 31 }
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private struct MapMarkerPlacement {
    let anchor: CGPoint
    let marker: CGPoint

    var isDisplaced: Bool {
        hypot(marker.x - anchor.x, marker.y - anchor.y) > 2
    }
}

private struct MapMarkerConnector: Shape {
    var anchor: CGPoint
    var marker: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(anchor.x, anchor.y),
                AnimatablePair(marker.x, marker.y)
            )
        }
        set {
            anchor = CGPoint(x: newValue.first.first, y: newValue.first.second)
            marker = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: anchor)
        path.addLine(to: marker)
        return path
    }
}

private struct SoftPressButtonStyle: ButtonStyle {
    let pressedScale: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct CountryRouteGrid: View {
    let routes: [PolicyCountryRoute]
    let selectedMemberTag: String?
    let choose: (PolicyCountryRoute) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(routes) { route in
                CountryRouteCard(
                    route: route,
                    selectedMemberTag: selectedMemberTag,
                    localeIdentifier: locale.identifier,
                    choose: { choose(route) }
                )
            }
        }
        .accessibilityIdentifier("policy.workspace.country-list")
    }
}

private struct CountryRouteCard: View {
    let route: PolicyCountryRoute
    let selectedMemberTag: String?
    let localeIdentifier: String
    let choose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false

    private var isSelected: Bool {
        route.members.contains(where: { $0.tag == selectedMemberTag })
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 11) {
                Text(route.country.flag)
                    .font(.system(size: 22))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(isSelected ? 0.16 : 0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(route.country.displayName(localeIdentifier: localeIdentifier))
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(route.members.count) \(String(localized: "policy.workspace.nodes"))")
                        if let latency = route.bestLatencyMilliseconds {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Label("\(latency) ms", systemImage: "gauge.with.dots.needle.33percent")
                                .foregroundStyle(latencyTint(latency))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering || isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.09), lineWidth: isSelected ? 1.5 : 1)
            }
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
            .animation(
                accessibilityReduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
                value: isSelected
            )
        }
        .buttonStyle(SoftPressButtonStyle(pressedScale: 0.985, reduceMotion: accessibilityReduceMotion))
        .onHover { isHovering = $0 }
        .help(Text("policy.workspace.country.choose.hint"))
        .accessibilityLabel(Text(verbatim: route.country.displayName(localeIdentifier: localeIdentifier)))
        .accessibilityValue(Text("\(route.members.count) \(String(localized: "policy.workspace.nodes"))"))
        .accessibilityHint(Text("policy.workspace.country.choose.hint"))
        .accessibilityIdentifier("policy.workspace.country-card.\(route.id)")
    }

    private func latencyTint(_ latency: Int) -> Color {
        if latency < 160 { return .green }
        if latency < 360 { return .orange }
        return .red
    }
}

private struct FlatMapCoordinate {
    let latitude: Double
    let longitude: Double
}

private struct FlatMapFocus: Equatable {
    let latitude: ClosedRange<Double>
    let longitude: ClosedRange<Double>

    static let world = FlatMapFocus(latitude: -90...90, longitude: -180...180)

    var latitudeSpan: Double { latitude.upperBound - latitude.lowerBound }
    var longitudeSpan: Double { longitude.upperBound - longitude.lowerBound }
}

private enum FlatMapProjection {
    static func rect(in size: CGSize) -> CGRect {
        let horizontalPadding = min(size.width * 0.03, 22)
        let verticalPadding = min(size.height * 0.12, 24)
        return CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: max(size.width - horizontalPadding * 2, 1),
            height: max(size.height - verticalPadding * 2, 1)
        )
    }

    static func point(for country: PolicyRouteCountry, in size: CGSize, focus: FlatMapFocus? = nil) -> CGPoint {
        point(latitude: country.latitude, longitude: country.longitude, in: size, focus: focus)
    }

    static func point(latitude: Double, longitude: Double, in size: CGSize, focus: FlatMapFocus? = nil) -> CGPoint {
        let mapFocus = focus ?? .world
        let bounds = rect(in: size)
        let normalized = normalizedPoint(latitude: latitude, longitude: longitude, focus: mapFocus)
        return CGPoint(
            x: bounds.minX + normalized.x * bounds.width,
            y: bounds.minY + normalized.y * bounds.height
        )
    }

    static func normalizedPoint(latitude: Double, longitude: Double, focus: FlatMapFocus) -> CGPoint {
        CGPoint(
            x: (longitude - focus.longitude.lowerBound) / focus.longitudeSpan,
            y: (focus.latitude.upperBound - latitude) / focus.latitudeSpan
        )
    }
}

/// Loads the bundled Natural Earth topology once. Rendering all rings in one
/// fill keeps the detailed coastline while avoiding per-country seam artifacts.
private enum WorldMapGeometry {
    static let rings: [[FlatMapCoordinate]] = load()

    private static func load() -> [[FlatMapCoordinate]] {
        guard let url = Bundle.main.url(forResource: "countries-110m", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transform = root["transform"] as? [String: Any] else {
            return []
        }
        let scale = numbers(transform["scale"])
        let translate = numbers(transform["translate"])
        guard scale.count == 2, translate.count == 2 else { return [] }

        let arcs = arrays(root["arcs"]).map { rawArc in
            arrays(rawArc).compactMap { point -> [Double]? in
                let values = numbers(point)
                return values.count >= 2 ? values : nil
            }
        }
        guard !arcs.isEmpty,
              let objects = root["objects"] as? [String: Any],
              let countries = objects["countries"] as? [String: Any] else {
            return []
        }

        var rings: [[FlatMapCoordinate]] = []
        for rawGeometry in arrays(countries["geometries"]) {
            guard let geometry = rawGeometry as? [String: Any],
                  let type = geometry["type"] as? String else { continue }
            let rawGeometryArcs = arrays(geometry["arcs"])
            switch type {
            case "Polygon":
                appendRings(rawGeometryArcs, arcs: arcs, scale: scale, translate: translate, to: &rings)
            case "MultiPolygon":
                for rawPolygon in rawGeometryArcs {
                    appendRings(arrays(rawPolygon), arcs: arcs, scale: scale, translate: translate, to: &rings)
                }
            default:
                continue
            }
        }
        return rings
    }

    private static func appendRings(
        _ rawRings: [Any],
        arcs: [[[Double]]],
        scale: [Double],
        translate: [Double],
        to rings: inout [[FlatMapCoordinate]]
    ) {
        for rawRing in rawRings {
            let indexes = numbers(rawRing).map { Int($0.rounded()) }
            let ring = decode(indexes, arcs: arcs, scale: scale, translate: translate)
            if ring.count >= 3 { rings.append(ring) }
        }
    }

    private static func decode(
        _ indexes: [Int],
        arcs: [[[Double]]],
        scale: [Double],
        translate: [Double]
    ) -> [FlatMapCoordinate] {
        var points: [FlatMapCoordinate] = []
        for (position, encodedIndex) in indexes.enumerated() {
            let reversed = encodedIndex < 0
            let index = reversed ? ~encodedIndex : encodedIndex
            guard arcs.indices.contains(index) else { continue }
            var previousX = 0.0
            var previousY = 0.0
            var decodedArc: [FlatMapCoordinate] = []
            for rawPoint in arcs[index] where rawPoint.count >= 2 {
                previousX += rawPoint[0]
                previousY += rawPoint[1]
                decodedArc.append(FlatMapCoordinate(
                    latitude: previousY * scale[1] + translate[1],
                    longitude: previousX * scale[0] + translate[0]
                ))
            }
            if reversed { decodedArc.reverse() }
            if position > 0, !decodedArc.isEmpty { decodedArc.removeFirst() }
            points.append(contentsOf: decodedArc)
        }
        return points
    }

    private static func arrays(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func numbers(_ value: Any?) -> [Double] {
        arrays(value).compactMap { ($0 as? NSNumber)?.doubleValue }
    }
}

private struct FlatWorldArtwork: View, Equatable {
    private static let normalizedLand: Path = {
        let polygons = WorldMapGeometry.rings.isEmpty ? fallbackContinents : WorldMapGeometry.rings
        var land = Path()
        for polygon in polygons {
            append(polygon, to: &land)
        }
        return land
    }()

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let bounds = FlatMapProjection.rect(in: size)
            let transform = CGAffineTransform(translationX: bounds.minX, y: bounds.minY)
                .scaledBy(x: bounds.width, y: bounds.height)
            context.clip(to: Path(bounds))
            context.fill(
                Self.normalizedLand.applying(transform),
                with: .color(Color.primary.opacity(0.045)),
                style: FillStyle(eoFill: true)
            )
        }
        .accessibilityHidden(true)
    }

    private static func append(
        _ polygon: [FlatMapCoordinate],
        to path: inout Path
    ) {
        guard let first = polygon.first else { return }
        var unwrapped = [first]
        for coordinate in polygon.dropFirst() {
            var longitude = coordinate.longitude
            guard let previousLongitude = unwrapped.last?.longitude else { continue }
            while longitude - previousLongitude > 180 { longitude -= 360 }
            while longitude - previousLongitude < -180 { longitude += 360 }
            unwrapped.append(FlatMapCoordinate(latitude: coordinate.latitude, longitude: longitude))
        }

        let closureDelta = (unwrapped.last?.longitude ?? first.longitude) - first.longitude
        if abs(closureDelta) > 180 {
            appendPolarRing(unwrapped, closureDelta: closureDelta, to: &path)
            return
        }

        // Dateline-crossing islands and coastlines are drawn on both sides of
        // the flat map, then clipped. No segment ever connects +180 to -180.
        for offset in [-360.0, 0, 360.0] {
            appendRing(unwrapped, longitudeOffset: offset, to: &path)
        }
    }

    private static func appendPolarRing(
        _ polygon: [FlatMapCoordinate],
        closureDelta: Double,
        to path: inout Path
    ) {
        guard let first = polygon.first else { return }
        let pole = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count) < 0 ? -90.0 : 90.0
        appendOpenRing(polygon, longitudeOffset: 0, to: &path)
        let endingEdge = closureDelta > 0 ? 180.0 : -180.0
        let startingEdge = closureDelta > 0 ? -180.0 : 180.0
        path.addLine(to: normalizedPoint(latitude: pole, longitude: endingEdge))
        path.addLine(to: normalizedPoint(latitude: pole, longitude: startingEdge))
        path.addLine(to: normalizedPoint(latitude: first.latitude, longitude: first.longitude))
        path.closeSubpath()
    }

    private static func appendRing(
        _ polygon: [FlatMapCoordinate],
        longitudeOffset: Double,
        to path: inout Path
    ) {
        appendOpenRing(polygon, longitudeOffset: longitudeOffset, to: &path)
        path.closeSubpath()
    }

    private static func appendOpenRing(
        _ polygon: [FlatMapCoordinate],
        longitudeOffset: Double,
        to path: inout Path
    ) {
        for (index, coordinate) in polygon.enumerated() {
            let point = normalizedPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude + longitudeOffset
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
    }

    private static func normalizedPoint(latitude: Double, longitude: Double) -> CGPoint {
        FlatMapProjection.normalizedPoint(latitude: latitude, longitude: longitude, focus: .world)
    }

    private static let fallbackContinents: [[FlatMapCoordinate]] = [
        [
            FlatMapCoordinate(latitude: 72, longitude: -168), FlatMapCoordinate(latitude: 70, longitude: -140),
            FlatMapCoordinate(latitude: 61, longitude: -128), FlatMapCoordinate(latitude: 55, longitude: -125),
            FlatMapCoordinate(latitude: 48, longitude: -124), FlatMapCoordinate(latitude: 30, longitude: -117),
            FlatMapCoordinate(latitude: 16, longitude: -90), FlatMapCoordinate(latitude: 20, longitude: -82),
            FlatMapCoordinate(latitude: 30, longitude: -82), FlatMapCoordinate(latitude: 44, longitude: -67),
            FlatMapCoordinate(latitude: 51, longitude: -58), FlatMapCoordinate(latitude: 60, longitude: -64),
            FlatMapCoordinate(latitude: 70, longitude: -76), FlatMapCoordinate(latitude: 75, longitude: -105),
            FlatMapCoordinate(latitude: 72, longitude: -168)
        ],
        [
            FlatMapCoordinate(latitude: 13, longitude: -81), FlatMapCoordinate(latitude: 5, longitude: -77),
            FlatMapCoordinate(latitude: -12, longitude: -78), FlatMapCoordinate(latitude: -23, longitude: -70),
            FlatMapCoordinate(latitude: -38, longitude: -73), FlatMapCoordinate(latitude: -55, longitude: -68),
            FlatMapCoordinate(latitude: -52, longitude: -58), FlatMapCoordinate(latitude: -35, longitude: -54),
            FlatMapCoordinate(latitude: -10, longitude: -35), FlatMapCoordinate(latitude: 4, longitude: -52),
            FlatMapCoordinate(latitude: 13, longitude: -81)
        ],
        [
            FlatMapCoordinate(latitude: 37, longitude: -10), FlatMapCoordinate(latitude: 44, longitude: -8),
            FlatMapCoordinate(latitude: 50, longitude: -5), FlatMapCoordinate(latitude: 59, longitude: 3),
            FlatMapCoordinate(latitude: 70, longitude: 32), FlatMapCoordinate(latitude: 67, longitude: 58),
            FlatMapCoordinate(latitude: 72, longitude: 100), FlatMapCoordinate(latitude: 67, longitude: 145),
            FlatMapCoordinate(latitude: 54, longitude: 168), FlatMapCoordinate(latitude: 42, longitude: 141),
            FlatMapCoordinate(latitude: 27, longitude: 122), FlatMapCoordinate(latitude: 18, longitude: 108),
            FlatMapCoordinate(latitude: 10, longitude: 80), FlatMapCoordinate(latitude: 24, longitude: 55),
            FlatMapCoordinate(latitude: 35, longitude: 35), FlatMapCoordinate(latitude: 36, longitude: 15),
            FlatMapCoordinate(latitude: 37, longitude: -10)
        ],
        [
            FlatMapCoordinate(latitude: 37, longitude: -18), FlatMapCoordinate(latitude: 35, longitude: 10),
            FlatMapCoordinate(latitude: 29, longitude: 33), FlatMapCoordinate(latitude: 13, longitude: 42),
            FlatMapCoordinate(latitude: -5, longitude: 51), FlatMapCoordinate(latitude: -22, longitude: 42),
            FlatMapCoordinate(latitude: -35, longitude: 27), FlatMapCoordinate(latitude: -34, longitude: 17),
            FlatMapCoordinate(latitude: -20, longitude: 10), FlatMapCoordinate(latitude: 2, longitude: -5),
            FlatMapCoordinate(latitude: 20, longitude: -17), FlatMapCoordinate(latitude: 37, longitude: -18)
        ],
        [
            FlatMapCoordinate(latitude: -11, longitude: 112), FlatMapCoordinate(latitude: -18, longitude: 129),
            FlatMapCoordinate(latitude: -35, longitude: 153), FlatMapCoordinate(latitude: -41, longitude: 146),
            FlatMapCoordinate(latitude: -38, longitude: 122), FlatMapCoordinate(latitude: -25, longitude: 113),
            FlatMapCoordinate(latitude: -11, longitude: 112)
        ],
        [
            FlatMapCoordinate(latitude: 83, longitude: -74), FlatMapCoordinate(latitude: 76, longitude: -63),
            FlatMapCoordinate(latitude: 70, longitude: -50), FlatMapCoordinate(latitude: 60, longitude: -43),
            FlatMapCoordinate(latitude: 66, longitude: -22), FlatMapCoordinate(latitude: 76, longitude: -20),
            FlatMapCoordinate(latitude: 83, longitude: -38), FlatMapCoordinate(latitude: 83, longitude: -74)
        ]
    ]
}

private struct MemberRow: View {
    let member: PolicyMemberPresentation
    let selectorID: Int
    let isDesired: Bool
    let isSelecting: Bool
    let choose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isDesired ? Color.accentColor : Color.primary.opacity(isHovering ? 0.1 : 0.065))
                    if isDesired {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(initials)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.tag)
                        .font(.callout.weight(isDesired ? .semibold : .regular))
                        .lineLimit(1)
                    if let statusKey = member.statusKey {
                        Label(LocalizedStringKey(statusKey), systemImage: member.statusSymbol)
                            .font(.caption)
                            .foregroundStyle(member.statusLevel.tint)
                    }
                }
                Spacer()
                if isSelecting && isDesired { ProgressView().controlSize(.small) }
                healthValue
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isHovering && !isDesired ? Color.secondary.opacity(0.45) : Color.clear)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isDesired
                    ? Color.accentColor.opacity(0.09)
                    : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                if !isDesired && !isHovering {
                    Divider()
                        .padding(.leading, 50)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!member.isSelectable)
        .onHover { isHovering = $0 }
        // Member rows are semantic Buttons, so their identity and presentation
        // facts live on the Button rather than on visual label descendants.
        .accessibilityIdentifier("policy.catalog.selector.\(selectorID).member.\(member.id)")
        .accessibilityLabel(Text(member.tag))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(Text(member.isSelectable ? "policy.workspace.member.choose.hint" : "policy.workspace.member.unavailable.hint"))
    }

    private var initials: String {
        let words = member.tag.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }

    private var accessibilityValue: Text {
        var value = Text(verbatim: member.type ?? "")
        if let statusKey = member.statusKey {
            value = value + Text(verbatim: ", ") + Text(LocalizedStringKey(statusKey))
        }
        if let titleKey = member.role.titleKey {
            value = value + Text(verbatim: ", ") + Text(LocalizedStringKey(titleKey))
        }
        value = value + Text(verbatim: ", ") + healthAccessibilityValue
        return value
    }

    @ViewBuilder
    private var healthValue: some View {
        switch member.health.state {
        case .unknown:
            EmptyView()
        case .testing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("policy.health.testing")
            }
            .foregroundStyle(.secondary)
        case .reachable:
            if let latency = member.health.latencyMilliseconds {
                HStack(spacing: 6) {
                    LatencySignal(latency: latency, tint: latencyTint(latency))
                    (Text(verbatim: "\(latency) ") + Text("policy.health.milliseconds.short"))
                        .monospacedDigit()
                }
                .foregroundStyle(latencyTint(latency))
            }
        case .unreachable:
            Text("policy.health.unavailable")
                .foregroundStyle(member.health.level.tint)
        case .runtimeUnavailable:
            Text("policy.health.runtime-unavailable")
                .foregroundStyle(member.health.level.tint)
        }
    }

    private func latencyTint(_ latency: Int) -> Color {
        if latency < 160 { return .green }
        if latency < 360 { return .orange }
        return .red
    }

    private var healthAccessibilityValue: Text {
        switch member.health.state {
        case .reachable:
            if let latency = member.health.latencyMilliseconds {
                return Text("policy.health.latency") + Text(verbatim: ": \(latency) ")
                    + Text("policy.health.milliseconds")
            }
            return Text("policy.health.unavailable")
        case .unknown, .testing, .unreachable, .runtimeUnavailable:
            return Text(LocalizedStringKey(member.health.titleKey))
        }
    }
}

private struct LatencySignal: View {
    let latency: Int
    let tint: Color

    private var activeBars: Int {
        if latency < 160 { return 3 }
        if latency < 360 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < activeBars ? tint : Color.primary.opacity(0.16))
                    .frame(width: 2.5, height: CGFloat(4 + index * 3))
            }
        }
        .frame(width: 12, height: 11, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

private struct PolicyCatalogState: View {
    let titleKey: LocalizedStringKey
    let symbol: String
    let descriptionKey: LocalizedStringKey
    let accessibilityIdentifier: String
    var actionTitleKey: LocalizedStringKey? = nil
    var actionAccessibilityIdentifier: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(titleKey, systemImage: symbol)
                .font(.title3.weight(.semibold))
            Text(descriptionKey)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let actionTitleKey, let action {
                Button(actionTitleKey, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(actionAccessibilityIdentifier ?? "policy.catalog.state.action")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
