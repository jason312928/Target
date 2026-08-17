import Foundation
import Yams

enum SubscriptionPayloadFormat: String, Equatable, Sendable {
    case singBoxJSON = "sing-box-json"
    case uriList = "uri-list"
    case base64URIList = "base64-uri-list"
    case clashYAML = "clash-yaml"

    var titleKey: String {
        switch self {
        case .singBoxJSON: "profile.subscription.format.sing-box"
        case .uriList: "profile.subscription.format.uri-list"
        case .base64URIList: "profile.subscription.format.base64-uri-list"
        case .clashYAML: "profile.subscription.format.clash-yaml"
        }
    }
}

enum SubscriptionProxyProtocol: String, CaseIterable, Equatable, Sendable {
    case shadowsocks
    case vmess
    case vless
    case trojan
    case anytls
}

enum SubscriptionCompatibilityWarning: String, Equatable, Sendable {
    case providerSemanticsNotImported = "provider_semantics_not_imported"
    case unsupportedNodesSkipped = "unsupported_nodes_skipped"
}

enum SubscriptionSkippedProtocol: String, Equatable, Sendable {
    case hysteria2
    case tuic
    case ssr
    case vless
    case trojan
    case anytls
}

struct SubscriptionCompatibilitySummary: Equatable, Sendable {
    let format: SubscriptionPayloadFormat
    /// Number of nodes that were converted into the Target-owned configuration.
    let nodeCount: Int
    /// Number of recognized provider nodes before compatibility filtering.
    let totalNodeCount: Int
    let skippedNodeCount: Int
    let skippedTLSVerificationNodeCount: Int
    let skippedProtocols: [SubscriptionSkippedProtocol]
    let protocols: [SubscriptionProxyProtocol]
    let warnings: [SubscriptionCompatibilityWarning]
    let isPassThrough: Bool
}

struct SubscriptionNormalizationResult: Sendable {
    let data: Data
    let summary: SubscriptionCompatibilitySummary
}

private struct ParsedProviderNodes {
    let nodes: [ProviderNode]
    let totalNodeCount: Int
    let skippedProtocols: [SubscriptionSkippedProtocol]

    var warnings: [SubscriptionCompatibilityWarning] {
        skippedProtocols.isEmpty ? [] : [.unsupportedNodesSkipped]
    }
}

enum SubscriptionIntakeError: Error, Equatable, Sendable {
    case emptyPayload
    case invalidUTF8
    case formatUnsupported
    case webPageReturned
    case payloadInvalid
    case protocolUnsupported
    case variantUnsupported
    case complexityLimitExceeded
    case validationFailed

    var messageKey: String {
        switch self {
        case .emptyPayload, .invalidUTF8, .payloadInvalid:
            "profile.subscription.error.payload-invalid"
        case .formatUnsupported:
            "profile.subscription.error.format-unsupported"
        case .webPageReturned:
            "profile.subscription.error.web-page"
        case .protocolUnsupported:
            "profile.subscription.error.protocol-unsupported"
        case .variantUnsupported:
            "profile.subscription.error.variant-unsupported"
        case .complexityLimitExceeded:
            "profile.subscription.error.too-complex"
        case .validationFailed:
            "profile.subscription.error.validation-failed"
        }
    }
}

struct SubscriptionIntakeFailure: Error, Equatable, Sendable {
    let cause: SubscriptionIntakeError
    let response: SubscriptionResponseMetadata
}

/// Pure, deterministic conversion of provider payloads into a Target-owned
/// sing-box document. It has no persistence, Keychain, network, or logging access.
struct SubscriptionNormalizer: Sendable {
    static let maximumPayloadBytes = SecureSubscriptionFetcher.defaultMaximumResponseBytes
    static let maximumNodeCount = 1_000
    static let maximumLineBytes = 16 * 1_024

    private static let supportedSchemes = Set(SubscriptionProxyProtocol.allCases.map(\.rawValue) + ["ss"])
    /// These are explicitly recognized provider protocols which Target does not
    /// yet convert. They may be skipped only when a subscription also contains
    /// at least one fully valid supported node.
    private static let skippableUnsupportedSchemes: [String: SubscriptionSkippedProtocol] = [
        "hysteria2": .hysteria2,
        "hy2": .hysteria2,
        "tuic": .tuic,
        "ssr": .ssr
    ]
    private static let shadowsocksMethods: Set<String> = [
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305"
    ]
    private static let vmessSecurity: Set<String> = ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305"]
    private static let clashClientFingerprints: Set<String> = [
        "chrome", "firefox", "safari", "edge", "360", "qq", "ios", "android",
        "random", "randomized"
    ]

