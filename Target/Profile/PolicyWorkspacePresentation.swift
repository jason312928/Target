import Foundation

/// Presentation-only facts for the Proxies workspace. This deliberately works
/// from the credential-safe PolicyCatalog rather than from Profile JSON.
enum PolicyWorkspaceFilter: String, CaseIterable, Identifiable {
    case all
    case selected
    case needsRestart
    case issues

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: "policy.workspace.filter.all"
        case .selected: "policy.workspace.filter.selected"
        case .needsRestart: "policy.workspace.filter.needs-restart"
        case .issues: "policy.workspace.filter.issues"
        }
    }
}

enum PolicyLatencyActionAvailability {
    static func isAvailable(
        engineIsRunning: Bool,
        isTestingLatency: Bool,
        lifecycleBusy: Bool,
        selectorTag: String?,
        hasSelectableMembers: Bool
    ) -> Bool {
        engineIsRunning
            && !isTestingLatency
            && !lifecycleBusy
            && selectorTag != nil
            && hasSelectableMembers
    }
}

struct PolicyWorkspacePresentation {
    let catalog: PolicyCatalog?
    let unavailable: Bool
    var healthBySelector: [Int: [String: RuntimeProxyHealth]] = [:]

    var selectors: [PolicySelectorPresentation] {
        catalog?.selectors.map { selector in
            PolicySelectorPresentation(selector, health: healthBySelector[selector.id] ?? [:])
        } ?? []
    }

    var selectorCount: Int { selectors.count }
    var overrideCount: Int { catalog?.storedOverrideCount ?? 0 }
    var restartRequiredCount: Int { selectors.filter(\.restartRequired).count }
    var hasIssues: Bool { selectors.contains(where: \.hasIssue) }

    func selectors(matching query: String, filter: PolicyWorkspaceFilter) -> [PolicySelectorPresentation] {
        selectors.filter { selector in
            selector.matches(query: query) && selector.matches(filter: filter)
        }
    }
}

struct PolicySelectorPresentation: Identifiable, Equatable {
    let selector: PolicyCatalogSelector
    let health: [String: RuntimeProxyHealth]

    init(_ selector: PolicyCatalogSelector, health: [String: RuntimeProxyHealth] = [:]) {
        self.selector = selector
        self.health = health
    }

    var id: Int { selector.id }
    var tag: String? { selector.tag }
    var displayTag: String { selector.tag ?? String(localized: "policy.catalog.invalid-tag") }
    var memberCount: Int { selector.members.count }
    var desiredSelection: String? { selector.effectiveDesired }
    var runningSelection: String? { selector.runningSelection }
    var configuredDefault: String? { selector.configuredDefault }
    var restartRequired: Bool { selector.restartRequired }
    var isMutable: Bool { selector.isMutable }
    var statusKey: String? { selector.status.presentationKey }
    var statusSymbol: String { selector.status.presentationSymbol }
    var statusLevel: TargetStatusLevel { selector.status.presentationLevel }
    var hasIssue: Bool {
        selector.status != .available
            || selector.members.contains(where: { $0.status != .available })
            || selector.runtimeConvergence == .unavailable
    }

    var runtime: PolicyRuntimePresentation {
        PolicyRuntimePresentation(selector: selector)
    }

    var members: [PolicyMemberPresentation] {
        selector.members.map { member in
            PolicyMemberPresentation(member, selector: selector, health: health[member.tag])
        }
    }
    var hasHealthResults: Bool {
        health.values.contains { ![.unknown, .testing].contains($0.state) }
    }

    func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return ([selector.tag ?? ""] + selector.members.flatMap { [$0.tag, $0.type ?? ""] })
            .contains { $0.lowercased().contains(normalized) }
    }

    func matches(filter: PolicyWorkspaceFilter) -> Bool {
        switch filter {
        case .all: true
        case .selected: selector.targetOverride != nil
        case .needsRestart: restartRequired
        case .issues: hasIssue
        }
    }
}

struct PolicyMemberPresentation: Identifiable, Equatable {
    let member: PolicyCatalogMember
    let role: PolicyMemberRole
    let health: PolicyMemberHealthPresentation

    init(
        _ member: PolicyCatalogMember,
        selector: PolicyCatalogSelector,
        health: RuntimeProxyHealth? = nil
    ) {
        self.member = member
        self.health = PolicyMemberHealthPresentation(health)
        if selector.effectiveDesired == member.tag {
            role = .desired
        } else if selector.runningSelection == member.tag {
            role = .running
        } else if selector.configuredDefault == member.tag {
            role = .configuredDefault
        } else {
            role = .none
        }
    }

