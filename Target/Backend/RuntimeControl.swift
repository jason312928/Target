import Foundation
import TargetCore

/// The narrow error vocabulary intentionally avoids propagating controller
/// response bodies (which could contain upstream-specific or sensitive data).
enum RuntimeControlError: Error, Equatable, Sendable {
    case invalidDescriptor
    case unavailable
    case redirectRefused
    case malformedResponse
    case probeFailed
    case selectionRejected
}

struct RuntimeSelectorState: Equatable, Sendable {
    let tag: String
    let selected: String
    let members: [String]
}

struct RuntimeConnectionTotals: Equatable, Sendable {
    let uploadTotalBytes: Int64
    let downloadTotalBytes: Int64
    let activeConnectionCount: Int
}

protocol RuntimeControlDescriptorProviding: Sendable {
    func verifiedRuntimeControlDescriptor() async -> RuntimeControlDescriptor?
}

protocol RuntimeObservationProviding: Sendable {
    func runtimeObservationAvailability() async -> RuntimeObservationState
    func currentRuntimeConnectionTotals() async -> RuntimeConnectionTotals?
}

protocol RuntimeControlClient: Sendable {
    func selectors(using descriptor: RuntimeControlDescriptor) async throws -> [String: RuntimeSelectorState]
    func select(selector: String, outbound: String, using descriptor: RuntimeControlDescriptor) async throws
    func probeLatency(outbound: String, using descriptor: RuntimeControlDescriptor) async throws -> Int
    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals
    func connections(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionsSnapshot
}

extension RuntimeControlClient {
    func probeLatency(outbound: String, using descriptor: RuntimeControlDescriptor) async throws -> Int {
        throw RuntimeControlError.unavailable
    }

    func connections(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionsSnapshot {
        throw RuntimeControlError.unavailable
    }
}

/// Fixed-purpose, loopback-only client for sing-box's local Clash-compatible
/// adapter. This is deliberately not a general HTTP client.
actor SingBoxRuntimeControlClient: RuntimeControlClient {
    enum ProbePolicy {
        /// This fixed HTTPS endpoint matches the connectivity semantics used by
        /// the pinned sing-box URL tester. It is intentionally not configurable
        /// by a Profile, the UI, or automation clients.
        static let connectivityURL = "https://www.gstatic.com/generate_204"
        static let timeoutMilliseconds = 1_500
        static let maximumLatencyMilliseconds = Int(UInt16.max)
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Controller requests must never traverse the user's system proxy. In
        // particular, the Bearer secret must not be sent to the mixed inbound.
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    func selectors(using descriptor: RuntimeControlDescriptor) async throws -> [String: RuntimeSelectorState] {
        let data = try await request(path: "/proxies", method: "GET", descriptor: descriptor, body: nil)
        let decoded: ProxyResponse
        do { decoded = try JSONDecoder().decode(ProxyResponse.self, from: data) }
        catch { throw RuntimeControlError.malformedResponse }
        var result: [String: RuntimeSelectorState] = [:]
        for (tag, value) in decoded.proxies {
            guard let selected = value.now, !selected.isEmpty else { continue }
            result[tag] = RuntimeSelectorState(tag: tag, selected: selected, members: value.all ?? [])
        }
        return result
    }

    func select(selector: String, outbound: String, using descriptor: RuntimeControlDescriptor) async throws {
        guard !selector.isEmpty, !outbound.isEmpty else { throw RuntimeControlError.invalidDescriptor }
        let payload = try JSONEncoder().encode(SelectorRequest(name: outbound))
        _ = try await request(path: "/proxies/\(Self.escapedPathComponent(selector))", method: "PUT", descriptor: descriptor, body: payload)
    }

    func probeLatency(outbound: String, using descriptor: RuntimeControlDescriptor) async throws -> Int {
        let request = try Self.makeDelayRequest(outbound: outbound, descriptor: descriptor)
        let data = try await send(request, nonSuccessError: .probeFailed)
        let decoded: DelayResponse
        do { decoded = try JSONDecoder().decode(DelayResponse.self, from: data) }
        catch { throw RuntimeControlError.malformedResponse }
        guard (1...ProbePolicy.maximumLatencyMilliseconds).contains(decoded.delay) else {
            throw RuntimeControlError.malformedResponse
        }
        return decoded.delay
    }

    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals {
        let snapshot = try await connections(using: descriptor)
        return snapshot.totals
    }

    func connections(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionsSnapshot {
        let data = try await request(path: "/connections", method: "GET", descriptor: descriptor, body: nil)
        return try RuntimeConnectionsParser.parse(data)
    }

    private func request(
        path: String,
        method: String,
        descriptor: RuntimeControlDescriptor,
        body: Data?
    ) async throws -> Data {
        let request = try Self.makeRequest(path: path, method: method, descriptor: descriptor, body: body)
        return try await send(request, nonSuccessError: .unavailable)
    }

    private func send(
        _ request: URLRequest,
        nonSuccessError: RuntimeControlError
    ) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RuntimeControlError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw RuntimeControlError.unavailable }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw RuntimeControlError.selectionRejected }
            if (300...399).contains(http.statusCode) { throw RuntimeControlError.redirectRefused }
            throw nonSuccessError
        }
        return data
    }

