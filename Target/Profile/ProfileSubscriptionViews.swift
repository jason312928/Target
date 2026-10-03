import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileSubscriptionStatus: View {
    let subscription: RemoteSubscription
    let presentation: ProfileWorkspacePresentation
    let isUpdating: Bool
    let update: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("profile.subscription.status")
                        .font(.callout.weight(.medium))
                    if let titleKey = presentation.subscriptionTitleKey,
                       let level = presentation.subscriptionLevel {
                        ProfileStatusBadge(level: level, titleKey: titleKey)
                    }
                }
                if let error = subscription.lastErrorKey {
                    Text(LocalizedStringKey(error))
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let checkedAt = subscription.lastCheckedAt {
                    (Text("profile.subscription.last-checked") + Text(" ") + Text(checkedAt, style: .relative))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            subscriptionAction
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.subscription.summary")
    }

    @ViewBuilder
    private var subscriptionAction: some View {
        if isUpdating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("profile.subscription.cancel", action: cancel)
                    .accessibilityIdentifier("profile.subscription.cancel")
            }
        } else {
            Button("profile.subscription.update", action: update)
                .controlSize(.small)
                .accessibilityIdentifier("profile.subscription.update")
        }
    }
}

struct SubscriptionFailureView: View {
    let diagnostic: SubscriptionFailureDiagnostic
    @State private var showsTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(diagnostic.titleKey), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(LocalizedStringKey(diagnostic.reasonKey))
                .font(.callout)
            DisclosureGroup("profile.subscription.diagnostic.details", isExpanded: $showsTechnicalDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        row("profile.subscription.diagnostic.stage", LocalizedStringKey(diagnostic.stage.titleKey))
                        row("profile.subscription.diagnostic.category", LocalizedStringKey(diagnostic.reasonKey))
                        if let status = diagnostic.httpStatus {
                            row("profile.subscription.diagnostic.http-status", Text("\(status)"))
                        }
                        if let domain = diagnostic.transportErrorDomain, let code = diagnostic.transportErrorCode {
                            row("profile.subscription.diagnostic.error-code", Text("\(domain) \(code)"))
                        }
                        if let attempts = diagnostic.attemptCount {
                            row("profile.subscription.diagnostic.attempts", Text("\(attempts)"))
                        }
                        if let contentType = diagnostic.contentType {
                            row("profile.subscription.diagnostic.content-type", Text(contentType))
                        }
                        if let bytes = diagnostic.responseBytes {
                            row("profile.subscription.diagnostic.response-bytes", Text("\(bytes)"))
                        }
                        if diagnostic.showsSupportedFormats {
                            row("profile.subscription.diagnostic.supported-formats",
                                LocalizedStringKey("profile.subscription.diagnostic.supported-formats.value"))
                        }
                        if let retryable = diagnostic.isRetryable {
                            row("profile.subscription.diagnostic.retry",
                                LocalizedStringKey(retryable
                                    ? "profile.subscription.diagnostic.retry.yes"
                                    : "profile.subscription.diagnostic.retry.no"))
                        }
                    }
                    .font(.caption)
                    Button("profile.subscription.diagnostic.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostic.copyableDescription, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("profile.subscription.diagnostic.copy")
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(12)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.subscription.failure-diagnostic")
    }

    @ViewBuilder
    private func row(_ titleKey: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        row(titleKey, Text(value))
    }

    @ViewBuilder
    private func row(_ titleKey: LocalizedStringKey, _ value: Text) -> some View {
        GridRow {
            Text(titleKey).foregroundStyle(.secondary)
            value.textSelection(.enabled)
        }
    }
}

struct SubscriptionIntakePreview: View {
    let pending: PendingSubscriptionIntake
    let dismiss: () -> Void
    let confirm: () -> Void

    private var summary: SubscriptionCompatibilitySummary { pending.normalization.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("profile.subscription.preview.title")
                .font(.headline)
                .accessibilityIdentifier("profile.subscription.preview")
            Text("profile.subscription.preview.description").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("profile.subscription.preview.format").foregroundStyle(.secondary)
                    Text(LocalizedStringKey(summary.format.titleKey))
                }
                GridRow {
                    Text("profile.subscription.preview.imported-nodes").foregroundStyle(.secondary)
                    Text("\(summary.nodeCount)")
                }
                if summary.skippedNodeCount > 0 {
                    GridRow {
                        Text("profile.subscription.preview.skipped-nodes").foregroundStyle(.secondary)
                        Text("\(summary.skippedNodeCount) / \(summary.totalNodeCount)")
                    }
                    GridRow {
                        Text("profile.subscription.preview.skipped-protocols").foregroundStyle(.secondary)
                        Text(summary.skippedProtocols.map(\.rawValue).joined(separator: ", "))
                    }
                }
                GridRow {
                    Text("profile.subscription.preview.protocols").foregroundStyle(.secondary)
                    Text(summary.protocols.map(\.rawValue).joined(separator: ", "))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.subscription.compatibility-summary")
            if summary.warnings.contains(.providerSemanticsNotImported) {
                Label("profile.subscription.warning.provider-semantics", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("profile.subscription.compatibility-warning")
            }
            if summary.warnings.contains(.unsupportedNodesSkipped) {
                Label("profile.subscription.warning.unsupported-nodes", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("profile.subscription.compatibility-warning.unsupported-nodes")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let diff = pending.diff {
                        DiffSection(section: diff.outbounds)
                        DiffSection(section: diff.routeRules)
                        DiffSection(section: diff.dns)
                        DiffSection(section: diff.inbounds)
                        DiffSection(section: diff.unknown)
                        if !diff.hasChanges {
                            Text("profile.diff.no-changes").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("profile.subscription.preview.new-description").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("profile.subscription.discard") { dismiss() }
                Button(confirmTitleKey) { confirm() }
                    .accessibilityIdentifier("profile.subscription.confirm")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }

    private var confirmTitleKey: LocalizedStringKey {
        if case .newProfile = pending.destination { return "profile.subscription.add-confirm" }
        return "profile.subscription.confirm"
    }
}

struct DiffSection: View {
    let section: ProfileConfigurationDiff.Section

    var body: some View {
        if section.hasChanges {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(section.id)).font(.subheadline.weight(.semibold))
                ForEach(section.added, id: \.self) { entry in
                    Label {
                        if entry == "profile.diff.added" { Text(LocalizedStringKey(entry)) }
                        else { Text(verbatim: entry) }
                    } icon: { Image(systemName: "plus.circle.fill") }
                        .foregroundStyle(.green)
                }
                ForEach(section.removed, id: \.self) { entry in
                    Label {
                        if entry == "profile.diff.removed" { Text(LocalizedStringKey(entry)) }
                        else { Text(verbatim: entry) }
                    } icon: { Image(systemName: "minus.circle.fill") }
                        .foregroundStyle(.red)
                }
                ForEach(section.modified, id: \.self) { entry in
                    Label {
                        if entry == "profile.diff.changed" { Text(LocalizedStringKey(entry)) }
                        else { Text(verbatim: entry) }
                    } icon: { Image(systemName: "pencil.circle.fill") }
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }
}
