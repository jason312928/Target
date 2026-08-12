import Foundation
import TargetCore

/// The narrow error vocabulary intentionally avoids propagating controller
/// response bodies (which could contain upstream-specific or sensitive data).
enum RuntimeControlError: Error, Equatable, Sendable {
    case invalidDescriptor
    case unavailable
    case redirectRefused
    case malformedResponse
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

protocol RuntimePolicyApplying: Sendable {
    func applyLivePolicySelection(selectorTag: String, outboundTag: String) async -> Bool
}

protocol RuntimeObservationProviding: Sendable {
    func runtimeObservationAvailability() async -> RuntimeObservationState
    func currentRuntimeConnectionTotals() async -> RuntimeConnectionTotals?
}

protocol RuntimeControlClient: Sendable {
    func selectors(using descriptor: RuntimeControlDescriptor) async throws -> [String: RuntimeSelectorState]
    func select(selector: String, outbound: String, using descriptor: RuntimeControlDescriptor) async throws
    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals
}

/// Fixed-purpose, loopback-only client for sing-box's local Clash-compatible
/// adapter. This is deliberately not a general HTTP client.
actor SingBoxRuntimeControlClient: RuntimeControlClient {
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
        _ = try await request(path: "/proxies/\(escapedPathComponent(selector))", method: "PUT", descriptor: descriptor, body: payload)
    }

    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals {
        let data = try await request(path: "/connections", method: "GET", descriptor: descriptor, body: nil)
        let decoded: ConnectionsResponse
        do { decoded = try JSONDecoder().decode(ConnectionsResponse.self, from: data) }
        catch { throw RuntimeControlError.malformedResponse }
        guard decoded.uploadTotal >= 0, decoded.downloadTotal >= 0 else {
            throw RuntimeControlError.malformedResponse
        }
        return RuntimeConnectionTotals(
            uploadTotalBytes: decoded.uploadTotal,
            downloadTotalBytes: decoded.downloadTotal,
            activeConnectionCount: decoded.connections.count
        )
    }

    private func request(
        path: String,
        method: String,
        descriptor: RuntimeControlDescriptor,
        body: Data?
    ) async throws -> Data {
        let request = try Self.makeRequest(path: path, method: method, descriptor: descriptor, body: body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw RuntimeControlError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw RuntimeControlError.unavailable }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw RuntimeControlError.selectionRejected }
            throw RuntimeControlError.unavailable
        }
        return data
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

    private func escapedPathComponent(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""
    }

    private struct SelectorRequest: Encodable { let name: String }
    private struct ProxyResponse: Decodable { let proxies: [String: Proxy] }
    private struct Proxy: Decodable { let now: String?; let all: [String]? }
    private struct ConnectionsResponse: Decodable {
        let uploadTotal: Int64
        let downloadTotal: Int64
        let connections: [Connection]
    }
    private struct Connection: Decodable {}
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
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