    func normalize(_ data: Data) throws -> SubscriptionNormalizationResult {
        guard !data.isEmpty else { throw SubscriptionIntakeError.emptyPayload }
        guard data.count <= Self.maximumPayloadBytes else { throw SubscriptionIntakeError.complexityLimitExceeded }
        guard let text = String(data: data, encoding: .utf8) else { throw SubscriptionIntakeError.invalidUTF8 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SubscriptionIntakeError.emptyPayload }

        if trimmed.first == "{" || trimmed.first == "[" {
            return try normalizeJSONCandidate(data, text: trimmed)
        }
        if let parsed = try parseURIListIfRecognized(trimmed) {
            return try generatedResult(
                nodes: parsed.nodes, format: .uriList, warnings: parsed.warnings,
                totalNodeCount: parsed.totalNodeCount, skippedProtocols: parsed.skippedProtocols
            )
        }
        if let decoded = strictBase64Decode(trimmed), let decodedText = String(data: decoded, encoding: .utf8),
           let parsed = try parseURIListIfRecognized(decodedText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return try generatedResult(
                nodes: parsed.nodes, format: .base64URIList, warnings: parsed.warnings,
                totalNodeCount: parsed.totalNodeCount, skippedProtocols: parsed.skippedProtocols
            )
        }
        if looksLikeClashYAML(trimmed) {
            return try normalizeClashYAML(trimmed)
        }
        throw SubscriptionIntakeError.formatUnsupported
    }

