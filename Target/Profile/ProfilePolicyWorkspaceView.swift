import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProfilePolicyWorkspaceView: View {
    let catalog: PolicyCatalog?
    let unavailable: Bool
    let isSelecting: Bool
    let healthBySelector: [Int: [String: RuntimeProxyHealth]]
    let testingSelectorID: Int?
    let lifecycle: BackendLifecycleModel?
    var participatingCountryRoutes: [PolicyCountryRoute]? = nil
    var inspectCountry: ((String) -> Void)? = nil
    var chooseParticipatingCountry: ((String) -> Void)? = nil
    var routeBindings: [ProfileRouteBinding] = []
    var bindRoute: ((URL, String, String) -> Void)? = nil
    var removeRouteBinding: ((String) -> Void)? = nil
    var smartActionsAvailable = false
    var isApplyingSmart = false
    var smartResult: SmartApplicationPresentation? = nil
    var applySmartSwitch: () -> Void = {}
    var applySmart: () -> Void = {}
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
            smartFeedback
                selectorDetail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var routeToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                routeTitle
                Spacer(minLength: 12)
                searchField.frame(width: 220)
                latencyButton
                automaticSelectionButton
                smartActionMenu
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    routeTitle
                    Spacer(minLength: 8)
                    latencyButton
                    automaticSelectionButton
                    smartActionMenu
                }
                searchField.frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: ProfileWorkspaceLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var smartActionMenu: some View {
        Menu {
            Button("policy.smart.switch", systemImage: "arrow.triangle.2.circlepath") {
                applySmartSwitch()
            }
            .disabled(!smartActionsAvailable || isApplyingSmart)
            .accessibilityIdentifier("policy.smart.switch")
            Button("policy.smart.apply", systemImage: "wand.and.stars") {
                applySmart()
            }
            .disabled(!smartActionsAvailable || isApplyingSmart)
            .accessibilityIdentifier("policy.smart.apply")
        } label: {
            Label("policy.smart.title", systemImage: "wand.and.stars")
        }
        .disabled(!smartActionsAvailable && smartResult == nil)
        .help(Text("policy.smart.help"))
        .accessibilityLabel(Text("policy.smart.title"))
        .accessibilityIdentifier("policy.smart.menu")
    }

    @ViewBuilder
    private var smartFeedback: some View {
        if isApplyingSmart {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("policy.smart.progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("policy.smart.progress"))
            .accessibilityIdentifier("policy.smart.progress")
        } else if let smartResult {
            HStack(spacing: 8) {
                Image(systemName: smartResult.symbolName)
                    .foregroundStyle(smartResult.isPositive ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(smartResult.messageKey))
                        .font(.caption.weight(.semibold))
                    if smartResult.result.action == .continuityApply {
                        Text(smartResult.result.selectorSwitched
                            ? "policy.smart.result.selector-switched"
                            : "policy.smart.result.selector-unchanged")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String.localizedStringWithFormat(
                            String(localized: "policy.smart.result.continuity.detail"),
                            Int64(smartResult.result.closedConnectionCount),
                            Int64(smartResult.result.preservedConnectionCount)
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if smartResult.result.selectorSwitched {
                        Text("policy.smart.result.switch.detail")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("policy.smart.feedback")
        }
    }

    private var routeTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe.asia.australia.fill")
                .foregroundStyle(Color.accentColor)
            Text("policy.workspace.choose-country")
                .font(.headline)
            Text("\(participatingCountryRoutes?.count ?? selectedSelector?.countryRoutes.count ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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

    @ViewBuilder
    private var automaticSelectionButton: some View {
        if presentation.overrideCount > 0 {
            Button("policy.workspace.automatic-selection", systemImage: "sparkles", action: reset)
                .buttonStyle(.borderless)
                .disabled(isSelecting)
                .help(Text("policy.catalog.reset"))
                .accessibilityIdentifier("policy.catalog.reset")
        }
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
                participatingCountryRoutes: participatingCountryRoutes,
                chooseParticipatingCountry: chooseParticipatingCountry,
                inspectCountry: { inspectCountry?($0.id) },
                routeBindings: routeBindings,
                availableRouteOutboundTags: Set(presentation.selectors.flatMap(\.members).filter(\.isSelectable).map(\.tag)),
                bindRoute: bindRoute,
                removeRouteBinding: removeRouteBinding,
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
