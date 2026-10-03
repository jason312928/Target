import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileConfigurationView: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TargetSectionTitle("profile.editor.section", systemImage: "curlybraces")
                    .accessibilityIdentifier("profile.editor.section")
                Spacer()
                if model.isDirty {
                    Label("profile.unsaved.indicator", systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("profile.unsaved.indicator"))
                        .accessibilityHint(Text("profile.unsaved.accessibility.hint"))
                        .accessibilityIdentifier("profile.editor.dirty")
                }
            }
            ZStack {
                JSONCodeEditor(
                    text: Binding(get: { model.editorText }, set: model.updateEditor),
                    isEditable: model.canEditConfiguration,
                    accessibilityIdentifier: "profile.json-editor",
                    accessibilityLabel: String(localized: "profile.editor.accessibility.label")
                )
                .id(profile.id)
                if !model.isConfigurationLoaded {
                    ContentUnavailableView(
                        "profile.editor.unavailable.title",
                        systemImage: "lock.trianglebadge.exclamationmark",
                        description: Text("profile.editor.unavailable.description")
                    )
                    .accessibilityIdentifier("profile.editor.unavailable")
                }
            }
            .frame(maxWidth: .infinity, minHeight: ProfileWorkspaceLayout.minimumEditorHeight, idealHeight: ProfileWorkspaceLayout.preferredEditorHeight, maxHeight: .infinity)
            .layoutPriority(1)
            ProfileFeedback(
                diagnostic: model.diagnostic,
                subscriptionFailure: model.subscriptionFailureDiagnostic,
                messageKey: model.messageKey
            )
            Divider()
            ProfileEditorActions(
                profile: profile,
                model: model
            )
        }
        // Keep the Configuration workspace's AX frame aligned with its detail
        // pane. Without an explicit expansion, AppKit reports only this
        // VStack's intrinsic content width even when the editor fills the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.workspace.configuration")
    }
}

struct ProfileFeedback: View {
    let diagnostic: ConfigurationDiagnostic?
    let subscriptionFailure: SubscriptionFailureDiagnostic?
    let messageKey: String?

    var body: some View {
        Group {
            if let subscriptionFailure {
                SubscriptionFailureView(diagnostic: subscriptionFailure)
            } else if let diagnostic {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(diagnostic.messageKey))
                        if let line = diagnostic.line, let column = diagnostic.column {
                            Text("profile.validation.location") + Text(" \(line):\(column)")
                        }
                    }
                }
                .foregroundStyle(.red)
                .font(.callout)
                .accessibilityIdentifier("profile.feedback.diagnostic")
            } else if let messageKey {
                TargetNotice(level: .neutral, messageKey: messageKey)
                    .accessibilityIdentifier("profile.feedback.message")
            }
        }
    }
}

struct ProfileEditorActions: View {
    let profile: Profile
    @Bindable var model: ProfileViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actions }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("profile.action.format") { model.format() }
                        .accessibilityIdentifier("profile.action.format")
                        .disabled(!model.canEditConfiguration)
                    Spacer()
                    saveButton
                }
                Text("profile.history.available") + Text(" \(profile.validRevision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("profile.editor.actions")
    }

    @ViewBuilder
    private var actions: some View {
        Button("profile.action.format") { model.format() }
            .accessibilityIdentifier("profile.action.format")
            .disabled(!model.canEditConfiguration)
        Text("profile.history.available") + Text(" \(profile.validRevision)")
            .font(.caption)
            .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        saveButton
    }

    private var saveButton: some View {
        Button("profile.action.save") { model.save() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s")
            .disabled(!model.isDirty || !model.canEditConfiguration)
            .accessibilityIdentifier("profile.action.save")
    }
}

struct ProfileStatusBadge: View {
    let level: ProfileWorkspaceStatusLevel
    let titleKey: String

    var body: some View {
        TargetStatusBadge(level: targetLevel, titleKey: titleKey)
    }

    private var targetLevel: TargetStatusLevel {
        switch level {
        case .neutral: .neutral
        case .positive: .positive
        case .warning: .warning
        case .critical: .critical
        }
    }
}