    private func normalizeJSONCandidate(_ data: Data, text: String) throws -> SubscriptionNormalizationResult {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw SubscriptionIntakeError.payloadInvalid }
        guard let root = object as? [String: Any], root["outbounds"] is [Any] else {
            throw SubscriptionIntakeError.formatUnsupported
        }
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let protocols = Set(outbounds.compactMap { item -> SubscriptionProxyProtocol? in
            guard let type = item["type"] as? String else { return nil }
            return SubscriptionProxyProtocol(rawValue: type == "shadowsocks" ? "shadowsocks" : type)
        }).sorted { $0.rawValue < $1.rawValue }
        return SubscriptionNormalizationResult(
            data: data,
            summary: SubscriptionCompatibilitySummary(
                format: .singBoxJSON,
                nodeCount: outbounds.filter { item in
                    guard let type = item["type"] as? String else { return false }
                    return SubscriptionProxyProtocol(rawValue: type) != nil
                }.count,
                totalNodeCount: outbounds.filter { item in
                    guard let type = item["type"] as? String else { return false }
                    return SubscriptionProxyProtocol(rawValue: type) != nil
                }.count,
                skippedNodeCount: 0,
                skippedTLSVerificationNodeCount: 0,
                skippedProtocols: [],
                protocols: protocols,
                warnings: [],
                isPassThrough: true
            )
        )
    }

    private func parseURIListIfRecognized(_ text: String) throws -> ParsedProviderNodes? {
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var entries: [String] = []
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: CharacterSet.whitespaces)
            guard line.utf8.count <= Self.maximumLineBytes else { throw SubscriptionIntakeError.complexityLimitExceeded }
            if line.isEmpty || line.hasPrefix("#") { continue }
            entries.append(line)
        }
        guard !entries.isEmpty else { return nil }
        guard entries.count <= Self.maximumNodeCount else { throw SubscriptionIntakeError.complexityLimitExceeded }

        var nodes: [ProviderNode] = []
        var skippedProtocols: [SubscriptionSkippedProtocol] = []
        var recognizedCount = 0
        for entry in entries {
            guard let scheme = entry.split(separator: ":", maxSplits: 1).first?.lowercased() else {
                throw SubscriptionIntakeError.payloadInvalid
            }
            if Self.supportedSchemes.contains(scheme) {
                recognizedCount += 1
                nodes.append(try parseURI(entry))
            } else if let skippedProtocol = Self.skippableUnsupportedSchemes[scheme] {
                recognizedCount += 1
                skippedProtocols.append(skippedProtocol)
            }
        }
        guard recognizedCount > 0 else {
            if entries.allSatisfy({ $0.contains("://") }) { throw SubscriptionIntakeError.protocolUnsupported }
            return nil
        }
        guard recognizedCount == entries.count else {
            let unrecognized = entries.filter { entry in
                guard let scheme = entry.split(separator: ":", maxSplits: 1).first?.lowercased() else { return true }
                return !Self.supportedSchemes.contains(scheme)
            }
            if unrecognized.contains(where: { $0.contains("://") }) { throw SubscriptionIntakeError.protocolUnsupported }
            throw SubscriptionIntakeError.payloadInvalid
        }
        guard !nodes.isEmpty else { throw SubscriptionIntakeError.protocolUnsupported }
        return ParsedProviderNodes(nodes: nodes, totalNodeCount: entries.count, skippedProtocols: skippedProtocols)
    }

    private func parseURI(_ value: String) throws -> ProviderNode {
        let scheme = value.split(separator: ":", maxSplits: 1).first?.lowercased()
        switch scheme {
        case "ss": return try parseShadowsocks(value)
        case "vmess": return try parseVMess(value)
        case "vless": return try parseVLESS(value)
        case "trojan": return try parseTrojan(value)
        case "anytls": return try parseAnyTLS(value)
        default: throw SubscriptionIntakeError.protocolUnsupported
        }
    }

    private func parseShadowsocks(_ value: String) throws -> ProviderNode {
        let bodyAndFragment = String(value.dropFirst("ss://".count))
        let fragmentParts = bodyAndFragment.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let body = String(fragmentParts[0])
        let name = fragmentParts.count == 2 ? decoded(String(fragmentParts[1])) : nil
        guard !body.contains("?") else { throw SubscriptionIntakeError.variantUnsupported }

        let credential: String
        let endpoint: String
        if let at = body.lastIndex(of: "@") {
            let encodedCredential = String(body[..<at])
            let decodedCredential = decoded(encodedCredential).flatMap(strictBase64DecodeString)
            guard let parsedCredential = strictBase64DecodeString(encodedCredential) ?? decodedCredential else {
                throw SubscriptionIntakeError.payloadInvalid
            }
            credential = parsedCredential
            endpoint = String(body[body.index(after: at)...])
        } else {
            guard let decodedBody = strictBase64DecodeString(body), let at = decodedBody.lastIndex(of: "@") else {
                throw SubscriptionIntakeError.payloadInvalid
            }
            credential = String(decodedBody[..<at])
            endpoint = String(decodedBody[decodedBody.index(after: at)...])
        }
        guard let separator = credential.firstIndex(of: ":") else { throw SubscriptionIntakeError.payloadInvalid }
        let method = String(credential[..<separator])
        let password = String(credential[credential.index(after: separator)...])
        guard Self.shadowsocksMethods.contains(method), !password.isEmpty else { throw SubscriptionIntakeError.variantUnsupported }
        let address = try parseEndpoint(endpoint)
        return ProviderNode(name: safeName(name, fallback: "Shadowsocks"), protocolKind: .shadowsocks, outbound: [
            "type": "shadowsocks", "server": address.host, "server_port": address.port,
            "method": method, "password": password
        ])
    }

    private func parseVMess(_ value: String) throws -> ProviderNode {
        let encoded = String(value.dropFirst("vmess://".count))
        guard let decodedData = strictBase64Decode(encoded),
              let object = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any] else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        guard string(object["v"]) == "2", let server = nonemptyString(object["add"]),
              let port = integer(object["port"]), validPort(port),
              let uuid = nonemptyString(object["id"]), UUID(uuidString: uuid) != nil else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        guard integer(object["aid"]) ?? 0 == 0 else { throw SubscriptionIntakeError.variantUnsupported }
        let security = nonemptyString(object["scy"]) ?? "auto"
        guard Self.vmessSecurity.contains(security) else { throw SubscriptionIntakeError.variantUnsupported }
        let network = nonemptyString(object["net"]) ?? "tcp"
        let tls = (nonemptyString(object["tls"]) ?? "none").lowercased()
        guard ["tcp", "ws"].contains(network), ["none", "tls"].contains(tls) else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        var outbound: [String: Any] = [
            "type": "vmess", "server": server, "server_port": port, "uuid": uuid,
            "security": security, "alter_id": 0
        ]
        try applyTransport(network: network, path: nonemptyString(object["path"]), host: nonemptyString(object["host"]), to: &outbound)
        if tls == "tls" { outbound["tls"] = tlsObject(serverName: nonemptyString(object["sni"]) ?? nonemptyString(object["host"]) ?? server) }
        return ProviderNode(name: safeName(nonemptyString(object["ps"]), fallback: "VMess"), protocolKind: .vmess, outbound: outbound)
    }

    private func parseVLESS(_ value: String) throws -> ProviderNode {
        let components = try standardComponents(value)
        guard let uuid = components.user, UUID(uuidString: uuid) != nil else { throw SubscriptionIntakeError.payloadInvalid }
        let query = queryMap(components)
        guard (query["encryption"] ?? "none") == "none", query["flow"] == nil else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        let network = query["type"] ?? "tcp"
        let security = query["security"] ?? "none"
        guard ["tcp", "ws"].contains(network), ["none", "tls"].contains(security), safeTLSQuery(query) else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        var outbound: [String: Any] = [
            "type": "vless", "server": components.host!, "server_port": components.port!, "uuid": uuid
        ]
        try applyTransport(network: network, path: query["path"], host: query["host"], to: &outbound)
        if security == "tls" { outbound["tls"] = tlsObject(serverName: query["sni"] ?? components.host!) }
        return ProviderNode(name: safeName(decoded(components.fragment), fallback: "VLESS"), protocolKind: .vless, outbound: outbound)
    }

    private func parseTrojan(_ value: String) throws -> ProviderNode {
        let components = try standardComponents(value)
        guard let password = components.user?.removingPercentEncoding, !password.isEmpty else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        let query = queryMap(components)
        let network = query["type"] ?? "tcp"
        let security = query["security"] ?? "tls"
        guard ["tcp", "ws"].contains(network), security == "tls", safeTLSQuery(query) else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        var outbound: [String: Any] = [
            "type": "trojan", "server": components.host!, "server_port": components.port!, "password": password,
            "tls": tlsObject(serverName: query["sni"] ?? components.host!)
        ]
        try applyTransport(network: network, path: query["path"], host: query["host"], to: &outbound)
        return ProviderNode(name: safeName(decoded(components.fragment), fallback: "Trojan"), protocolKind: .trojan, outbound: outbound)
    }

    private func parseAnyTLS(_ value: String) throws -> ProviderNode {
        let components = try anyTLSComponents(value)
        let query = queryMap(components)
        let security = (query["security"] ?? "tls").lowercased()
        guard security == "tls", safeAnyTLSQuery(query) else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        let password = [components.password, components.user, query["password"]]
            .compactMap { $0?.removingPercentEncoding }
            .first { !$0.isEmpty }
        guard let password else { throw SubscriptionIntakeError.payloadInvalid }

        let outbound: [String: Any] = [
            "type": "anytls", "server": components.host!, "server_port": components.port!,
            "password": password,
            "tls": anyTLSTLSObject(serverName: query["sni"] ?? query["servername"] ?? components.host!, query: query)
        ]
        return ProviderNode(
            name: safeName(decoded(components.fragment), fallback: "AnyTLS"),
            protocolKind: .anytls,
            outbound: outbound
        )
    }

    private func normalizeClashYAML(_ text: String) throws -> SubscriptionNormalizationResult {
        let loaded: Any
        do { loaded = try Yams.load(yaml: text) as Any }
        catch { throw SubscriptionIntakeError.payloadInvalid }
        guard let root = stringDictionary(loaded), let rawProxies = root["proxies"] as? [Any], !rawProxies.isEmpty else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        guard rawProxies.count <= Self.maximumNodeCount else { throw SubscriptionIntakeError.complexityLimitExceeded }
        var nodes: [ProviderNode] = []
        var skippedProtocols: [SubscriptionSkippedProtocol] = []
        for raw in rawProxies {
            guard let proxy = stringDictionary(raw), let type = nonemptyString(proxy["type"])?.lowercased() else {
                throw SubscriptionIntakeError.payloadInvalid
            }
            switch type {
            case "ss": nodes.append(try clashShadowsocks(proxy))
            case "vmess": nodes.append(try clashVMess(proxy))
            case "vless": nodes.append(try clashVLESS(proxy))
            case "trojan": nodes.append(try clashTrojan(proxy))
            case "anytls": nodes.append(try clashAnyTLS(proxy))
            case let type where Self.skippableUnsupportedSchemes[type] != nil:
                skippedProtocols.append(Self.skippableUnsupportedSchemes[type]!)
            default: throw SubscriptionIntakeError.protocolUnsupported
            }
        }
        guard !nodes.isEmpty else { throw SubscriptionIntakeError.protocolUnsupported }
        let semanticKeys: Set<String> = ["proxy-groups", "rules", "rule-providers", "proxy-providers", "dns", "tun", "script"]
        var warnings: [SubscriptionCompatibilityWarning] = root.keys.contains(where: semanticKeys.contains)
            ? [.providerSemanticsNotImported] : []
        if !skippedProtocols.isEmpty { warnings.append(.unsupportedNodesSkipped) }
        return try generatedResult(
            nodes: nodes, format: .clashYAML, warnings: warnings,
            totalNodeCount: rawProxies.count, skippedProtocols: skippedProtocols
        )
    }

    private func clashShadowsocks(_ proxy: [String: Any]) throws -> ProviderNode {
        let common = try clashCommon(proxy)
        guard let method = nonemptyString(proxy["cipher"]), Self.shadowsocksMethods.contains(method),
              let password = nonemptyString(proxy["password"]), proxy["plugin"] == nil else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        return ProviderNode(name: common.name, protocolKind: .shadowsocks, outbound: [
            "type": "shadowsocks", "server": common.server, "server_port": common.port,
            "method": method, "password": password
        ])
    }

    private func clashVMess(_ proxy: [String: Any]) throws -> ProviderNode {
        let common = try clashCommon(proxy)
        guard let uuid = nonemptyString(proxy["uuid"]), UUID(uuidString: uuid) != nil,
              integer(proxy["alterId"]) ?? 0 == 0 else { throw SubscriptionIntakeError.payloadInvalid }
        let security = nonemptyString(proxy["cipher"]) ?? "auto"
        guard Self.vmessSecurity.contains(security) else { throw SubscriptionIntakeError.variantUnsupported }
        var outbound: [String: Any] = [
            "type": "vmess", "server": common.server, "server_port": common.port,
            "uuid": uuid, "security": security, "alter_id": 0
        ]
        try applyClashNetworkAndTLS(proxy, server: common.server, tlsRequired: false, to: &outbound)
        return ProviderNode(name: common.name, protocolKind: .vmess, outbound: outbound)
    }

    private func clashVLESS(_ proxy: [String: Any]) throws -> ProviderNode {
        let common = try clashCommon(proxy)
        guard let uuid = nonemptyString(proxy["uuid"]), UUID(uuidString: uuid) != nil else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        let flow = nonemptyString(proxy["flow"])
        guard flow == nil || flow == "xtls-rprx-vision" else { throw SubscriptionIntakeError.variantUnsupported }
        var outbound: [String: Any] = [
            "type": "vless", "server": common.server, "server_port": common.port, "uuid": uuid
        ]
        try applyClashNetworkAndTLS(proxy, server: common.server, tlsRequired: false, to: &outbound)
        if let reality = stringDictionary(proxy["reality-opts"] as Any) {
            guard flow == "xtls-rprx-vision", boolean(proxy["tls"]) == true,
                  let publicKey = nonemptyString(reality["public-key"]), validRealityPublicKey(publicKey),
                  let shortID = nonemptyString(reality["short-id"]), validRealityShortID(shortID),
                  nonemptyString(proxy["client-fingerprint"]) == "firefox",
                  var tls = outbound["tls"] as? [String: Any] else {
                throw SubscriptionIntakeError.variantUnsupported
            }
            tls["utls"] = ["enabled": true, "fingerprint": "firefox"]
            tls["reality"] = ["enabled": true, "public_key": publicKey, "short_id": shortID]
            outbound["tls"] = tls
            outbound["flow"] = flow
        } else if flow != nil {
            throw SubscriptionIntakeError.variantUnsupported
        }
        return ProviderNode(name: common.name, protocolKind: .vless, outbound: outbound)
    }

    private func clashTrojan(_ proxy: [String: Any]) throws -> ProviderNode {
        let common = try clashCommon(proxy)
        guard let password = nonemptyString(proxy["password"]) else { throw SubscriptionIntakeError.payloadInvalid }
        var outbound: [String: Any] = [
            "type": "trojan", "server": common.server, "server_port": common.port, "password": password
        ]
        try applyClashNetworkAndTLS(
            proxy, server: common.server, tlsRequired: true,
            usesServerNameAsWebSocketHost: true, to: &outbound
        )
        return ProviderNode(name: common.name, protocolKind: .trojan, outbound: outbound)
    }

    private func clashAnyTLS(_ proxy: [String: Any]) throws -> ProviderNode {
        let common = try clashCommon(proxy)
        guard let password = nonemptyString(proxy["password"]),
              (boolean(proxy["tls"]) ?? true) else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        var tls = tlsObject(serverName: nonemptyString(proxy["servername"] ?? proxy["sni"]) ?? common.server)
        applyClashTLSVerification(proxy, to: &tls)
        try applyClashTLSCompatibility(proxy, allowsScalarALPN: true, to: &tls)
        let outbound: [String: Any] = [
            "type": "anytls", "server": common.server, "server_port": common.port,
            "password": password, "tls": tls
        ]
        return ProviderNode(name: common.name, protocolKind: .anytls, outbound: outbound)
    }

    private func clashCommon(_ proxy: [String: Any]) throws -> (name: String, server: String, port: Int) {
        guard let name = nonemptyString(proxy["name"]), let server = nonemptyString(proxy["server"]),
              let port = integer(proxy["port"]), validPort(port) else { throw SubscriptionIntakeError.payloadInvalid }
        return (safeName(name, fallback: "Proxy"), server, port)
    }

    private func applyClashNetworkAndTLS(
        _ proxy: [String: Any], server: String, tlsRequired: Bool,
        usesServerNameAsWebSocketHost: Bool = false, to outbound: inout [String: Any]
    ) throws {
        let network = nonemptyString(proxy["network"]) ?? "tcp"
        guard ["tcp", "ws"].contains(network), proxy["grpc-opts"] == nil, proxy["h2-opts"] == nil else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        let tls = boolean(proxy["tls"]) ?? tlsRequired
        if tlsRequired && !tls { throw SubscriptionIntakeError.variantUnsupported }
        let serverName = nonemptyString(proxy["servername"] ?? proxy["sni"]) ?? server
        if tls {
            var tlsOptions = tlsObject(serverName: serverName)
            applyClashTLSVerification(proxy, to: &tlsOptions)
            try applyClashTLSCompatibility(proxy, to: &tlsOptions)
            outbound["tls"] = tlsOptions
        } else if proxy.keys.contains("client-fingerprint") || proxy.keys.contains("alpn") {
            throw SubscriptionIntakeError.variantUnsupported
        }

        let wsOptions = stringDictionary(proxy["ws-opts"] as Any) ?? [:]
        let headers = stringDictionary(wsOptions["headers"] as Any) ?? [:]
        let explicitHost = nonemptyString(headers["Host"] ?? headers["host"])
        // Mihomo Trojan WebSocket uses the effective SNI as its request Host when no header is explicit.
        let transportHost = explicitHost ?? (usesServerNameAsWebSocketHost && network == "ws" ? serverName : nil)
        try applyTransport(
            network: network,
            path: nonemptyString(wsOptions["path"]),
            host: transportHost,
            to: &outbound
        )
    }

    private func applyClashTLSCompatibility(
        _ proxy: [String: Any], allowsScalarALPN: Bool = false, to tls: inout [String: Any]
    ) throws {
        if proxy.keys.contains("alpn") {
            tls["alpn"] = try clashALPN(proxy["alpn"], allowsScalar: allowsScalarALPN)
        }
        if proxy.keys.contains("client-fingerprint") {
            guard let fingerprint = nonemptyString(proxy["client-fingerprint"])?.lowercased(),
                  Self.clashClientFingerprints.contains(fingerprint) else {
                throw SubscriptionIntakeError.variantUnsupported
            }
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
    }

    private func applyClashTLSVerification(_ proxy: [String: Any], to tls: inout [String: Any]) {
        if boolean(proxy["skip-cert-verify"]) == true {
            tls["insecure"] = true
        }
    }

    private func generatedResult(
        nodes: [ProviderNode], format: SubscriptionPayloadFormat,
        warnings: [SubscriptionCompatibilityWarning], totalNodeCount: Int? = nil,
        skippedProtocols: [SubscriptionSkippedProtocol] = [], skippedTLSVerificationNodeCount: Int = 0
    ) throws -> SubscriptionNormalizationResult {
        guard !nodes.isEmpty else { throw SubscriptionIntakeError.payloadInvalid }
        var usedTags = Set<String>(["Proxy", "direct", "target-mixed"])
        var tags: [String] = []
        var outbounds: [[String: Any]] = []
        for (index, node) in nodes.enumerated() {
            let base = sanitizedTag(node.name, fallback: "Proxy \(index + 1)")
            var tag = base
            var suffix = 2
            while usedTags.contains(tag) { tag = "\(base) \(suffix)"; suffix += 1 }
            usedTags.insert(tag)
            tags.append(tag)
            var outbound = node.outbound
            outbound["tag"] = tag
            outbounds.append(outbound)
        }
        outbounds.insert(["type": "selector", "tag": "Proxy", "outbounds": tags, "default": tags[0]], at: 0)
        outbounds.append(["type": "direct", "tag": "direct"])
        let root: [String: Any] = [
            "inbounds": [["type": "mixed", "tag": "target-mixed", "listen": "127.0.0.1", "listen_port": 0]],
            "outbounds": outbounds,
            "route": ["final": "Proxy"]
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0A])
        return SubscriptionNormalizationResult(
            data: data,
            summary: SubscriptionCompatibilitySummary(
                format: format,
                nodeCount: nodes.count,
                totalNodeCount: totalNodeCount ?? nodes.count,
                skippedNodeCount: skippedProtocols.count,
                skippedTLSVerificationNodeCount: skippedTLSVerificationNodeCount,
                skippedProtocols: Array(Set(skippedProtocols)).sorted { $0.rawValue < $1.rawValue },
                protocols: Set(nodes.map(\.protocolKind)).sorted { $0.rawValue < $1.rawValue },
                warnings: warnings,
                isPassThrough: false
            )
        )
    }

    private func applyTransport(network: String, path: String?, host: String?, to outbound: inout [String: Any]) throws {
        guard ["tcp", "ws"].contains(network) else { throw SubscriptionIntakeError.variantUnsupported }
        guard network == "ws" else { return }
        var transport: [String: Any] = ["type": "ws"]
        if let path, !path.isEmpty { transport["path"] = path }
        if let host, !host.isEmpty { transport["headers"] = ["Host": host] }
        outbound["transport"] = transport
    }

    private func standardComponents(_ value: String) throws -> URLComponents {
        guard let components = URLComponents(string: value), let host = components.host, !host.isEmpty,
              let port = components.port, validPort(port), components.password == nil else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        return components
    }

    private func anyTLSComponents(_ value: String) throws -> URLComponents {
        guard let components = URLComponents(string: value), let host = components.host, !host.isEmpty,
              let port = components.port, validPort(port) else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        return components
    }

    private func queryMap(_ components: URLComponents) -> [String: String] {
        Dictionary(components.queryItems?.compactMap { item in item.value.map { (item.name.lowercased(), $0) } } ?? [], uniquingKeysWith: { _, last in last })
    }

    private func safeTLSQuery(_ query: [String: String]) -> Bool {
        let insecure = query["allowinsecure"] ?? query["insecure"] ?? "0"
        return ["0", "false"].contains(insecure.lowercased()) && query["pbk"] == nil && query["sid"] == nil
    }

    private func safeAnyTLSQuery(_ query: [String: String]) -> Bool {
        let insecure = query["allowinsecure"] ?? query["insecure"] ?? "0"
        guard ["0", "false"].contains(insecure.lowercased()) else { return false }
        if let fingerprint = query["fp"], !Self.clashClientFingerprints.contains(fingerprint.lowercased()) { return false }
        return true
    }

    private func tlsObject(serverName: String) -> [String: Any] {
        ["enabled": true, "server_name": serverName, "insecure": false]
    }

    private func anyTLSTLSObject(serverName: String, query: [String: String]) -> [String: Any] {
        var tls = tlsObject(serverName: serverName)
        if let alpn = query["alpn"]?.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }), !alpn.isEmpty {
            tls["alpn"] = alpn
        }
        if let fingerprint = query["fp"], Self.clashClientFingerprints.contains(fingerprint.lowercased()) {
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint.lowercased()]
        }
        return tls
    }

    private func parseEndpoint(_ endpoint: String) throws -> (host: String, port: Int) {
        guard let components = URLComponents(string: "scheme://\(endpoint)"), let host = components.host,
              !host.isEmpty, let port = components.port, validPort(port) else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        return (host, port)
    }

    private func strictBase64DecodeString(_ value: String) -> String? {
        strictBase64Decode(value).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func strictBase64Decode(_ value: String) -> Data? {
        let compact = value.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count <= Self.maximumPayloadBytes * 2,
              compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/_-=".contains($0)) }) else { return nil }
        let normalized = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized + padding, options: [])
    }

    private func looksLikeClashYAML(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*proxies\s*:"#, options: .regularExpression) != nil
    }

    private func stringDictionary(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let dictionary = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary { guard let key = key as? String else { return nil }; result[key] = value }
            return result
        }
        return nil
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            if value.lowercased() == "true" { return true }
            if value.lowercased() == "false" { return false }
        }
        return nil
    }

    private func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }

    private func clashALPN(_ value: Any?, allowsScalar: Bool) throws -> [String] {
        let result: [String]
        if let values = value as? [Any] {
            guard let strings = values as? [String], strings.count <= 16 else {
                throw SubscriptionIntakeError.variantUnsupported
            }
            result = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else if allowsScalar, let value = nonemptyString(value) {
            result = value.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        guard !result.isEmpty, result.count <= 16,
              result.allSatisfy({ value in
                  !value.isEmpty && value.utf8.count <= 64
                      && value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
              }) else {
            throw SubscriptionIntakeError.variantUnsupported
        }
        return result
    }

    private func validRealityPublicKey(_ value: String) -> Bool {
        value.utf8.count <= 256 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_=".contains($0)) }
    }

    private func validRealityShortID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16 && value.allSatisfy { $0.isHexDigit }
    }

    private func decoded(_ value: String?) -> String? {
        value?.removingPercentEncoding
    }

    private func safeName(_ value: String?, fallback: String) -> String {
        let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidate.isEmpty, candidate.utf8.count <= 256 else { return fallback }
        return candidate
    }

    private func sanitizedTag(_ value: String, fallback: String) -> String {
        let filtered = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(filtered).split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let limited = String(collapsed.prefix(80))
        return limited.isEmpty || limited.contains("://") || UUID(uuidString: limited) != nil ? fallback : limited
    }
}

