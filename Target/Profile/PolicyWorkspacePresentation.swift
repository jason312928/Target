import Foundation

/// Presentation-only facts for the Proxies workspace. This deliberately works
/// from the credential-safe PolicyCatalog rather than from Profile JSON.
enum PolicyWorkspaceFilter: String, CaseIterable, Identifiable {
    case all
    case selected
    case needsRestart
    case issues

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: "policy.workspace.filter.all"
        case .selected: "policy.workspace.filter.selected"
        case .needsRestart: "policy.workspace.filter.needs-restart"
        case .issues: "policy.workspace.filter.issues"
        }
    }
}

enum PolicyLatencyActionAvailability {
    static func isAvailable(
        engineIsRunning: Bool,
        isTestingLatency: Bool,
        lifecycleBusy: Bool,
        selectorTag: String?,
        hasSelectableMembers: Bool
    ) -> Bool {
        engineIsRunning
            && !isTestingLatency
            && !lifecycleBusy
            && selectorTag != nil
            && hasSelectableMembers
    }
}

struct PolicyWorkspacePresentation {
    let catalog: PolicyCatalog?
    let unavailable: Bool
    var healthBySelector: [Int: [String: RuntimeProxyHealth]] = [:]

    var selectors: [PolicySelectorPresentation] {
        catalog?.selectors.map { selector in
            PolicySelectorPresentation(selector, health: healthBySelector[selector.id] ?? [:])
        } ?? []
    }

    var selectorCount: Int { selectors.count }
    var overrideCount: Int { catalog?.storedOverrideCount ?? 0 }
    var restartRequiredCount: Int { selectors.filter(\.restartRequired).count }
    var hasIssues: Bool { selectors.contains(where: \.hasIssue) }

    func selectors(matching query: String, filter: PolicyWorkspaceFilter) -> [PolicySelectorPresentation] {
        selectors.filter { selector in
            selector.matches(query: query) && selector.matches(filter: filter)
        }
    }
}

struct PolicySelectorPresentation: Identifiable, Equatable {
    let selector: PolicyCatalogSelector
    let health: [String: RuntimeProxyHealth]

    init(_ selector: PolicyCatalogSelector, health: [String: RuntimeProxyHealth] = [:]) {
        self.selector = selector
        self.health = health
    }

    var id: Int { selector.id }
    var tag: String? { selector.tag }
    var displayTag: String { selector.tag ?? String(localized: "policy.catalog.invalid-tag") }
    var memberCount: Int { selector.members.count }
    var desiredSelection: String? { selector.effectiveDesired }
    var runningSelection: String? { selector.runningSelection }
    var configuredDefault: String? { selector.configuredDefault }
    var restartRequired: Bool { selector.restartRequired }
    var isMutable: Bool { selector.isMutable }
    var statusKey: String? { selector.status.presentationKey }
    var statusSymbol: String { selector.status.presentationSymbol }
    var statusLevel: TargetStatusLevel { selector.status.presentationLevel }
    var hasIssue: Bool {
        selector.status != .available
            || selector.members.contains(where: { $0.status != .available })
            || selector.runtimeConvergence == .unavailable
    }

    var runtime: PolicyRuntimePresentation {
        PolicyRuntimePresentation(selector: selector)
    }

    var members: [PolicyMemberPresentation] {
        selector.members.map { member in
            PolicyMemberPresentation(member, selector: selector, health: health[member.tag])
        }
    }
    var hasHealthResults: Bool {
        health.values.contains { ![.unknown, .testing].contains($0.state) }
    }

    func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return ([selector.tag ?? ""] + selector.members.flatMap { [$0.tag, $0.type ?? ""] })
            .contains { $0.lowercased().contains(normalized) }
    }

    func matches(filter: PolicyWorkspaceFilter) -> Bool {
        switch filter {
        case .all: true
        case .selected: selector.targetOverride != nil
        case .needsRestart: restartRequired
        case .issues: hasIssue
        }
    }
}

