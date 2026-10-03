import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FlatMapCoordinate {
    let latitude: Double
    let longitude: Double
}

struct FlatMapFocus: Equatable {
    let latitude: ClosedRange<Double>
    let longitude: ClosedRange<Double>

    static let world = FlatMapFocus(latitude: -90...90, longitude: -180...180)

    var latitudeSpan: Double { latitude.upperBound - latitude.lowerBound }
    var longitudeSpan: Double { longitude.upperBound - longitude.lowerBound }
}

enum FlatMapProjection {
    static func rect(in size: CGSize) -> CGRect {
        let horizontalPadding = min(size.width * 0.03, 22)
        let verticalPadding = min(size.height * 0.12, 24)
        return CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: max(size.width - horizontalPadding * 2, 1),
            height: max(size.height - verticalPadding * 2, 1)
        )
    }

    static func point(for country: PolicyRouteCountry, in size: CGSize, focus: FlatMapFocus? = nil) -> CGPoint {
        point(latitude: country.latitude, longitude: country.longitude, in: size, focus: focus)
    }

    static func point(latitude: Double, longitude: Double, in size: CGSize, focus: FlatMapFocus? = nil) -> CGPoint {
        let mapFocus = focus ?? .world
        let bounds = rect(in: size)
        let normalized = normalizedPoint(latitude: latitude, longitude: longitude, focus: mapFocus)
        return CGPoint(
            x: bounds.minX + normalized.x * bounds.width,
            y: bounds.minY + normalized.y * bounds.height
        )
    }

    static func normalizedPoint(latitude: Double, longitude: Double, focus: FlatMapFocus) -> CGPoint {
        CGPoint(
            x: (longitude - focus.longitude.lowerBound) / focus.longitudeSpan,
            y: (focus.latitude.upperBound - latitude) / focus.latitudeSpan
        )
    }
}

/// Loads the bundled Natural Earth topology once. Rendering all rings in one
/// fill keeps the detailed coastline while avoiding per-country seam artifacts.
enum WorldMapGeometry {
    static let rings: [[FlatMapCoordinate]] = load()

    private static func load() -> [[FlatMapCoordinate]] {
        guard let url = Bundle.main.url(forResource: "countries-110m", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transform = root["transform"] as? [String: Any] else {
            return []
        }
        let scale = numbers(transform["scale"])
        let translate = numbers(transform["translate"])
        guard scale.count == 2, translate.count == 2 else { return [] }

        let arcs = arrays(root["arcs"]).map { rawArc in
            arrays(rawArc).compactMap { point -> [Double]? in
                let values = numbers(point)
                return values.count >= 2 ? values : nil
            }
        }
        guard !arcs.isEmpty,
              let objects = root["objects"] as? [String: Any],
              let countries = objects["countries"] as? [String: Any] else {
            return []
        }

        var rings: [[FlatMapCoordinate]] = []
        for rawGeometry in arrays(countries["geometries"]) {
            guard let geometry = rawGeometry as? [String: Any],
                  let type = geometry["type"] as? String else { continue }
            let rawGeometryArcs = arrays(geometry["arcs"])
            switch type {
            case "Polygon":
                appendRings(rawGeometryArcs, arcs: arcs, scale: scale, translate: translate, to: &rings)
            case "MultiPolygon":
                for rawPolygon in rawGeometryArcs {
                    appendRings(arrays(rawPolygon), arcs: arcs, scale: scale, translate: translate, to: &rings)
                }
            default:
                continue
            }
        }
        return rings
    }

    private static func appendRings(
        _ rawRings: [Any],
        arcs: [[[Double]]],
        scale: [Double],
        translate: [Double],
        to rings: inout [[FlatMapCoordinate]]
    ) {
        for rawRing in rawRings {
            let indexes = numbers(rawRing).map { Int($0.rounded()) }
            let ring = decode(indexes, arcs: arcs, scale: scale, translate: translate)
            if ring.count >= 3 { rings.append(ring) }
        }
    }

    private static func decode(
        _ indexes: [Int],
        arcs: [[[Double]]],
        scale: [Double],
        translate: [Double]
    ) -> [FlatMapCoordinate] {
        var points: [FlatMapCoordinate] = []
        for (position, encodedIndex) in indexes.enumerated() {
            let reversed = encodedIndex < 0
            let index = reversed ? ~encodedIndex : encodedIndex
            guard arcs.indices.contains(index) else { continue }
            var previousX = 0.0
            var previousY = 0.0
            var decodedArc: [FlatMapCoordinate] = []
            for rawPoint in arcs[index] where rawPoint.count >= 2 {
                previousX += rawPoint[0]
                previousY += rawPoint[1]
                decodedArc.append(FlatMapCoordinate(
                    latitude: previousY * scale[1] + translate[1],
                    longitude: previousX * scale[0] + translate[0]
                ))
            }
            if reversed { decodedArc.reverse() }
            if position > 0, !decodedArc.isEmpty { decodedArc.removeFirst() }
            points.append(contentsOf: decodedArc)
        }
        return points
    }

    private static func arrays(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func numbers(_ value: Any?) -> [Double] {
        arrays(value).compactMap { ($0 as? NSNumber)?.doubleValue }
    }
}

struct FlatWorldArtwork: View, Equatable {
    private static let normalizedLand: Path = {
        let polygons = WorldMapGeometry.rings.isEmpty ? fallbackContinents : WorldMapGeometry.rings
        var land = Path()
        for polygon in polygons {
            append(polygon, to: &land)
        }
        return land
    }()

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let bounds = FlatMapProjection.rect(in: size)
            let transform = CGAffineTransform(translationX: bounds.minX, y: bounds.minY)
                .scaledBy(x: bounds.width, y: bounds.height)
            context.clip(to: Path(bounds))
            context.fill(
                Self.normalizedLand.applying(transform),
                with: .color(Color.primary.opacity(0.045)),
                style: FillStyle(eoFill: true)
            )
        }
        .accessibilityHidden(true)
    }

