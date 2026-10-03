import Foundation

enum RuntimeConnectionRouteMark: Equatable {
    case country(PolicyRouteCountry)
    case bypass
    case defaultRoute
}

struct RuntimeConnectionSidebarPresentation: Equatable {
    let destination: String
    let detail: String?
    let routeMark: RuntimeConnectionRouteMark

    init(connection: RuntimeConnection) {
        destination = connection.destination.isEmpty ? "-" : connection.destination
        let detailParts = [
            connection.destinationPort.map(String.init),
            connection.network?.uppercased()
        ].compactMap { $0 }
        detail = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
        routeMark = Self.routeMark(for: connection.outboundChain)
    }

    private static func routeMark(for chain: [String]) -> RuntimeConnectionRouteMark {
        if let country = chain.lazy.compactMap({ PolicyRouteCountry.recognize(in: $0) }).first {
            return .country(country)
        }
        let normalized = chain.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .init(identifier: "en_US_POSIX"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.contains(where: {
            $0 == "direct" || $0.contains("bypass") || $0.contains("绕过")
        }) {
            return .bypass
        }
        return .defaultRoute
    }
}


enum RuntimeConnectionSort: String, CaseIterable, Identifiable {
    case newest, destination, traffic
    var id: String { rawValue }
    var titleKey: String { "diagnostics.sort." + rawValue }
}

enum RuntimeConnectionPresentation {
    static func rows(_ source: [RuntimeConnection], query: String, sort: RuntimeConnectionSort) -> [RuntimeConnection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.filter { row in
            query.isEmpty || [row.destination, row.destinationIP ?? "", row.network ?? "", row.inbound ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || row.outboundChain.contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { lhs, rhs in
            switch sort {
            case .newest:
                if lhs.startedAt != rhs.startedAt { return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast) }
            case .destination:
                if lhs.destination != rhs.destination { return lhs.destination.localizedStandardCompare(rhs.destination) == .orderedAscending }
            case .traffic:
                let left = Double(lhs.uploadBytes ?? 0) + Double(lhs.downloadBytes ?? 0)
                let right = Double(rhs.uploadBytes ?? 0) + Double(rhs.downloadBytes ?? 0)
                if left != right { return left > right }
            }
            return lhs.id < rhs.id
        }
    }
}
