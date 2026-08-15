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
    case transport(SubscriptionTransportFailure)

    var messageKey: String {
        switch self {
        case .noSubscription: "profile.subscription.error.no-url"
        case .unsafeURL, .unsafeRedirect: "profile.subscription.error.unsafe-url"
        case .timedOut: "profile.subscription.error.timeout"
        case .responseTooLarge: "profile.subscription.error.too-large"
        case .invalidResponse, .transportFailure, .transport: "profile.subscription.error.download-failed"
        case .httpStatus(let status): SubscriptionFailureDiagnostic.httpMessageKey(for: status)
        case .cancelled: "profile.subscription.error.cancelled"
        }
    }
}

enum SubscriptionTransportCategory: String, Equatable, Sendable {
    case dnsResolutionFailed
    case cannotConnect
    case connectionLost
    case tlsFailed
    case certificateFailed
    case networkUnavailable
    case timedOut
    case redirectFailed
    case invalidResponse
    case other
}

struct SubscriptionTransportFailure: Equatable, Sendable {
    static let errorDomain = NSURLErrorDomain

    let category: SubscriptionTransportCategory
    let code: Int

    init(_ code: URLError.Code) {
        self.code = code.rawValue
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            category = .dnsResolutionFailed
        case .cannotConnectToHost:
            category = .cannotConnect
        case .networkConnectionLost:
            category = .connectionLost
        case .secureConnectionFailed:
            category = .tlsFailed
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            category = .certificateFailed
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            category = .networkUnavailable
        case .timedOut:
            category = .timedOut
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            category = .redirectFailed
        case .cannotParseResponse, .badServerResponse:
            category = .invalidResponse
        default:
            category = .other
        }
    }
}

struct SubscriptionResponseMetadata: Equatable, Sendable {
    let contentType: String?
    let byteCount: Int
    let attemptCount: Int?

    init(contentType: String?, byteCount: Int, attemptCount: Int? = nil) {
        self.contentType = Self.safeContentType(contentType)
        self.byteCount = max(0, byteCount)
        self.attemptCount = attemptCount.map { max(1, $0) }
    }

    private static func safeContentType(_ value: String?) -> String? {
        guard let value else { return nil }
        let mime = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !mime.isEmpty, mime.utf8.count <= 127,
              mime.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                      || "!#$&^_.+-/".unicodeScalars.contains(scalar))
              }), let slash = mime.firstIndex(of: "/") else { return nil }
        let known: Set<String> = [
            "application/json", "application/yaml", "application/x-yaml",
            "application/octet-stream", "application/x-subscription",
            "application/xhtml+xml", "text/plain", "text/yaml", "text/x-yaml", "text/html"
        ]
        if known.contains(mime) { return mime }
        let topLevel = String(mime[..<slash])
        guard ["application", "text"].contains(topLevel) else { return nil }
        return "\(topLevel)/other"
    }
}

struct SubscriptionFetchFailure: Error, Equatable, Sendable {
    let cause: SubscriptionUpdateError
    let attempts: Int
    let response: SubscriptionResponseMetadata?
}

struct SubscriptionPersistenceFailure: Error, Equatable, Sendable {}

struct SubscriptionResponse: Sendable {
    let data: Data
    let cacheStatus: SubscriptionCacheStatus
    let etag: String?
    let lastModified: String?
    let metadata: SubscriptionResponseMetadata

    init(
        data: Data,
        cacheStatus: SubscriptionCacheStatus,
        etag: String?,
        lastModified: String?,
        contentType: String? = nil,
        attemptCount: Int = 1
    ) {
        self.data = data
        self.cacheStatus = cacheStatus
        self.etag = etag
        self.lastModified = lastModified
        metadata = SubscriptionResponseMetadata(
            contentType: contentType,
            byteCount: data.count,
            attemptCount: attemptCount
        )
    }

