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

    @State private var selectedSelectorID: Int?
    @State private var query = ""
    @State private var filter: PolicyWorkspaceFilter = .all

    private var presentation: PolicyWorkspacePresentation {
        PolicyWorkspacePresentation(
            catalog: catalog,
            unavailable: unavailable,
            healthBySelector: healthBySelector
        )
    }

    private var visibleSelectors: [PolicySelectorPresentation] {
        presentation.selectors(matching: query, filter: filter)
    }

    private var selectedSelector: PolicySelectorPresentation? {
        if let selectedSelectorID,
           let selected = visibleSelectors.first(where: { $0.id == selectedSelectorID }) {
            return selected
        }
        return visibleSelectors.first
    }

    var body: some View {
        Group {
            if unavailable {
                PolicyCatalogState(
                    titleKey: "policy.catalog.unavailable.title",
                    symbol: "lock.trianglebadge.exclamationmark",
                    descriptionKey: "policy.catalog.unavailable.description",
                    accessibilityIdentifier: "policy.catalog.unavailable"
                )
            } else if presentation.selectors.isEmpty {
                PolicyCatalogState(
                    titleKey: "policy.catalog.empty.title",
                    symbol: "point.3.connected.trianglepath.dotted",
                    descriptionKey: "policy.catalog.empty.description",
                    accessibilityIdentifier: "policy.catalog.empty"
                )
            } else {
                proxyWorkspace
            }
        }
        .onChange(of: visibleSelectors.map(\.id)) { _, ids in
            // Filtering is presentation-only. Keep the user's selector choice
            // intact even while it is temporarily filtered out.
            if selectedSelectorID == nil {
                selectedSelectorID = ids.first
            }
        }
        .task {
            if selectedSelectorID == nil { selectedSelectorID = visibleSelectors.first?.id }
        }
    }

    private var proxyWorkspace: some View {
        VStack(spacing: 0) {
            proxyToolbar
            Divider()
            HSplitView {
                selectorList
                    .frame(minWidth: 210, idealWidth: 255, maxWidth: 320)
                selectorDetail
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var proxyToolbar: some View {
        HStack(spacing: 10) {
            TextField("policy.workspace.search", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("policy.workspace.search")
            Picker("policy.workspace.filter", selection: $filter) {
                ForEach(PolicyWorkspaceFilter.allCases) { item in
                    Text(LocalizedStringKey(item.titleKey)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("policy.workspace.filter")
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(Text("policy.workspace.refresh"))
            .disabled(isSelecting || lifecycle?.isBusy == true)
            .accessibilityLabel(Text("policy.workspace.refresh"))
            .accessibilityIdentifier("policy.workspace.refresh")
            if presentation.overrideCount > 0 {
                Button("policy.catalog.reset", action: reset)
                    .controlSize(.small)
                    .disabled(isSelecting)
                    .accessibilityIdentifier("policy.catalog.reset")
            }
        }
        .padding(12)
    }

    private var selectorList: some View {
        Group {
            if visibleSelectors.isEmpty {
                PolicyCatalogState(
                    titleKey: "policy.workspace.search.empty.title",
                    symbol: "magnifyingglass",
                    descriptionKey: "policy.workspace.search.empty.description",
                    accessibilityIdentifier: "policy.workspace.search.empty"
                )
            } else {
                List {
                    ForEach(visibleSelectors) { selector in
                        Button {
                            selectedSelectorID = selector.id
                        } label: {
                            SelectorRow(selector: selector)
                        }
                        .buttonStyle(.plain)
                        // A native List row does not preserve an accessibility label
                        // or value set on its SwiftUI content.  The selector itself
                        // is an interaction, so expose it as the stable Button that
                        // selects the detail pane.
                        .accessibilityIdentifier("policy.catalog.selector.\(selector.id)")
                        .accessibilityLabel(Text(verbatim: selector.displayTag))
                        .accessibilityValue(selector.accessibilityValue(isSelected: selectedSelectorID == selector.id))
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("policy.workspace.selectors")
            }
        }
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

private struct SelectorRow: View {
    let selector: PolicySelectorPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: selector.statusSymbol)
                    .foregroundStyle(selector.statusLevel.tint)
                Text(selector.displayTag).lineLimit(1)
                Spacer(minLength: 0)
                if selector.restartRequired {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 4) {
                Text(selector.desiredSelection ?? "—")
                if let running = selector.runningSelection, running != selector.desiredSelection {
                    Image(systemName: "arrow.right")
                    Text(running)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            (Text("policy.workspace.member-count") + Text(": \(selector.memberCount)"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
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
    let select: (String, String) -> Void
    let probeLatency: () -> Void
    let restart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                runtimeSummary
                members
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selector.displayTag)
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Label {
                    Text("policy.workspace.member-count") + Text(": \(selector.memberCount)")
                } icon: {
                    Image(systemName: "circle.grid.2x2")
                }
                if let statusKey = selector.statusKey {
                    Label(LocalizedStringKey(statusKey), systemImage: selector.statusSymbol)
                        .foregroundStyle(selector.statusLevel.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var runtimeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(selector.runtime.titleKey), systemImage: selector.runtime.symbolName)
                .font(.callout.weight(.medium))
                .foregroundStyle(selector.runtime.level.tint)
            Text(LocalizedStringKey(selector.runtime.detailKey))
                .font(.caption)
                .foregroundStyle(.secondary)
            policyRelations
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

    @ViewBuilder
    private var policyRelations: some View {
        if let configuredDefault = selector.configuredDefault {
            LabeledContent("policy.catalog.configured-default", value: configuredDefault)
                .font(.caption)
        }
        if let desired = selector.desiredSelection {
            LabeledContent("policy.catalog.desired-selection", value: desired)
                .font(.caption)
        }
        if let running = selector.runningSelection, running != selector.desiredSelection {
            LabeledContent("policy.catalog.running-selection", value: running)
                .font(.caption)
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TargetSectionTitle("policy.workspace.members", systemImage: "circle.grid.2x2")
                Spacer()
                Button(action: probeLatency) {
                    Text(LocalizedStringKey(
                        isTestingLatency
                            ? "policy.health.testing"
                            : (selector.hasHealthResults ? "policy.health.probe-again" : "policy.health.test-latency")
                    ))
                }
                .controlSize(.small)
                .disabled(!PolicyLatencyActionAvailability.isAvailable(
                    engineIsRunning: engineIsRunning,
                    isTestingLatency: isTestingLatency,
                    lifecycleBusy: lifecycleBusy,
                    selectorTag: selector.tag,
                    hasSelectableMembers: selector.members.contains(where: \.isSelectable)
                ))
                .accessibilityIdentifier("policy.health.test-latency")
            }
            ForEach(selector.members) { member in
                MemberRow(
                    member: member,
                    selectorID: selector.id,
                    isDesired: selector.desiredSelection == member.tag,
                    isSelecting: isSelecting,
                    choose: {
                        guard let selectorTag = selector.tag, member.isSelectable else { return }
                        select(selectorTag, member.tag)
                    }
                )
            }
        }
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
                    HStack(spacing: 6) {
                        Text(member.tag).lineLimit(1)
                        if let type = member.type {
                            Text(type).foregroundStyle(.secondary)
                        }
                    }
                    if let statusKey = member.statusKey {
                        Label(LocalizedStringKey(statusKey), systemImage: member.statusSymbol)
                            .font(.caption)
                            .foregroundStyle(member.statusLevel.tint)
                    }
                    if let titleKey = member.role.titleKey {
                        Text(LocalizedStringKey(titleKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelecting && isDesired { ProgressView().controlSize(.small) }
                healthValue
            }
            .padding(.vertical, 6)
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
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .help(Text("policy.health.not-tested"))
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

    var body: some View {
        ContentUnavailableView(titleKey, systemImage: symbol, description: Text(descriptionKey))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