private struct ProviderNode {
    let name: String
    let protocolKind: SubscriptionProxyProtocol
    let outbound: [String: Any]
}

struct PendingSubscriptionIntake: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Destination: Sendable {
        case newProfile(name: String, source: RemoteSubscription)
        case existingProfile(profileID: UUID, expectedRevision: Int)
    }

    let destination: Destination
    let normalization: SubscriptionNormalizationResult
    let response: SubscriptionResponse
    let diff: ProfileConfigurationDiff?

    var description: String {
        "PendingSubscriptionIntake(format: \(normalization.summary.format.rawValue), nodes: \(normalization.summary.nodeCount))"
    }

    var debugDescription: String { description }
}

struct PreparedSubscriptionUpdate: Sendable {
    let profileID: UUID
    let expectedRevision: Int
    let response: SubscriptionResponse
    let candidate: PendingSubscriptionIntake?
}

/// Shared semantic operation used by the Profiles UI and local automation.
/// Fetching, normalization, validation, and persistence are never reimplemented
/// by either caller.
struct TargetSubscriptionOperations: @unchecked Sendable {
    private let store: ProfileStore
    private let fetcher: any ProfileSubscriptionFetching
    private let normalizer: SubscriptionNormalizer

    init(
        store: ProfileStore,
        fetcher: any ProfileSubscriptionFetching = SecureSubscriptionFetcher(),
        normalizer: SubscriptionNormalizer = SubscriptionNormalizer()
    ) {
        self.store = store
        self.fetcher = fetcher
        self.normalizer = normalizer
    }

