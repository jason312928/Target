import SwiftUI

enum TargetUI {
    static let pageContentMaxWidth: CGFloat = 960
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardCornerRadius: CGFloat = 8
}

struct TargetPageLayout<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TargetUI.sectionSpacing) {
                content
            }
            .frame(maxWidth: TargetUI.pageContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(TargetUI.pagePadding)
        }
    }
}

struct TargetPageHeader: View {
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey?

    init(_ titleKey: LocalizedStringKey, subtitleKey: LocalizedStringKey? = nil) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.largeTitle.weight(.semibold))
            if let subtitleKey {
                Text(subtitleKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TargetSectionTitle: View {
    let titleKey: LocalizedStringKey
    let symbolName: String

    init(_ titleKey: LocalizedStringKey, systemImage symbolName: String) {
        self.titleKey = titleKey
        self.symbolName = symbolName
    }

    var body: some View {
        Label(titleKey, systemImage: symbolName)
            .font(.headline)
            .accessibilityElement(children: .combine)
    }
}

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
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TargetUI.cardCornerRadius, style: .continuous))
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: TargetUI.cardCornerRadius, style: .continuous))
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
