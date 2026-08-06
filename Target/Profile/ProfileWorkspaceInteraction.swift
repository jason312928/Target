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
