import SwiftUI

struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DashboardStatusBadge: View {
    let level: DashboardStatusLevel
    let titleKey: String

    private var symbol: String {
        switch level {
        case .neutral: "circle.fill"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch level {
        case .neutral: .secondary
        case .positive: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var body: some View {
        Label {
            Text(LocalizedStringKey(titleKey))
        } icon: {
            Image(systemName: symbol)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
        .accessibilityLabel(Text(LocalizedStringKey(titleKey)))
    }
}

struct DashboardStatusRow: View {
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

struct DashboardNotice: View {
    let level: DashboardStatusLevel
    let messageKey: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DashboardStatusBadge(level: level, titleKey: messageKey)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHint(Text("dashboard.notice.hint"))
    }
}
