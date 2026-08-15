import Foundation
import Network
import XCTest

@testable import Target

final class ProfileSubscriptionTests: XCTestCase, ProfileTestCaseSupport {
    func testSubscriptionETagAnd304WithLocalMockServer() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 200, headers: ["ETag": "v1", "Last-Modified": "Wed, 01 Jan 2025 00:00:00 GMT"], body: Data("{\"inbounds\":[]}".utf8)),
            .init(status: 304, headers: ["ETag": "v1"], body: Data())
        ])
        defer { server.stop() }
        let fetcher = SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 1, retryCount: 0)
        let initial = RemoteSubscription(url: server.url)
        let first = try await fetcher.fetch(subscription: initial)
        XCTAssertEqual(first.cacheStatus, .updated)
        let cached = RemoteSubscription(url: server.url, etag: first.etag, lastModified: first.lastModified)
        let second = try await fetcher.fetch(subscription: cached)
        XCTAssertEqual(second.cacheStatus, .notModified)
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(SecureSubscriptionFetcher.userAgent, "Target/1.0 Clash.Meta")
        XCTAssertTrue(requests.allSatisfy { $0.headers["user-agent"] == SecureSubscriptionFetcher.userAgent })
        XCTAssertTrue(requests.allSatisfy { $0.headers["accept"] == SecureSubscriptionFetcher.accept })
        XCTAssertEqual(requests[1].headers["if-none-match"], "v1")
        XCTAssertEqual(requests[1].headers["if-modified-since"], "Wed, 01 Jan 2025 00:00:00 GMT")
    }

    func testSubscriptionTimeoutAndCancellationWithLocalMockServer() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 200, headers: [:], body: Data("{}".utf8), delay: 0.35),
            .init(status: 200, headers: [:], body: Data("{}".utf8), delay: 0.35)
        ])
        defer { server.stop() }
        let slow = SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 0.05, retryCount: 0)
        do {
            _ = try await slow.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected timeout")
        } catch let failure as SubscriptionFetchFailure {
            XCTAssertEqual(failure.cause, .timedOut)
            XCTAssertEqual(failure.attempts, 1)
        }

        let task = Task { try await SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 2, retryCount: 0).fetch(subscription: RemoteSubscription(url: server.url)) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as SubscriptionUpdateError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testSubscriptionRedirectAndPrivateOriginsAreRejected() async throws {
        let server = try MockHTTPServer(responses: [.init(status: 302, headers: ["Location": "http://example.com/redirect"], body: Data())])
        defer { server.stop() }
        let fetcher = SecureSubscriptionFetcher(policy: .localMockTesting, timeout: 1, retryCount: 0)
        do {
            _ = try await fetcher.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected redirect rejection")
        } catch let failure as SubscriptionFetchFailure {
            XCTAssertEqual(failure.cause, .unsafeRedirect)
        }
        for string in ["file:///tmp/sub.json", "http://example.com/sub", "https://localhost/sub", "https://127.0.0.1/sub", "https://10.0.0.1/sub", "https://[::1]/sub"] {
            XCTAssertThrowsError(try SubscriptionURLPolicy.production.validate(try XCTUnwrap(URL(string: string))))
        }
    }

    func testSubscriptionURLPolicyAllowsPublicAndFakeIPHostnameResolutions() throws {
        for address in ["93.184.216.34", "198.18.0.1", "198.19.20.30"] {
            let policy = SubscriptionURLPolicy(
                allowsLocalHTTPForTesting: false,
                resolver: FixedSubscriptionHostResolver(addresses: ["provider.example": [address]])
            )
            XCTAssertNoThrow(try policy.validate(try XCTUnwrap(URL(string: "https://provider.example/sub"))))
        }

        let failedResolution = SubscriptionURLPolicy(
            allowsLocalHTTPForTesting: false,
            resolver: FixedSubscriptionHostResolver(addresses: [:])
        )
        XCTAssertNoThrow(try failedResolution.validate(try XCTUnwrap(URL(string: "https://provider.example/sub"))))
    }

    func testSubscriptionURLPolicyRejectsSyntheticLiteralsAndPrivateHostnameResolutions() throws {
        let noResolution = SubscriptionURLPolicy(
            allowsLocalHTTPForTesting: false,
            resolver: FixedSubscriptionHostResolver(addresses: [:])
        )
        for string in ["https://198.18.0.1/sub", "https://198.19.20.30/sub"] {
            XCTAssertThrowsError(try noResolution.validate(try XCTUnwrap(URL(string: string)))) { error in
                XCTAssertEqual(error as? SubscriptionUpdateError, .unsafeURL)
            }
        }

        for address in ["127.0.0.1", "10.20.30.40", "172.16.20.30", "192.168.20.30", "169.254.20.30", "::1", "fd00::1", "fe80::1"] {
            let policy = SubscriptionURLPolicy(
                allowsLocalHTTPForTesting: false,
                resolver: FixedSubscriptionHostResolver(addresses: ["provider.example": [address]])
            )
            XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: "https://provider.example/sub")))) { error in
                XCTAssertEqual(error as? SubscriptionUpdateError, .unsafeURL)
            }
        }

        let mixed = SubscriptionURLPolicy(
            allowsLocalHTTPForTesting: false,
            resolver: FixedSubscriptionHostResolver(addresses: ["provider.example": ["198.18.0.1", "93.184.216.34", "10.0.0.1"]])
        )
        XCTAssertThrowsError(try mixed.validate(try XCTUnwrap(URL(string: "https://provider.example/sub")))) { error in
            XCTAssertEqual(error as? SubscriptionUpdateError, .unsafeURL)
        }
    }

    func testSubscriptionURLPolicyKeepsMalformedHTTPCredentialAndLocalHostRejections() throws {
        let policy = SubscriptionURLPolicy(
            allowsLocalHTTPForTesting: false,
            resolver: FixedSubscriptionHostResolver(addresses: ["provider.example": ["93.184.216.34"]])
        )
        for string in [
            "not-a-url",
            "http://provider.example/sub",
            "https://user:password@provider.example/sub",
            "https://localhost/sub",
            "https://service.localhost/sub",
            "https://service.local/sub"
        ] {
            XCTAssertThrowsError(try policy.validate(try XCTUnwrap(URL(string: string)))) { error in
                XCTAssertEqual(error as? SubscriptionUpdateError, .unsafeURL)
            }
        }
    }

    func testSubscriptionRedirectRejectsInjectedPrivateHostnameResolution() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 302, headers: ["Location": "https://redirect.example/sub"], body: Data())
        ])
        defer { server.stop() }
        let policy = SubscriptionURLPolicy(
            allowsLocalHTTPForTesting: true,
            resolver: FixedSubscriptionHostResolver(addresses: ["redirect.example": ["10.0.0.1"]])
        )
        let fetcher = SecureSubscriptionFetcher(policy: policy, timeout: 1, retryCount: 0)
        do {
            _ = try await fetcher.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected redirect rejection")
        } catch let failure as SubscriptionFetchFailure {
            XCTAssertEqual(failure.cause, .unsafeRedirect)
        }
    }

    func testSubscriptionRejectsLargeResponseFromLocalMockServer() async throws {
        let server = try MockHTTPServer(responses: [.init(status: 200, headers: [:], body: Data(repeating: 65, count: 2048))])
        defer { server.stop() }
        let fetcher = SecureSubscriptionFetcher(policy: .localMockTesting, maximumResponseBytes: 128, timeout: 1, retryCount: 0)
        do {
            _ = try await fetcher.fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected response size rejection")
        } catch let failure as SubscriptionFetchFailure {
            XCTAssertEqual(failure.cause, .responseTooLarge)
            XCTAssertEqual(failure.response?.byteCount, 2_048)
        }
    }

    func testHTTPRetryPolicyUsesBoundedStatusAllowlist() async throws {
        for status in [400, 401, 403, 404, 406, 409, 410] {
            let server = try MockHTTPServer(responses: [
                .init(status: status, headers: ["Content-Type": "text/plain"], body: Data())
            ])
            defer { server.stop() }
            do {
                _ = try await SecureSubscriptionFetcher(
                    policy: .localMockTesting, timeout: 1, retryCount: 2
                ).fetch(subscription: RemoteSubscription(url: server.url))
                XCTFail("Expected HTTP \(status)")
            } catch let failure as SubscriptionFetchFailure {
                XCTAssertEqual(failure.cause, .httpStatus(status))
                XCTAssertEqual(failure.attempts, 1)
                XCTAssertEqual(failure.response?.contentType, "text/plain")
            }
            XCTAssertEqual(server.requests.count, 1, "HTTP \(status) must not be retried")
        }

        for status in [408, 429, 500, 502, 503, 504] {
            let server = try MockHTTPServer(responses: [
                .init(status: status, headers: [:], body: Data()),
                .init(status: status, headers: [:], body: Data()),
                .init(status: 200, headers: [:], body: Data("{}".utf8))
            ])
            defer { server.stop() }
            let response = try await SecureSubscriptionFetcher(
                policy: .localMockTesting, timeout: 1, retryCount: 2
            ).fetch(subscription: RemoteSubscription(url: server.url))
            XCTAssertEqual(response.cacheStatus, .updated)
            XCTAssertEqual(server.requests.count, 3, "HTTP \(status) should use bounded retry")
        }
    }

    func testCancellationStopsRetryBackoff() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 503, headers: [:], body: Data()),
            .init(status: 200, headers: [:], body: Data("{}".utf8))
        ])
        defer { server.stop() }
        let task = Task {
            try await SecureSubscriptionFetcher(
                policy: .localMockTesting, timeout: 1, retryCount: 2
            ).fetch(subscription: RemoteSubscription(url: server.url))
        }
        for _ in 0..<100 where server.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation during backoff")
        } catch let error as SubscriptionUpdateError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRedirectCompatibilityAndLoopBound() async throws {
        for status in [301, 302, 303, 307, 308] {
            let server = try MockHTTPServer(responses: [
                .init(status: status, headers: ["Location": "{{BASE_URL}}/redirected"], body: Data()),
                .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data("{}".utf8))
            ])
            defer { server.stop() }
            let response = try await SecureSubscriptionFetcher(
                policy: .localMockTesting, timeout: 1, retryCount: 0
            ).fetch(subscription: RemoteSubscription(
                url: server.url, etag: "redirect-etag", lastModified: "Wed, 01 Jan 2025 00:00:00 GMT"
            ))
            XCTAssertEqual(response.metadata.contentType, "application/octet-stream")
            XCTAssertEqual(server.requests.map(\.method), ["GET", "GET"])
            XCTAssertEqual(server.requests.last?.target, "/redirected")
            XCTAssertTrue(server.requests.allSatisfy {
                $0.headers["user-agent"] == SecureSubscriptionFetcher.userAgent
                    && $0.headers["accept"] == SecureSubscriptionFetcher.accept
                    && $0.headers["if-none-match"] == "redirect-etag"
                    && $0.headers["if-modified-since"] == "Wed, 01 Jan 2025 00:00:00 GMT"
            })
        }

        let loopServer = try MockHTTPServer(responses: (0..<25).map { _ in
            .init(status: 302, headers: ["Location": "{{BASE_URL}}/loop"], body: Data())
        })
        defer { loopServer.stop() }
        do {
            _ = try await SecureSubscriptionFetcher(
                policy: .localMockTesting, timeout: 2, retryCount: 0
            ).fetch(subscription: RemoteSubscription(url: loopServer.url))
            XCTFail("Expected bounded redirect-loop failure")
        } catch let failure as SubscriptionFetchFailure {
            guard case .transport(let transport) = failure.cause else {
                return XCTFail("Unexpected failure: \(failure.cause)")
            }
            XCTAssertEqual(transport.category, .redirectFailed)
        }
        XCTAssertLessThanOrEqual(loopServer.requests.count, 25)
    }

    func testFoundationContentDecodingAndFinalDecodedSizeLimit() async throws {
        let compressedJSON = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAC/6uuBQBDv6ajAgAAAA=="))
        let server = try MockHTTPServer(responses: [
            .init(status: 200, headers: [
                "Content-Encoding": "gzip",
                "Content-Type": "application/octet-stream"
            ], body: compressedJSON)
        ])
        defer { server.stop() }
        let response = try await SecureSubscriptionFetcher(
            policy: .localMockTesting, maximumResponseBytes: 128, timeout: 1, retryCount: 0
        ).fetch(subscription: RemoteSubscription(url: server.url))
        XCTAssertEqual(response.data, Data("{}".utf8))
        XCTAssertEqual(response.metadata.byteCount, 2)

        let compressedExpansion = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAC/3N0HNkAABNbl0kAAQAA"))
        let expansionServer = try MockHTTPServer(responses: [
            .init(status: 200, headers: ["Content-Encoding": "gzip"], body: compressedExpansion)
        ])
        defer { expansionServer.stop() }
        do {
            _ = try await SecureSubscriptionFetcher(
                policy: .localMockTesting, maximumResponseBytes: 128, timeout: 1, retryCount: 0
            ).fetch(subscription: RemoteSubscription(url: expansionServer.url))
            XCTFail("Expected decoded response limit")
        } catch let failure as SubscriptionFetchFailure {
            XCTAssertEqual(failure.cause, .responseTooLarge)
            XCTAssertEqual(failure.response?.byteCount, 256)
        }
    }

    func testChunkedResponseCannotBypassFinalSizeLimit() async throws {
        let server = try MockHTTPServer(responses: [
            .init(status: 200, headers: [:], body: Data(repeating: 65, count: 256), chunked: true)
        ])
        defer { server.stop() }
        do {
            _ = try await SecureSubscriptionFetcher(
                policy: .localMockTesting, maximumResponseBytes: 128, timeout: 1, retryCount: 0
            ).fetch(subscription: RemoteSubscription(url: server.url))
            XCTFail("Expected final chunked response limit")
        } catch let failure as SubscriptionFetchFailure {
            XCTAssertEqual(failure.cause, .responseTooLarge)
            XCTAssertEqual(failure.response?.byteCount, 256)
        }
    }

    func testConnectionFailureAndInvalidHTTPMappingAreSafelyClassified() async throws {
        let closedServer = try MockHTTPServer(responses: [])
        let closedURL = closedServer.url
        closedServer.stop()
        try await Task.sleep(for: .milliseconds(30))
        do {
            _ = try await SecureSubscriptionFetcher(
                policy: .localMockTesting, timeout: 1, retryCount: 0
            ).fetch(subscription: RemoteSubscription(url: closedURL))
            XCTFail("Expected connection failure")
        } catch let failure as SubscriptionFetchFailure {
            guard case .transport(let transport) = failure.cause else {
                return XCTFail("Unexpected failure: \(failure.cause)")
            }
            XCTAssertEqual(transport.category, .cannotConnect)
        }

        let invalidResponse = SubscriptionTransportFailure(.cannotParseResponse)
        XCTAssertEqual(invalidResponse.category, .invalidResponse)
        let diagnostic = SubscriptionFailureDiagnostic(error: SubscriptionUpdateError.transport(invalidResponse))
        XCTAssertEqual(diagnostic.stage, .httpResponse)
        XCTAssertEqual(diagnostic.category, .invalidResponse)
        XCTAssertEqual(diagnostic.transportErrorCode, URLError.Code.cannotParseResponse.rawValue)
    }

    func testHTMLClassificationRunsOnlyAfterPayloadDetectionFails() async throws {
        let store = try makeStore()
        let webResponse = SubscriptionResponse(
            data: Data("<!doctype html><html><body><a href=\"https://example.com\">Sign in</a></body></html>".utf8),
            cacheStatus: .updated, etag: nil, lastModified: nil, contentType: "text/html; charset=utf-8"
        )
        do {
            _ = try await TargetSubscriptionOperations(
                store: store,
                fetcher: ImmediateSubscriptionFetcher(result: .success(webResponse))
            ).prepareNew(name: "Web", url: URL(string: "https://example.com/sub")!)
            XCTFail("Expected web page classification")
        } catch let failure as SubscriptionIntakeFailure {
            XCTAssertEqual(failure.cause, .webPageReturned)
            XCTAssertEqual(failure.response.contentType, "text/html")
            XCTAssertEqual(failure.response.byteCount, webResponse.data.count)
        }

        let validYAML = Data("""
        proxies:
          - {name: Safe, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: test-password}
        """.utf8)
        let validResponse = SubscriptionResponse(
            data: validYAML, cacheStatus: .updated, etag: nil, lastModified: nil, contentType: "text/html"
        )
        let pending = try await TargetSubscriptionOperations(
            store: store,
            fetcher: ImmediateSubscriptionFetcher(result: .success(validResponse))
        ).prepareNew(name: "Valid", url: URL(string: "https://example.com/sub")!)
        XCTAssertEqual(pending.normalization.summary.format, .clashYAML)
    }

    func testDiagnosticsAreTypedCompleteAndSecretSafe() throws {
        let http = SubscriptionFailureDiagnostic(error: SubscriptionUpdateError.httpStatus(403))
        XCTAssertEqual(http.stage, .httpResponse)
        XCTAssertEqual(http.category, .httpError)
        XCTAssertEqual(http.httpStatus, 403)

        let secretURL = "https://provider.example/sub?token=TOP-SECRET"
        let tlsError = URLError(.secureConnectionFailed, userInfo: [
            NSURLErrorFailingURLStringErrorKey: secretURL,
            "Authorization": "Bearer SECRET",
            "Cookie": "SESSION"
        ])
        let tls = SubscriptionFailureDiagnostic(error: tlsError)
        XCTAssertEqual(tls.stage, .tls)
        XCTAssertEqual(tls.category, .tlsFailure)
        XCTAssertEqual(tls.transportErrorDomain, NSURLErrorDomain)
        XCTAssertEqual(tls.transportErrorCode, URLError.Code.secureConnectionFailed.rawValue)

        let cases: [(SubscriptionIntakeError, SubscriptionFailureStage, SubscriptionFailureCategory)] = [
            (.formatUnsupported, .payloadDetection, .formatUnsupported),
            (.protocolUnsupported, .normalization, .protocolUnsupported),
            (.variantUnsupported, .normalization, .variantUnsupported),
            (.validationFailed, .configurationValidation, .validationFailed)
        ]
        for (error, stage, category) in cases {
            let diagnostic = SubscriptionFailureDiagnostic(error: error)
            XCTAssertEqual(diagnostic.stage, stage)
            XCTAssertEqual(diagnostic.category, category)
        }

        let suspiciousMetadata = SubscriptionResponseMetadata(
            contentType: "text/plain; token=TOP-SECRET", byteCount: 0
        )
        XCTAssertEqual(
            SubscriptionResponseMetadata(contentType: "application/TOP-SECRET", byteCount: 0).contentType,
            "application/other"
        )
        let sanitized = SubscriptionFailureDiagnostic(error: SubscriptionFetchFailure(
            cause: .httpStatus(403), attempts: 1, response: suspiciousMetadata
        ))
        let outputs = [
            tls.description, tls.copyableDescription, tls.titleKey, tls.reasonKey,
            sanitized.description, sanitized.copyableDescription, sanitized.titleKey, sanitized.reasonKey
        ]
        for output in outputs {
            for secret in ["TOP-SECRET", "Bearer SECRET", "SECRET", "SESSION", secretURL] {
                XCTAssertFalse(output.contains(secret), "Diagnostic leaked \(secret)")
            }
        }
        XCTAssertEqual(sanitized.attemptCount, 1)
        XCTAssertEqual(sanitized.contentType, "text/plain")
        XCTAssertEqual(sanitized.responseBytes, 0)
    }

    func testInvalidSubscriptionPreviewDoesNotReplaceCurrentVersion() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Subscription", subscriptionURL: URL(string: "https://example.com/sub")!)
        let original = try store.configurationText(for: profile.id)
        XCTAssertThrowsError(try store.previewSubscriptionUpdate(.init(data: Data("{\"inbounds\":[}".utf8), cacheStatus: .updated, etag: nil, lastModified: nil), for: profile.id))
        XCTAssertEqual(try store.configurationText(for: profile.id), original)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).subscription?.cacheStatus, .failed)
    }

    func testStructuredDiffAndRedactionNeverExposeSensitiveValues() throws {
        let old = Data(#"{"outbounds":[{"tag":"old","type":"direct"},{"tag":"removed","type":"direct"}],"route":{"final":"old"},"dns":{"servers":[{"address":"https://secret.example"}]},"inbounds":[{"tag":"in","type":"mixed"}],"custom":{"password":"old-secret"}}"#.utf8)
        let new = Data(#"{"outbounds":[{"tag":"new","type":"direct"},{"tag":"old","type":"block"}],"route":{"final":"new","rules":[{}]},"dns":{"servers":[{"address":"https://new-secret.example"}]},"inbounds":[{"tag":"in","type":"socks"}],"custom":{"password":"new-secret"}}"#.utf8)
        let diff = ProfileConfigurationDiff.make(current: old, candidate: new)
        XCTAssertEqual(diff.outbounds.added, ["new"])
        XCTAssertEqual(diff.outbounds.removed, ["removed"])
        XCTAssertEqual(diff.outbounds.modified, ["old"])
        XCTAssertTrue(diff.routeRules.hasChanges)
        XCTAssertTrue(diff.dns.hasChanges)
        XCTAssertTrue(diff.inbounds.hasChanges)
        XCTAssertTrue(diff.unknown.hasChanges)
        let redacted = SensitiveConfigurationRedactor.redactedJSON(new)
        XCTAssertFalse(redacted.contains("new-secret"))
        XCTAssertFalse(redacted.contains("https://new-secret"))
    }

    func testUserCancelsPreviewAndRunningProfileUpdateRequiresRestart() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Subscription", subscriptionURL: URL(string: "https://example.com/sub")!)
        let before = try store.configurationText(for: profile.id)
        let pending = try XCTUnwrap(try store.previewSubscriptionUpdate(.init(data: Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"version\":2}".utf8), cacheStatus: .updated, etag: "v2", lastModified: nil), for: profile.id))
        XCTAssertEqual(try store.configurationText(for: profile.id), before, "A preview must not save before confirmation")
        try store.recordSubscriptionCancellation(for: profile.id)
        XCTAssertEqual(try store.configurationText(for: profile.id), before)
        try store.applySubscriptionUpdate(pending)
        let updated = try XCTUnwrap(store.listProfiles().first)
        XCTAssertEqual(updated.subscription?.cacheStatus, .updated)
        XCTAssertGreaterThan(updated.validRevision, profile.validRevision)

        let record = EngineRuntimeRecord(pid: 42, executablePath: "/tmp/target", executableFingerprint: "x", endpoint: LocalEngineEndpoint(port: 51_234), profileID: profile.id, profileRevision: profile.validRevision, sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(Data(before.utf8)), configurationFingerprint: "runtime", startedAt: Date(), runtimeConfigurationID: UUID())
        XCTAssertTrue(EngineRuntimeProfileState.requiresRestart(record: record, selected: try store.selectedValidVersion()))
    }

    func testDetectorAcceptsDirectSingBoxJSONWithoutRewriting() throws {
        let data = Data(#"{"outbounds":[{"type":"direct","tag":"direct"}],"custom":true}"#.utf8)
        let result = try SubscriptionNormalizer().normalize(data)
        XCTAssertEqual(result.summary.format, .singBoxJSON)
        XCTAssertTrue(result.summary.isPassThrough)
        XCTAssertEqual(result.data, data)
    }

    func testDetectorFailsClosedForMalformedJSONAndUnsupportedText() throws {
        assertIntakeError(.payloadInvalid, #"{"outbounds":[}"#)
        assertIntakeError(.formatUnsupported, "ordinary provider response")
        assertIntakeError(.emptyPayload, " \r\n ")
        assertIntakeError(.formatUnsupported, Data("hello".utf8).base64EncodedString())
    }

    func testPlainAndWholeBodyBase64URIListsNormalizeStably() throws {
        let list = try supportedURIList()
        let plain = try SubscriptionNormalizer().normalize(Data(("# nodes\r\n" + list + "\r\n").utf8))
        let wrapped = try SubscriptionNormalizer().normalize(Data(Data(list.utf8).base64EncodedString().utf8))
        XCTAssertEqual(plain.summary.format, .uriList)
        XCTAssertEqual(wrapped.summary.format, .base64URIList)
        XCTAssertEqual(plain.summary.nodeCount, 4)
        XCTAssertEqual(plain.summary.protocols, [.shadowsocks, .trojan, .vless, .vmess])
        XCTAssertEqual(plain.data, wrapped.data)
    }

    func testAnyTLSURIAndClashNodesNormalizeWithVerifiedTLS() throws {
        let uri = "anytls://fixture-password@example.com:443?security=tls&sni=proxy.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome#AnyTLS%20URI"
        let uriResult = try SubscriptionNormalizer().normalize(Data(uri.utf8))
        XCTAssertEqual(uriResult.summary.protocols, [.anytls])
        let uriOutbound = try generatedOutbounds(uriResult.data)[1]
        XCTAssertEqual(uriOutbound["type"] as? String, "anytls")
        XCTAssertEqual(uriOutbound["password"] as? String, "fixture-password")
        let uriTLS = try XCTUnwrap(uriOutbound["tls"] as? [String: Any])
        XCTAssertEqual(uriTLS["server_name"] as? String, "proxy.example.com")
        XCTAssertEqual(uriTLS["insecure"] as? Bool, false)
        XCTAssertEqual(uriTLS["alpn"] as? [String], ["h2", "http/1.1"])

        let clash = try SubscriptionNormalizer().normalize(Data("""
        proxies:
          - name: AnyTLS Clash
            type: anytls
            server: example.com
            port: 443
            password: fixture-password
            sni: proxy.example.com
            alpn: [h2, http/1.1]
            client-fingerprint: chrome
            skip-cert-verify: false
        """.utf8))
        XCTAssertEqual(clash.summary.protocols, [.anytls])
        let clashOutbound = try generatedOutbounds(clash.data)[1]
        XCTAssertEqual(clashOutbound["type"] as? String, "anytls")
        XCTAssertEqual((clashOutbound["tls"] as? [String: Any])?["server_name"] as? String, "proxy.example.com")

        if FileManager.default.isExecutableFile(atPath: singBoxExecutable.path) {
            let check = SingBoxConfigurationChecker(executableURL: singBoxExecutable).check(configurationURL: try writeCandidate(uriResult.data))
            if case .failure(let diagnostic) = check {
                XCTFail("Generated AnyTLS configuration failed sing-box validation: \(diagnostic.messageKey)")
            }
        }
        assertIntakeError(.variantUnsupported, "anytls://fixture-password@example.com:443?security=tls&insecure=1#AnyTLS")
    }

    func testMixedAnyTLSAndUnsupportedProtocolsSkipOnlyUnsupportedNodes() throws {
        let ss = try shadowsocksURI(name: "SS")
        let anytls = "anytls://fixture-password@example.com:443?security=tls#AnyTLS"
        let result = try SubscriptionNormalizer().normalize(Data((ss + "\n" + anytls + "\nssr://fixture\nhy2://fixture\ntuic://fixture").utf8))
        XCTAssertEqual(result.summary.nodeCount, 2)
        XCTAssertEqual(result.summary.totalNodeCount, 5)
        XCTAssertEqual(result.summary.skippedNodeCount, 3)
        XCTAssertEqual(result.summary.skippedProtocols, [.hysteria2, .ssr, .tuic])
        XCTAssertEqual(result.summary.protocols, [.anytls, .shadowsocks])
        XCTAssertEqual(result.summary.warnings, [.unsupportedNodesSkipped])
        assertIntakeError(.protocolUnsupported, "ssr://fixture")
    }

    func testURIListPartiallyImportsRecognizedUnsupportedProtocolsButRejectsMalformedSupportedEntries() throws {
        let ss = try shadowsocksURI(name: "One")
        assertIntakeError(.payloadInvalid, ss + "\nnot-a-node")
        let partial = try SubscriptionNormalizer().normalize(Data((ss + "\nhysteria2://fixture").utf8))
        XCTAssertEqual(partial.summary.nodeCount, 1)
        XCTAssertEqual(partial.summary.totalNodeCount, 2)
        XCTAssertEqual(partial.summary.skippedNodeCount, 1)
        XCTAssertEqual(partial.summary.skippedProtocols, [.hysteria2])
        XCTAssertEqual(partial.summary.warnings, [.unsupportedNodesSkipped])
        assertIntakeError(.protocolUnsupported, "hysteria2://fixture")
        assertIntakeError(.payloadInvalid, "vless://not-a-uuid@example.com:443?security=tls")
        assertIntakeError(.payloadInvalid, "trojan://test-password@example.com:70000")
    }

    func testBase64URIListReportsRecognizedUnsupportedProtocolSkips() throws {
        let ss = try shadowsocksURI(name: "One")
        let encoded = Data((ss + "\nhysteria2://fixture").utf8).base64EncodedString()
        let result = try SubscriptionNormalizer().normalize(Data(encoded.utf8))
        XCTAssertEqual(result.summary.format, .base64URIList)
        XCTAssertEqual(result.summary.nodeCount, 1)
        XCTAssertEqual(result.summary.totalNodeCount, 2)
        XCTAssertEqual(result.summary.skippedNodeCount, 1)
        XCTAssertEqual(result.summary.skippedProtocols, [.hysteria2])
        XCTAssertEqual(result.summary.warnings, [.unsupportedNodesSkipped])
    }

    func testShadowsocksSIP002AndDuplicateNamesHaveStableTags() throws {
        let first = try shadowsocksURI(name: "Duplicate")
        let result = try SubscriptionNormalizer().normalize(Data((first + "\n" + first).utf8))
        let outbounds = try generatedOutbounds(result.data)
        XCTAssertEqual(outbounds[1]["tag"] as? String, "Duplicate")
        XCTAssertEqual(outbounds[2]["tag"] as? String, "Duplicate 2")
        assertIntakeError(.variantUnsupported, "ss://" + Data("rc4-md5:test-password".utf8).base64EncodedString() + "@example.com:8388#Legacy")
        assertIntakeError(.variantUnsupported, first.replacingOccurrences(of: "#Duplicate", with: "?plugin=obfs-local#Duplicate"))
    }

    func testVMessV2TCPAndWebSocketTLSSubset() throws {
        let tcp = vmessURI(name: "VMess TCP", network: "tcp", tls: "none")
        let ws = vmessURI(name: "VMess WS", network: "ws", tls: "tls")
        let result = try SubscriptionNormalizer().normalize(Data((tcp + "\n" + ws).utf8))
        let outbounds = try generatedOutbounds(result.data)
        XCTAssertNil(outbounds[1]["transport"])
        XCTAssertEqual((outbounds[2]["transport"] as? [String: Any])?["type"] as? String, "ws")
        XCTAssertEqual((outbounds[2]["tls"] as? [String: Any])?["enabled"] as? Bool, true)
        assertIntakeError(.variantUnsupported, vmessURI(name: "gRPC", network: "grpc", tls: "tls"))
        assertIntakeError(.payloadInvalid, vmessURI(name: "Bad UUID", network: "tcp", tls: "none", uuid: "bad"))
    }

    func testVLESSTCPAndWebSocketTLSSubset() throws {
        let tcp = "vless://11111111-1111-4111-8111-111111111111@example.com:443?encryption=none&security=tls&type=tcp&sni=example.com#VLESS%20TCP"
        let ws = "vless://11111111-1111-4111-8111-111111111111@example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fws&sni=example.com#VLESS%20WS"
        let result = try SubscriptionNormalizer().normalize(Data((tcp + "\n" + ws).utf8))
        XCTAssertEqual(result.summary.protocols, [.vless])
        let reality = """
        proxies:
          - name: VLESS Reality
            type: vless
            server: example.com
            port: 443
            uuid: 11111111-1111-4111-8111-111111111111
            tls: true
            flow: xtls-rprx-vision
            client-fingerprint: firefox
            reality-opts:
              public-key: dGVzdC1wdWJsaWMta2V5
              short-id: a1b2c3d4
        """
        let realityResult = try SubscriptionNormalizer().normalize(Data(reality.utf8))
        let realityOutbound = try generatedOutbounds(realityResult.data)[1]
        XCTAssertEqual(realityOutbound["flow"] as? String, "xtls-rprx-vision")
        let realityTLS = try XCTUnwrap(realityOutbound["tls"] as? [String: Any])
        XCTAssertEqual((realityTLS["utls"] as? [String: Any])?["fingerprint"] as? String, "firefox")
        XCTAssertEqual((realityTLS["reality"] as? [String: Any])?["enabled"] as? Bool, true)
        let realityCheck = try makeStore().checkSubscriptionCandidate(realityResult.data)
        if case .failure(let diagnostic) = realityCheck {
            if diagnostic.messageKey == "profile.validation.engine-unavailable" {
                throw XCTSkip("sing-box is not installed for generated configuration validation.")
            }
            XCTFail("Generated Reality configuration failed sing-box validation: \(diagnostic.messageKey), line \(diagnostic.line ?? 0)")
        }
        assertIntakeError(.variantUnsupported, tcp.replacingOccurrences(of: "#", with: "&flow=xtls-rprx-vision#"))
        assertIntakeError(.variantUnsupported, tcp.replacingOccurrences(of: "security=tls", with: "security=reality"))
    }

    func testTrojanTCPAndWebSocketTLSSubset() throws {
        let tcp = "trojan://test-password@example.com:443?security=tls&type=tcp&sni=example.com#Trojan%20TCP"
        let ws = "trojan://test-password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fws#Trojan%20WS"
        let result = try SubscriptionNormalizer().normalize(Data((tcp + "\n" + ws).utf8))
        XCTAssertEqual(result.summary.protocols, [.trojan])
        assertIntakeError(.payloadInvalid, "trojan://@example.com:443?security=tls")
        assertIntakeError(.variantUnsupported, tcp.replacingOccurrences(of: "type=tcp", with: "type=grpc"))
        assertIntakeError(.variantUnsupported, tcp.replacingOccurrences(of: "security=tls", with: "security=none"))
    }

    func testClashNodeCatalogConvertsSupportedNodesAndReportsIgnoredSemanticsSafely() throws {
        let yaml = """
        proxies:
          - name: SS Node
            type: ss
            server: ss.example.com
            port: 8388
            cipher: aes-128-gcm
            password: test-password
          - name: VLESS Node
            type: vless
            server: vless.example.com
            port: 443
            uuid: 11111111-1111-4111-8111-111111111111
            network: ws
            tls: true
            servername: example.com
            ws-opts:
              path: /ws
              headers:
                Host: cdn.example.com
        proxy-groups:
          - name: Provider Choice
            type: select
            proxies: [SS Node, VLESS Node]
        rules:
          - MATCH,Provider Choice
        dns:
          enable: true
        """
        let result = try SubscriptionNormalizer().normalize(Data(yaml.utf8))
        XCTAssertEqual(result.summary.format, .clashYAML)
        XCTAssertEqual(result.summary.nodeCount, 2)
        XCTAssertEqual(result.summary.warnings, [.providerSemanticsNotImported])
        let description = String(describing: result.summary)
        for secret in ["ss.example.com", "test-password", "11111111-1111-4111-8111-111111111111"] {
            XCTAssertFalse(description.contains(secret))
        }
    }

    func testClashPartiallyImportsRecognizedUnsupportedProtocolsButFailsClosedForMalformedSupportedProxy() throws {
        assertIntakeError(.payloadInvalid, "proxies:\n  - name: [unterminated")
        assertIntakeError(.payloadInvalid, "proxies: []")
        assertIntakeError(.protocolUnsupported, "proxies:\n  - {name: Extra, type: hysteria2, server: example.com, port: 443}")
        let partial = try SubscriptionNormalizer().normalize(Data("""
        proxies:
          - {name: VLESS, type: vless, server: example.com, port: 443, uuid: 11111111-1111-4111-8111-111111111111, tls: true}
          - {name: Unsupported, type: hysteria2, server: example.com, port: 443}
        """.utf8))
        XCTAssertEqual(partial.summary.nodeCount, 1)
        XCTAssertEqual(partial.summary.totalNodeCount, 2)
        XCTAssertEqual(partial.summary.skippedNodeCount, 1)
        XCTAssertEqual(partial.summary.skippedProtocols, [.hysteria2])
        XCTAssertEqual(partial.summary.warnings, [.unsupportedNodesSkipped])
        let tlsSkipped = try SubscriptionNormalizer().normalize(Data("""
        proxies:
          - {name: Trojan, type: trojan, server: example.com, port: 443, password: test-password, tls: true}
          - {name: VLESS insecure, type: vless, server: example.com, port: 443, uuid: 11111111-1111-4111-8111-111111111111, tls: true, skip-cert-verify: true}
          - {name: Unsupported, type: hysteria2, server: example.com, port: 443}
        """.utf8))
        XCTAssertEqual(tlsSkipped.summary.nodeCount, 1)
        XCTAssertEqual(tlsSkipped.summary.totalNodeCount, 3)
        XCTAssertEqual(tlsSkipped.summary.skippedNodeCount, 2)
        XCTAssertEqual(tlsSkipped.summary.skippedTLSVerificationNodeCount, 1)
        XCTAssertEqual(tlsSkipped.summary.skippedProtocols, [.hysteria2, .vless])
        XCTAssertEqual(tlsSkipped.summary.warnings, [.unsupportedNodesSkipped, .tlsVerificationRequired])
        assertIntakeError(.variantUnsupported, "proxies:\n  - {name: SS, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: test-password, plugin: obfs}")
    }

    func testComplexityLimitsAreDeterministic() throws {
        let oversized = Data(repeating: 65, count: SubscriptionNormalizer.maximumPayloadBytes + 1)
        XCTAssertThrowsError(try SubscriptionNormalizer().normalize(oversized)) { error in
            XCTAssertEqual(error as? SubscriptionIntakeError, .complexityLimitExceeded)
        }
        let longLine = "ss://" + String(repeating: "A", count: SubscriptionNormalizer.maximumLineBytes + 1)
        assertIntakeError(.complexityLimitExceeded, longLine)
    }

    func testGeneratedConfigurationPassesInstalledSingBoxCheck() throws {
        let result = try SubscriptionNormalizer().normalize(Data((try supportedURIList()).utf8))
        let store = try makeStore()
        let check = try store.checkSubscriptionCandidate(result.data)
        if case .failure(let diagnostic) = check {
            if diagnostic.messageKey == "profile.validation.engine-unavailable" {
                throw XCTSkip("sing-box is not installed for generated configuration validation.")
            }
            XCTFail("Generated configuration failed installed sing-box validation: \(diagnostic.messageKey)")
        }
    }

    func testNewSubscriptionIsTransactionalUntilConfirmationAndEncryptedAtRest() async throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let secretURL = URL(string: "https://example.com/subscription/test-token")!
        let fetcher = ImmediateSubscriptionFetcher(result: .success(.init(
            data: Data((try supportedURIList()).utf8), cacheStatus: .updated, etag: "fixture-etag", lastModified: "fixture-date"
        )))
        let operations = TargetSubscriptionOperations(store: store, fetcher: fetcher)
        let pending = try await operations.prepareNew(name: "Provider", url: secretURL)
        XCTAssertFalse(String(describing: pending).contains("test-token"))
        XCTAssertTrue(try store.listProfiles().isEmpty)
        XCTAssertNil(try store.selectedProfileID())

        let profile = try operations.commit(pending)
        XCTAssertEqual(try store.listProfiles().count, 1)
        XCTAssertEqual(profile.validRevision, 1)
        XCTAssertEqual(profile.validation.status, .valid)
        XCTAssertEqual(profile.subscription?.etag, "fixture-etag")
        XCTAssertEqual(try store.selectedProfileID(), profile.id)
        XCTAssertFalse(try recursiveData(in: root).contains(Data("test-token".utf8)))
    }

    func testFailedNormalizationAndValidationLeaveNewProfileStateUnchanged() async throws {
        for (payload, checker) in [
            (Data("unsupported".utf8), TestChecker(result: .success(()))),
            (Data((try supportedURIList()).utf8), TestChecker(result: .failure(.init(messageKey: "profile.validation.check-failed", line: nil, column: nil))))
        ] {
            let store = try makeStore(checker: checker)
            let operations = TargetSubscriptionOperations(
                store: store,
                fetcher: ImmediateSubscriptionFetcher(result: .success(.init(data: payload, cacheStatus: .updated, etag: nil, lastModified: nil)))
            )
            do {
                _ = try await operations.prepareNew(name: "Provider", url: URL(string: "https://example.com/sub")!)
                XCTFail("Expected intake failure")
            } catch {}
            XCTAssertTrue(try store.listProfiles().isEmpty)
            XCTAssertNil(try store.selectedProfileID())
        }
    }

    func testExistingUpdateUsesNormalizerAndRejectsStaleRevisionAtCommit() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Provider", subscriptionURL: URL(string: "https://example.com/sub")!)
        let operations = TargetSubscriptionOperations(
            store: store,
            fetcher: ImmediateSubscriptionFetcher(result: .success(.init(
                data: Data((try supportedURIList()).utf8), cacheStatus: .updated, etag: "v2", lastModified: nil
            )))
        )
        let prepared = try await operations.prepareUpdate(profileID: profile.id)
        let pending = try XCTUnwrap(prepared.candidate)
        XCTAssertEqual(pending.normalization.summary.format, .uriList)
        XCTAssertNotNil(pending.diff)
        try store.save(json: #"{"inbounds":[],"outbounds":[],"route":{},"concurrent":true}"#, for: profile.id)
        let concurrent = try store.configurationText(for: profile.id)
        XCTAssertThrowsError(try operations.commit(pending)) { error in
            XCTAssertEqual(error as? ProfileStoreError, .noValidVersion)
        }
        XCTAssertEqual(try store.configurationText(for: profile.id), concurrent)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).validRevision, profile.validRevision + 1)
    }

    func testNotModifiedPreservesExistingRevisionAndUpdatesCacheMetadata() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Provider", subscriptionURL: URL(string: "https://example.com/sub")!)
        let operations = TargetSubscriptionOperations(
            store: store,
            fetcher: ImmediateSubscriptionFetcher(result: .success(.init(data: Data(), cacheStatus: .notModified, etag: "same", lastModified: nil)))
        )
        let prepared = try await operations.prepareUpdate(profileID: profile.id)
        XCTAssertNil(prepared.candidate)
        XCTAssertNotEqual(try XCTUnwrap(store.listProfiles().first).subscription?.cacheStatus, .notModified)
        _ = try operations.commitNotModified(prepared)
        let updated = try XCTUnwrap(store.listProfiles().first)
        XCTAssertEqual(updated.validRevision, profile.validRevision)
        XCTAssertEqual(updated.subscription?.cacheStatus, .notModified)
        XCTAssertEqual(updated.subscription?.etag, "same")
    }

    func testNotModifiedStaleResultDoesNotWriteCacheMetadata() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Provider", subscriptionURL: URL(string: "https://example.com/sub")!)
        let operations = TargetSubscriptionOperations(
            store: store,
            fetcher: ImmediateSubscriptionFetcher(result: .success(.init(data: Data(), cacheStatus: .notModified, etag: "stale", lastModified: nil)))
        )
        let prepared = try await operations.prepareUpdate(profileID: profile.id)
        try store.save(json: #"{"inbounds":[],"outbounds":[],"route":{},"concurrent":true}"#, for: profile.id)
        XCTAssertThrowsError(try operations.commitNotModified(prepared)) { error in
            XCTAssertEqual(error as? ProfileStoreError, .noValidVersion)
        }
        let current = try XCTUnwrap(store.listProfiles().first)
        XCTAssertNotEqual(current.subscription?.cacheStatus, .notModified)
        XCTAssertNotEqual(current.subscription?.etag, "stale")
    }

    private func assertIntakeError(_ expected: SubscriptionIntakeError, _ text: String) {
        XCTAssertThrowsError(try SubscriptionNormalizer().normalize(Data(text.utf8))) { error in
            XCTAssertEqual(error as? SubscriptionIntakeError, expected)
            XCTAssertFalse(String(describing: error).contains(text))
        }
    }

    private func supportedURIList() throws -> String {
        [
            try shadowsocksURI(name: "SS Node"),
            vmessURI(name: "VMess Node", network: "ws", tls: "tls"),
            "vless://11111111-1111-4111-8111-111111111111@example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fws&sni=example.com#VLESS%20Node",
            "trojan://test-password@example.com:443?security=tls&type=tcp&sni=example.com#Trojan%20Node"
        ].joined(separator: "\n")
    }

    private func shadowsocksURI(name: String) throws -> String {
        let credential = Data("aes-128-gcm:test-password".utf8).base64EncodedString()
        return "ss://\(credential)@example.com:8388#\(name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!)"
    }

    private func vmessURI(
        name: String, network: String, tls: String,
        uuid: String = "22222222-2222-4222-8222-222222222222"
    ) -> String {
        let object: [String: Any] = [
            "v": "2", "ps": name, "add": "example.com", "port": "443", "id": uuid,
            "aid": "0", "scy": "auto", "net": network, "tls": tls,
            "host": "cdn.example.com", "path": "/ws", "sni": "example.com"
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "vmess://" + data.base64EncodedString()
    }

    private func generatedOutbounds(_ data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["outbounds"] as? [[String: Any]])
    }

    private func writeCandidate(_ data: Data) throws -> URL {
        let root = try temporaryDirectory()
        let url = root.appending(path: "candidate.json")
        try data.write(to: url)
        return url
    }

    private struct ImmediateSubscriptionFetcher: ProfileSubscriptionFetching {
        let result: Result<SubscriptionResponse, Error>
        func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse { try result.get() }
    }

    private struct FixedSubscriptionHostResolver: SubscriptionHostResolving {
        let addresses: [String: [String]]

        func addresses(for host: String) -> [String]? {
            addresses[host]
        }
    }

