import Foundation

/// Presentation-only facts for the Profile workspace. This keeps display
/// decisions deterministic without creating another source of Profile state.
struct ProfileWorkspacePresentation: Equatable {
    enum Source: Equatable {
        case local
        case remote
    }

    let source: Source
    let validationTitleKey: String
    let validationLevel: ProfileWorkspaceStatusLevel
    let subscriptionTitleKey: String?
    let subscriptionLevel: ProfileWorkspaceStatusLevel?
    let hasSubscriptionError: Bool

    init(profile: Profile) {
        source = profile.hasRemoteSubscription ? .remote : .local

        switch profile.validation.status {
        case .valid:
            validationTitleKey = "profile.validation.valid"
            validationLevel = .positive
        case .invalid:
            validationTitleKey = "profile.validation.invalid"
            validationLevel = .critical
        case .notChecked:
            validationTitleKey = "profile.validation.not-checked"
            validationLevel = .neutral
        }

        if let subscription = profile.subscription {
            subscriptionTitleKey = subscription.cacheStatus == .notModified
                ? "profile.subscription.cache.not-modified"
                : "profile.subscription.cache.\(subscription.cacheStatus.rawValue)"
            subscriptionLevel = Self.subscriptionLevel(for: subscription.cacheStatus)
            hasSubscriptionError = subscription.lastErrorKey != nil
        } else {
            subscriptionTitleKey = nil
            subscriptionLevel = nil
            hasSubscriptionError = false
        }
    }

    private static func subscriptionLevel(for status: SubscriptionCacheStatus) -> ProfileWorkspaceStatusLevel {
        switch status {
        case .updated:
            .positive
        case .failed:
            .critical
        case .cancelled:
            .warning
        case .notChecked, .notModified:
            .neutral
        }
    }
}

enum ProfileWorkspaceStatusLevel: Equatable {
    case neutral
    case positive
    case warning
    case critical
}

enum ProfileWorkspaceLayout {
    static let minimumEditorHeight: CGFloat = 180
    static let preferredEditorHeight: CGFloat = 260
    static let sidebarMinimumWidth: CGFloat = 140
    static let sidebarIdealWidth: CGFloat = 170
    static let sidebarMaximumWidth: CGFloat = 210

}

/// An auditable description of a Profile action that must not replace a dirty
/// editor until the user explicitly resolves its changes. It intentionally
/// carries data, not arbitrary deferred closures.
enum ProfileWorkspaceOperation {
    case select(UUID)
    case create(name: String, subscriptionURL: URL?)
    case duplicate(UUID)
    case delete(UUID)
    case restore(UUID)
    case importCandidate(ProfileImportCandidate, name: String)
    case applySubscription(PendingSubscriptionUpdate)
}

enum ProfileUnsavedChangesDecision {
    case saveAndContinue
    case discardChanges
    case cancel
}

/// The outcome of an explicit unsaved-changes decision. The view uses this
/// rather than assuming that an Alert button always completed its work.
enum ProfileUnsavedChangesDecisionResult: Equatable {
    case resolved
    case cancelled
    case failedAndStillPending
    case noPendingOperation
}

/// Small, UI-framework-independent ownership of unsaved-decision presentation.
/// A generic Alert dismissal is deliberately not a decision: only a successful
/// resolution or explicit Cancel may retire the active presentation.
struct ProfileUnsavedChangesPresentation: Equatable {
    private(set) var generation = 0
    private(set) var activeGeneration: Int?

    var isPresented: Bool { activeGeneration != nil }

    mutating func requestPresentation() {
        generation &+= 1
        activeGeneration = generation
    }

    mutating func resolve(_ result: ProfileUnsavedChangesDecisionResult) {
        switch result {
        case .failedAndStillPending:
            // A failed button action gets one new presentation generation. It
            // stays stable until the user takes another explicit action.
            requestPresentation()
        case .resolved, .cancelled, .noPendingOperation:
            activeGeneration = nil
        }
    }

    func alertPresentationDidChange(_ isPresented: Bool) {
        // SwiftUI writes false while it dismisses an Alert. That event is not
        // authorization to discard a typed pending operation.
        guard isPresented else { return }
    }
}
