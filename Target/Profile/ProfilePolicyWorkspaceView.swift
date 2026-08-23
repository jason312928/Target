import SwiftUI
import MapKit

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
                currentRoute
                runtimeSummary
                destinations
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
        return PolicyRouteCountry.recognize(in: selectedMemberTag)
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
        Map(
            initialPosition: .region(Self.region(for: routes)),
            interactionModes: [.pan, .zoom]
        ) {
            ForEach(routes) { route in
                Annotation(
                    route.country.englishName,
                    coordinate: CLLocationCoordinate2D(
                        latitude: route.country.latitude,
                        longitude: route.country.longitude
                    ),
                    anchor: .bottom
                ) {
                    countryButton(route)
                }
            }
        }
        .mapStyle(.standard(
            elevation: .flat,
            pointsOfInterest: .excludingAll,
            showsTraffic: false
        ))
        .mapControlVisibility(.hidden)
        .frame(height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .accessibilityIdentifier("policy.workspace.country-map")
    }

    private func countryButton(_ route: PolicyCountryRoute) -> some View {
        let isSelected = route.members.contains(where: { $0.tag == selectedMemberTag })
        let isHovered = hoveredCountryCode == route.id
        return Button {
            choose(route)
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                        .frame(width: isSelected ? 48 : 42, height: isSelected ? 48 : 42)
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    Text(route.country.flag)
                        .font(.system(size: isSelected ? 23 : 20))
                        .frame(width: isSelected ? 48 : 42, height: isSelected ? 48 : 42)
                    Text("\(route.members.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.accentColor, in: Circle())
                        .offset(x: 5, y: -4)
                }
                if isSelected || isHovered {
                    VStack(spacing: 1) {
                        Text(route.country.displayName(localeIdentifier: locale.identifier))
                            .font(.caption.weight(.semibold))
                        if let latency = route.bestLatencyMilliseconds {
                            Text("\(latency) ms")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(latencyTint(latency))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .fixedSize()
                }
            }
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(route.bestMember == nil)
        .onHover { hovering in
            hoveredCountryCode = hovering ? route.id : nil
        }
        .help(route.country.displayName(localeIdentifier: locale.identifier))
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

    private func latencyTint(_ latency: Int) -> Color {
        if latency < 160 { return .green }
        if latency < 360 { return .orange }
        return .red
    }

    private static func region(for routes: [PolicyCountryRoute]) -> MKCoordinateRegion {
        guard let first = routes.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 18, longitude: 12),
                span: MKCoordinateSpan(latitudeDelta: 145, longitudeDelta: 330)
            )
        }
        let latitudes = routes.map(\.country.latitude)
        let longitudes = routes.map(\.country.longitude)
        let latitudeBounds = (latitudes.min() ?? first.country.latitude, latitudes.max() ?? first.country.latitude)
        let longitudeBounds = (longitudes.min() ?? first.country.longitude, longitudes.max() ?? first.country.longitude)
        let latitudeSpan = min(max((latitudeBounds.1 - latitudeBounds.0) * 1.45, 24), 145)
        let longitudeSpan = min(max((longitudeBounds.1 - longitudeBounds.0) * 1.35, 42), 330)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudeBounds.0 + latitudeBounds.1) / 2,
                longitude: (longitudeBounds.0 + longitudeBounds.1) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }
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