    var id: Int { member.id }
    var tag: String { member.tag }
    var type: String? { member.type }
    var endpoint: String? { member.endpoint }
    var statusKey: String? { member.status.presentationKey }
    var statusSymbol: String { member.status.presentationSymbol }
    var statusLevel: TargetStatusLevel { member.status.presentationLevel }
    var isSelectable: Bool { member.status == .available }
}

struct PolicyMemberHealthPresentation: Equatable {
    let state: RuntimeProxyHealthState
    let latencyMilliseconds: Int?

    init(_ health: RuntimeProxyHealth?) {
        state = health?.state ?? .unknown
        latencyMilliseconds = health?.latencyMilliseconds
    }

    var titleKey: String {
        switch state {
        case .unknown: "policy.health.not-tested"
        case .testing: "policy.health.testing"
        case .reachable: "policy.health.latency"
        case .unreachable: "policy.health.unavailable"
        case .runtimeUnavailable: "policy.health.runtime-unavailable"
        }
    }

    var level: TargetStatusLevel {
        switch state {
        case .unreachable, .runtimeUnavailable: .warning
        case .unknown, .testing, .reachable: .neutral
        }
    }
}

struct PolicyRouteCountry: Identifiable, Equatable, Hashable {
    let code: String
    let englishName: String
    let simplifiedChineseName: String
    let latitude: Double
    let longitude: Double
    let aliases: [String]

    var id: String { code }

