import SwiftUI

/// Test-host-only accessibility state. This file is deliberately not a member
/// of the product target and exposes no profile JSON, paths, or credentials.
struct PresentationStateProbe: View {
    let fixture: PresentationFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            state("presentation.scenario", fixture.scenario.rawValue)
            state("presentation.selected-profile", fixture.model.selectedProfile?.name ?? "none")
            state("presentation.dirty", fixture.model.isDirty ? "true" : "false")
            state("presentation.pending-operation", pendingOperationName)
            state("presentation.active-presentation", fixture.model.unsavedChangesPresentation.isPresented ? "active" : "inactive")
            state("presentation.generation", "\(fixture.model.unsavedChangesPresentation.generation)")
            state("presentation.readiness-generation", "\(fixture.model.readinessChangeGeneration)")
            state("presentation.fixture-readiness-generation", "\(fixture.model.readinessChangeGeneration)")
            state("presentation.editor-state", editorState)
            state("presentation.import-candidate", fixture.model.pendingImportCandidate == nil ? "false" : "true")
            state("presentation.import-confirmation-presented", fixture.model.shouldPresentImportConfirmation ? "true" : "false")
            state("presentation.import-candidate-fingerprint", importCandidateFingerprint)
            state("presentation.subscription-candidate", fixture.model.pendingSubscriptionUpdate == nil ? "false" : "true")
            state("presentation.subscription-preview-presented", fixture.model.shouldPresentSubscriptionPreview ? "true" : "false")
            state("presentation.subscription-candidate-fingerprint", subscriptionCandidateFingerprint)
            state("presentation.subscription-intake-state", subscriptionIntakeState)
            state("presentation.subscription-source-presentation", "Remote Subscription")
            state("presentation.profile-count", "\(fixture.model.profiles.count)")
            state("presentation.selected-revision", "\(fixture.model.selectedProfile?.validRevision ?? 0)")
            state("presentation.second-profile-id", fixture.second.id.uuidString)
        }
        .font(.caption2)
        .foregroundStyle(.clear)
        .allowsHitTesting(false)
        .accessibilityHidden(false)
    }

    private func state(_ identifier: String, _ value: String) -> some View {
        Text(value)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value)
    }

    private var pendingOperationName: String {
        switch fixture.model.pendingOperation {
        case .none: "none"
        case .select(let id): id == fixture.second.id ? "select-second" : "select"
        case .selectPolicy: "select-policy"
        case .create: "create"
        case .duplicate: "duplicate"
        case .delete: "delete"
        case .restore: "restore"
        case .importCandidate: "import-candidate"
        case .applySubscription: "apply-subscription"
        }
    }

    private var editorState: String {
        if fixture.model.editorText.contains("fixtureDirty") { return "fixture-dirty" }
        if fixture.model.selectedID == fixture.second.id { return "second-persisted" }
        return "first-persisted"
    }

    private var importCandidateFingerprint: String {
        fixture.model.pendingImportCandidate.map { TargetConfigurationFingerprint.sha256($0.data) } ?? "none"
    }

    private var subscriptionCandidateFingerprint: String {
        fixture.model.pendingSubscriptionUpdate.map {
            TargetConfigurationFingerprint.sha256($0.normalization.data)
        } ?? "none"
    }


    private var subscriptionIntakeState: String {
        if fixture.model.isUpdatingSubscription { return "progress" }
        if fixture.model.pendingSubscriptionIntake != nil { return "preview" }
        if fixture.model.messageKey == "profile.subscription.error.download-failed" { return "safe-error" }
        return "idle"
    }
}