    static func makeDelayRequest(
        outbound: String,
        descriptor: RuntimeControlDescriptor
    ) throws -> URLRequest {
        guard !outbound.isEmpty else { throw RuntimeControlError.invalidDescriptor }
        var request = try makeRequest(
            path: "/proxies/\(escapedPathComponent(outbound))/delay",
            method: "GET",
            descriptor: descriptor,
            body: nil
        )
        guard var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw RuntimeControlError.invalidDescriptor
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: ProbePolicy.connectivityURL),
            URLQueryItem(name: "timeout", value: String(ProbePolicy.timeoutMilliseconds))
        ]
        guard let url = components.url,
              url.scheme == "http",
              url.host == RuntimeControlDescriptor.host,
              url.port == Int(descriptor.port) else {
            throw RuntimeControlError.invalidDescriptor
        }
        request.url = url
        return request
    }

    static func makeRequest(
        path: String,
        method: String,
        descriptor: RuntimeControlDescriptor,
        body: Data?
    ) throws -> URLRequest {
        guard descriptor.host == RuntimeControlDescriptor.host,
              descriptor.port >= LocalEngineEndpoint.minimumDynamicPort,
              !descriptor.secret.isEmpty,
              path.hasPrefix("/") else { throw RuntimeControlError.invalidDescriptor }
        var components = URLComponents()
        components.scheme = "http"
        components.host = RuntimeControlDescriptor.host
        components.port = Int(descriptor.port)
        components.percentEncodedPath = path
        guard let url = components.url, url.host == RuntimeControlDescriptor.host else {
            throw RuntimeControlError.invalidDescriptor
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = method
        request.setValue("Bearer \(descriptor.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func escapedPathComponent(_ component: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private struct SelectorRequest: Encodable { let name: String }
    private struct ProxyResponse: Decodable { let proxies: [String: Proxy] }
    private struct Proxy: Decodable { let now: String?; let all: [String]? }
    private struct DelayResponse: Decodable { let delay: Int }
}

enum RuntimeConnectionsParser {
    /// sing-box 1.13's Clash adapter serializes only this documented snapshot
    /// shape. The product DTO intentionally drops source addresses, process paths,
    /// memory values, and unknown controller data.
    static func parse(_ data: Data) throws -> RuntimeConnectionsSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let upload = nonNegativeInt64(root["uploadTotal"]),
              let download = nonNegativeInt64(root["downloadTotal"]),
              let rawConnections = root["connections"] as? [Any] else {
            throw RuntimeControlError.malformedResponse
        }
        guard rawConnections.count <= 1_000 else { throw RuntimeControlError.malformedResponse }
        let connections = rawConnections.compactMap(parseConnection)
        return .init(
            totals: .init(
                uploadTotalBytes: upload,
                downloadTotalBytes: download,
                activeConnectionCount: rawConnections.count
            ),
            connections: connections
        )
    }

    private static func parseConnection(_ value: Any) -> RuntimeConnection? {
        guard let dictionary = value as? [String: Any],
              let id = nonEmptyString(dictionary["id"]) else { return nil }
        let metadata = dictionary["metadata"] as? [String: Any] ?? [:]
        let chain = (dictionary["chains"] as? [Any] ?? []).compactMap(nonEmptyString)
        return .init(
            id: id,
            destinationHost: nonEmptyString(metadata["host"]),
            destinationIP: nonEmptyString(metadata["destinationIP"]),
            destinationPort: nonNegativeInt(metadata["destinationPort"]),
            network: nonEmptyString(metadata["network"]),
            inbound: nonEmptyString(metadata["type"]),
            outboundChain: chain,
            rule: nonEmptyString(dictionary["rule"]),
            uploadBytes: nonNegativeInt64(dictionary["upload"]),
            downloadBytes: nonNegativeInt64(dictionary["download"]),
            startedAt: parseDate(dictionary["start"])
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let numeric = nonNegativeInt64(value), numeric <= Int64(Int.max) else { return nil }
        return Int(numeric)
    }

    private static func nonNegativeInt64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let integer = number.int64Value
            return number.doubleValue == Double(integer) && integer >= 0 ? integer : nil
        }
        switch value {
        case let value as Int where value >= 0: return Int64(value)
        case let value as Int64 where value >= 0: return value
        case let value as String:
            guard let number = Int64(value), number >= 0 else { return nil }
            return number
        default: return nil
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum RuntimeControlDescriptorParser {
    static func parse(_ data: Data) -> RuntimeControlDescriptor? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let experimental = root["experimental"] as? [String: Any],
              let clashAPI = experimental["clash_api"] as? [String: Any],
              let endpoint = clashAPI["external_controller"] as? String,
              let secret = clashAPI["secret"] as? String,
              !secret.isEmpty,
              let split = endpoint.lastIndex(of: ":"),
              String(endpoint[..<split]) == RuntimeControlDescriptor.host,
              let rawPort = UInt16(endpoint[endpoint.index(after: split)...]),
              rawPort >= LocalEngineEndpoint.minimumDynamicPort else { return nil }
        return RuntimeControlDescriptor(host: RuntimeControlDescriptor.host, port: rawPort, secret: secret)
    }
}

enum RuntimeObservationState: String, Codable, Equatable, Sendable {
    case stopped, loading, available, unavailable
}

struct RuntimeObservation: Equatable, Sendable {
    let state: RuntimeObservationState
    let uploadTotalBytes: Int64?
    let downloadTotalBytes: Int64?
    let uploadBytesPerSecond: Double?
    let downloadBytesPerSecond: Double?
    let activeConnectionCount: Int?
    let observedAt: Date?

    static let stopped = RuntimeObservation(
        state: .stopped, uploadTotalBytes: nil, downloadTotalBytes: nil,
        uploadBytesPerSecond: nil, downloadBytesPerSecond: nil,
        activeConnectionCount: nil, observedAt: nil
    )
    static let loading = RuntimeObservation(
        state: .loading, uploadTotalBytes: nil, downloadTotalBytes: nil,
        uploadBytesPerSecond: nil, downloadBytesPerSecond: nil,
        activeConnectionCount: nil, observedAt: nil
    )
    static let unavailable = RuntimeObservation(
        state: .unavailable, uploadTotalBytes: nil, downloadTotalBytes: nil,
        uploadBytesPerSecond: nil, downloadBytesPerSecond: nil,
        activeConnectionCount: nil, observedAt: nil
    )
}

struct RuntimeObservationReducer: Sendable {
    private var previous: (totals: RuntimeConnectionTotals, date: Date)?

    mutating func reduce(totals: RuntimeConnectionTotals, at date: Date) -> RuntimeObservation {
        let uploadRate: Double
        let downloadRate: Double
        if let previous, date > previous.date,
           totals.uploadTotalBytes >= previous.totals.uploadTotalBytes,
           totals.downloadTotalBytes >= previous.totals.downloadTotalBytes {
            let elapsed = date.timeIntervalSince(previous.date)
            uploadRate = Double(totals.uploadTotalBytes - previous.totals.uploadTotalBytes) / elapsed
            downloadRate = Double(totals.downloadTotalBytes - previous.totals.downloadTotalBytes) / elapsed
        } else {
            uploadRate = 0
            downloadRate = 0
        }
        previous = (totals, date)
        return RuntimeObservation(
            state: .available,
            uploadTotalBytes: totals.uploadTotalBytes,
            downloadTotalBytes: totals.downloadTotalBytes,
            uploadBytesPerSecond: uploadRate,
            downloadBytesPerSecond: downloadRate,
            activeConnectionCount: totals.activeConnectionCount,
            observedAt: date
        )
    }

    mutating func reset() { previous = nil }
}

protocol TargetRuntimeObserving: Sendable {
    func read() async -> RuntimeObservation
}

struct UnavailableRuntimeObservationProvider: TargetRuntimeObserving {
    func read() async -> RuntimeObservation { .unavailable }
}

actor TargetRuntimeObservationOperations: TargetRuntimeObserving {
    private let provider: any RuntimeObservationProviding
    private var reducer = RuntimeObservationReducer()

    init(provider: any RuntimeObservationProviding) { self.provider = provider }

    func read() async -> RuntimeObservation {
        let availability = await provider.runtimeObservationAvailability()
        guard availability == .loading else {
            reducer.reset()
            return availability == .stopped ? .stopped : .unavailable
        }
        guard let totals = await provider.currentRuntimeConnectionTotals() else {
            reducer.reset()
            return .unavailable
        }
        return reducer.reduce(totals: totals, at: Date())
    }

    func stopped() {
        reducer.reset()
    }
}

extension RuntimeObservation {
    func automationJSON() -> JSONValue {
        .object([
            "activeConnectionCount": activeConnectionCount.map(JSONValue.integer) ?? .null,
            "downloadBytesPerSecond": downloadBytesPerSecond.map(JSONValue.number) ?? .null,
            "downloadTotalBytes": downloadTotalBytes.map { .integer(Int($0)) } ?? .null,
            "state": .string(state.rawValue),
            "uploadBytesPerSecond": uploadBytesPerSecond.map(JSONValue.number) ?? .null,
            "uploadTotalBytes": uploadTotalBytes.map { .integer(Int($0)) } ?? .null
        ])
    }
}