struct PolicyMemberPresentation: Identifiable, Equatable {
    let member: PolicyCatalogMember
    let role: PolicyMemberRole
    let health: PolicyMemberHealthPresentation

    init(
        _ member: PolicyCatalogMember,
        selector: PolicyCatalogSelector,
        health: RuntimeProxyHealth? = nil
    ) {
        self.member = member
        self.health = PolicyMemberHealthPresentation(health)
        if selector.effectiveDesired == member.tag {
            role = .desired
        } else if selector.runningSelection == member.tag {
            role = .running
        } else if selector.configuredDefault == member.tag {
            role = .configuredDefault
        } else {
            role = .none
        }
    }

    var id: Int { member.id }
    var tag: String { member.tag }
    var type: String? { member.type }
    var statusKey: String? { member.status.presentationKey }
    var statusSymbol: String { member.status.presentationSymbol }
    var statusLevel: TargetStatusLevel { member.status.presentationLevel }
    var isSelectable: Bool { member.status == .available }
}

struct PolicyMemberHealthPresentation: Equatable {
    let state: RuntimeProxyHealthState
    let latencyMilliseconds: Int?

    init(_ health: RuntimeProxyHealth?) {
        state = health?.state ?? .unknown
        latencyMilliseconds = health?.latencyMilliseconds
    }

    var titleKey: String {
        switch state {
        case .unknown: "policy.health.not-tested"
        case .testing: "policy.health.testing"
        case .reachable: "policy.health.latency"
        case .unreachable: "policy.health.unavailable"
        case .runtimeUnavailable: "policy.health.runtime-unavailable"
        }
    }

    var level: TargetStatusLevel {
        switch state {
        case .unreachable, .runtimeUnavailable: .warning
        case .unknown, .testing, .reachable: .neutral
        }
    }
}

enum PolicyMemberRole: Equatable {
    case none
    case configuredDefault
    case desired
    case running

    var titleKey: String? {
        switch self {
        case .none: nil
        case .configuredDefault: "policy.workspace.member.configured-default"
        case .desired: "policy.workspace.member.desired"
        case .running: "policy.workspace.member.running"
        }
    }
}

struct PolicyRuntimePresentation: Equatable {
    let state: PolicyRuntimeConvergenceState
    let titleKey: String
    let detailKey: String
    let symbolName: String
    let level: TargetStatusLevel

    init(selector: PolicyCatalogSelector) {
        state = selector.runtimeConvergence
        switch selector.runtimeConvergence {
        case .notRunning:
            titleKey = "policy.workspace.runtime.not-running"
            detailKey = "policy.workspace.runtime.not-running.detail"
            symbolName = "power"
            level = .neutral
        case .converged:
            titleKey = "policy.workspace.runtime.converged"
            detailKey = "policy.workspace.runtime.converged.detail"
            symbolName = "checkmark.circle"
            level = .neutral
        case .restartRequired:
            titleKey = "policy.catalog.restart-required"
            detailKey = "policy.workspace.runtime.restart-required.detail"
            symbolName = "arrow.clockwise"
            level = .warning
        case .unavailable:
            titleKey = "policy.workspace.runtime.unavailable"
            detailKey = "policy.workspace.runtime.unavailable.detail"
            symbolName = "questionmark.circle"
            level = .warning
        }
    }
}

private extension PolicyCatalogStructuralStatus {
    var presentationKey: String? {
        switch self {
        case .available: nil
        case .missingReference: "policy.catalog.status.missingReference"
        case .duplicateTag: "policy.catalog.status.duplicateTag"
        case .malformedMembers: "policy.catalog.status.malformedMembers"
        case .invalidTag: "policy.catalog.status.invalidTag"
        case .unavailable: "policy.catalog.status.unavailable"
        }
    }

    var presentationSymbol: String {
        self == .available ? "checkmark.circle" : "exclamationmark.triangle"
    }

    var presentationLevel: TargetStatusLevel {
        self == .available ? .neutral : .warning
    }
}