    func prepareNew(name: String, url: URL) async throws -> PendingSubscriptionIntake {
        let source = RemoteSubscription(url: url)
        let response = try await fetcher.fetch(subscription: source)
        guard response.cacheStatus == .updated else { throw SubscriptionIntakeError.payloadInvalid }
        let normalization = try normalizeAndValidate(response)
        return PendingSubscriptionIntake(
            destination: .newProfile(name: name, source: source),
            normalization: normalization,
            response: response,
            diff: nil
        )
    }

    func prepareUpdate(profileID: UUID) async throws -> PreparedSubscriptionUpdate {
        guard let profile = try store.listProfiles().first(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound
        }
        guard let source = profile.subscription else { throw SubscriptionUpdateError.noSubscription }
        let expectedRevision = profile.validRevision
        let response = try await fetcher.fetch(subscription: source)
        if response.cacheStatus == .notModified {
            return PreparedSubscriptionUpdate(
                profileID: profileID, expectedRevision: expectedRevision,
                response: response, candidate: nil
            )
        }
        let normalization = try normalizeAndValidate(response)
        let current = try store.validVersion(for: profileID, revision: expectedRevision).data
        let candidate = PendingSubscriptionIntake(
            destination: .existingProfile(profileID: profileID, expectedRevision: expectedRevision),
            normalization: normalization,
            response: response,
            diff: .make(current: current, candidate: normalization.data)
        )
        return PreparedSubscriptionUpdate(
            profileID: profileID, expectedRevision: expectedRevision,
            response: response, candidate: candidate
        )
    }

