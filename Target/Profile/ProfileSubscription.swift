import Darwin
import Foundation

enum SubscriptionUpdateError: Error, Equatable, Sendable {
    case noSubscription
    case unsafeURL
    case unsafeRedirect
    case timedOut
    case responseTooLarge
    case invalidResponse
    case httpStatus(Int)
    case cancelled
    case transportFailure

    var messageKey: String {
        switch self {
        case .noSubscription: "profile.subscription.error.no-url"
        case .unsafeURL, .unsafeRedirect: "profile.subscription.error.unsafe-url"
        case .timedOut: "profile.subscription.error.timeout"
        case .responseTooLarge: "profile.subscription.error.too-large"
        case .invalidResponse, .httpStatus, .transportFailure: "profile.subscription.error.download-failed"
        case .cancelled: "profile.subscription.error.cancelled"
        }
    }
}

struct SubscriptionResponse: Sendable {
    let data: Data
    let cacheStatus: SubscriptionCacheStatus
    let etag: String?
    let lastModified: String?
}

struct PendingSubscriptionUpdate: Sendable {
    let profileID: UUID
    let json: String
    let diff: ProfileConfigurationDiff
    let response: SubscriptionResponse
}

/// The production policy accepts only public HTTPS origins. The test-only switch
/// exists so unit tests can exercise the HTTP state machine against an isolated
/// loopback mock server without weakening the app's production path.
struct SubscriptionURLPolicy: Sendable {
    let allowsLocalHTTPForTesting: Bool

    static let production = SubscriptionURLPolicy(allowsLocalHTTPForTesting: false)
    static let localMockTesting = SubscriptionURLPolicy(allowsLocalHTTPForTesting: true)

    func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw SubscriptionUpdateError.unsafeURL
        }
        if allowsLocalHTTPForTesting,
           ["http", "https"].contains(scheme.lowercased()),
           isLoopback(host) {
            return
        }
        guard scheme == "https", url.user == nil, url.password == nil, !isLocalOrPrivateHost(host) else {
            throw SubscriptionUpdateError.unsafeURL
        }
    }

    private func isLocalOrPrivateHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") { return true }
        return isPrivateIPv4(lower) || isPrivateIPv6(lower) || resolvesToPrivateAddress(lower)
    }

    private func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }

    private func isPrivateIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let bytes = host.split(separator: ".").compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1]
        return a == 0 || a == 10 || a == 127 || a >= 224
            || (a == 100 && (64...127).contains(b))
            || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || (a == 198 && (18...19).contains(b))
    }

    private func isPrivateIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        return bytes.allSatisfy { $0 == 0 } || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
    }

    /// Resolve before connecting so a public-looking hostname cannot point at a
    /// loopback or RFC1918 address. Failed resolution is left to URLSession as a
    /// normal transport error; only an affirmative private result is rejected.
    private func resolvesToPrivateAddress(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return false }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: buffer)
                if isPrivateIPv4(address) || isPrivateIPv6(address) { return true }
            }
            cursor = info.ai_next
        }
        return false
    }
}

private final class SubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: SubscriptionURLPolicy
    private(set) var rejectedRedirect = false

    init(policy: SubscriptionURLPolicy) { self.policy = policy }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            guard let url = request.url else { throw SubscriptionUpdateError.unsafeRedirect }
            try policy.validate(url)
            completionHandler(request)
        } catch {
            rejectedRedirect = true
            completionHandler(nil)
        }
    }
}

/// An explicit, cancelable download operation. It retains no URLs or response
/// content after returning, and exposes only safe status/error categories.
final class SecureSubscriptionFetcher: @unchecked Sendable {
    static let defaultMaximumResponseBytes = 5 * 1024 * 1024
    static let defaultTimeout: TimeInterval = 20
    static let defaultRetryCount = 2

    private let policy: SubscriptionURLPolicy
    private let maximumResponseBytes: Int
    private let timeout: TimeInterval
    private let retryCount: Int

    init(
        policy: SubscriptionURLPolicy = .production,
        maximumResponseBytes: Int = SecureSubscriptionFetcher.defaultMaximumResponseBytes,
        timeout: TimeInterval = SecureSubscriptionFetcher.defaultTimeout,
        retryCount: Int = SecureSubscriptionFetcher.defaultRetryCount
    ) {
        self.policy = policy
        self.maximumResponseBytes = maximumResponseBytes
        self.timeout = timeout
        self.retryCount = retryCount
    }

    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        try policy.validate(subscription.url)
        var lastError: SubscriptionUpdateError = .transportFailure
        for attempt in 0...retryCount {
            do {
                return try await fetchOnce(subscription: subscription)
            } catch is CancellationError {
                throw SubscriptionUpdateError.cancelled
            } catch let error as SubscriptionUpdateError {
                if error == .cancelled { throw error }
                lastError = error
                guard attempt < retryCount, shouldRetry(error) else { throw error }
                try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            } catch {
                lastError = .transportFailure
                guard attempt < retryCount else { throw lastError }
                try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }
        throw lastError
    }