    var flag: String {
        String(code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127_397 + Int($0.value))
        }.map(Character.init))
    }

    func displayName(localeIdentifier: String) -> String {
        localeIdentifier.lowercased().hasPrefix("zh") ? simplifiedChineseName : englishName
    }

    static func recognize(in nodeName: String, endpoint: String? = nil) -> PolicyRouteCountry? {
        if let ipCountry = PolicyIPCountryResolver.country(for: endpoint),
           let country = supported.first(where: { $0.code == ipCountry }) {
            return country
        }
        if let flaggedCountry = supported.first(where: { nodeName.contains($0.flag) }) {
            return flaggedCountry
        }

        let normalizedName = normalized(nodeName)
        let paddedName = " \(normalizedName) "
        var bestMatch: (country: PolicyRouteCountry, length: Int)?

        for country in supported {
            for alias in country.aliases {
                let normalizedAlias = normalized(alias)
                let containsAlias: Bool
                if normalizedAlias.unicodeScalars.contains(where: { !$0.isASCII }) {
                    containsAlias = normalizedName.contains(normalizedAlias)
                } else {
                    containsAlias = paddedName.contains(" \(normalizedAlias) ")
                }
                guard containsAlias else { continue }
                // Equal-length aliases keep the earlier supported country.
                // This prevents a broad later alias such as "中国" from
                // overriding the explicit Taiwan match in "中国台湾".
                if bestMatch.map({ normalizedAlias.count > $0.length }) ?? true {
                    bestMatch = (country, normalizedAlias.count)
                }
            }
        }
        return bestMatch?.country
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let supported: [PolicyRouteCountry] = [
        .init(code: "HK", englishName: "Hong Kong", simplifiedChineseName: "香港", latitude: 22.32, longitude: 114.17, aliases: ["hong kong", "hongkong", "hk", "hkg", "香港"]),
        .init(code: "TW", englishName: "Taiwan", simplifiedChineseName: "台湾", latitude: 23.70, longitude: 120.96, aliases: ["taiwan", "taipei", "tw", "tpe", "台湾", "台灣", "台北", "臺北"]),
        .init(code: "JP", englishName: "Japan", simplifiedChineseName: "日本", latitude: 36.20, longitude: 138.25, aliases: ["japan", "tokyo", "osaka", "jp", "jpn", "日本", "东京", "大阪"]),
        .init(code: "SG", englishName: "Singapore", simplifiedChineseName: "新加坡", latitude: 1.35, longitude: 103.82, aliases: ["singapore", "singapore city", "sg", "sgp", "新加坡", "狮城"]),
        .init(code: "CN", englishName: "China", simplifiedChineseName: "中国", latitude: 35.86, longitude: 104.20, aliases: ["china", "beijing", "shanghai", "cn", "chn", "中国", "北京", "上海"]),
        .init(code: "KR", englishName: "South Korea", simplifiedChineseName: "韩国", latitude: 36.50, longitude: 127.90, aliases: ["south korea", "korea", "seoul", "kr", "kor", "韩国", "首尔"]),
        .init(code: "US", englishName: "United States", simplifiedChineseName: "美国", latitude: 39.50, longitude: -98.35, aliases: ["united states", "usa", "us", "america", "los angeles", "new york", "san jose", "seattle", "chicago", "美国", "洛杉矶", "纽约", "西雅图", "圣何塞"]),
        .init(code: "CA", englishName: "Canada", simplifiedChineseName: "加拿大", latitude: 56.13, longitude: -106.35, aliases: ["canada", "toronto", "vancouver", "montreal", "ca", "can", "加拿大", "多伦多", "温哥华"]),
        .init(code: "GB", englishName: "United Kingdom", simplifiedChineseName: "英国", latitude: 54.70, longitude: -3.50, aliases: ["united kingdom", "great britain", "britain", "england", "london", "uk", "gb", "英国", "伦敦"]),
        .init(code: "DE", englishName: "Germany", simplifiedChineseName: "德国", latitude: 51.17, longitude: 10.45, aliases: ["germany", "frankfurt", "berlin", "de", "deu", "德国", "法兰克福", "柏林"]),
        .init(code: "FR", englishName: "France", simplifiedChineseName: "法国", latitude: 46.23, longitude: 2.21, aliases: ["france", "paris", "fr", "fra", "法国", "巴黎"]),
        .init(code: "NL", englishName: "Netherlands", simplifiedChineseName: "荷兰", latitude: 52.13, longitude: 5.29, aliases: ["netherlands", "holland", "amsterdam", "nl", "nld", "荷兰", "阿姆斯特丹"]),
        .init(code: "CH", englishName: "Switzerland", simplifiedChineseName: "瑞士", latitude: 46.82, longitude: 8.23, aliases: ["switzerland", "zurich", "ch", "che", "瑞士", "苏黎世"]),
        .init(code: "SE", englishName: "Sweden", simplifiedChineseName: "瑞典", latitude: 60.13, longitude: 18.64, aliases: ["sweden", "stockholm", "se", "swe", "瑞典", "斯德哥尔摩"]),
        .init(code: "FI", englishName: "Finland", simplifiedChineseName: "芬兰", latitude: 61.92, longitude: 25.75, aliases: ["finland", "helsinki", "fi", "fin", "芬兰", "赫尔辛基"]),
        .init(code: "NO", englishName: "Norway", simplifiedChineseName: "挪威", latitude: 60.47, longitude: 8.47, aliases: ["norway", "oslo", "no", "nor", "挪威", "奥斯陆"]),
        .init(code: "DK", englishName: "Denmark", simplifiedChineseName: "丹麦", latitude: 56.26, longitude: 9.50, aliases: ["denmark", "copenhagen", "dk", "dnk", "丹麦", "哥本哈根"]),
        .init(code: "IE", englishName: "Ireland", simplifiedChineseName: "爱尔兰", latitude: 53.14, longitude: -7.69, aliases: ["ireland", "dublin", "ie", "irl", "爱尔兰", "都柏林"]),
        .init(code: "IT", englishName: "Italy", simplifiedChineseName: "意大利", latitude: 41.87, longitude: 12.57, aliases: ["italy", "milan", "rome", "it", "ita", "意大利", "米兰", "罗马"]),
        .init(code: "ES", englishName: "Spain", simplifiedChineseName: "西班牙", latitude: 40.46, longitude: -3.75, aliases: ["spain", "madrid", "es", "esp", "西班牙", "马德里"]),
        .init(code: "PL", englishName: "Poland", simplifiedChineseName: "波兰", latitude: 51.92, longitude: 19.15, aliases: ["poland", "warsaw", "pl", "pol", "波兰", "华沙"]),
        .init(code: "CZ", englishName: "Czechia", simplifiedChineseName: "捷克", latitude: 49.82, longitude: 15.47, aliases: ["czechia", "czech republic", "prague", "cz", "cze", "捷克", "布拉格"]),
        .init(code: "AT", englishName: "Austria", simplifiedChineseName: "奥地利", latitude: 47.52, longitude: 14.55, aliases: ["austria", "vienna", "at", "aut", "奥地利", "维也纳"]),
        .init(code: "BE", englishName: "Belgium", simplifiedChineseName: "比利时", latitude: 50.50, longitude: 4.47, aliases: ["belgium", "brussels", "be", "bel", "比利时", "布鲁塞尔"]),
        .init(code: "PT", englishName: "Portugal", simplifiedChineseName: "葡萄牙", latitude: 39.40, longitude: -8.22, aliases: ["portugal", "lisbon", "pt", "prt", "葡萄牙", "里斯本"]),
        .init(code: "TR", englishName: "Turkey", simplifiedChineseName: "土耳其", latitude: 38.96, longitude: 35.24, aliases: ["turkey", "turkiye", "istanbul", "tr", "tur", "土耳其", "伊斯坦布尔"]),
        .init(code: "AE", englishName: "United Arab Emirates", simplifiedChineseName: "阿联酋", latitude: 23.42, longitude: 53.85, aliases: ["united arab emirates", "uae", "dubai", "ae", "are", "阿联酋", "迪拜"]),
        .init(code: "IL", englishName: "Israel", simplifiedChineseName: "以色列", latitude: 31.05, longitude: 34.85, aliases: ["israel", "tel aviv", "il", "isr", "以色列", "特拉维夫"]),
        .init(code: "IN", englishName: "India", simplifiedChineseName: "印度", latitude: 20.59, longitude: 78.96, aliases: ["india", "mumbai", "delhi", "in", "ind", "印度", "孟买", "德里"]),
        .init(code: "TH", englishName: "Thailand", simplifiedChineseName: "泰国", latitude: 15.87, longitude: 100.99, aliases: ["thailand", "bangkok", "th", "tha", "泰国", "曼谷"]),
        .init(code: "MY", englishName: "Malaysia", simplifiedChineseName: "马来西亚", latitude: 4.21, longitude: 101.98, aliases: ["malaysia", "kuala lumpur", "my", "mys", "马来西亚", "吉隆坡"]),
        .init(code: "ID", englishName: "Indonesia", simplifiedChineseName: "印度尼西亚", latitude: -0.79, longitude: 113.92, aliases: ["indonesia", "jakarta", "id", "idn", "印度尼西亚", "印尼", "雅加达"]),
        .init(code: "PH", englishName: "Philippines", simplifiedChineseName: "菲律宾", latitude: 12.88, longitude: 121.77, aliases: ["philippines", "manila", "ph", "phl", "菲律宾", "马尼拉"]),
        .init(code: "VN", englishName: "Vietnam", simplifiedChineseName: "越南", latitude: 14.06, longitude: 108.28, aliases: ["vietnam", "hanoi", "ho chi minh", "vn", "vnm", "越南", "河内", "胡志明"]),
        .init(code: "AU", englishName: "Australia", simplifiedChineseName: "澳大利亚", latitude: -25.27, longitude: 133.78, aliases: ["australia", "sydney", "melbourne", "au", "aus", "澳大利亚", "澳洲", "悉尼", "墨尔本"]),
        .init(code: "NZ", englishName: "New Zealand", simplifiedChineseName: "新西兰", latitude: -40.90, longitude: 174.89, aliases: ["new zealand", "auckland", "nz", "nzl", "新西兰", "奥克兰"]),
        .init(code: "BR", englishName: "Brazil", simplifiedChineseName: "巴西", latitude: -14.24, longitude: -51.93, aliases: ["brazil", "sao paulo", "br", "bra", "巴西", "圣保罗"]),
        .init(code: "MX", englishName: "Mexico", simplifiedChineseName: "墨西哥", latitude: 23.63, longitude: -102.55, aliases: ["mexico", "mexico city", "mx", "mex", "墨西哥"]),
        .init(code: "AR", englishName: "Argentina", simplifiedChineseName: "阿根廷", latitude: -38.42, longitude: -63.62, aliases: ["argentina", "buenos aires", "ar", "arg", "阿根廷", "布宜诺斯艾利斯"]),
        .init(code: "CL", englishName: "Chile", simplifiedChineseName: "智利", latitude: -35.68, longitude: -71.54, aliases: ["chile", "santiago", "cl", "chl", "智利", "圣地亚哥"]),
        .init(code: "ZA", englishName: "South Africa", simplifiedChineseName: "南非", latitude: -30.56, longitude: 22.94, aliases: ["south africa", "johannesburg", "cape town", "za", "zaf", "南非", "约翰内斯堡", "开普敦"])
    ]
}

