import Foundation
import XCTest
@testable import Target
import TargetCore

final class RuntimeControlTests: XCTestCase, ProfileTestCaseSupport {
    func testPreparationOwnsLoopbackControllerAndPreservesExperimentalFields() throws {
        let version = ProfileConfigurationVersion(
            profile: profile(), revision: 1,
            data: Data(#"{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":0}],"experimental":{"cache_file":{"enabled":true},"clash_api":{"external_controller":"0.0.0.0:9090","secret":"user-secret","external_ui":"https://example.invalid","access_control_allow_origin":"*"}},"outbounds":[{"type":"direct","tag":"direct"}]}"#.utf8)
        )
        let prepared = try ProfileRuntimeConfigurationPreparer(
            portSelector: TestPortSelector([51_234]),
            controllerPortSelector: TestPortSelector([51_235]),
            secretGenerator: TestSecretGenerator(value: "unit-test-secret-not-production")
        ).prepare(version)
        XCTAssertEqual(prepared.runtimeControl.host, "127.0.0.1")
        XCTAssertEqual(prepared.runtimeControl.port, 51_235)
        XCTAssertEqual(prepared.runtimeControl.secret, "unit-test-secret-not-production")
        XCTAssertNotEqual(prepared.runtimeControl.port, prepared.primaryPort)
        XCTAssertNotEqual(prepared.configurationFingerprint, TargetConfigurationFingerprint.sha256(version.data))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        XCTAssertNotNil(experimental["cache_file"])
        let clash = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clash["external_controller"] as? String, "127.0.0.1:51235")
        XCTAssertEqual(clash["secret"] as? String, "unit-test-secret-not-production")
        XCTAssertNil(clash["external_ui"])
        XCTAssertNil(clash["access_control_allow_origin"])
        XCTAssertEqual(String(decoding: version.data, as: UTF8.self).contains("0.0.0.0:9090"), true)
    }