    func withAttemptCount(_ attemptCount: Int) -> SubscriptionResponse {
        SubscriptionResponse(
            data: data,
            cacheStatus: cacheStatus,
            etag: etag,
            lastModified: lastModified,
            contentType: metadata.contentType,
            attemptCount: attemptCount
        )
    }
}

struct PendingSubscriptionUpdate: Sendable {
    let profileID: UUID
    let json: String
    let diff: ProfileConfigurationDiff
    let response: SubscriptionResponse
}

protocol ProfileSubscriptionFetching: Sendable {
    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse
}

protocol SubscriptionHostResolving: Sendable {
    /// Returns numeric addresses, or nil when the system resolver cannot produce
    /// an answer. Resolution failure remains a transport concern.
    func addresses(for host: String) -> [String]?
}

struct SystemSubscriptionHostResolver: SubscriptionHostResolving {
    func addresses(for host: String) -> [String]? {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = info.ai_next
        }
        return addresses
    }
}

/// The production policy accepts only public HTTPS origins. The test-only switch
/// exists so unit tests can exercise the HTTP state machine against an isolated
/// loopback mock server without weakening the app's production path.
struct SubscriptionURLPolicy: Sendable {
    let allowsLocalHTTPForTesting: Bool
    private let resolver: any SubscriptionHostResolving

    static let production = SubscriptionURLPolicy(allowsLocalHTTPForTesting: false)
    static let localMockTesting = SubscriptionURLPolicy(allowsLocalHTTPForTesting: true)

    init(
        allowsLocalHTTPForTesting: Bool,
        resolver: any SubscriptionHostResolving = SystemSubscriptionHostResolver()
    ) {
        self.allowsLocalHTTPForTesting = allowsLocalHTTPForTesting
        self.resolver = resolver
    }

    func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw SubscriptionUpdateError.unsafeURL
        }
        if allowsLocalHTTPForTesting,
           ["http", "https"].contains(scheme.lowercased()),
           isLoopback(host) {
            return
        }
        guard scheme == "https", url.user == nil, url.password == nil, isSafeHost(host) else {
            throw SubscriptionUpdateError.unsafeURL
        }
    }

    private func isSafeHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") { return false }

        if isIPv4Literal(lower) {
            return !isUnsafeIPv4(lower, allowsSyntheticBenchmarkRange: false)
        }
        if isIPv6Literal(lower) {
            return !isUnsafeIPv6(lower)
        }

        guard let addresses = resolver.addresses(for: lower) else { return true }
        return !addresses.contains { address in
            isUnsafeIPv4(address, allowsSyntheticBenchmarkRange: true) || isUnsafeIPv6(address)
        }
    }

    private func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }

    private func isIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    private func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1
    }

    private func isUnsafeIPv4(_ host: String, allowsSyntheticBenchmarkRange: Bool) -> Bool {
        guard isIPv4Literal(host) else { return false }
        let bytes = host.split(separator: ".").compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1]
        return a == 0 || a == 10 || a == 127 || a >= 224
            || (a == 100 && (64...127).contains(b))
            || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || (!allowsSyntheticBenchmarkRange && a == 198 && (18...19).contains(b))
    }

    private func isUnsafeIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        return bytes.allSatisfy { $0 == 0 } || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
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
            var compatibleRequest = request
            compatibleRequest.setValue(SecureSubscriptionFetcher.userAgent, forHTTPHeaderField: "User-Agent")
            compatibleRequest.setValue(SecureSubscriptionFetcher.accept, forHTTPHeaderField: "Accept")
            completionHandler(compatibleRequest)
        } catch {
            rejectedRedirect = true
            completionHandler(nil)
        }
    }
}