    func commitNotModified(_ prepared: PreparedSubscriptionUpdate) throws -> Profile {
        guard prepared.candidate == nil, prepared.response.cacheStatus == .notModified else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        return try store.recordSubscriptionResult(
            for: prepared.profileID,
            response: prepared.response,
            expectedRevision: prepared.expectedRevision
        )
    }

    func commit(_ pending: PendingSubscriptionIntake) throws -> Profile {
        switch pending.destination {
        case .newProfile(let name, let source):
            return try store.importSubscriptionCandidate(
                pending.normalization.data,
                name: name,
                source: source,
                response: pending.response
            )
        case .existingProfile(let profileID, let expectedRevision):
            return try store.applySubscriptionCandidate(
                pending.normalization.data,
                response: pending.response,
                profileID: profileID,
                expectedRevision: expectedRevision
            )
        }
    }

    private func validate(_ result: SubscriptionNormalizationResult) throws -> SubscriptionNormalizationResult {
        guard let text = String(data: result.data, encoding: .utf8), JSONSyntaxChecker.validate(text) == nil else {
            throw SubscriptionIntakeError.payloadInvalid
        }
        let check = try store.checkSubscriptionCandidate(result.data)
        guard case .success = check else { throw SubscriptionIntakeError.validationFailed }
        return result
    }

    private func normalizeAndValidate(_ response: SubscriptionResponse) throws -> SubscriptionNormalizationResult {
        do {
            return try validate(normalizer.normalize(response.data))
        } catch let error as SubscriptionIntakeError {
            // A valid subscription is accepted before this point regardless of its
            // MIME type. Only a bounded structural HTML signature can replace a
            // real parsing error, so HTML containing URI-looking links is not
            // reported as an unsupported proxy protocol.
            let cause: SubscriptionIntakeError = isLikelyWebPage(response) ? .webPageReturned : error
            throw SubscriptionIntakeFailure(cause: cause, response: response.metadata)
        }
    }

    private func isLikelyWebPage(_ response: SubscriptionResponse) -> Bool {
        let prefix = response.data.prefix(4_096)
        guard let text = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return text.hasPrefix("<!doctype html") || text.hasPrefix("<html")
            || text.hasPrefix("<head") || text.hasPrefix("<body")
    }
}
