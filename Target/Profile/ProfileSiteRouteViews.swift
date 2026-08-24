import SwiftUI

struct CountryRouteInspector: View {
    let route: PolicyCountryRoute
    let bindings: [ProfileRouteBinding]
    let availableRouteOutboundTags: Set<String>
    let close: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 10) {
                    Text(route.country.flag)
                        .font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.country.displayName(localeIdentifier: locale.identifier))
                            .font(.headline)
                        Text("profile.route.country-detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text("profile.route.close-details"))
                }

                inspectorSection("profile.route.nodes", symbol: "server.rack") {
                    ForEach(route.members) { member in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(healthTint(member))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.tag)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(LocalizedStringKey(member.health.titleKey))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if let latency = member.health.latencyMilliseconds {
                                Text("\(latency) ms")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help(member.tag)
                    }
                }

                inspectorSection("profile.route.sites", symbol: "link") {
                    if bindings.isEmpty {
                        Text("profile.route.country-empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bindings) { binding in
                            Label(
                                binding.domain,
                                systemImage: availableRouteOutboundTags.contains(binding.outboundTag)
                                    ? "globe"
                                    : "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                availableRouteOutboundTags.contains(binding.outboundTag)
                                    ? Color.primary
                                    : Color.orange
                            )
                            .lineLimit(1)
                            .help(binding.domain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(.background.secondary)
        .accessibilityIdentifier("profile.route.country-detail.\(route.id)")
    }

    private func inspectorSection<Content: View>(
        _ titleKey: LocalizedStringKey,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(titleKey, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func healthTint(_ member: PolicyMemberPresentation) -> Color {
        guard member.isSelectable else { return .red }
        switch member.health.state {
        case .reachable: return .green
        case .unreachable, .runtimeUnavailable: return .red
        case .testing: return .orange
        case .unknown: return .secondary
        }
    }
}

enum RouteBindingDrop {
    static func load(from providers: [NSItemProvider], receive: @escaping (URL) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { receive(url) }
        }
        return true
    }
}

struct RouteBindingChip: View {
    let binding: ProfileRouteBinding
    let isAvailable: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isAvailable ? "globe" : "exclamationmark.triangle.fill")
                .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
            Text(binding.domain)
                .lineLimit(1)
            Text(PolicyRouteCountry.supported.first(where: { $0.code == binding.countryCode })?.flag ?? binding.countryCode)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("profile.route.remove"))
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(Text(isAvailable ? "profile.route.active" : "profile.route.unavailable"))
        .accessibilityIdentifier("profile.route.binding.\(binding.domain)")
    }
}

struct RouteBindingSheet: View {
    let route: PolicyCountryRoute
    let bind: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var parsedURL: URL? {
        guard let url = URL(string: text), ProfileRouteBinding.domain(from: url) != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("profile.route.add-link")
                .font(.title3.weight(.semibold))
            Text(route.country.displayName(localeIdentifier: Locale.current.identifier))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("profile.route.url", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("profile.action.cancel", role: .cancel) { dismiss() }
                Button("profile.route.save") {
                    guard let parsedURL else { return }
                    bind(parsedURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedURL == nil)
            }
        }
        .padding(20)
    }
}
