import SwiftUI

enum TargetStatusLevel: Equatable {
    case neutral
    case positive
    case warning
    case critical

    var symbolName: String {
        switch self {
        case .neutral: "circle.fill"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .neutral: .secondary
        case .positive: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct TargetCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TargetStatusBadge: View {
    let level: TargetStatusLevel
    let titleKey: String

    var body: some View {
        Label {
            Text(LocalizedStringKey(titleKey))
        } icon: {
            Image(systemName: level.symbolName)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(level.tint)
        .accessibilityLabel(Text(LocalizedStringKey(titleKey)))
    }
}

struct TargetNotice: View {
    let level: TargetStatusLevel
    let messageKey: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TargetStatusBadge(level: level, titleKey: messageKey)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHint(Text("dashboard.notice.hint"))
    }
}

struct TargetStatusRow: View {
    let labelKey: String
    let valueKey: String?
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(labelKey))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            if let valueKey {
                Text(LocalizedStringKey(valueKey))
                    .multilineTextAlignment(.trailing)
            } else {
                Text(value ?? "—")
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
