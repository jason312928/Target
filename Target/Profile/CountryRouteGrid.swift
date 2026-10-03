import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CountryRouteGrid: View {
    let routes: [PolicyCountryRoute]
    let selectedMemberTag: String?
    let bindings: [ProfileRouteBinding]
    let bind: (URL, PolicyCountryRoute) -> Void
    let inspect: (PolicyCountryRoute) -> Void
    let choose: (PolicyCountryRoute) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(routes) { route in
                CountryRouteCard(
                    route: route,
                    selectedMemberTag: selectedMemberTag,
                    localeIdentifier: locale.identifier,
                    bindings: bindings.filter { $0.countryCode == route.country.code },
                    bind: bind,
                    inspect: { inspect(route) },
                    choose: { choose(route) }
                )
            }
        }
        .accessibilityIdentifier("policy.workspace.country-list")
    }
}

struct CountryRouteCard: View {
    let route: PolicyCountryRoute
    let selectedMemberTag: String?
    let localeIdentifier: String
    let bindings: [ProfileRouteBinding]
    let bind: (URL, PolicyCountryRoute) -> Void
    let inspect: () -> Void
    let choose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false
    @State private var isAddingLink = false

    private var isSelected: Bool {
        route.members.contains(where: { $0.tag == selectedMemberTag })
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 11) {
                Text(route.country.flag)
                    .font(.system(size: 22))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(isSelected ? 0.16 : 0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(route.country.displayName(localeIdentifier: localeIdentifier))
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(route.members.count) \(String(localized: "policy.workspace.nodes"))")
                        if let latency = route.bestLatencyMilliseconds {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Label("\(latency) ms", systemImage: "gauge.with.dots.needle.33percent")
                                .foregroundStyle(latencyTint(latency))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering || isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.09), lineWidth: isSelected ? 1.5 : 1)
            }
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
            .animation(
                accessibilityReduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
                value: isSelected
            )
        }
        .buttonStyle(SoftPressButtonStyle(pressedScale: 0.985, reduceMotion: accessibilityReduceMotion))
        .onHover { isHovering = $0 }
        .help(Text("policy.workspace.country.choose.hint"))
        .accessibilityLabel(Text(verbatim: route.country.displayName(localeIdentifier: localeIdentifier)))
        .accessibilityValue(Text("\(route.members.count) \(String(localized: "policy.workspace.nodes"))"))
        .accessibilityHint(Text("policy.workspace.country.choose.hint"))
        .accessibilityIdentifier("policy.workspace.country-card.\(route.id)")
        .onDrop(of: [.url], isTargeted: nil) { providers in
            RouteBindingDrop.load(from: providers) { url in bind(url, route) }
        }
        .contextMenu {
            Button("profile.route.view-details", systemImage: "sidebar.left", action: inspect)
            Divider()
            Text("\(route.members.filter(\.isSelectable).count) \(String(localized: "policy.workspace.nodes"))")
            ForEach(bindings) { binding in
                Text(binding.domain)
            }
            Divider()
            Button("profile.route.add-link", systemImage: "link.badge.plus") {
                isAddingLink = true
            }
        }
        .sheet(isPresented: $isAddingLink) {
            RouteBindingSheet(route: route) { url in
                bind(url, route)
            }
        }
    }

    private func latencyTint(_ latency: Int) -> Color {
        if latency < 160 { return .green }
        if latency < 360 { return .orange }
        return .red
    }
}