    func testPreparationAddsTargetOwnedMixedInboundToProviderOutboundOnlyJSON() throws {
        let source = Data(#"{"outbounds":[{"type":"direct","tag":"target-mixed"}]}"#.utf8)
        let version = ProfileConfigurationVersion(profile: profile(), revision: 1, data: source)
        let prepared = try ProfileRuntimeConfigurationPreparer(
            portSelector: TestPortSelector([51_234]),
            controllerPortSelector: TestPortSelector([51_235]),
            secretGenerator: TestSecretGenerator(value: "unit-test-secret-not-production")
        ).prepare(version)
        XCTAssertEqual(prepared.primaryPort, 51_234)
        XCTAssertEqual(source, version.data)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["type"] as? String, "mixed")
        XCTAssertEqual(inbound["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbound["listen_port"] as? Int, 51_234)
        XCTAssertEqual(inbound["tag"] as? String, "target-mixed-2")
    }

    func testDescriptorParserRejectsNonLoopbackController() {
        XCTAssertNil(RuntimeControlDescriptorParser.parse(Data(#"{"experimental":{"clash_api":{"external_controller":"0.0.0.0:51234","secret":"fixture"}}}"#.utf8)))
        XCTAssertNil(RuntimeControlDescriptorParser.parse(Data(#"{"experimental":{"clash_api":{"external_controller":"127.0.0.1:80","secret":"fixture"}}}"#.utf8)))
    }

    func testControllerRequestUsesLoopbackBearerAndNoSystemProxy() throws {
        let descriptor = RuntimeControlDescriptor(host: "127.0.0.1", port: 51_234, secret: "unit-test-secret-not-production")
        let request = try SingBoxRuntimeControlClient.makeRequest(path: "/proxies/group", method: "PUT", descriptor: descriptor, body: Data("{}".utf8))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:51234/proxies/group")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
        XCTAssertThrowsError(try SingBoxRuntimeControlClient.makeRequest(path: "/connections", method: "GET", descriptor: .init(host: "localhost", port: 51_234, secret: "fixture"), body: nil))
        XCTAssertEqual(SingBoxRuntimeControlClient.makeSession().configuration.connectionProxyDictionary?.isEmpty, true)
    }

    func testSingleConnectionCloseRequestHasFixedUUIDContract() throws {
        let id = "A92B264D-42E6-4E1C-AF55-A7D960040A1B"
        let request = try SingBoxRuntimeControlClient.makeConnectionCloseRequest(id: id, descriptor: runtimeDescriptor)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:51234/connections/\(id.lowercased())")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        for unsafe in ["", "/", "../connections", id + "/extra", "00000000-0000-0000-0000-000000000000"] {
            XCTAssertThrowsError(try SingBoxRuntimeControlClient.makeConnectionCloseRequest(id: unsafe, descriptor: runtimeDescriptor))
        }
        XCTAssertThrowsError(try SingBoxRuntimeControlClient.makeConnectionCloseRequest(id: id, descriptor: .init(host: "localhost", port: 51_234, secret: "fixture")))
    }

    func testCloseAuthorizationRunsAtDispatchAndRefusalNeverSendsRequest() async throws {
        let id = UUID().uuidString
        let client = makeRuntimeControlClient(status: 204, body: Data())
        do {
            try await client.closeConnection(id: id, using: runtimeDescriptor) { _ in
                throw PolicySelectionApplyRefusal.selectionChanged
            }
            XCTFail("Expected final authorization refusal")
        } catch PolicySelectionApplyRefusal.selectionChanged {}
        XCTAssertNil(RuntimeControlURLProtocol.lastRequest)
        try await client.closeConnection(id: id, using: runtimeDescriptor) { dispatch in dispatch() }
        XCTAssertEqual(RuntimeControlURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(RuntimeControlURLProtocol.lastRequest?.url?.path, "/connections/\(id.lowercased())")
    }

    func testCloseMissingDispatchFailsClosedAndCancellationNeverSends() async throws {
        let client = makeRuntimeControlClient(status: 204, body: Data())
        do {
            try await client.closeConnection(id: UUID().uuidString, using: runtimeDescriptor) { _ in }
            XCTFail("Expected missing dispatch refusal")
        } catch let error as RuntimeControlError { XCTAssertEqual(error, .unavailable) }
        XCTAssertNil(RuntimeControlURLProtocol.lastRequest)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.closeConnection(id: UUID().uuidString, using: runtimeDescriptor) { dispatch in dispatch() }
        }
        do { try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertNil(RuntimeControlURLProtocol.lastRequest)
    }

    func testCloseRejectsAuthenticationRedirectFailureAndNonContractSuccess() async throws {
        for (status, expected) in [(401, RuntimeControlError.selectionRejected), (403, .selectionRejected), (302, .redirectRefused), (404, .unavailable), (200, .unavailable)] {
            let client = makeRuntimeControlClient(status: status, body: Data())
            do {
                try await client.closeConnection(id: UUID().uuidString, using: runtimeDescriptor) { dispatch in dispatch() }
                XCTFail("Expected close response refusal")
            } catch let error as RuntimeControlError { XCTAssertEqual(error, expected) }
        }
    }

    func testCloseResponseBoundCancelsWithoutRetainingControllerBody() async throws {
        let client = makeRuntimeControlClient(status: 200, body: Data(repeating: 65, count: SingBoxRuntimeControlClient.maximumCloseResponseBytes + 1))
        do {
            try await client.closeConnection(id: UUID().uuidString, using: runtimeDescriptor) { dispatch in dispatch() }
            XCTFail("Expected bounded response refusal")
        } catch let error as RuntimeControlError { XCTAssertEqual(error, .malformedResponse) }
    }

    func testLatencyTimeoutPolicyIsBoundedAndOrdered() throws {
        let policy = SingBoxRuntimeControlClient.ProbePolicy.timeout
        XCTAssertTrue(policy.isValid)
        XCTAssertEqual(policy.probeMilliseconds, 5_000)
        XCTAssertLessThan(policy.probeSeconds, policy.controllerRequestSeconds)
        XCTAssertLessThanOrEqual(policy.controllerRequestSeconds, policy.controllerResourceSeconds)

        let configuration = SingBoxRuntimeControlClient.makeSession().configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, policy.controllerRequestSeconds)
        XCTAssertEqual(configuration.timeoutIntervalForResource, policy.controllerResourceSeconds)

        let request = try SingBoxRuntimeControlClient.makeRequest(
            path: "/proxies/node/delay",
            method: "GET",
            descriptor: runtimeDescriptor,
            body: nil
        )
        XCTAssertEqual(request.timeoutInterval, policy.controllerRequestSeconds)
    }

    func testDelayRequestUsesFixedLoopbackPolicyAndPercentEncodesMember() throws {
        let descriptor = RuntimeControlDescriptor(
            host: "127.0.0.1",
            port: 51_234,
            secret: "unit-test-secret-not-production"
        )
        let request = try SingBoxRuntimeControlClient.makeDelayRequest(
            outbound: "Hong Kong/01?fast",
            descriptor: descriptor
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.port, 51_234)
        XCTAssertEqual(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath,
            "/proxies/Hong%20Kong%2F01%3Ffast/delay"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems?.first(where: { $0.name == "url" })?.value, "https://www.gstatic.com/generate_204")
        XCTAssertEqual(query.queryItems?.first(where: { $0.name == "timeout" })?.value, "5000")
    }

    func testDelayProbeParsesBoundedLatency() async throws {
        let client = makeRuntimeControlClient(status: 200, body: Data(#"{"delay":42}"#.utf8))
        let latency = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
        XCTAssertEqual(latency, 42)
        let request = try XCTUnwrap(RuntimeControlURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-secret-not-production")
    }

    func testDelayProbeRejectsMalformedAndNegativeLatencyWithoutLeakingSecret() async {
        for body in [Data(#"{"delay":"fast"}"#.utf8), Data(#"{"delay":-1}"#.utf8)] {
            let client = makeRuntimeControlClient(status: 200, body: body)
            do {
                _ = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
                XCTFail("Expected malformed delay response")
            } catch {
                XCTAssertEqual(error as? RuntimeControlError, .malformedResponse)
                XCTAssertFalse(String(describing: error).contains(runtimeDescriptor.secret))
            }
        }
    }

    func testDelayProbeMapsNonSuccessToBoundedProbeFailure() async {
        let client = makeRuntimeControlClient(status: 503, body: Data(#"{"message":"sensitive-upstream-detail"}"#.utf8))
        do {
            _ = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
            XCTFail("Expected probe failure")
        } catch {
            XCTAssertEqual(error as? RuntimeControlError, .probeFailed)
            XCTAssertFalse(String(describing: error).contains("sensitive-upstream-detail"))
            XCTAssertFalse(String(describing: error).contains(runtimeDescriptor.secret))
        }
    }

    func testDelayProbeMapsAuthenticationRejectionToControllerFailure() async {
        let client = makeRuntimeControlClient(status: 401, body: Data())
        do {
            _ = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
            XCTFail("Expected authentication rejection")
        } catch {
            XCTAssertEqual(error as? RuntimeControlError, .selectionRejected)
            XCTAssertFalse(String(describing: error).contains(runtimeDescriptor.secret))
        }
    }

    func testDelayProbeMapsTransportFailureToReconciledMemberFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFailingRuntimeControlURLProtocol.self]
        let client = SingBoxRuntimeControlClient(session: URLSession(configuration: configuration))

        do {
            _ = try await client.probeLatency(outbound: "node", using: runtimeDescriptor)
            XCTFail("Expected delay transport failure")
        } catch {
            XCTAssertEqual(error as? RuntimeControlError, .probeTransportFailure)
            XCTAssertFalse(String(describing: error).contains(runtimeDescriptor.secret))
        }
    }

    func testControllerRedirectDelegateRefusesRedirect() throws {
        let session = URLSession(configuration: .ephemeral)
        let original = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:51234/proxies/node/delay")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://example.invalid"]
        ))
        let task = session.dataTask(with: original.url!)
        let refused = expectation(description: "redirect refused")
        RedirectRefusingDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: original,
            newRequest: URLRequest(url: URL(string: "https://example.invalid")!)
        ) { redirected in
            XCTAssertNil(redirected)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 1)
    }

    func testRateReducerUsesElapsedTimeAndResetsCountersSafely() {
        var reducer = RuntimeObservationReducer()
        let first = reducer.reduce(totals: .init(uploadTotalBytes: 100, downloadTotalBytes: 300, activeConnectionCount: 2), at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(first.uploadBytesPerSecond, 0)
        let second = reducer.reduce(totals: .init(uploadTotalBytes: 160, downloadTotalBytes: 380, activeConnectionCount: 3), at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(second.uploadBytesPerSecond, 30)
        XCTAssertEqual(second.downloadBytesPerSecond, 40)
        let reset = reducer.reduce(totals: .init(uploadTotalBytes: 2, downloadTotalBytes: 3, activeConnectionCount: 0), at: Date(timeIntervalSince1970: 13))
        XCTAssertEqual(reset.uploadBytesPerSecond, 0)
        XCTAssertEqual(reset.downloadBytesPerSecond, 0)
    }

    func testConnectionsParserKeepsOnlyBoundedProductFields() throws {
        let snapshot = try RuntimeConnectionsParser.parse(Data(#"""
        {"uploadTotal":42,"downloadTotal":84,"memory":123,"connections":[{
          "id":"connection-1","metadata":{"network":"tcp","type":"mixed/local","sourceIP":"127.0.0.1","processPath":"/private/example","destinationIP":"198.51.100.10","destinationPort":"443","host":"example.test"},
          "upload":4,"download":8,"start":"2026-01-02T03:04:05.123Z","chains":["proxy","node"],"rule":"some-sensitive-or-complex-upstream-rule","unexpected":{"secret":"do-not-retain"}
        }]}
        """#.utf8))
        XCTAssertEqual(snapshot.totals, .init(uploadTotalBytes: 42, downloadTotalBytes: 84, activeConnectionCount: 1))
        let connection = try XCTUnwrap(snapshot.connections.first)
        XCTAssertEqual(connection.id, "connection-1")
        XCTAssertEqual(connection.destinationHost, "example.test")
        XCTAssertEqual(connection.destinationIP, "198.51.100.10")
        XCTAssertEqual(connection.destinationPort, 443)
        XCTAssertEqual(connection.network, "tcp")
        XCTAssertEqual(connection.inbound, "mixed/local")
        XCTAssertEqual(connection.outboundChain, ["proxy", "node"])
        XCTAssertEqual(connection.uploadBytes, 4)
        XCTAssertEqual(connection.downloadBytes, 8)
        XCTAssertNotNil(connection.startedAt)
        let fields = Set(Mirror(reflecting: connection).children.compactMap(\.label))
        XCTAssertEqual(fields, [
            "id", "destinationHost", "destinationIP", "destinationPort", "network", "inbound",
            "outboundChain", "uploadBytes", "downloadBytes", "startedAt"
        ])
    }

    func testConnectionsParserRejectsInvalidTopLevelAndToleratesOptionalFields() throws {
        XCTAssertThrowsError(try RuntimeConnectionsParser.parse(Data(#"{"uploadTotal":"not-a-number","downloadTotal":1,"connections":[]}"#.utf8)))
        XCTAssertThrowsError(try RuntimeConnectionsParser.parse(Data(#"{"uploadTotal":true,"downloadTotal":1,"connections":[]}"#.utf8)))
        XCTAssertThrowsError(try RuntimeConnectionsParser.parse(Data(#"[]"#.utf8)))
        let snapshot = try RuntimeConnectionsParser.parse(Data(#"{"uploadTotal":0,"downloadTotal":0,"connections":[{"id":"stable"},{"metadata":{}}]}"#.utf8))
        XCTAssertEqual(snapshot.totals.activeConnectionCount, 2)
        XCTAssertEqual(snapshot.connections.map(\.id), ["stable"])
        XCTAssertNil(snapshot.connections.first?.uploadBytes)
        XCTAssertNil(snapshot.connections.first?.destinationHost)
    }

    func testConnectionsParserBoundsDetailsAndRetainsTotals() throws {
        let rawConnections = (0..<1_001).map { ["id": "connection-\($0)"] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: [
            "uploadTotal": 0,
            "downloadTotal": 0,
            "connections": rawConnections
        ])
        let snapshot = try RuntimeConnectionsParser.parse(data)
        XCTAssertEqual(snapshot.totals.activeConnectionCount, 1_001)
        XCTAssertEqual(snapshot.connections.count, 1_000)
        XCTAssertTrue(snapshot.isTruncated)
    }

    func testConnectionSidebarPresentationShowsDestinationAndEffectiveRouteMark() throws {
        let country = RuntimeConnectionSidebarPresentation(connection: RuntimeConnection(
            id: "country",
            destinationHost: "chat.example.test",
            destinationIP: "198.51.100.4",
            destinationPort: 443,
            network: "tcp",
            inbound: "mixed",
            outboundChain: ["Proxy", "United States West 01"],
            uploadBytes: 12,
            downloadBytes: 34,
            startedAt: nil
        ))
        XCTAssertEqual(country.destination, "chat.example.test")
        XCTAssertEqual(country.detail, "443 · TCP")
        guard case .country(let routeCountry) = country.routeMark else {
            return XCTFail("Expected a country route mark")
        }
        XCTAssertEqual(routeCountry.code, "US")

        let bypass = RuntimeConnectionSidebarPresentation(connection: RuntimeConnection(
            id: "bypass",
            destinationHost: nil,
            destinationIP: "192.0.2.8",
            destinationPort: 80,
            network: "udp",
            inbound: nil,
            outboundChain: ["bypass-mainland", "direct"],
            uploadBytes: nil,
            downloadBytes: nil,
            startedAt: nil
        ))
        XCTAssertEqual(bypass.destination, "192.0.2.8")
        XCTAssertEqual(bypass.routeMark, .bypass)

        let fallback = RuntimeConnectionSidebarPresentation(connection: RuntimeConnection(
            id: "default",
            destinationHost: nil,
            destinationIP: nil,
            destinationPort: nil,
            network: nil,
            inbound: nil,
            outboundChain: ["Proxy", "Automatic"],
            uploadBytes: nil,
            downloadBytes: nil,
            startedAt: nil
        ))
        XCTAssertEqual(fallback.destination, "-")
        XCTAssertNil(fallback.detail)
        XCTAssertEqual(fallback.routeMark, .defaultRoute)
    }

    func testTrafficHistoryIsBoundedAndResetsAtRuntimeBoundary() {
        var history = RuntimeTrafficHistory()
        for index in 0..<100 {
            history.append(.init(
                state: .available, uploadTotalBytes: 0, downloadTotalBytes: 0,
                uploadBytesPerSecond: Double(index), downloadBytesPerSecond: Double(index + 1),
                activeConnectionCount: 0, observedAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        XCTAssertEqual(history.samples.count, RuntimeTrafficHistory.maximumSamples)
        XCTAssertEqual(history.samples.first?.uploadBytesPerSecond, 10)
        history.reset()
        XCTAssertTrue(history.samples.isEmpty)
    }

    func testRuntimeLogBufferBoundsEntriesHandlesPartialUTF8AndRedacts() {
        let buffer = RuntimeLogBuffer()
        buffer.append(Data("INFO first".utf8), timestamp: Date(timeIntervalSince1970: 1))
        buffer.append(Data(" entry\nERROR url=https://user:password@example.test/path Authorization: Bearer controller-secret\n".utf8), timestamp: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(buffer.snapshot().map(\.level), [.info, .error])
        XCTAssertFalse(buffer.snapshot().contains { $0.message.contains("user:password") })
        XCTAssertFalse(buffer.snapshot().contains { $0.message.contains("controller-secret") })
        for index in 0...RuntimeLogBuffer.maximumEntries {
            buffer.append(Data("DEBUG line-\(index)\n".utf8))
        }
        let entries = buffer.snapshot()
        XCTAssertEqual(entries.count, RuntimeLogBuffer.maximumEntries)
        XCTAssertEqual(entries.last?.level, .debug)
        XCTAssertGreaterThan(entries.first?.id ?? 0, 1)
        buffer.clear()
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }

    func testPolicySelectPersistsThenHotAppliesAndRereadsAuthority() async throws {
        let store = try makeStore()
        let selected = try store.create(name: "Runtime")
        try store.save(json: #"{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"selector","tag":"group","outbounds":["first","second"],"default":"first"},{"type":"direct","tag":"first"},{"type":"direct","tag":"second"}]}"#, for: selected.id)
        let version = try store.selectedValidVersion()
        let evidence = HotPolicyEvidence(profileID: selected.id, revision: version.revision, source: version.data)
        let operations = TargetPolicyOperations(profileStore: store, runtimeEvidenceProvider: evidence)
        let result = try await operations.select(selectorTag: "group", outboundTag: "second")
        XCTAssertEqual(result.selectors.first?.runningSelection, "second")
        XCTAssertEqual(result.selectors.first?.runtimeConvergence, .converged)
        XCTAssertFalse(result.selectors.first?.restartRequired ?? true)
        let applyCount = await evidence.applyCount
        XCTAssertEqual(applyCount, 1)
    }

    func testPolicyLatencyProbePreservesPartialResultsAndProfileIdentity() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first", "second"]), for: profile.id)
        let version = try store.selectedValidVersion()
        let identity = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let provider = HealthProbeEvidence(identity: identity) { tags in
            .results([
                RuntimeProxyHealth.reachable(tag: tags[0], latencyMilliseconds: 42, observedAt: Date(timeIntervalSince1970: 1))!,
                .unreachable(tag: tags[1], observedAt: Date(timeIntervalSince1970: 1))
            ])
        }
        let result = try await TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: provider
        ).probeLatency(selectorTag: "group")

        XCTAssertTrue(result.runtimeAvailable)
        XCTAssertEqual(result.profileID, profile.id)
        XCTAssertEqual(result.profileRevision, version.revision)
        XCTAssertEqual(result.members.map(\.tag), ["first", "second"])
        XCTAssertEqual(result.members.map(\.state), [.reachable, .unreachable])
        XCTAssertEqual(result.members.first?.latencyMilliseconds, 42)
        let requestCount = await provider.controllerRequestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testMemberDelayTransportFailurePreservesOtherLatencyAfterControllerReconciliation() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [
            "node-a": .latency(1_200),
            "node-b": .runtimeError(.probeTransportFailure)
        ])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["node-a", "node-b"], client: client)

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["node-a", "node-b"]
        )

        guard case let .results(results) = outcome else { return XCTFail("Expected available runtime") }
        XCTAssertEqual(results.map(\.tag), ["node-a", "node-b"])
        XCTAssertEqual(results.map(\.state), [.reachable, .unreachable])
        XCTAssertEqual(results.first?.latencyMilliseconds, 1_200)
        XCTAssertFalse(results[1].isConclusiveFailure)
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 1)
    }

    func testMultipleMemberDelayTransportFailuresUseOneControllerReconciliation() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [
            "node-a": .runtimeError(.probeTransportFailure),
            "node-b": .runtimeError(.probeTransportFailure),
            "node-c": .runtimeError(.probeTransportFailure)
        ])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["node-a", "node-b", "node-c"], client: client)

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["node-a", "node-b", "node-c"]
        )

        guard case let .results(results) = outcome else { return XCTFail("Expected available runtime") }
        XCTAssertEqual(results.map(\.state), [.unreachable, .unreachable, .unreachable])
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 1)
    }

    func testMemberDelayTransportFailureBecomesRuntimeUnavailableWhenControllerReconciliationFails() async throws {
        let client = ControlledRuntimeControlClient(
            probeOutcomes: ["node": .runtimeError(.probeTransportFailure)],
            selectorError: .unavailable
        )
        let fixture = try makeRuntimePolicyProbeFixture(members: ["node"], client: client)

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["node"]
        )

        XCTAssertEqual(outcome, .runtimeUnavailable)
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 1)
    }

    func testControllerAuthenticationRejectionRemainsRuntimeUnavailable() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["node": .runtimeError(.selectionRejected)])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["node"], client: client)

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["node"]
        )

        XCTAssertEqual(outcome, .runtimeUnavailable)
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 0)
    }

    func testRuntimeConfigurationIdentityChangeDuringDelayProbeRemainsRuntimeUnavailable() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["node": .latency(42)])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["node"], client: client)
        await client.replaceRuntimeIdentityWhenProbing(tag: "node") {
            fixture.replaceRuntimeConfigurationIdentity()
        }

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["node"]
        )

        XCTAssertEqual(outcome, .runtimeUnavailable)
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 0)
    }

    func testHTTPProbeFailureAndMalformedDelayResponseRemainMemberUnreachable() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [
            "http": .runtimeError(.probeFailed),
            "malformed": .runtimeError(.malformedResponse)
        ])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["http", "malformed"], client: client)

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["http", "malformed"]
        )

        guard case let .results(results) = outcome else { return XCTFail("Expected available runtime") }
        XCTAssertEqual(results.map(\.state), [.unreachable, .unreachable])
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 0)
    }

    func testPolicyMemberDelayProbeCancellationPropagates() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["node": .cancelled])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["node"], client: client)

        do {
            _ = try await fixture.backend.probePolicyMemberLatency(
                expectedRuntime: fixture.expectedRuntime,
                outboundTags: ["node"]
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be classified as health state.
        }
    }

    func testAllMemberLatenciesRemainOrderedWithoutControllerReconciliation() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [
            "first": .latency(12),
            "second": .latency(34),
            "third": .latency(56)
        ])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["first", "second", "third"], client: client)

        let outcome = try await fixture.backend.probePolicyMemberLatency(
            expectedRuntime: fixture.expectedRuntime,
            outboundTags: ["first", "second", "third"]
        )

        guard case let .results(results) = outcome else { return XCTFail("Expected available runtime") }
        XCTAssertEqual(results.map(\.tag), ["first", "second", "third"])
        XCTAssertEqual(results.map(\.latencyMilliseconds), [12, 34, 56])
        let selectorCalls = await client.selectorCallCount()
        XCTAssertEqual(selectorCalls, 0)
    }

    func testPolicyLatencyProbeRuntimeIdentityMismatchMakesZeroControllerRequests() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first"]), for: profile.id)
        let version = try store.selectedValidVersion()
        let selectedIdentity = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let mismatches = [
            ExpectedPolicyRuntimeIdentity(profileID: UUID(), profileRevision: selectedIdentity.profileRevision, sourceFingerprint: selectedIdentity.sourceFingerprint),
            ExpectedPolicyRuntimeIdentity(profileID: selectedIdentity.profileID, profileRevision: selectedIdentity.profileRevision + 1, sourceFingerprint: selectedIdentity.sourceFingerprint),
            ExpectedPolicyRuntimeIdentity(profileID: selectedIdentity.profileID, profileRevision: selectedIdentity.profileRevision, sourceFingerprint: "different")
        ]

        for runtimeIdentity in mismatches {
            let provider = HealthProbeEvidence(identity: runtimeIdentity) { _ in .runtimeUnavailable }
            let result = try await TargetPolicyOperations(
                profileStore: store,
                runtimeEvidenceProvider: provider
            ).probeLatency(selectorTag: "group")
            XCTAssertFalse(result.runtimeAvailable)
            XCTAssertEqual(result.members.map(\.state), [.runtimeUnavailable])
            let requestCount = await provider.controllerRequestCount
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testPolicyLatencyProbeStoppedOrUnprovenRuntimeIsUnavailable() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(json: policyConfiguration(configuredDefault: "first", members: ["first"]), for: profile.id)
        let stopped = try await TargetPolicyOperations(profileStore: store).probeLatency(selectorTag: "group")
        XCTAssertFalse(stopped.runtimeAvailable)
        XCTAssertEqual(stopped.members.map(\.state), [.runtimeUnavailable])

        let unproven = try await TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: UnprovenPolicyRuntimeEvidence()
        ).probeLatency(selectorTag: "group")
        XCTAssertFalse(unproven.runtimeAvailable)
        XCTAssertEqual(unproven.members.map(\.state), [.runtimeUnavailable])
    }

    func testPolicyLatencyProbeSkipsStructurallyInvalidMembersAndRejectsAmbiguousSelector() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Health")
        try store.save(
            json: #"{"outbounds":[{"type":"selector","tag":"group","outbounds":["good","missing"]},{"type":"vmess","tag":"good"}]}"#,
            for: profile.id
        )
        let version = try store.selectedValidVersion()
        let identity = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let provider = HealthProbeEvidence(identity: identity) { tags in
            .results([RuntimeProxyHealth.reachable(tag: tags[0], latencyMilliseconds: 9, observedAt: .now)!])
        }
        let result = try await TargetPolicyOperations(
            profileStore: store,
            runtimeEvidenceProvider: provider
        ).probeLatency(selectorTag: "group")
        XCTAssertEqual(result.members.map(\.tag), ["good"])
        let requestCount = await provider.controllerRequestCount
        XCTAssertEqual(requestCount, 1)

        try store.save(
            json: #"{"outbounds":[{"type":"selector","tag":"group","outbounds":["good"]},{"type":"selector","tag":"group","outbounds":["good"]},{"type":"vmess","tag":"good"}]}"#,
            for: profile.id
        )
        do {
            _ = try await TargetPolicyOperations(
                profileStore: store,
                runtimeEvidenceProvider: provider
            ).probeLatency(selectorTag: "group")
            XCTFail("Expected ambiguous selector")
        } catch {
            XCTAssertEqual(error as? TargetPolicyOperationError, .selectorAmbiguous)
        }
        let finalRequestCount = await provider.controllerRequestCount
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testRuntimeProxyHealthRejectsOutOfRangeLatency() {
        XCTAssertNil(RuntimeProxyHealth.reachable(tag: "node", latencyMilliseconds: -1, observedAt: .now))
        XCTAssertNil(RuntimeProxyHealth.reachable(tag: "node", latencyMilliseconds: 0, observedAt: .now))
        XCTAssertNil(RuntimeProxyHealth.reachable(
            tag: "node",
            latencyMilliseconds: RuntimeProxyHealth.maximumLatencyMilliseconds + 1,
            observedAt: .now
        ))
    }

    func testRuntimeStatusCommandIsBoundedAndDoesNotExposeControllerMaterial() async throws {
        XCTAssertEqual(try TargetCtlCommandParser.parse(["runtime", "status", "--json"]).action, "runtime.status")
        let operations = TargetAutomationOperations(runtimeObservationOperations: FixedRuntimeObservationProvider(value: .init(
            state: .available, uploadTotalBytes: 10, downloadTotalBytes: 20,
            uploadBytesPerSecond: 1.5, downloadBytesPerSecond: 2.5,
            activeConnectionCount: 1, observedAt: Date()
        )))
        let response = await operations.handle(.init(protocolVersion: 1, action: "runtime.status"))
        let data = AutomationProtocol.encodeResponse(response)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("uploadTotalBytes"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("127.0.0.1"))
    }

    func testShadowBackendUsesVerifiedReadOnlyBoundaryAndNeverSelects() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["a": .latency(100), "b": .latency(40)], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        for _ in 0..<5 {
            let result = try await fixture.backend.collectShadowEvidence(expectedRuntime: fixture.expectedRuntime, selector: "group", candidates: ["a", "b"])
            guard case .available(let evidence) = result else { return XCTFail("Expected verified shadow evidence") }
            XCTAssertEqual(evidence.currentOutbound, "a")
            guard case .results(let probes) = evidence.probes else { return XCTFail("Expected health facts") }
            XCTAssertEqual(probes.map(\.state), [.reachable, .reachable])
        }
        let calls = await client.selectionCallCount()
        let snapshots = await client.snapshotCallCount()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(snapshots, 5)
    }

    func testShadowBackendRejectsIdentityMismatchBeforeControllerAccess() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["a": .latency(100)], selectorMembers: ["a"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a"], client: client)
        let mismatch = ExpectedPolicyRuntimeIdentity(profileID: UUID(), profileRevision: 1, sourceFingerprint: "mismatch")
        let result = try await fixture.backend.collectShadowEvidence(expectedRuntime: mismatch, selector: "group", candidates: ["a"])
        guard case .unavailable("identityMismatch") = result else { return XCTFail("Expected identity refusal") }
        let calls = await client.selectorCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testShadowBackendRejectsRuntimeReplacementAndSelectorStaleness() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["a": .latency(100)], selectorMembers: ["a"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a"], client: client)
        let stale = try await fixture.backend.collectShadowEvidence(expectedRuntime: fixture.expectedRuntime, selector: "group", candidates: ["a", "b"])
        guard case .unavailable("selectorStale") = stale else { return XCTFail("Expected stale selector refusal") }
        await client.replaceRuntimeIdentityWhenProbing(tag: "a") { fixture.replaceRuntimeConfigurationIdentity() }
        let changed = try await fixture.backend.collectShadowEvidence(expectedRuntime: fixture.expectedRuntime, selector: "group", candidates: ["a"])
        guard case .unavailable = changed else { return XCTFail("Expected runtime replacement refusal") }
        let calls = await client.selectionCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testSmartApplyUsesSharedPolicyAndExactlyOneControllerWrite() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: ["a": .latency(300), "b": .latency(30)], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        let automation = TargetAutomationOperations(profileStore: fixture.profileStore, policyOperations: policy, backend: fixture.backend)
        let response = await automation.handle(.init(protocolVersion: 1, action: "smart.apply"))
        XCTAssertTrue(response.ok)
        let output = String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self)
        XCTAssertTrue(output.contains("\"applied\":true"))
        XCTAssertEqual(try policy.readPersisted().selectors.first?.effectiveDesired, "b")
        let count = await client.selectionCallCount()
        XCTAssertEqual(count, 1)
        let again = await automation.handle(.init(protocolVersion: 1, action: "smart.apply"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(again), as: UTF8.self).contains("keepCurrent"))
        let finalCount = await client.selectionCallCount()
        XCTAssertEqual(finalCount, 1)
        let capability = await automation.handle(.init(protocolVersion: 1, action: "capabilities"))
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(capability), as: UTF8.self).contains("smart.apply"))
        let invalid = await automation.handle(.init(protocolVersion: 1, action: "smart.apply", arguments: ["selector": "group"]))
        XCTAssertFalse(invalid.ok)
        for forbidden in ["unit-test-runtime-control-secret", "127.0.0.1", "sessionID", "sourceFingerprint", "destination", "connectionID"] { XCTAssertFalse(output.contains(forbidden)) }
    }

    func testConditionalSelectionProfileLiveAndRuntimeRacesAbortWithoutWrites() async throws {
        for race in ["profile", "live", "identity"] {
            let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
            let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
            let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
            let evidence = try fixture.selectionEvidence()
            let generation = policy.selectionGeneration()
            let other = try fixture.profileStore.create(name: "Other")
            try fixture.profileStore.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: other.id)
            if race == "profile" { try fixture.profileStore.select(other.id) }
            if race == "live" { await client.setSelected("b") }
            if race == "identity" { fixture.replaceRuntimeConfigurationIdentity() }
            let result = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "b", generation: generation)
            XCTAssertFalse(result.applied, race)
            XCTAssertEqual(result.reason, race == "profile" ? .profileChanged : race == "live" ? .liveSelectionChanged : .identityChanged)
            let count = await client.selectionCallCount()
            XCTAssertEqual(count, 0, race)
        }
    }

    func testProfileChangeDuringFinalControllerReadAbortsAtSharedCommit() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        let evidence = try fixture.selectionEvidence()
        let other = try fixture.profileStore.create(name: "Other")
        try fixture.profileStore.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: other.id)
        await client.onNextSelectorRead { try? fixture.profileStore.select(other.id) }
        let result = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "b", generation: policy.selectionGeneration())
        XCTAssertEqual(result.reason, .profileChanged)
        let count = await client.selectionCallCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try fixture.profileStore.selectedValidVersion().profile.policyOverrides.isEmpty)
    }

    func testManualSelectionGenerationRejectsStaleDecisionEvenAfterReturningToOriginalChoice() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        _ = try await policy.select(selectorTag: "group", outboundTag: "a")
        let evidence = try fixture.selectionEvidence()
        let generation = policy.selectionGeneration()
        _ = try await policy.select(selectorTag: "group", outboundTag: "b")
        _ = try await policy.select(selectorTag: "group", outboundTag: "a")
        XCTAssertEqual(try policy.readPersisted(), evidence.catalog)
        let before = await client.selectionCallCount()
        let result = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "b", generation: generation)
        XCTAssertEqual(result.reason, .selectionChanged)
        let after = await client.selectionCallCount()
        XCTAssertEqual(after, before)
    }

    func testConditionalSelectionRejectsStaleAndCancelledRequestsBeforeCommit() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        let fresh = try fixture.selectionEvidence()
        let stale = PolicySelectionEvidence(catalog: fresh.catalog, sessionID: fresh.sessionID, selector: fresh.selector, currentOutbound: fresh.currentOutbound, observedAt: .now.addingTimeInterval(-11))
        let result = try await policy.selectIfUnchanged(evidence: stale, outboundTag: "b", generation: 0)
        XCTAssertEqual(result.reason, .staleEvidence)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await policy.selectIfUnchanged(evidence: fresh, outboundTag: "b", generation: 0)
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let count = await client.selectionCallCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try fixture.profileStore.selectedValidVersion().profile.policyOverrides.isEmpty)
    }

    func testConcurrentConditionalMutationIsBoundedAndLaterManualSelectionWins() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        let evidence = try fixture.selectionEvidence()
        await client.gateNextSelection()
        let smart = Task { try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "b", generation: 0) }
        await client.waitUntilSelecting()
        let concurrent = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "b", generation: 0)
        XCTAssertEqual(concurrent.reason, .mutationInProgress)
        let manual = Task { try await policy.select(selectorTag: "group", outboundTag: "a") }
        let deadline = ContinuousClock.now + .seconds(2)
        while policy.selectionGeneration() < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(policy.selectionGeneration(), 2)
        await client.releaseSelection()
        let smartResult = try await smart.value
        XCTAssertTrue(smartResult.applied)
        _ = try await manual.value
        XCTAssertEqual(try policy.readPersisted().selectors.first?.effectiveDesired, "a")
        let selected = try await client.selectors(using: runtimeDescriptor)["group"]?.selected
        XCTAssertEqual(selected, "a")
        let count = await client.selectionCallCount()
        XCTAssertEqual(count, 2)
    }

    func testConditionalRuntimeChangeDuringFinalReadAndInvalidCandidateNeverMutate() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        let evidence = try fixture.selectionEvidence()
        let invalid = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "removed", generation: 0)
        XCTAssertEqual(invalid.reason, .invalidRecommendation)
        await client.onNextSelectorRead { fixture.replaceRuntimeConfigurationIdentity() }
        let changed = try await policy.selectIfUnchanged(evidence: evidence, outboundTag: "b", generation: 0)
        XCTAssertEqual(changed.reason, .identityChanged)
        let count = await client.selectionCallCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try fixture.profileStore.selectedValidVersion().profile.policyOverrides.isEmpty)
    }

    func testContinuityUsesOneVerifiedSnapshotWithoutSelectorOrRuntimeMutation() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a"], client: client)
        let before = try fixture.profileStore.selectedValidVersion()
        let automation = TargetAutomationOperations(profileStore: fixture.profileStore, backend: fixture.backend)
        let response = await automation.handle(.init(protocolVersion: 1, action: "smart.continuity"))
        XCTAssertTrue(response.ok)
        XCTAssertTrue(String(decoding: AutomationProtocol.encodeResponse(response), as: UTF8.self).contains("\"state\":\"available\""))
        let snapshots = await client.snapshotCallCount(); XCTAssertEqual(snapshots, 1)
        let selectors = await client.selectorCallCount(); XCTAssertEqual(selectors, 0)
        let selections = await client.selectionCallCount(); XCTAssertEqual(selections, 0)
        let after = try fixture.profileStore.selectedValidVersion()
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.profile, before.profile)
        XCTAssertEqual(after.revision, before.revision)
    }

    func testContinuityRejectsIdentityChangeDuringReadAndUnavailableController() async throws {
        for changeIdentity in [true, false] {
            let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a"])
            let fixture = try makeRuntimePolicyProbeFixture(members: ["a"], client: client)
            if changeIdentity { await client.onNextSnapshotRead { fixture.replaceRuntimeConfigurationIdentity() } }
            else { await client.failSnapshots() }
            let result = try await fixture.backend.collectContinuityEvidence()
            guard case .unavailable = result else { return XCTFail("Expected unavailable evidence") }
            let snapshots = await client.snapshotCallCount(); XCTAssertEqual(snapshots, 1)
            let selections = await client.selectionCallCount(); XCTAssertEqual(selections, 0)
        }
    }

    func testContinuityRejectsUnverifiedProfileAndStoppedRuntimeBeforeControllerRead() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a"], client: client)
        try fixture.profileStore.save(json: policyConfiguration(configuredDefault: "b", members: ["a", "b"]), for: fixture.expectedRuntime.profileID)
        // The recorded revision remains readable; corrupting its runtime material
        // invalidates ownership-authorized observation without any host action.
        fixture.removeRuntimeConfiguration()
        guard case .unavailable = try await fixture.backend.collectContinuityEvidence() else { return XCTFail("Expected unavailable") }
        fixture.clearRuntimeRecord()
        guard case .stopped = try await fixture.backend.collectContinuityEvidence() else { return XCTFail("Expected stopped") }
        let snapshots = await client.snapshotCallCount(); XCTAssertEqual(snapshots, 0)
    }

    func testContinuityCancellationBeforeReadDoesNotAccessController() async throws {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a"], client: client)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.backend.collectContinuityEvidence()
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let snapshots = await client.snapshotCallCount(); XCTAssertEqual(snapshots, 0)
    }

    func testContinuityCloseOnlyDispatchesVerifiedRelevantReplaceableAndConfirmsDisappearance() async throws {
        let (fixture, policy, client, request) = try await makeContinuityCloseFixture()
        let original = request.receipt.identity
        let outcome = try await policy.closeContinuityConnectionIfUnchanged(request)
        guard case .closed = outcome else { return XCTFail("Expected confirmed single-ID close") }
        let closes = await client.closeCallCount(); XCTAssertEqual(closes, 1)
        XCTAssertEqual(fixture.currentRuntimeRecord(), original)
        let selected = try await client.selectors(using: runtimeDescriptor)["group"]?.selected
        XCTAssertEqual(selected, "b")
        let ids = await client.closedIDs(); XCTAssertEqual(ids, [request.connection.id])
    }

    func testContinuityClosePreservesProtectUnknownUnrelatedAndNewSelection() async throws {
        for scenario in ["protect", "unknown", "unrelated", "newSelection"] {
            let (_, policy, client, initial) = try await makeContinuityCloseFixture()
            let chain = scenario == "unrelated" ? ["a", "other"] : scenario == "newSelection" ? ["b", "group"] : ["a", "group"]
            let connection = continuityConnection(id: initial.connection.id, at: initial.plan.evidence.observedAt, chain: chain)
            let plan = continuityPlan(identity: initial.receipt.identity, connection: connection,
                                      observedAt: initial.plan.evidence.observedAt,
                                      classification: scenario == "protect" ? .protect : scenario == "unknown" ? .unknown : nil)
            await client.setSnapshot(plan.evidence.snapshot)
            let result = try await policy.closeContinuityConnectionIfUnchanged(.init(plan: plan, connection: connection, receipt: initial.receipt))
            guard case .preserved = result else { return XCTFail("Expected preservation: \(scenario)") }
            let closes = await client.closeCallCount(); XCTAssertEqual(closes, 0, scenario)
        }
    }

    func testContinuityFreshDisappearanceReuseActivityChainAndTruncationPreserve() async throws {
        for scenario in ["disappeared", "reused", "activity", "chain", "truncated"] {
            let (_, policy, client, initial) = try await makeContinuityCloseFixture()
            let old = initial.connection
            let changed = RuntimeConnection(id: old.id, destinationHost: old.destinationHost, destinationIP: old.destinationIP,
                                            destinationPort: old.destinationPort, network: old.network, inbound: old.inbound,
                                            outboundChain: scenario == "chain" ? ["a", "other", "group"] : old.outboundChain,
                                            uploadBytes: scenario == "activity" ? 1 : old.uploadBytes, downloadBytes: old.downloadBytes,
                                            startedAt: scenario == "reused" ? old.startedAt?.addingTimeInterval(1) : old.startedAt)
            let values = scenario == "disappeared" ? [] : [changed]
            await client.setSnapshot(.init(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0,
                                                       activeConnectionCount: scenario == "truncated" ? 2 : values.count), connections: values))
            let result = try await policy.closeContinuityConnectionIfUnchanged(initial)
            guard case .preserved = result else { return XCTFail("Expected preservation: \(scenario)") }
            let closes = await client.closeCallCount(); XCTAssertEqual(closes, 0, scenario)
        }
    }

    func testContinuityActivityDuringSecondSelectorReadIsObservedBeforeClose() async throws {
        let (_, policy, client, request) = try await makeContinuityCloseFixture()
        let selectorsBefore = await client.selectorCallCount()
        await client.activateConnectionOnSelectorRead(after: 2)
        let outcome = try await policy.closeContinuityConnectionIfUnchanged(request)
        guard case .preserved(let reason) = outcome else { return XCTFail("New activity must preserve the candidate") }
        XCTAssertEqual(reason, "connectionChanged")
        let selectorsAfter = await client.selectorCallCount(); XCTAssertEqual(selectorsAfter - selectorsBefore, 2)
        let closes = await client.closeCallCount(); XCTAssertEqual(closes, 0)
    }

    func testContinuityRuntimeIdentityAndProfileChangesPreserve() async throws {
        for scenario in ["session", "start", "pid", "configuration", "profile", "revision", "generation", "route"] {
            let (fixture, policy, client, request) = try await makeContinuityCloseFixture()
            switch scenario {
            case "session": fixture.replaceRuntimeConfigurationIdentity()
            case "start", "pid": fixture.replaceRuntimeProcessIdentity(changePID: scenario == "pid")
            case "configuration": fixture.removeRuntimeConfiguration()
            case "profile":
                let other = try fixture.profileStore.create(name: "Other")
                try fixture.profileStore.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: other.id)
                try fixture.profileStore.select(other.id)
            case "revision":
                try fixture.profileStore.save(json: policyConfiguration(configuredDefault: "a", members: ["a", "b"]), for: request.receipt.identity.profileID)
            case "generation":
                _ = try await policy.select(selectorTag: "group", outboundTag: "a")
                _ = try await policy.select(selectorTag: "group", outboundTag: "b")
            default:
                try fixture.profileStore.persistRouteBinding(profileID: request.receipt.identity.profileID,
                                                           expectedRevision: request.receipt.identity.profileRevision,
                                                           binding: try XCTUnwrap(.init(domain: "fixture.invalid", outboundTag: "a", countryCode: "US")))
            }
            let result = try await policy.closeContinuityConnectionIfUnchanged(request)
            guard case .preserved = result else { return XCTFail("Expected preservation: \(scenario)") }
            let closes = await client.closeCallCount(); XCTAssertEqual(closes, 0, scenario)
        }
    }

    func testContinuityFinalDispatchGuardsCatchActorHopRuntimeAndProfileRaces() async throws {
        for race in ["runtime", "profile"] {
            let (fixture, policy, client, request) = try await makeContinuityCloseFixture()
            await client.onNextClose {
                if race == "runtime" { fixture.replaceRuntimeConfigurationIdentity() }
                else { try? fixture.profileStore.select(nil) }
            }
            let outcome = try await policy.closeContinuityConnectionIfUnchanged(request)
            guard case .preserved(let reason) = outcome else { return XCTFail("Expected dispatch guard preservation") }
            XCTAssertEqual(reason, race == "runtime" ? "identityChanged" : "profileChanged")
            let closes = await client.closeCallCount(); XCTAssertEqual(closes, 0)
        }
    }

    func testContinuityCloseRequiresPost204DisappearanceAndNeverRetries() async throws {
        let (_, policy, client, request) = try await makeContinuityCloseFixture()
        await client.keepClosedConnections()
        let result = try await policy.closeContinuityConnectionIfUnchanged(request)
        guard case .failed = result else { return XCTFail("204 alone must not confirm close") }
        let closes = await client.closeCallCount(); XCTAssertEqual(closes, 1)
    }

    func testContinuityCloseLeaseRejectsConcurrentMutationAndCancellationAfterDispatchIsUnconfirmed() async throws {
        let (fixture, policy, client, request) = try await makeContinuityCloseFixture()
        await client.gateNextClose()
        let closing = Task { try await policy.closeContinuityConnectionIfUnchanged(request) }
        await client.waitUntilClosing()
        let concurrent = try await fixture.backend.closeContinuityConnection(request) { dispatch in dispatch() }
        guard case .preserved(let reason) = concurrent else { return XCTFail("Expected lease refusal") }
        XCTAssertEqual(reason, "mutationInProgress")
        do { _ = try await fixture.backend.startEngine(); XCTFail("Expected lifecycle lease refusal") }
        catch BackendError.invalidLifecycleTransition {}
        closing.cancel()
        await client.releaseClose()
        let result = try await closing.value
        guard case .failed = result else { return XCTFail("Dispatched cancellation must be unconfirmed") }
        let closes = await client.closeCallCount(); XCTAssertEqual(closes, 1)
    }

    private func makeContinuityCloseFixture() async throws -> (RuntimePolicyProbeFixture, TargetPolicyOperations, ControlledRuntimeControlClient, SmartContinuityCloseRequest) {
        let client = ControlledRuntimeControlClient(probeOutcomes: [:], selectorMembers: ["a", "b"])
        let fixture = try makeRuntimePolicyProbeFixture(members: ["a", "b"], client: client)
        let policy = TargetPolicyOperations(profileStore: fixture.profileStore, runtimeEvidenceProvider: fixture.backend)
        let applied = try await policy.selectIfUnchanged(evidence: fixture.selectionEvidence(), outboundTag: "b", generation: 0)
        let receipt = try XCTUnwrap(applied.receipt)
        let time = Date().addingTimeInterval(-0.1)
        let connection = continuityConnection(id: UUID().uuidString, at: time)
        let plan = continuityPlan(identity: receipt.identity, connection: connection, observedAt: time)
        XCTAssertEqual(plan.classifications[connection.id], .replaceable)
        await client.setSnapshot(plan.evidence.snapshot)
        return (fixture, policy, client, .init(plan: plan, connection: connection, receipt: receipt))
    }

    private func continuityConnection(id: String, at time: Date, chain: [String] = ["a", "group"]) -> RuntimeConnection {
        .init(id: id, destinationHost: "fixture.invalid", destinationIP: nil, destinationPort: 80, network: "tcp", inbound: "mixed/local",
              outboundChain: chain, uploadBytes: 0, downloadBytes: 0, startedAt: time.addingTimeInterval(-40))
    }

    private func continuityPlan(identity: EngineRuntimeRecord, connection: RuntimeConnection, observedAt: Date,
                                classification: SmartContinuityClassification? = nil) -> SmartContinuityPlan {
        let snapshot = RuntimeConnectionsSnapshot(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: 1), connections: [connection])
        var classifier = SmartContinuityClassifier()
        var summary = SmartContinuitySummary.unavailable("warming")
        for offset in [-30.0, -20, -10, 0] {
            summary = classifier.observe(.init(identity: identity, snapshot: snapshot, observedAt: observedAt.addingTimeInterval(offset)))
        }
        return .init(evidence: .init(identity: identity, snapshot: snapshot, observedAt: observedAt), classifier: classifier,
                     classifications: classification.map { [connection.id: $0] } ?? classifier.classifications, summary: summary)
    }

    private func makeRuntimePolicyProbeFixture(
        members: [String],
        client: any RuntimeControlClient
    ) throws -> RuntimePolicyProbeFixture {
        let root = try temporaryDirectory()
        let engineDirectory = root.appending(path: "Engine", directoryHint: .isDirectory)
        let executable = engineDirectory.appending(path: "sing-box")
        try FileManager.default.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        try Data("runtime-control-test-executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let profileStore = ProfileStore(
            rootDirectory: root.appending(path: "Profiles", directoryHint: .isDirectory),
            checker: TestChecker(result: .success(())),
            keyProvider: TestProfileKeyProvider()
        )
        let profile = try profileStore.create(name: "Runtime Health")
        try profileStore.save(
            json: policyConfiguration(configuredDefault: members[0], members: members),
            for: profile.id
        )
        let version = try profileStore.selectedValidVersion()
        let expectedRuntime = ExpectedPolicyRuntimeIdentity(
            profileID: profile.id,
            profileRevision: version.revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(version.data)
        )
        let runtimeData = Data(#"{"experimental":{"clash_api":{"external_controller":"127.0.0.1:51235","secret":"unit-test-runtime-control-secret"}}}"#.utf8)
        let configurations = RuntimeConfigurationStore(
            directory: engineDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        )
        let configurationID = UUID()
        _ = try configurations.write(runtimeData, id: configurationID)
        let record = EngineRuntimeRecord(
            pid: getpid(),
            executablePath: executable.path,
            executableFingerprint: try EngineExecutableFingerprint.sha256(of: executable),
            endpoint: LocalEngineEndpoint(port: 51_234),
            profileID: profile.id,
            profileRevision: version.revision,
            sourceConfigurationFingerprint: expectedRuntime.sourceFingerprint,
            configurationFingerprint: TargetConfigurationFingerprint.sha256(runtimeData),
            startedAt: .now,
            runtimeConfigurationID: configurationID
        )
        let recordStore = MutableEngineRuntimeStore(record: record)
        let ownership = EngineRuntimeOwnership(
            store: recordStore,
            processInspector: AlwaysMatchingEngineProcessInspector(),
            portProbe: AlwaysListeningEnginePortProbe()
        )
        let backend = SingBoxBackend(
            runtimeOwnership: ownership,
            profileStore: profileStore,
            engineDirectory: engineDirectory,
            executableURL: executable,
            runtimeControlClient: client
        )
        return RuntimePolicyProbeFixture(
            backend: backend,
            profileStore: profileStore,
            expectedRuntime: expectedRuntime,
            recordStore: recordStore,
            configurations: configurations,
            runtimeData: runtimeData
        )
    }
}

private let runtimeDescriptor = RuntimeControlDescriptor(
    host: "127.0.0.1",
    port: 51_234,
    secret: "unit-test-secret-not-production"
)

private func makeRuntimeControlClient(status: Int, body: Data) -> SingBoxRuntimeControlClient {
    RuntimeControlURLProtocol.configure(status: status, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RuntimeControlURLProtocol.self]
    configuration.connectionProxyDictionary = [:]
    return SingBoxRuntimeControlClient(session: URLSession(configuration: configuration))
}

private final class RuntimeControlURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response = (status: 200, body: Data())
    private(set) static var lastRequest: URLRequest?

    static func configure(status: Int, body: Data) {
        lock.lock()
        response = (status, body)
        lastRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        let response = Self.response
        Self.lock.unlock()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TransportFailingRuntimeControlURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}

private enum ControlledProbeOutcome: Sendable {
    case latency(Int)
    case runtimeError(RuntimeControlError)
    case cancelled
}

private actor ControlledRuntimeControlClient: RuntimeControlClient {
    private let probeOutcomes: [String: ControlledProbeOutcome]
    private let selectorError: RuntimeControlError?
    private var selectorCalls = 0
    private var selectionCalls = 0
    private var snapshotCalls = 0
    private var snapshotReadAction: (@Sendable () -> Void)?
    private var snapshotsFail = false
    private let selectorMembers: [String]?
    private var identityChange: (tag: String, action: @Sendable () -> Void)?
    private var selected: String?
    private var selectorReadAction: (@Sendable () -> Void)?
    private var shouldGateSelection = false
    private var selectionGate: CheckedContinuation<Void, Never>?
    private var selectionWaiting: CheckedContinuation<Void, Never>?
    private var snapshot: RuntimeConnectionsSnapshot?
    private var closeReadAction: (@Sendable () -> Void)?
    private var closes: [String] = []
    private var removesClosedConnections = true
    private var shouldGateClose = false
    private var closeGate: CheckedContinuation<Void, Never>?
    private var closeWaiting: CheckedContinuation<Void, Never>?
    private var activateOnSelectorRead: Int?


    init(
        probeOutcomes: [String: ControlledProbeOutcome],
        selectorError: RuntimeControlError? = nil,
        selectorMembers: [String]? = nil
    ) {
        self.probeOutcomes = probeOutcomes
        self.selectorError = selectorError
        self.selectorMembers = selectorMembers
    }

    func selectors(using descriptor: RuntimeControlDescriptor) async throws -> [String: RuntimeSelectorState] {
        selectorCalls += 1
        if let selectorError { throw selectorError }
        if selectorCalls == activateOnSelectorRead, let snapshot {
            activateOnSelectorRead = nil
            let connections = snapshot.connections.map { connection in
                RuntimeConnection(id: connection.id, destinationHost: connection.destinationHost, destinationIP: connection.destinationIP,
                                  destinationPort: connection.destinationPort, network: connection.network, inbound: connection.inbound,
                                  outboundChain: connection.outboundChain, uploadBytes: (connection.uploadBytes ?? 0) + 1,
                                  downloadBytes: connection.downloadBytes, startedAt: connection.startedAt)
            }
            self.snapshot = .init(totals: .init(uploadTotalBytes: snapshot.totals.uploadTotalBytes + 1,
                                               downloadTotalBytes: snapshot.totals.downloadTotalBytes,
                                               activeConnectionCount: snapshot.totals.activeConnectionCount), connections: connections)
        }
        selectorReadAction?(); selectorReadAction = nil
        return ["group": .init(tag: "group", selected: selected ?? selectorMembers?.first ?? "node", members: selectorMembers ?? [])]
    }

    func select(selector: String, outbound: String, using descriptor: RuntimeControlDescriptor) async throws {
        selectionCalls += 1
        if shouldGateSelection {
            shouldGateSelection = false
            await withCheckedContinuation { selectionGate = $0; selectionWaiting?.resume(); selectionWaiting = nil }
        }
        selected = outbound
    }
    func gateNextSelection() { shouldGateSelection = true }
    func waitUntilSelecting() async {
        if selectionGate != nil { return }
        await withCheckedContinuation { selectionWaiting = $0 }
    }
    func releaseSelection() { selectionGate?.resume(); selectionGate = nil }

    func setSelected(_ value: String) { selected = value }
    func onNextSelectorRead(_ action: @escaping @Sendable () -> Void) { selectorReadAction = action }

    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals {
        .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: 0)
    }

    func probeLatency(outbound: String, using descriptor: RuntimeControlDescriptor) async throws -> Int {
        try Task.checkCancellation()
        if let identityChange, identityChange.tag == outbound {
            self.identityChange = nil
            identityChange.action()
        }
        guard let outcome = probeOutcomes[outbound] else { throw RuntimeControlError.unavailable }
        switch outcome {
        case let .latency(milliseconds): return milliseconds
        case let .runtimeError(error): throw error
        case .cancelled: throw CancellationError()
        }
    }

    func selectorCallCount() -> Int { selectorCalls }
    func selectionCallCount() -> Int { selectionCalls }
    func snapshotCallCount() -> Int { snapshotCalls }
    func onNextSnapshotRead(_ action: @escaping @Sendable () -> Void) { snapshotReadAction = action }
    func setSnapshot(_ value: RuntimeConnectionsSnapshot) { snapshot = value }
    func activateConnectionOnSelectorRead(after reads: Int) { activateOnSelectorRead = selectorCalls + reads }
    func onNextClose(_ action: @escaping @Sendable () -> Void) { closeReadAction = action }
    func closeCallCount() -> Int { closes.count }
    func closedIDs() -> [String] { closes }
    func keepClosedConnections() { removesClosedConnections = false }
    func gateNextClose() { shouldGateClose = true }
    func waitUntilClosing() async {
        if closeGate != nil { return }
        await withCheckedContinuation { closeWaiting = $0 }
    }
    func releaseClose() { closeGate?.resume(); closeGate = nil }
    func closeConnection(id: String, using descriptor: RuntimeControlDescriptor,
                         authorize: @escaping @Sendable (_ dispatch: @Sendable () -> Void) throws -> Void) async throws {
        closeReadAction?(); closeReadAction = nil
        let state = TestCloseDispatchState()
        try authorize { state.markDispatched() }
        guard state.wasDispatched else { throw RuntimeControlError.unavailable }
        closes.append(id)
        if shouldGateClose {
            shouldGateClose = false
            await withCheckedContinuation { closeGate = $0; closeWaiting?.resume(); closeWaiting = nil }
        }
        try Task.checkCancellation()
        if removesClosedConnections, let snapshot {
            let remaining = snapshot.connections.filter { $0.id != id }
            self.snapshot = .init(totals: .init(uploadTotalBytes: snapshot.totals.uploadTotalBytes,
                                              downloadTotalBytes: snapshot.totals.downloadTotalBytes,
                                              activeConnectionCount: remaining.count), connections: remaining)
        }
    }
    func failSnapshots() { snapshotsFail = true }
    func connections(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionsSnapshot {
        snapshotCalls += 1
        snapshotReadAction?(); snapshotReadAction = nil
        if snapshotsFail { throw RuntimeControlError.unavailable }
        if let snapshot { return snapshot }
        return .init(totals: .init(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: 0), connections: [])
    }

    func replaceRuntimeIdentityWhenProbing(tag: String, action: @escaping @Sendable () -> Void) {
        identityChange = (tag, action)
    }
}

private final class RuntimePolicyProbeFixture: @unchecked Sendable {
    let backend: SingBoxBackend
    let expectedRuntime: ExpectedPolicyRuntimeIdentity
    let profileStore: ProfileStore
    private let recordStore: MutableEngineRuntimeStore
    private let configurations: RuntimeConfigurationStore
    private let runtimeData: Data

    init(
        backend: SingBoxBackend,
        profileStore: ProfileStore,
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        recordStore: MutableEngineRuntimeStore,
        configurations: RuntimeConfigurationStore,
        runtimeData: Data
    ) {
        self.backend = backend
        self.profileStore = profileStore
        self.expectedRuntime = expectedRuntime
        self.recordStore = recordStore
        self.configurations = configurations
        self.runtimeData = runtimeData
    }

    func selectionEvidence() throws -> PolicySelectionEvidence {
        .init(catalog: try PolicyCatalogOperation(profileStore: profileStore).read(), sessionID: try XCTUnwrap(recordStore.current()?.runtimeConfigurationID), selector: "group", currentOutbound: "a", observedAt: .now)
    }

    func removeRuntimeConfiguration() {
        if let record = recordStore.current() { configurations.remove(id: record.runtimeConfigurationID) }
    }
    func clearRuntimeRecord() { try? recordStore.clear() }
    func currentRuntimeRecord() -> EngineRuntimeRecord? { recordStore.current() }

    func replaceRuntimeProcessIdentity(changePID: Bool) {
        guard let current = recordStore.current() else { return }
        recordStore.replace(.init(pid: changePID ? current.pid + 10_000 : current.pid,
                                  executablePath: current.executablePath, executableFingerprint: current.executableFingerprint,
                                  endpoint: current.endpoint, profileID: current.profileID, profileRevision: current.profileRevision,
                                  sourceConfigurationFingerprint: current.sourceConfigurationFingerprint,
                                  configurationFingerprint: current.configurationFingerprint,
                                  startedAt: changePID ? current.startedAt : current.startedAt.addingTimeInterval(1),
                                  runtimeConfigurationID: current.runtimeConfigurationID,
                                  routeBindingsFingerprint: current.routeBindingsFingerprint))
    }

    func replaceRuntimeConfigurationIdentity() {
        guard let current = recordStore.current() else { return }
        let replacementID = UUID()
        guard (try? configurations.write(runtimeData, id: replacementID)) != nil else { return }
        recordStore.replace(EngineRuntimeRecord(
            pid: current.pid,
            executablePath: current.executablePath,
            executableFingerprint: current.executableFingerprint,
            endpoint: current.endpoint,
            profileID: current.profileID,
            profileRevision: current.profileRevision,
            sourceConfigurationFingerprint: current.sourceConfigurationFingerprint,
            configurationFingerprint: current.configurationFingerprint,
            startedAt: current.startedAt,
            runtimeConfigurationID: replacementID
        ))
    }
}

private final class TestCloseDispatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched = false
    var wasDispatched: Bool { lock.lock(); defer { lock.unlock() }; return dispatched }
    func markDispatched() { lock.lock(); dispatched = true; lock.unlock() }
}

private final class MutableEngineRuntimeStore: EngineRuntimeStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: EngineRuntimeRecord?

    init(record: EngineRuntimeRecord?) { self.record = record }

    func load() throws -> EngineRuntimeRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func save(_ record: EngineRuntimeRecord) throws { replace(record) }

    func clear() throws {
        lock.lock()
        record = nil
        lock.unlock()
    }

    func current() -> EngineRuntimeRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func replace(_ record: EngineRuntimeRecord) {
        lock.lock()
        self.record = record
        lock.unlock()
    }
}

private struct AlwaysMatchingEngineProcessInspector: EngineProcessInspecting {
    func matches(pid: Int32, executablePath: String) -> Bool { true }
}

private struct AlwaysListeningEnginePortProbe: LocalEnginePortProbing {
    func isListening(on port: UInt16) async -> Bool { true }
}

private struct TestPortSelector: LocalEnginePortSelecting {
    let ports: [UInt16]
    init(_ ports: [UInt16]) { self.ports = ports }
    func selectAvailablePort() throws -> UInt16 { ports[0] }
}

private struct TestSecretGenerator: RuntimeControlSecretGenerating {
    let value: String
    func generate() throws -> String { value }
}

private struct FixedRuntimeObservationProvider: TargetRuntimeObserving {
    let value: RuntimeObservation
    func read() async -> RuntimeObservation { value }
}

private actor HotPolicyEvidence: PolicyRuntimeEvidenceProviding, RuntimePolicyApplying {
    let profileID: UUID
    let revision: Int
    let source: Data
    private var selection = "first"
    private(set) var applyCount = 0

    init(profileID: UUID, revision: Int, source: Data) {
        self.profileID = profileID
        self.revision = revision
        self.source = source
    }

    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence {
        .running(
            profileID: profileID, profileRevision: revision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(source),
            configuration: source, liveSelections: ["group": selection]
        )
    }

    func applyLivePolicySelection(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        selectorTag: String,
        outboundTag: String
    ) async -> Bool {
        guard expectedRuntime.profileID == profileID,
              expectedRuntime.profileRevision == revision,
              expectedRuntime.sourceFingerprint == TargetConfigurationFingerprint.sha256(source) else {
            return false
        }
        applyCount += 1
        selection = outboundTag
        return true
    }
}

private actor HealthProbeEvidence: PolicyRuntimeEvidenceProviding, RuntimePolicyHealthProbing {
    let identity: ExpectedPolicyRuntimeIdentity
    let outcome: @Sendable ([String]) -> RuntimePolicyHealthProbeOutcome
    private(set) var controllerRequestCount = 0

    init(
        identity: ExpectedPolicyRuntimeIdentity,
        outcome: @escaping @Sendable ([String]) -> RuntimePolicyHealthProbeOutcome
    ) {
        self.identity = identity
        self.outcome = outcome
    }

    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .unavailable }

    func probePolicyMemberLatency(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        outboundTags: [String]
    ) async throws -> RuntimePolicyHealthProbeOutcome {
        guard expectedRuntime == identity else { return .runtimeUnavailable }
        controllerRequestCount += outboundTags.count
        return outcome(outboundTags)
    }
}

private struct UnprovenPolicyRuntimeEvidence: PolicyRuntimeEvidenceProviding {
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .unavailable }
}

private func profile() -> Profile {
    Profile(id: UUID(), name: "Runtime", subscription: nil, createdAt: .now, updatedAt: .now, validation: .notChecked, validRevision: 1)
}
