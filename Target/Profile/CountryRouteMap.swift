import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CountryRouteMap: View {
    let routes: [PolicyCountryRoute]
    let selectedMemberTag: String?
    let bindings: [ProfileRouteBinding]
    let bind: (URL, PolicyCountryRoute) -> Void
    let inspect: (PolicyCountryRoute) -> Void
    let choose: (PolicyCountryRoute) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hoveredCountryCode: String?

    private var selectedCountryCode: String? {
        routes.first(where: { route in
            route.members.contains(where: { $0.tag == selectedMemberTag })
        })?.id
    }

    private var selectionAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06)
    }

    var body: some View {
        GeometryReader { proxy in
            let focus = FlatMapFocus.world
            let placements = Self.markerPlacements(
                for: routes,
                selectedCountryCode: selectedCountryCode,
                in: proxy.size,
                focus: focus
            )
            ZStack {
                FlatWorldArtwork()
                    .equatable()
                markerConnectors(placements)
                ForEach(routes) { route in
                    countryButton(route)
                        .position(placements[route.id]?.marker ?? Self.point(for: route.country, in: proxy.size, focus: focus))
                        .zIndex(route.id == selectedCountryCode ? 1 : 0)
                }
            }
            .animation(selectionAnimation, value: selectedCountryCode)
        }
        .aspectRatio(1.9, contentMode: .fit)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("policy.workspace.country-map")
    }

    private func markerConnectors(_ placements: [String: MapMarkerPlacement]) -> some View {
        ZStack {
            ForEach(routes) { route in
                if let placement = placements[route.id] {
                    MapMarkerConnector(anchor: placement.anchor, marker: placement.marker)
                        .stroke(Color.primary.opacity(0.13), lineWidth: 0.8)
                    Circle()
                        .fill(Color.primary.opacity(0.24))
                        .frame(width: 3, height: 3)
                        .position(placement.anchor)
                        .opacity(placement.isDisplaced ? 1 : 0)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func countryButton(_ route: PolicyCountryRoute) -> some View {
        let isSelected = route.members.contains(where: { $0.tag == selectedMemberTag })
        let isHovered = hoveredCountryCode == route.id
        return Button {
            choose(route)
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                    .frame(width: isSelected ? 28 : 24, height: isSelected ? 28 : 24)
                    .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: 3, y: 1)
                Text(route.country.flag)
                    .font(.system(size: isSelected ? 14 : 12))
            }
            .frame(width: 34, height: 34)
            .overlay {
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.22 : 0.08), lineWidth: isSelected ? 2 : 1)
                    .frame(width: isSelected ? 34 : 28, height: isSelected ? 34 : 28)
            }
            .animation(selectionAnimation, value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .compositingGroup()
        }
        .buttonStyle(SoftPressButtonStyle(pressedScale: 0.94, reduceMotion: accessibilityReduceMotion))
        .disabled(route.bestMember == nil)
        .onHover { hovering in
            hoveredCountryCode = hovering ? route.id : nil
        }
        .help("\(route.country.displayName(localeIdentifier: locale.identifier)) · \(route.members.count) \(String(localized: "policy.workspace.nodes"))")
        .accessibilityLabel(Text(verbatim: route.country.displayName(localeIdentifier: locale.identifier)))
        .accessibilityValue(countryAccessibilityValue(route, selected: isSelected))
        .accessibilityHint(Text("policy.workspace.country.choose.hint"))
        .accessibilityIdentifier("policy.workspace.country.\(route.id)")
        .onDrop(of: [.url], isTargeted: nil) { providers in
            RouteBindingDrop.load(from: providers) { url in bind(url, route) }
        }
        .contextMenu {
            Button("profile.route.view-details", systemImage: "sidebar.left") { inspect(route) }
            Divider()
            Text("\(route.members.filter(\.isSelectable).count) \(String(localized: "policy.workspace.nodes"))")
            ForEach(bindings.filter { $0.countryCode == route.country.code }) { binding in
                Text(binding.domain)
            }
        }
    }

    private func countryAccessibilityValue(_ route: PolicyCountryRoute, selected: Bool) -> Text {
        var value = Text("policy.workspace.member-count") + Text(verbatim: ": \(route.members.count)")
        if let latency = route.bestLatencyMilliseconds {
            value = value + Text(verbatim: ", ") + Text("policy.health.latency")
                + Text(verbatim: ": \(latency) ") + Text("policy.health.milliseconds")
        }
        if selected {
            value = value + Text(verbatim: ", ") + Text("policy.workspace.filter.selected")
        }
        return value
    }

    private static func point(for country: PolicyRouteCountry, in size: CGSize, focus: FlatMapFocus) -> CGPoint {
        FlatMapProjection.point(for: country, in: size, focus: focus)
    }

    private static func markerPlacements(
        for routes: [PolicyCountryRoute],
        selectedCountryCode: String?,
        in size: CGSize,
        focus: FlatMapFocus
    ) -> [String: MapMarkerPlacement] {
        var placed: [CGPoint] = []
        var placements: [String: MapMarkerPlacement] = [:]
        let offsets: [CGSize] = [
            .zero,
            CGSize(width: 30, height: 0), CGSize(width: -30, height: 0),
            CGSize(width: 22, height: -24), CGSize(width: -22, height: -24),
            CGSize(width: 22, height: 24), CGSize(width: -22, height: 24),
            CGSize(width: 0, height: -32), CGSize(width: 0, height: 32),
            CGSize(width: 44, height: -16), CGSize(width: -44, height: -16),
            CGSize(width: 44, height: 16), CGSize(width: -44, height: 16)
        ]
        let mapBounds = FlatMapProjection.rect(in: size)
        let orderedRoutes = routes.sorted { $0.country.englishName < $1.country.englishName }

        // Establish a selection-independent layout first. Changing countries can
        // then move only the markers that actually collide with the new anchor.
        for route in orderedRoutes {
            let base = point(for: route.country, in: size, focus: focus)
            let candidate = markerCandidates(anchor: base, offsets: offsets, bounds: mapBounds)
                .first(where: { isAvailable($0, avoiding: placed) })
                ?? clamped(base, to: mapBounds)
            placements[route.id] = MapMarkerPlacement(anchor: base, marker: candidate)
            placed.append(candidate)
        }

        guard let selectedCountryCode,
              let selectedRoute = orderedRoutes.first(where: { $0.id == selectedCountryCode }) else {
            return placements
        }

        let selectedAnchor = point(for: selectedRoute.country, in: size, focus: focus)
        let affectedRoutes = orderedRoutes.filter { route in
            guard route.id != selectedCountryCode, let placement = placements[route.id] else { return false }
            return distance(placement.marker, selectedAnchor) < 31
        }
        let affectedIDs = Set(affectedRoutes.map(\.id))
        var occupied = [selectedAnchor]
        occupied.append(contentsOf: orderedRoutes.compactMap { route in
            guard route.id != selectedCountryCode,
                  !affectedIDs.contains(route.id) else { return nil }
            return placements[route.id]?.marker
        })

        placements[selectedCountryCode] = MapMarkerPlacement(anchor: selectedAnchor, marker: selectedAnchor)
        for route in affectedRoutes {
            let anchor = point(for: route.country, in: size, focus: focus)
            let previous = placements[route.id]?.marker
            let candidates = (previous.map { [$0] } ?? [])
                + markerCandidates(anchor: anchor, offsets: offsets, bounds: mapBounds)
            let marker = candidates.first(where: { isAvailable($0, avoiding: occupied) })
                ?? clamped(anchor, to: mapBounds)
            placements[route.id] = MapMarkerPlacement(anchor: anchor, marker: marker)
            occupied.append(marker)
        }
        return placements
    }

    private static func markerCandidates(anchor: CGPoint, offsets: [CGSize], bounds: CGRect) -> [CGPoint] {
        offsets.map { offset in
            clamped(CGPoint(x: anchor.x + offset.width, y: anchor.y + offset.height), to: bounds)
        }
    }

    private static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX + 18), bounds.maxX - 18),
            y: min(max(point.y, bounds.minY + 18), bounds.maxY - 18)
        )
    }

    private static func isAvailable(_ point: CGPoint, avoiding occupied: [CGPoint]) -> Bool {
        occupied.allSatisfy { distance($0, point) >= 31 }
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

struct MapMarkerPlacement {
    let anchor: CGPoint
    let marker: CGPoint

    var isDisplaced: Bool {
        hypot(marker.x - anchor.x, marker.y - anchor.y) > 2
    }
}

struct MapMarkerConnector: Shape {
    var anchor: CGPoint
    var marker: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(anchor.x, anchor.y),
                AnimatablePair(marker.x, marker.y)
            )
        }
        set {
            anchor = CGPoint(x: newValue.first.first, y: newValue.first.second)
            marker = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: anchor)
        path.addLine(to: marker)
        return path
    }
}

struct SoftPressButtonStyle: ButtonStyle {
    let pressedScale: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