struct PolicyCountryRoute: Identifiable, Equatable {
    let country: PolicyRouteCountry
    let members: [PolicyMemberPresentation]

    var id: String { country.id }

    var bestMember: PolicyMemberPresentation? {
        let selectable = members.filter(\.isSelectable)
        let measured = selectable.compactMap { member -> (PolicyMemberPresentation, Int)? in
            guard member.health.state == .reachable,
                  let latency = member.health.latencyMilliseconds else { return nil }
            return (member, latency)
        }
        if let fastest = measured.min(by: { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1
        }) {
            return fastest.0
        }
        return selectable.first(where: { $0.role == .desired }) ?? selectable.first
    }

    var bestLatencyMilliseconds: Int? {
        bestMember?.health.latencyMilliseconds
    }

    func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return country.code.lowercased().contains(normalized)
            || country.englishName.lowercased().contains(normalized)
            || country.simplifiedChineseName.contains(normalized)
            || members.contains {
                $0.tag.lowercased().contains(normalized)
                    || ($0.type?.lowercased().contains(normalized) == true)
            }
    }
}

extension PolicySelectorPresentation {
    var countryRoutes: [PolicyCountryRoute] {
        let grouped = Dictionary(grouping: members) { member in
            PolicyRouteCountry.recognize(in: member.tag, endpoint: member.endpoint)
        }
        return grouped.compactMap { country, members in
            country.map { PolicyCountryRoute(country: $0, members: members) }
        }
        .sorted { $0.country.englishName < $1.country.englishName }
    }

