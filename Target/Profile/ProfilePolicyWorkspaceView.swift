import SwiftUI

struct ProfilePolicyWorkspaceView: View {
    let catalog: PolicyCatalog?
    let unavailable: Bool
    let isSelecting: Bool
    let lifecycle: BackendLifecycleModel?
    let select: (String, String) -> Void
    let reset: () -> Void
    let refresh: () -> Void

    @State private var selectedSelectorID: Int?
    @State private var query = ""
    @State private var filter: PolicyWorkspaceFilter = .all

    private var presentation: PolicyWorkspacePresentation {
        PolicyWorkspacePresentation(catalog: catalog, unavailable: unavailable)
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
                ContentUnavailableView(
                    "policy.catalog.unavailable.title",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text("policy.catalog.unavailable.description")
                )
                .accessibilityIdentifier("policy.catalog.unavailable")
            } else if presentation.selectors.isEmpty {
                ContentUnavailableView(
                    "policy.catalog.empty.title",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("policy.catalog.empty.description")
                )
                .accessibilityIdentifier("policy.catalog.empty")
            } else {
                proxyWorkspace
            }
        }
        .accessibilityIdentifier("policy.workspace")
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
        List(selection: $selectedSelectorID) {
            ForEach(visibleSelectors) { selector in
                SelectorRow(selector: selector)
                    .tag(selector.id)
                    .accessibilityIdentifier("policy.catalog.selector.\(selector.id)")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("policy.workspace.selectors")
    }

    @ViewBuilder
    private var selectorDetail: some View {
        if let selector = selectedSelector {
            SelectorDetail(
                selector: selector,
                isSelecting: isSelecting,
                canRestart: lifecycle?.canRestart == true,
                lifecycleBusy: lifecycle?.isBusy == true,
                select: select,
                restart: { lifecycle?.restartWithCurrentProfile() }
            )
        } else {
            ContentUnavailableView(
                "policy.workspace.search.empty.title",
                systemImage: "magnifyingglass",
                description: Text("policy.workspace.search.empty.description")
            )
            .accessibilityIdentifier("policy.workspace.search.empty")
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
                    .accessibilityIdentifier("policy.catalog.selector.\(selector.id).tag")
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
        .accessibilityElement(children: .contain)
    }
}

private struct SelectorDetail: View {
    let selector: PolicySelectorPresentation
    let isSelecting: Bool
    let canRestart: Bool
    let lifecycleBusy: Bool
    let select: (String, String) -> Void
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
        .accessibilityIdentifier("policy.workspace.selector-detail")
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
                        .accessibilityIdentifier("policy.catalog.selector.\(selector.id).status")
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
                .accessibilityIdentifier("policy.catalog.selector.\(selector.id).runtime")
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
                .accessibilityIdentifier("policy.catalog.selector.\(selector.id).configured-default")
        }
        if let desired = selector.desiredSelection {
            LabeledContent("policy.catalog.desired-selection", value: desired)
                .font(.caption)
                .accessibilityIdentifier("policy.catalog.selector.\(selector.id).desired-selection")
        }
        if let running = selector.runningSelection, running != selector.desiredSelection {
            LabeledContent("policy.catalog.running-selection", value: running)
                .font(.caption)
                .accessibilityIdentifier("policy.catalog.selector.\(selector.id).running-selection")
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 8) {
            TargetSectionTitle("policy.workspace.members", systemImage: "circle.grid.2x2")
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
                            .accessibilityIdentifier("policy.catalog.selector.\(selectorID).member.\(member.id).tag")
                        if let type = member.type {
                            Text(type).foregroundStyle(.secondary)
                                .accessibilityIdentifier("policy.catalog.selector.\(selectorID).member.\(member.id).type")
                        }
                    }
                    if let statusKey = member.statusKey {
                        Label(LocalizedStringKey(statusKey), systemImage: member.statusSymbol)
                            .font(.caption)
                            .foregroundStyle(member.statusLevel.tint)
                            .accessibilityIdentifier("policy.catalog.selector.\(selectorID).member.\(member.id).status")
                    }
                    if let titleKey = member.role.titleKey {
                        Text(LocalizedStringKey(titleKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelecting && isDesired { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!member.isSelectable || isSelecting)
        .accessibilityIdentifier("policy.catalog.selector.\(selectorID).member.\(member.id)")
        .accessibilityLabel(Text(member.tag))
        .accessibilityHint(Text(member.isSelectable ? "policy.workspace.member.choose.hint" : "policy.workspace.member.unavailable.hint"))
    }
}