private final class MockHTTPServer: @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let target: String
        let headers: [String: String]
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: TimeInterval
        let chunked: Bool
        let declaredContentLength: Int?
        let rawResponse: Data?

        init(
            status: Int,
            headers: [String: String],
            body: Data,
            delay: TimeInterval = 0,
            chunked: Bool = false,
            declaredContentLength: Int? = nil,
            rawResponse: Data? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delay = delay
            self.chunked = chunked
            self.declaredContentLength = declaredContentLength
            self.rawResponse = rawResponse
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TargetTests.MockHTTPServer")
    private let lock = NSLock()
    private var responses: [Response]
    private var capturedRequests: [Request] = []
    private var port: UInt16 = 0

    init(responses: [Response]) throws {
        self.responses = responses
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let value = self?.listener.port?.rawValue {
                self?.port = value
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, port > 0 else {
            listener.cancel()
            throw NSError(domain: "MockHTTPServer", code: 1)
        }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/subscription")! }

    var requests: [Request] {
        lock.withLock { capturedRequests }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = self.parseRequest(data ?? Data())
            let response = self.lock.withLock {
                self.capturedRequests.append(request)
                return self.responses.isEmpty
                    ? Response(status: 500, headers: [:], body: Data())
                    : self.responses.removeFirst()
            }
            self.queue.asyncAfter(deadline: .now() + response.delay) {
                if let rawResponse = response.rawResponse {
                    connection.send(content: rawResponse, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                var header = "HTTP/1.1 \(response.status) Test\r\nConnection: close\r\n"
                header += response.chunked
                    ? "Transfer-Encoding: chunked\r\n"
                    : "Content-Length: \(response.declaredContentLength ?? response.body.count)\r\n"
                for (name, value) in response.headers {
                    let expanded = value.replacingOccurrences(
                        of: "{{BASE_URL}}",
                        with: "http://127.0.0.1:\(self.port)"
                    )
                    header += "\(name): \(expanded)\r\n"
                }
                header += "\r\n"
                let payload: Data
                if response.chunked {
                    payload = Data(header.utf8)
                        + Data(String(response.body.count, radix: 16).utf8)
                        + Data("\r\n".utf8) + response.body + Data("\r\n0\r\n\r\n".utf8)
                } else {
                    payload = Data(header.utf8) + response.body
                }
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func parseRequest(_ data: Data) -> Request {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return Request(
            method: requestLine.first.map(String.init) ?? "",
            target: requestLine.count > 1 ? String(requestLine[1]) : "",
            headers: headers
        )
    }
}
}
