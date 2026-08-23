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
        .frame(maxWidth: 900)
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
    @State private var pendingSelection: String?

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
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(20)
        }
        .onChange(of: isSelecting) { wasSelecting, selecting in
            if wasSelecting && !selecting {
                pendingSelection = nil
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
                CountryRouteGrid(
                    routes: filteredCountryRoutes,
                    selectedMemberTag: selectedMemberTag,
                    choose: chooseCountry
                )
                if !filteredUnclassifiedMembers.isEmpty {
                    unclassifiedMembers
                }
            } else {
                memberGrid(filteredMembers)
            }
        }
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
    @State private var hoveredCountryCode: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                FlatWorldArtwork()
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    countryButton(route)
                        .position(Self.point(for: route.country, index: index, routes: routes, in: proxy.size))
                }
            }
        }
        .frame(height: 218)
        .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
        .overlay(alignment: .topLeading) {
            Label("policy.workspace.map.overview", systemImage: "map")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .accessibilityIdentifier("policy.workspace.country-map")
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
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: 3, y: 1)
                Text(route.country.flag)
                    .font(.system(size: 15))
            }
            .overlay {
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.22 : 0.08), lineWidth: isSelected ? 2 : 1)
                    .frame(width: 36, height: 36)
            }
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
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

    private static func point(
        for country: PolicyRouteCountry,
        index: Int,
        routes: [PolicyCountryRoute],
        in size: CGSize
    ) -> CGPoint {
        let base = FlatMapProjection.point(for: country, in: size)
        let nearbyBefore = routes.prefix(index).filter { other in
            let otherPoint = FlatMapProjection.point(for: other.country, in: size)
            return abs(otherPoint.x - base.x) < 42 && abs(otherPoint.y - base.y) < 28
        }.count
        let offsets: [CGSize] = [
            .zero, CGSize(width: 24, height: -16), CGSize(width: -24, height: 16),
            CGSize(width: 26, height: 18), CGSize(width: -26, height: -18),
            CGSize(width: 0, height: 28)
        ]
        let offset = offsets[min(nearbyBefore, offsets.count - 1)]
        let mapBounds = FlatMapProjection.rect(in: size)
        return CGPoint(
            x: min(max(base.x + offset.width, mapBounds.minX + 22), mapBounds.maxX - 22),
            y: min(max(base.y + offset.height, mapBounds.minY + 25), mapBounds.maxY - 24)
        )
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
        }
        .buttonStyle(.plain)
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

private enum FlatMapProjection {
    // Keep the map's natural 2:1 world ratio. Stretching it to the full
    // workspace width made the countries look visibly flattened in Preview.
    private static let worldAspectRatio = 2.0

    static func rect(in size: CGSize) -> CGRect {
        let horizontalPadding = min(size.width * 0.03, 22)
        let verticalPadding = min(size.height * 0.12, 24)
        let availableWidth = max(size.width - horizontalPadding * 2, 1)
        let availableHeight = max(size.height - verticalPadding * 2, 1)
        let availableAspectRatio = availableWidth / availableHeight
        if availableAspectRatio > worldAspectRatio {
            let height = availableHeight
            let width = height * worldAspectRatio
            return CGRect(
                x: (size.width - width) / 2,
                y: verticalPadding,
                width: width,
                height: height
            )
        }
        let width = availableWidth
        let height = width / worldAspectRatio
        return CGRect(
            x: horizontalPadding,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    static func point(for country: PolicyRouteCountry, in size: CGSize) -> CGPoint {
        point(latitude: country.latitude, longitude: country.longitude, in: size)
    }

    static func point(latitude: Double, longitude: Double, in size: CGSize) -> CGPoint {
        let bounds = rect(in: size)
        return CGPoint(
            x: bounds.minX + ((longitude + 180) / 360) * bounds.width,
            y: bounds.minY + ((90 - latitude) / 180) * bounds.height
        )
    }
}

/// Loads country boundaries from world-atlas/Natural Earth once at runtime.
/// The resource is bundled locally, so rendering never depends on a network map.
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
                guard values.count >= 2 else { return nil }
                return values
            }
        }
        guard !arcs.isEmpty,
              let objects = root["objects"] as? [String: Any],
              let countries = objects["countries"] as? [String: Any] else {
            return []
        }

        var rings: [[FlatMapCoordinate]] = []
        for geometry in arrays(countries["geometries"]) {
            guard let geometry = geometry as? [String: Any],
                  let type = geometry["type"] as? String else { continue }
            let rawGeometry = arrays(geometry["arcs"])
            switch type {
            case "Polygon":
                for rawRing in rawGeometry {
                    let indexes = numbers(rawRing).map { Int($0.rounded()) }
                    let ring = decode(indexes, arcs: arcs, scale: scale, translate: translate)
                    if ring.count >= 3 { rings.append(ring) }
                }
            case "MultiPolygon":
                for rawPolygon in rawGeometry {
                    for rawRing in arrays(rawPolygon) {
                        let indexes = numbers(rawRing).map { Int($0.rounded()) }
                        let ring = decode(indexes, arcs: arcs, scale: scale, translate: translate)
                        if ring.count >= 3 { rings.append(ring) }
                    }
                }
            default:
                continue
            }
        }
        return rings
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
            let arc = arcs[index]
            var previousX = 0.0
            var previousY = 0.0
            var decodedArc: [FlatMapCoordinate] = []
            for rawPoint in arc {
                guard rawPoint.count >= 2 else { continue }
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
        arrays(value).compactMap { item in
            if let number = item as? NSNumber { return number.doubleValue }
            if let number = item as? Double { return number }
            if let number = item as? Int { return Double(number) }
            return nil
        }
    }
}

private struct FlatWorldArtwork: View {
    var body: some View {
        Canvas { context, size in
            let mapBounds = FlatMapProjection.rect(in: size)
            let fillColor = Color.primary.opacity(0.028)
            let outlineColor = Color.primary.opacity(0.12)
            let polygons = WorldMapGeometry.rings.isEmpty ? Self.fallbackContinents : WorldMapGeometry.rings
            for polygon in polygons {
                var path = Path()
                for (index, coordinate) in polygon.enumerated() {
                    let point = FlatMapProjection.point(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        in: size
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.fill(path, with: .color(fillColor))
                context.stroke(path, with: .color(outlineColor), lineWidth: 0.55)
            }

            // A quiet frame keeps the artwork legible without implying a
            // geographic coordinate system or adding chart-like decoration.
            context.stroke(
                Path(roundedRect: mapBounds, cornerRadius: 10),
                with: .color(Color.primary.opacity(0.045)),
                lineWidth: 0.8
            )
        }
        .accessibilityHidden(true)
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