    var unclassifiedMembers: [PolicyMemberPresentation] {
        members.filter { PolicyRouteCountry.recognize(in: $0.tag, endpoint: $0.endpoint) == nil }
    }
}

/// A deliberately local IP-to-country boundary. Production can replace this
/// table with a bundled, licensed offline GeoIP database without changing the
/// presentation or policy-selection contracts. No endpoint is sent to a
/// geolocation service, and unknown addresses are left for name fallback.
private enum PolicyIPCountryResolver {
    private static let exactCountryCodes: [String: String] = [
        // Documentation-only ranges keep Xcode Preview and unit tests offline.
        "192.0.2.1": "JP", "198.51.100.1": "HK", "203.0.113.1": "US",
        "1.0.0.1": "AU", "1.1.1.1": "AU",
        "8.8.4.4": "US", "8.8.8.8": "US", "9.9.9.9": "US",
        "114.114.114.114": "CN", "223.5.5.5": "CN",
        "168.95.1.1": "TW",
        "208.67.222.222": "US"
    ]

    static func country(for endpoint: String?) -> String? {
        guard let endpoint,
              let address = ipv4Literal(in: endpoint) else { return nil }
        return exactCountryCodes[address]
    }

    private static func ipv4Literal(in endpoint: String) -> String? {
        let candidates = endpoint
            .split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "[" || $0 == "]" || $0 == " " })
            .map(String.init)
        return candidates.first(where: { candidate in
            let octets = candidate.split(separator: ".")
            return octets.count == 4 && octets.allSatisfy { octet in
                guard let value = Int(octet) else { return false }
                return (0...255).contains(value)
            }
        })
    }
}

enum PolicyMemberRole: Equatable {
    case none
    case configuredDefault
    case desired
    case running

    var titleKey: String? {
        switch self {
        case .none: nil
        case .configuredDefault: "policy.workspace.member.configured-default"
        case .desired: "policy.workspace.member.desired"
        case .running: "policy.workspace.member.running"
        }
    }
}

struct PolicyRuntimePresentation: Equatable {
    let state: PolicyRuntimeConvergenceState
    let titleKey: String
    let detailKey: String
    let symbolName: String
    let level: TargetStatusLevel

    init(selector: PolicyCatalogSelector) {
        state = selector.runtimeConvergence
        switch selector.runtimeConvergence {
        case .notRunning:
            titleKey = "policy.workspace.runtime.not-running"
            detailKey = "policy.workspace.runtime.not-running.detail"
            symbolName = "power"
            level = .neutral
        case .converged:
            titleKey = "policy.workspace.runtime.converged"
            detailKey = "policy.workspace.runtime.converged.detail"
            symbolName = "checkmark.circle"
            level = .neutral
        case .restartRequired:
            titleKey = "policy.catalog.restart-required"
            detailKey = "policy.workspace.runtime.restart-required.detail"
            symbolName = "arrow.clockwise"
            level = .warning
        case .unavailable:
            titleKey = "policy.workspace.runtime.unavailable"
            detailKey = "policy.workspace.runtime.unavailable.detail"
            symbolName = "questionmark.circle"
            level = .warning
        }
    }
}

private extension PolicyCatalogStructuralStatus {
    var presentationKey: String? {
        switch self {
        case .available: nil
        case .missingReference: "policy.catalog.status.missingReference"
        case .duplicateTag: "policy.catalog.status.duplicateTag"
        case .malformedMembers: "policy.catalog.status.malformedMembers"
        case .invalidTag: "policy.catalog.status.invalidTag"
        case .unavailable: "policy.catalog.status.unavailable"
        }
    }

    var presentationSymbol: String {
        self == .available ? "checkmark.circle" : "exclamationmark.triangle"
    }

    var presentationLevel: TargetStatusLevel {
        self == .available ? .neutral : .warning
    }
}