    private func fetchOnce(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        let delegate = SubscriptionRedirectDelegate(policy: policy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: subscription.url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = subscription.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = subscription.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        do {
            let (data, response) = try await session.data(for: request)
            if delegate.rejectedRedirect { throw SubscriptionUpdateError.unsafeRedirect }
            guard let http = response as? HTTPURLResponse else { throw SubscriptionUpdateError.invalidResponse }
            if http.statusCode == 304 {
                return SubscriptionResponse(data: Data(), cacheStatus: .notModified, etag: http.value(forHTTPHeaderField: "ETag") ?? subscription.etag, lastModified: http.value(forHTTPHeaderField: "Last-Modified") ?? subscription.lastModified)
            }
            guard (200...299).contains(http.statusCode) else { throw SubscriptionUpdateError.httpStatus(http.statusCode) }
            if http.expectedContentLength > Int64(maximumResponseBytes) || data.count > maximumResponseBytes {
                throw SubscriptionUpdateError.responseTooLarge
            }
            return SubscriptionResponse(data: data, cacheStatus: .updated, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        } catch is CancellationError {
            throw SubscriptionUpdateError.cancelled
        } catch let error as URLError {
            if error.code == .timedOut { throw SubscriptionUpdateError.timedOut }
            if error.code == .cancelled { throw SubscriptionUpdateError.cancelled }
            throw SubscriptionUpdateError.transportFailure
        }
    }

    private func shouldRetry(_ error: SubscriptionUpdateError) -> Bool {
        switch error {
        case .timedOut, .transportFailure, .httpStatus: true
        default: false
        }
    }
}

struct ProfileConfigurationDiff: Equatable, Sendable {
    struct Section: Identifiable, Equatable, Sendable {
        let id: String
        let added: [String]
        let removed: [String]
        let modified: [String]
        var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !modified.isEmpty }
    }

    let outbounds: Section
    let routeRules: Section
    let dns: Section
    let inbounds: Section
    let unknown: Section

    var hasChanges: Bool { [outbounds, routeRules, dns, inbounds, unknown].contains(where: \.hasChanges) }

    static func make(current: Data, candidate: Data) -> ProfileConfigurationDiff {
        let old = object(from: current)
        let new = object(from: candidate)
        return ProfileConfigurationDiff(
            outbounds: taggedSection(id: "profile.diff.outbounds", key: "outbounds", old: old, new: new),
            routeRules: valueSection(id: "profile.diff.route-rules", key: "route", old: old, new: new),
            dns: valueSection(id: "profile.diff.dns", key: "dns", old: old, new: new),
            inbounds: taggedSection(id: "profile.diff.inbounds", key: "inbounds", old: old, new: new),
            unknown: unknownSection(old: old, new: new)
        )
    }

    private static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func taggedSection(id: String, key: String, old: [String: Any], new: [String: Any]) -> Section {
        func entries(_ object: [String: Any]) -> [String: Any] {
            let array = object[key] as? [[String: Any]] ?? []
            return Dictionary(uniqueKeysWithValues: array.enumerated().map { index, value in
                let tag = (value["tag"] as? String).map(SensitiveConfigurationRedactor.displayIdentifier) ?? "#\(index + 1)"
                return (tag, value)
            })
        }
        return compare(id: id, old: entries(old), new: entries(new))
    }

    private static func valueSection(id: String, key: String, old: [String: Any], new: [String: Any]) -> Section {
        let oldValue = old[key]
        let newValue = new[key]
        guard !jsonEqual(oldValue, newValue) else { return Section(id: id, added: [], removed: [], modified: []) }
        if oldValue == nil { return Section(id: id, added: ["profile.diff.added"], removed: [], modified: []) }
        if newValue == nil { return Section(id: id, added: [], removed: ["profile.diff.removed"], modified: []) }
        return Section(id: id, added: [], removed: [], modified: ["profile.diff.changed"])
    }

    private static func unknownSection(old: [String: Any], new: [String: Any]) -> Section {
        let known: Set<String> = ["outbounds", "route", "dns", "inbounds"]
        return compare(id: "profile.diff.other", old: old.filter { !known.contains($0.key) }, new: new.filter { !known.contains($0.key) })
    }

    private static func compare(id: String, old: [String: Any], new: [String: Any]) -> Section {
        let added = new.keys.filter { old[$0] == nil }.sorted()
        let removed = old.keys.filter { new[$0] == nil }.sorted()
        let modified = new.keys.filter { old[$0] != nil && !jsonEqual(old[$0], new[$0]) }.sorted()
        return Section(id: id, added: added, removed: removed, modified: modified)
    }

    private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs,
              let l = try? JSONSerialization.data(withJSONObject: [lhs], options: [.sortedKeys]),
              let r = try? JSONSerialization.data(withJSONObject: [rhs], options: [.sortedKeys]) else { return lhs == nil && rhs == nil }
        return l == r
    }
}

enum SensitiveConfigurationRedactor {
    private static let sensitiveKeys: Set<String> = ["password", "uuid", "private_key", "private-key", "token", "secret", "authorization", "url", "server", "username", "client_secret", "address", "host", "domain"]

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return "<redacted>"
    }

    static func displayIdentifier(_ text: String) -> String {
        if text.contains("://") || UUID(uuidString: text) != nil || text.lowercased().contains("secret") || text.lowercased().contains("password") {
            return "<redacted>"
        }
        return text
    }

    static func redactedJSON(_ data: Data) -> String {
        guard var object = try? JSONSerialization.jsonObject(with: data) else { return "<invalid>" }
        redact(&object)
        guard let result = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "<redacted>" }
        return String(decoding: result, as: UTF8.self)
    }

    private static func redact(_ value: inout Any) {
        if var dictionary = value as? [String: Any] {
            for key in dictionary.keys {
                if sensitiveKeys.contains(key.lowercased()) { dictionary[key] = "<redacted>" }
                else if var child = dictionary[key] { redact(&child); dictionary[key] = child }
            }
            value = dictionary
        } else if var array = value as? [Any] {
            for index in array.indices { var child = array[index]; redact(&child); array[index] = child }
            value = array
        }
    }
}