/// An explicit, cancelable download operation. It retains no URLs or response
/// content after returning, and exposes only safe status/error categories.
final class SecureSubscriptionFetcher: ProfileSubscriptionFetching, @unchecked Sendable {
    static let defaultMaximumResponseBytes = 5 * 1024 * 1024
    static let defaultTimeout: TimeInterval = 20
    static let defaultRetryCount = 2
    static let userAgent = "Target/1.0 Clash.Meta"
    static let accept = "*/*"

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
        for attempt in 0...retryCount {
            do {
                return (try await fetchOnce(subscription: subscription)).withAttemptCount(attempt + 1)
            } catch is CancellationError {
                throw SubscriptionUpdateError.cancelled
            } catch let failure as SubscriptionFetchFailure {
                if failure.cause == .cancelled { throw failure.cause }
                guard attempt < retryCount, shouldRetry(failure.cause) else {
                    throw SubscriptionFetchFailure(
                        cause: failure.cause,
                        attempts: attempt + 1,
                        response: failure.response
                    )
                }
                try await waitBeforeRetry(attempt: attempt)
            } catch let error as SubscriptionUpdateError {
                if error == .cancelled { throw error }
                guard attempt < retryCount, shouldRetry(error) else {
                    throw SubscriptionFetchFailure(
                        cause: error,
                        attempts: attempt + 1,
                        response: nil
                    )
                }
                try await waitBeforeRetry(attempt: attempt)
            } catch {
                let failure = SubscriptionUpdateError.transportFailure
                guard attempt < retryCount else {
                    throw SubscriptionFetchFailure(cause: failure, attempts: attempt + 1, response: nil)
                }
                try await waitBeforeRetry(attempt: attempt)
            }
        }
        throw SubscriptionFetchFailure(cause: .transportFailure, attempts: retryCount + 1, response: nil)
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
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        if let etag = subscription.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = subscription.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        do {
            let (data, response) = try await session.data(for: request)
            if delegate.rejectedRedirect { throw SubscriptionUpdateError.unsafeRedirect }
            guard let http = response as? HTTPURLResponse else { throw SubscriptionUpdateError.invalidResponse }
            let metadata = SubscriptionResponseMetadata(contentType: http.mimeType, byteCount: data.count)
            if http.statusCode == 304 {
                return SubscriptionResponse(
                    data: Data(), cacheStatus: .notModified,
                    etag: http.value(forHTTPHeaderField: "ETag") ?? subscription.etag,
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified") ?? subscription.lastModified,
                    contentType: metadata.contentType
                )
            }
            if http.expectedContentLength > Int64(maximumResponseBytes) || data.count > maximumResponseBytes {
                throw SubscriptionFetchFailure(cause: .responseTooLarge, attempts: 1, response: metadata)
            }
            guard (200...299).contains(http.statusCode) else {
                throw SubscriptionFetchFailure(cause: .httpStatus(http.statusCode), attempts: 1, response: metadata)
            }
            return SubscriptionResponse(
                data: data, cacheStatus: .updated,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                contentType: metadata.contentType
            )
        } catch is CancellationError {
            throw SubscriptionUpdateError.cancelled
        } catch let failure as SubscriptionFetchFailure {
            throw failure
        } catch let error as URLError {
            if error.code == .timedOut { throw SubscriptionUpdateError.timedOut }
            if error.code == .cancelled { throw SubscriptionUpdateError.cancelled }
            throw SubscriptionUpdateError.transport(SubscriptionTransportFailure(error.code))
        }
    }

    private func shouldRetry(_ error: SubscriptionUpdateError) -> Bool {
        switch error {
        case .timedOut, .transportFailure:
            true
        case .httpStatus(let status):
            [408, 429, 500, 502, 503, 504].contains(status)
        case .transport(let failure):
            [.dnsResolutionFailed, .cannotConnect, .connectionLost, .timedOut].contains(failure.category)
        default: false
        }
    }

    private func waitBeforeRetry(attempt: Int) async throws {
        do {
            try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
        } catch is CancellationError {
            throw SubscriptionUpdateError.cancelled
        }
    }
}

enum SubscriptionFailureStage: String, Equatable, Sendable {
    case urlSafety = "URL Safety"
    case resolving = "Resolving"
    case connecting = "Connecting"
    case tls = "TLS"
    case httpRequest = "HTTP Request"
    case redirect = "Redirect"
    case httpResponse = "HTTP Response"
    case downloading = "Downloading"
    case payloadDetection = "Payload Detection"
    case normalization = "Normalization"
    case configurationValidation = "Configuration Validation"
    case persistence = "Persistence"

