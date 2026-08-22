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
            proxyToolbar
            if presentation.selectors.count > 1 {
                Divider()
                selectorTabs
            }
            Divider()
            selectorDetail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var proxyToolbar: some View {
        HStack(spacing: 10) {
            TextField("policy.workspace.search", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("policy.workspace.search")
                .frame(maxWidth: 320)
            Spacer(minLength: 0)
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
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var selectorTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(presentation.selectors) { selector in
                    Button {
                        selectedSelectorID = selector.id
                    } label: {
                        VStack(spacing: 7) {
                            Text(selector.displayTag)
                                .lineLimit(1)
                                .foregroundStyle(selectedSelectorID == selector.id ? .primary : .secondary)
                            Rectangle()
                                .fill(selectedSelectorID == selector.id ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("policy.catalog.selector.\(selector.id)")
                    .accessibilityLabel(Text(verbatim: selector.displayTag))
                    .accessibilityValue(selector.accessibilityValue(isSelected: selectedSelectorID == selector.id))
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .accessibilityIdentifier("policy.workspace.selectors")
    }

    @ViewBuilder
    private var selectorDetail: some View {
        if let selector = selectedSelector {
            SelectorDetail(
                selector: selector,
                isSelecting: isSelecting,
                isTestingLatency: testingSelectorID == selector.id,
                canRestart: lifecycle?.canRestart == true,
                lifecycleBusy: lifecycle?.isBusy == true,
                engineIsRunning: lifecycle?.isEngineRunning == true,
                query: query,
                exposesSelectorAccessibilityIdentity: presentation.selectors.count == 1,
                select: select,
                probeLatency: {
                    guard let tag = selector.tag else { return }
                    probeLatency(selector.id, tag)
                },
                restart: { lifecycle?.restartWithCurrentProfile() }
            )
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
    let isTestingLatency: Bool
    let canRestart: Bool
    let lifecycleBusy: Bool
    let engineIsRunning: Bool
    let query: String
    let exposesSelectorAccessibilityIdentity: Bool
    let select: (String, String) -> Void
    let probeLatency: () -> Void
    let restart: () -> Void
    @State private var pendingSelection: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                runtimeSummary
                members
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(20)
        }
        .onChange(of: isSelecting) { wasSelecting, selecting in
            if wasSelecting && !selecting {
                pendingSelection = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selector.displayTag)
                    .font(.title3.weight(.semibold))
                (Text("policy.workspace.nodes") + Text(" · \(selector.memberCount)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let statusKey = selector.statusKey {
                Label(LocalizedStringKey(statusKey), systemImage: selector.statusSymbol)
                    .font(.caption)
                    .foregroundStyle(selector.statusLevel.tint)
            }
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

    private var members: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TargetSectionTitle("policy.workspace.nodes", systemImage: "server.rack")
                Spacer()
                if latencyActionIsAvailable || isTestingLatency {
                    Button(action: probeLatency) {
                        Text(LocalizedStringKey(
                            isTestingLatency
                                ? "policy.health.testing"
                                : (selector.hasHealthResults ? "policy.health.probe-again" : "policy.health.test-latency")
                        ))
                    }
                    .controlSize(.small)
                    .disabled(!latencyActionIsAvailable)
                    .accessibilityIdentifier("policy.health.test-latency")
                }
            }
            if selector.members.isEmpty {
                ContentUnavailableView(
                    "policy.workspace.members.empty.title",
                    systemImage: "server.rack",
                    description: Text("policy.workspace.members.empty.description")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityIdentifier("policy.workspace.members.empty")
            } else if filteredMembers.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityIdentifier("policy.workspace.members.empty")
            } else {
                ForEach(filteredMembers) { member in
                    MemberRow(
                        member: member,
                        selectorID: selector.id,
                        isDesired: (pendingSelection ?? selector.desiredSelection) == member.tag,
                        isSelecting: isSelecting,
                        choose: {
                            guard let selectorTag = selector.tag, member.isSelectable else { return }
                            pendingSelection = member.tag
                            select(selectorTag, member.tag)
                        }
                    )
                    if member.id != filteredMembers.last?.id { Divider() }
                }
            }
        }
    }

    private var latencyActionIsAvailable: Bool {
        PolicyLatencyActionAvailability.isAvailable(
            engineIsRunning: engineIsRunning,
            isTestingLatency: isTestingLatency,
            lifecycleBusy: lifecycleBusy,
            selectorTag: selector.tag,
            hasSelectableMembers: selector.members.contains(where: \.isSelectable)
        )
    }
}

private struct MemberRow: View {
    let member: PolicyMemberPresentation
    let selectorID: Int
    let isDesired: Bool
    let isSelecting: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: isDesired ? "checkmark.circle.fill" : member.statusSymbol)
                    .foregroundStyle(isDesired ? Color.accentColor : member.statusLevel.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.tag).lineLimit(1)
                    if let statusKey = member.statusKey {
                        Label(LocalizedStringKey(statusKey), systemImage: member.statusSymbol)
                            .font(.caption)
                            .foregroundStyle(member.statusLevel.tint)
                    }
                }
                Spacer()
                if isSelecting && isDesired { ProgressView().controlSize(.small) }
                healthValue
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isDesired ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!member.isSelectable || isSelecting)
        // Member rows are semantic Buttons, so their identity and presentation
        // facts live on the Button rather than on visual label descendants.
        .accessibilityIdentifier("policy.catalog.selector.\(selectorID).member.\(member.id)")
        .accessibilityLabel(Text(member.tag))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(Text(member.isSelectable ? "policy.workspace.member.choose.hint" : "policy.workspace.member.unavailable.hint"))
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
                (Text(verbatim: "\(latency) ") + Text("policy.health.milliseconds.short"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .unreachable:
            Text("policy.health.unavailable")
                .foregroundStyle(member.health.level.tint)
        case .runtimeUnavailable:
            Text("policy.health.runtime-unavailable")
                .foregroundStyle(member.health.level.tint)
        }
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