    private static func append(
        _ polygon: [FlatMapCoordinate],
        to path: inout Path
    ) {
        guard let first = polygon.first else { return }
        var unwrapped = [first]
        for coordinate in polygon.dropFirst() {
            var longitude = coordinate.longitude
            guard let previousLongitude = unwrapped.last?.longitude else { continue }
            while longitude - previousLongitude > 180 { longitude -= 360 }
            while longitude - previousLongitude < -180 { longitude += 360 }
            unwrapped.append(FlatMapCoordinate(latitude: coordinate.latitude, longitude: longitude))
        }

        let closureDelta = (unwrapped.last?.longitude ?? first.longitude) - first.longitude
        if abs(closureDelta) > 180 {
            appendPolarRing(unwrapped, closureDelta: closureDelta, to: &path)
            return
        }

        // Dateline-crossing islands and coastlines are drawn on both sides of
        // the flat map, then clipped. No segment ever connects +180 to -180.
        for offset in [-360.0, 0, 360.0] {
            appendRing(unwrapped, longitudeOffset: offset, to: &path)
        }
    }

    private static func appendPolarRing(
        _ polygon: [FlatMapCoordinate],
        closureDelta: Double,
        to path: inout Path
    ) {
        guard let first = polygon.first else { return }
        let pole = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count) < 0 ? -90.0 : 90.0
        appendOpenRing(polygon, longitudeOffset: 0, to: &path)
        let endingEdge = closureDelta > 0 ? 180.0 : -180.0
        let startingEdge = closureDelta > 0 ? -180.0 : 180.0
        path.addLine(to: normalizedPoint(latitude: pole, longitude: endingEdge))
        path.addLine(to: normalizedPoint(latitude: pole, longitude: startingEdge))
        path.addLine(to: normalizedPoint(latitude: first.latitude, longitude: first.longitude))
        path.closeSubpath()
    }

    private static func appendRing(
        _ polygon: [FlatMapCoordinate],
        longitudeOffset: Double,
        to path: inout Path
    ) {
        appendOpenRing(polygon, longitudeOffset: longitudeOffset, to: &path)
        path.closeSubpath()
    }

    private static func appendOpenRing(
        _ polygon: [FlatMapCoordinate],
        longitudeOffset: Double,
        to path: inout Path
    ) {
        for (index, coordinate) in polygon.enumerated() {
            let point = normalizedPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude + longitudeOffset
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
    }

    private static func normalizedPoint(latitude: Double, longitude: Double) -> CGPoint {
        FlatMapProjection.normalizedPoint(latitude: latitude, longitude: longitude, focus: .world)
    }

    private static let fallbackContinents: [[FlatMapCoordinate]] = [
        [
            FlatMapCoordinate(latitude: 72, longitude: -168), FlatMapCoordinate(latitude: 70, longitude: -140),
            FlatMapCoordinate(latitude: 61, longitude: -128), FlatMapCoordinate(latitude: 55, longitude: -125),
            FlatMapCoordinate(latitude: 48, longitude: -124), FlatMapCoordinate(latitude: 30, longitude: -117),
            FlatMapCoordinate(latitude: 16, longitude: -90), FlatMapCoordinate(latitude: 20, longitude: -82),
            FlatMapCoordinate(latitude: 30, longitude: -82), FlatMapCoordinate(latitude: 44, longitude: -67),
            FlatMapCoordinate(latitude: 51, longitude: -58), FlatMapCoordinate(latitude: 60, longitude: -64),
            FlatMapCoordinate(latitude: 70, longitude: -76), FlatMapCoordinate(latitude: 75, longitude: -105),
            FlatMapCoordinate(latitude: 72, longitude: -168)
        ],
        [
            FlatMapCoordinate(latitude: 13, longitude: -81), FlatMapCoordinate(latitude: 5, longitude: -77),
            FlatMapCoordinate(latitude: -12, longitude: -78), FlatMapCoordinate(latitude: -23, longitude: -70),
            FlatMapCoordinate(latitude: -38, longitude: -73), FlatMapCoordinate(latitude: -55, longitude: -68),
            FlatMapCoordinate(latitude: -52, longitude: -58), FlatMapCoordinate(latitude: -35, longitude: -54),
            FlatMapCoordinate(latitude: -10, longitude: -35), FlatMapCoordinate(latitude: 4, longitude: -52),
            FlatMapCoordinate(latitude: 13, longitude: -81)
        ],
        [
            FlatMapCoordinate(latitude: 37, longitude: -10), FlatMapCoordinate(latitude: 44, longitude: -8),
            FlatMapCoordinate(latitude: 50, longitude: -5), FlatMapCoordinate(latitude: 59, longitude: 3),
            FlatMapCoordinate(latitude: 70, longitude: 32), FlatMapCoordinate(latitude: 67, longitude: 58),
            FlatMapCoordinate(latitude: 72, longitude: 100), FlatMapCoordinate(latitude: 67, longitude: 145),
            FlatMapCoordinate(latitude: 54, longitude: 168), FlatMapCoordinate(latitude: 42, longitude: 141),
            FlatMapCoordinate(latitude: 27, longitude: 122), FlatMapCoordinate(latitude: 18, longitude: 108),
            FlatMapCoordinate(latitude: 10, longitude: 80), FlatMapCoordinate(latitude: 24, longitude: 55),
            FlatMapCoordinate(latitude: 35, longitude: 35), FlatMapCoordinate(latitude: 36, longitude: 15),
            FlatMapCoordinate(latitude: 37, longitude: -10)
        ],
        [
            FlatMapCoordinate(latitude: 37, longitude: -18), FlatMapCoordinate(latitude: 35, longitude: 10),
            FlatMapCoordinate(latitude: 29, longitude: 33), FlatMapCoordinate(latitude: 13, longitude: 42),
            FlatMapCoordinate(latitude: -5, longitude: 51), FlatMapCoordinate(latitude: -22, longitude: 42),
            FlatMapCoordinate(latitude: -35, longitude: 27), FlatMapCoordinate(latitude: -34, longitude: 17),
            FlatMapCoordinate(latitude: -20, longitude: 10), FlatMapCoordinate(latitude: 2, longitude: -5),
            FlatMapCoordinate(latitude: 20, longitude: -17), FlatMapCoordinate(latitude: 37, longitude: -18)
        ],
        [
            FlatMapCoordinate(latitude: -11, longitude: 112), FlatMapCoordinate(latitude: -18, longitude: 129),
            FlatMapCoordinate(latitude: -35, longitude: 153), FlatMapCoordinate(latitude: -41, longitude: 146),
            FlatMapCoordinate(latitude: -38, longitude: 122), FlatMapCoordinate(latitude: -25, longitude: 113),
            FlatMapCoordinate(latitude: -11, longitude: 112)
        ],
        [
            FlatMapCoordinate(latitude: 83, longitude: -74), FlatMapCoordinate(latitude: 76, longitude: -63),
            FlatMapCoordinate(latitude: 70, longitude: -50), FlatMapCoordinate(latitude: 60, longitude: -43),
            FlatMapCoordinate(latitude: 66, longitude: -22), FlatMapCoordinate(latitude: 76, longitude: -20),
            FlatMapCoordinate(latitude: 83, longitude: -38), FlatMapCoordinate(latitude: 83, longitude: -74)
        ]
    ]
}