    var titleKey: String {
        switch self {
        case .urlSafety: "profile.subscription.diagnostic.stage.urlSafety"
        case .resolving: "profile.subscription.diagnostic.stage.resolving"
        case .connecting: "profile.subscription.diagnostic.stage.connecting"
        case .tls: "profile.subscription.diagnostic.stage.tls"
        case .httpRequest: "profile.subscription.diagnostic.stage.httpRequest"
        case .redirect: "profile.subscription.diagnostic.stage.redirect"
        case .httpResponse: "profile.subscription.diagnostic.stage.httpResponse"
        case .downloading: "profile.subscription.diagnostic.stage.downloading"
        case .payloadDetection: "profile.subscription.diagnostic.stage.payloadDetection"
        case .normalization: "profile.subscription.diagnostic.stage.normalization"
        case .configurationValidation: "profile.subscription.diagnostic.stage.configurationValidation"
        case .persistence: "profile.subscription.diagnostic.stage.persistence"
        }
    }
}

enum SubscriptionFailureCategory: String, Equatable, Sendable {
    case missingSource = "Missing Source"
    case unsafeURL = "Unsafe URL"
    case redirectRejected = "Redirect Rejected"
    case httpError = "HTTP Error"
    case dnsFailure = "DNS Failure"
    case connectionFailure = "Connection Failure"
    case connectionLost = "Connection Lost"
    case tlsFailure = "TLS Failure"
    case certificateFailure = "Certificate Failure"
    case networkUnavailable = "Network Unavailable"
    case timeout = "Timeout"
    case invalidResponse = "Invalid HTTP Response"
    case transportFailure = "Transport Failure"
    case responseTooLarge = "Response Too Large"
    case webPageReturned = "Web Page Returned"
    case formatUnsupported = "Format Unsupported"
    case payloadInvalid = "Payload Invalid"
    case protocolUnsupported = "Protocol Unsupported"
    case variantUnsupported = "Variant Unsupported"
    case complexityLimitExceeded = "Complexity Limit Exceeded"
    case validationFailed = "Configuration Validation Failed"
    case persistenceFailed = "Persistence Failed"
    case cancelled = "Cancelled"
}

struct SubscriptionFailureDiagnostic: Equatable, Sendable, CustomStringConvertible {
    static let supportedFormats = "sing-box JSON; URI list; Base64 URI list; Clash YAML"

    let titleKey: String
    let stage: SubscriptionFailureStage
    let category: SubscriptionFailureCategory
    let reasonKey: String
    let httpStatus: Int?
    let transportErrorDomain: String?
    let transportErrorCode: Int?
    let attemptCount: Int?
    let contentType: String?
    let responseBytes: Int?
    let isRetryable: Bool?
    let showsSupportedFormats: Bool

    private init(
        titleKey: String,
        stage: SubscriptionFailureStage,
        category: SubscriptionFailureCategory,
        reasonKey: String,
        httpStatus: Int?,
        transportErrorDomain: String?,
        transportErrorCode: Int?,
        attemptCount: Int?,
        contentType: String?,
        responseBytes: Int?,
        isRetryable: Bool?,
        showsSupportedFormats: Bool
    ) {
        self.titleKey = titleKey
        self.stage = stage
        self.category = category
        self.reasonKey = reasonKey
        self.httpStatus = httpStatus
        self.transportErrorDomain = transportErrorDomain
        self.transportErrorCode = transportErrorCode
        self.attemptCount = attemptCount
        self.contentType = contentType
        self.responseBytes = responseBytes
        self.isRetryable = isRetryable
        self.showsSupportedFormats = showsSupportedFormats
    }

