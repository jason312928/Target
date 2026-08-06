import Foundation

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