    init(error: Error) {
        if let failure = error as? SubscriptionFetchFailure {
            self = Self.update(
                failure.cause,
                attempts: failure.attempts,
                response: failure.response
            )
        } else if let failure = error as? SubscriptionIntakeFailure {
            self = Self.intake(failure.cause, response: failure.response)
        } else if let error = error as? SubscriptionUpdateError {
            self = Self.update(error, attempts: nil, response: nil)
        } else if let error = error as? SubscriptionIntakeError {
            self = Self.intake(error, response: nil)
        } else if error is SubscriptionPersistenceFailure {
            self = Self.make(
                title: "profile.subscription.diagnostic.title.content",
                stage: .persistence,
                category: .persistenceFailed,
                reason: "profile.subscription.error.persistence-failed",
                common: (nil, nil, nil),
                retryable: false
            )
        } else if let error = error as? URLError {
            self = Self.update(
                .transport(SubscriptionTransportFailure(error.code)),
                attempts: nil,
                response: nil
            )
        } else if let error = error as? ProfileStoreError, case .validationFailed = error {
            self = Self.intake(.validationFailed, response: nil)
        } else {
            self = Self.update(.transportFailure, attempts: nil, response: nil)
        }
    }

    var description: String { copyableDescription }

    var copyableDescription: String {
        var lines = [
            "Target Subscription Diagnostic",
            "Stage: \(stage.rawValue)",
            "Category: \(category.rawValue)"
        ]
        if let httpStatus { lines.append("HTTP Status: \(httpStatus)") }
        if let transportErrorDomain, let transportErrorCode {
            lines.append("Error Code: \(transportErrorDomain) \(transportErrorCode)")
        }
        if let attemptCount { lines.append("Attempts: \(attemptCount)") }
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if let responseBytes { lines.append("Response Bytes: \(responseBytes)") }
        if showsSupportedFormats { lines.append("Supported Formats: \(Self.supportedFormats)") }
        if let isRetryable { lines.append("Retryable: \(isRetryable ? "Yes" : "No")") }
        return lines.joined(separator: "\n")
    }

    static func httpMessageKey(for status: Int) -> String {
        switch status {
        case 401, 403: "profile.subscription.error.http-rejected"
        case 404, 410: "profile.subscription.error.http-unavailable"
        case 406: "profile.subscription.error.http-negotiation"
        case 408: "profile.subscription.error.timeout"
        case 429: "profile.subscription.error.http-rate-limited"
        case 500...599: "profile.subscription.error.http-temporary"
        default: "profile.subscription.error.http"
        }
    }

    private static func update(
        _ error: SubscriptionUpdateError,
        attempts: Int?,
        response: SubscriptionResponseMetadata?
    ) -> Self {
        let common = (
            attempts: attempts,
            contentType: response?.contentType,
            responseBytes: response?.byteCount
        )
        switch error {
        case .noSubscription:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .urlSafety,
                             category: .missingSource, reason: error.messageKey, common: common, retryable: false)
        case .unsafeURL:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .urlSafety,
                             category: .unsafeURL, reason: error.messageKey, common: common, retryable: false)
        case .unsafeRedirect:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .redirect,
                             category: .redirectRejected, reason: "profile.subscription.error.redirect-rejected",
                             common: common, retryable: false)
        case .timedOut:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .downloading,
                             category: .timeout, reason: error.messageKey, common: common, retryable: true,
                             domain: SubscriptionTransportFailure.errorDomain,
                             code: URLError.Code.timedOut.rawValue)
        case .responseTooLarge:
            return Self.make(title: "profile.subscription.diagnostic.title.content", stage: .downloading,
                             category: .responseTooLarge, reason: error.messageKey, common: common, retryable: false)
        case .invalidResponse:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .httpResponse,
                             category: .invalidResponse, reason: "profile.subscription.error.invalid-response",
                             common: common, retryable: false)
        case .httpStatus(let status):
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .httpResponse,
                             category: .httpError, reason: httpMessageKey(for: status), common: common,
                             retryable: [408, 429, 500, 502, 503, 504].contains(status), status: status)
        case .cancelled:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .downloading,
                             category: .cancelled, reason: error.messageKey, common: common, retryable: false)
        case .transportFailure:
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: .connecting,
                             category: .transportFailure, reason: error.messageKey, common: common, retryable: true)
        case .transport(let failure):
            let mapping: (SubscriptionFailureStage, SubscriptionFailureCategory, String, Bool)
            switch failure.category {
            case .dnsResolutionFailed:
                mapping = (.resolving, .dnsFailure, "profile.subscription.error.dns", true)
            case .cannotConnect:
                mapping = (.connecting, .connectionFailure, "profile.subscription.error.connect", true)
            case .connectionLost:
                mapping = (.downloading, .connectionLost, "profile.subscription.error.connection-lost", true)
            case .tlsFailed:
                mapping = (.tls, .tlsFailure, "profile.subscription.error.tls", false)
            case .certificateFailed:
                mapping = (.tls, .certificateFailure, "profile.subscription.error.certificate", false)
            case .networkUnavailable:
                mapping = (.connecting, .networkUnavailable, "profile.subscription.error.network-unavailable", false)
            case .timedOut:
                mapping = (.downloading, .timeout, "profile.subscription.error.timeout", true)
            case .redirectFailed:
                mapping = (.redirect, .redirectRejected, "profile.subscription.error.redirect-rejected", false)
            case .invalidResponse:
                mapping = (.httpResponse, .invalidResponse, "profile.subscription.error.invalid-response", false)
            case .other:
                mapping = (.connecting, .transportFailure, "profile.subscription.error.download-failed", false)
            }
            return Self.make(title: "profile.subscription.diagnostic.title.download", stage: mapping.0,
                             category: mapping.1, reason: mapping.2, common: common, retryable: mapping.3,
                             domain: SubscriptionTransportFailure.errorDomain, code: failure.code)
        }
    }

    private static func intake(
        _ error: SubscriptionIntakeError,
        response: SubscriptionResponseMetadata?
    ) -> Self {
        let common = (attempts: response?.attemptCount, contentType: response?.contentType,
                      responseBytes: response?.byteCount)
        switch error {
        case .formatUnsupported:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .payloadDetection,
                        category: .formatUnsupported, reason: error.messageKey, common: common,
                        retryable: false, formats: true)
        case .webPageReturned:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .payloadDetection,
                        category: .webPageReturned, reason: error.messageKey, common: common, retryable: false)
        case .emptyPayload, .invalidUTF8, .payloadInvalid:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .payloadDetection,
                        category: .payloadInvalid, reason: error.messageKey, common: common, retryable: false)
        case .protocolUnsupported:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .normalization,
                        category: .protocolUnsupported, reason: error.messageKey, common: common, retryable: false)
        case .variantUnsupported:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .normalization,
                        category: .variantUnsupported, reason: error.messageKey, common: common, retryable: false)
        case .complexityLimitExceeded:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .normalization,
                        category: .complexityLimitExceeded, reason: error.messageKey, common: common, retryable: false)
        case .validationFailed:
            return make(title: "profile.subscription.diagnostic.title.content", stage: .configurationValidation,
                        category: .validationFailed, reason: error.messageKey, common: common, retryable: false)
        }
    }

    private static func make(
        title: String,
        stage: SubscriptionFailureStage,
        category: SubscriptionFailureCategory,
        reason: String,
        common: (attempts: Int?, contentType: String?, responseBytes: Int?),
        retryable: Bool?,
        status: Int? = nil,
        domain: String? = nil,
        code: Int? = nil,
        formats: Bool = false
    ) -> Self {
        Self(titleKey: title, stage: stage, category: category, reasonKey: reason,
             httpStatus: status, transportErrorDomain: domain, transportErrorCode: code,
             attemptCount: common.attempts, contentType: common.contentType,
             responseBytes: common.responseBytes, isRetryable: retryable,
             showsSupportedFormats: formats)
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
