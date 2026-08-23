import Foundation
import XCTest

@testable import Target

final class ProfileViewModelTests: XCTestCase, ProfileTestCaseSupport {
    @MainActor
    func testSubscriptionDiagnosticLifecycleIsTypedAndProfileScoped() async throws {
        let store = try makeStore()
        let first = try store.create(
            name: "First",
            subscriptionURL: URL(string: "https://provider.example/sub?token=TOP-SECRET")!
        )
        let second = try store.create(name: "Second")
        try store.select(first.id)
        let failure = SubscriptionFetchFailure(
            cause: .httpStatus(403), attempts: 1,
            response: SubscriptionResponseMetadata(contentType: "text/plain", byteCount: 0)
        )
        let model = ProfileViewModel(
            store: store,
            subscriptionFetcher: ViewModelSubscriptionFetcher(result: .failure(failure))
        )

        model.updateSubscription()
        try await waitForSubscriptionCompletion(model)
        let diagnostic = try XCTUnwrap(model.subscriptionFailureDiagnostic)
        XCTAssertEqual(diagnostic.stage, .httpResponse)
        XCTAssertEqual(diagnostic.httpStatus, 403)
        XCTAssertEqual(diagnostic.attemptCount, 1)
        XCTAssertEqual(model.messageKey, "profile.subscription.error.http-rejected")
        XCTAssertFalse(diagnostic.copyableDescription.contains("TOP-SECRET"))

        model.prepareSubscription(
            name: "Retry",
            url: URL(string: "https://provider.example/another?token=TOP-SECRET")!
        )
        XCTAssertNil(model.subscriptionFailureDiagnostic, "A new operation must clear stale diagnostics")
        model.cancelSubscriptionIntake()
        XCTAssertNil(model.subscriptionFailureDiagnostic)
        XCTAssertEqual(model.messageKey, "profile.subscription.error.cancelled")

        model.updateSubscription()
        try await waitForSubscriptionCompletion(model)
        XCTAssertNotNil(model.subscriptionFailureDiagnostic)
        model.requestSelection(second.id)
        XCTAssertNil(model.subscriptionFailureDiagnostic, "A Profile switch must not retain the previous failure")
    }

    @MainActor
    func testStaleNotModifiedResultIsReportedAsPersistenceFailure() async throws {
        let store = try makeStore()
        let profile = try store.create(
            name: "Provider",
            subscriptionURL: URL(string: "https://provider.example/sub")!
        )
        try store.select(profile.id)
        let fetcher = ViewModelSubscriptionGateFetcher()
        let model = ProfileViewModel(store: store, subscriptionFetcher: fetcher)

        model.updateSubscription()
        await fetcher.waitUntilStarted()
        try store.save(
            json: #"{"inbounds":[],"outbounds":[],"route":{},"concurrent":true}"#,
            for: profile.id
        )
        await fetcher.completeNotModified()
        try await waitForSubscriptionCompletion(model)

        XCTAssertEqual(model.messageKey, "profile.subscription.error.persistence-failed")
        XCTAssertEqual(model.subscriptionFailureDiagnostic?.stage, .persistence)
        XCTAssertEqual(model.subscriptionFailureDiagnostic?.category, .persistenceFailed)
        XCTAssertNotEqual(model.selectedProfile?.subscription?.cacheStatus, .notModified)
    }

    @MainActor
    func testViewModelDisablesExportForUnsavedEditorChanges() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Editor")
        let model = ProfileViewModel(store: store)

        XCTAssertEqual(model.selectedProfile?.id, profile.id)
        XCTAssertTrue(model.canExport)
        model.updateEditor("{\"changed\":true}")
        XCTAssertFalse(model.canExport)
        model.requestExport()
        XCTAssertEqual(model.messageKey, "profile.export.unsaved-changes")
    }

    @MainActor
    func testViewModelCancelsPreflightAndSelectionChangeDiscardsPreparedCandidate() async throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        let input = root.deletingLastPathComponent().appending(path: "candidate.json")
        try Data("{}".utf8).write(to: input)
        let model = ProfileViewModel(store: store)
        let beforeCancellation = try treeSnapshot(root)

        model.prepareImport(from: input)
        model.cancelPreparedImport()
        await Task.yield()
        XCTAssertNil(model.pendingImportCandidate)
        XCTAssertEqual(try treeSnapshot(root), beforeCancellation)

        model.prepareImport(from: input)
        for _ in 0..<100 where model.pendingImportCandidate == nil { await Task.yield() }
        XCTAssertNotNil(model.pendingImportCandidate)
        model.requestSelection(model.selectedID == first.id ? second.id : first.id)
        XCTAssertNil(model.pendingImportCandidate)
    }

    @MainActor
    func testViewModelExportSuccessCancellationAndFailureMessages() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: TestProfileKeyProvider())
        _ = try store.create(name: "Messages")
        let model = ProfileViewModel(store: store)
        let directory = root.deletingLastPathComponent().appending(path: "MessageExport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        model.requestExport()
        model.exportCancelled()
        XCTAssertEqual(model.messageKey, "profile.export.cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "cancelled.json").path))

        model.requestExport()
        model.exportSelectedProfile(to: directory.appending(path: "success.json"))
        XCTAssertEqual(model.messageKey, "profile.export.success")

        model.requestExport()
        model.exportSelectedProfile(to: directory)
        XCTAssertEqual(model.messageKey, "profile.export.error.unsafe-destination")
    }

    func testPolicyWorkspacePresentationSeparatesStoppedConvergedRestartAndUnavailableRuntime() {
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .notRunning)).titleKey, "policy.workspace.runtime.not-running")
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .converged)).titleKey, "policy.workspace.runtime.converged")
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .restartRequired)).titleKey, "policy.catalog.restart-required")
        XCTAssertEqual(PolicyRuntimePresentation(selector: selector(runtime: .unavailable)).titleKey, "policy.workspace.runtime.unavailable")
    }

    func testPolicyLatencyActionRequiresRunningEngineButNotControllerObservation() {
        XCTAssertFalse(PolicyLatencyActionAvailability.isAvailable(
            engineIsRunning: false,
            isTestingLatency: false,
            lifecycleBusy: false,
            selectorTag: "group",
            hasSelectableMembers: true
        ))
        XCTAssertTrue(PolicyLatencyActionAvailability.isAvailable(
            engineIsRunning: true,
            isTestingLatency: false,
            lifecycleBusy: false,
            selectorTag: "group",
            hasSelectableMembers: true
        ))
        XCTAssertFalse(PolicyLatencyActionAvailability.isAvailable(
            engineIsRunning: true,
            isTestingLatency: true,
            lifecycleBusy: false,
            selectorTag: "group",
            hasSelectableMembers: true
        ))
    }

    func testPolicyWorkspacePresentationSearchesCredentialSafeTagAndTypeFacts() {
        let catalog = PolicyCatalog(
            formatVersion: 1,
            profileID: nil,
            profileRevision: nil,
            sourceFingerprint: nil,
            storedOverrideCount: 1,
            selectors: [selector(runtime: .restartRequired)]
        )
        let presentation = PolicyWorkspacePresentation(catalog: catalog, unavailable: false)

        XCTAssertEqual(presentation.selectors(matching: "fast", filter: .all).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "vmess", filter: .all).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "missing", filter: .all).count, 0)
        XCTAssertEqual(presentation.selectors(matching: "", filter: .selected).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "", filter: .needsRestart).count, 1)
        XCTAssertEqual(presentation.selectors(matching: "", filter: .issues).count, 0)
    }

    func testPolicyWorkspacePresentationTreatsStructuralMembersAsIssuesAndNotSelectable() {
        let invalidMember = PolicyCatalogMember(identity: 0, tag: "broken", type: nil, status: .missingReference)
        let invalidSelector = PolicyCatalogSelector(
            identity: 0,
            tag: "group",
            status: .available,
            configuredDefault: "broken",
            targetOverride: nil,
            overrideValid: false,
            effectiveDesired: "broken",
            runningSelection: nil,
            runtimeConvergence: .notRunning,
            restartRequired: false,
            members: [invalidMember]
        )
        let presentation = PolicySelectorPresentation(invalidSelector)

        XCTAssertTrue(presentation.hasIssue)
        XCTAssertFalse(presentation.isMutable)
        XCTAssertFalse(presentation.members[0].isSelectable)
    }

    func testPolicyMemberHealthPresentationCoversUnknownTestingReachableAndUnavailableStates() {
        XCTAssertEqual(PolicyMemberHealthPresentation(nil).state, .unknown)
        XCTAssertEqual(
            PolicyMemberHealthPresentation(.testing(tag: "node")).titleKey,
            "policy.health.testing"
        )
        let reachable = PolicyMemberHealthPresentation(RuntimeProxyHealth.reachable(
            tag: "node",
            latencyMilliseconds: 42,
            observedAt: Date(timeIntervalSince1970: 1)
        ))
        XCTAssertEqual(reachable.state, .reachable)
        XCTAssertEqual(reachable.latencyMilliseconds, 42)
        XCTAssertEqual(reachable.titleKey, "policy.health.latency")
        XCTAssertEqual(
            PolicyMemberHealthPresentation(.unreachable(tag: "node", observedAt: .now)).titleKey,
            "policy.health.unavailable"
        )
        XCTAssertEqual(
            PolicyMemberHealthPresentation(.runtimeUnavailable(tag: "node")).titleKey,
            "policy.health.runtime-unavailable"
        )
    }

    func testPolicyRouteCountryRecognizesNamesCodesCitiesAndFlags() {
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "Hong Kong 03")?.code, "HK")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "东京 IPLC")?.code, "JP")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "US West 01")?.code, "US")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "🇸🇬 Premium")?.code, "SG")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "印度尼西亚 01")?.code, "ID")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "中国台湾 01")?.code, "TW")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "中國台灣 02")?.code, "TW")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "台湾 CN2")?.code, "TW")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: "🇹🇼 Premium")?.code, "TW")
        XCTAssertEqual(
            PolicyRouteCountry.recognize(in: "China 01", endpoint: "168.95.1.1:443")?.code,
            "TW"
        )
        XCTAssertEqual(
            PolicyRouteCountry.supported.first(where: { $0.code == "TW" })?.displayName(localeIdentifier: "zh-Hans"),
            "台湾"
        )
        XCTAssertNil(PolicyRouteCountry.recognize(in: "Automatic Route"))
    }

    func testPolicyRouteCountryPrefersLocalIPResolutionOverMisleadingName() throws {
        XCTAssertEqual(
            PolicyRouteCountry.recognize(in: "Japan 01", endpoint: "1.1.1.1:443")?.code,
            "AU"
        )

        let catalog = PolicyCatalogParser.parse(Data(#"""
        {
          "outbounds": [
            {"type":"selector","tag":"Proxy","outbounds":["Japan 01"]},
            {"type":"vmess","tag":"Japan 01","server":"1.1.1.1","server_port":443}
          ]
        }
        """#.utf8))
        let member = try XCTUnwrap(catalog.selectors.first?.members.first)
        XCTAssertEqual(member.endpoint, "1.1.1.1")
        XCTAssertEqual(PolicyRouteCountry.recognize(in: member.tag, endpoint: member.endpoint)?.code, "AU")
    }

    func testCountryRoutesChooseLowestMeasuredLatencyAndKeepUnknownNodesSeparate() throws {
        let selector = PolicyCatalogSelector(
            identity: 0,
            tag: "Proxy",
            status: .available,
            configuredDefault: "Japan 02",
            targetOverride: nil,
            overrideValid: true,
            effectiveDesired: "Japan 02",
            runningSelection: nil,
            runtimeConvergence: .notRunning,
            restartRequired: false,
            members: [
                PolicyCatalogMember(identity: 0, tag: "Japan 01", type: "vmess", status: .available),
                PolicyCatalogMember(identity: 1, tag: "Japan 02", type: "vmess", status: .available),
                PolicyCatalogMember(identity: 2, tag: "Manual Route", type: "direct", status: .available)
            ]
        )
        let fast = try XCTUnwrap(RuntimeProxyHealth.reachable(
            tag: "Japan 01", latencyMilliseconds: 42, observedAt: .now
        ))
        let slow = try XCTUnwrap(RuntimeProxyHealth.reachable(
            tag: "Japan 02", latencyMilliseconds: 126, observedAt: .now
        ))
        let presentation = PolicySelectorPresentation(
            selector,
            health: ["Japan 01": fast, "Japan 02": slow]
        )

        let japan = try XCTUnwrap(presentation.countryRoutes.first(where: { $0.country.code == "JP" }))
        XCTAssertEqual(japan.members.count, 2)
        XCTAssertEqual(japan.bestMember?.tag, "Japan 01")
        XCTAssertEqual(japan.bestLatencyMilliseconds, 42)
        XCTAssertEqual(presentation.unclassifiedMembers.map(\.tag), ["Manual Route"])
    }

    func testCountryRouteWithoutMeasurementsPrefersCurrentDesiredNode() throws {
        let selector = PolicyCatalogSelector(
            identity: 0,
            tag: "Proxy",
            status: .available,
            configuredDefault: "Singapore 01",
            targetOverride: "Singapore 02",
            overrideValid: true,
            effectiveDesired: "Singapore 02",
            runningSelection: nil,
            runtimeConvergence: .notRunning,
            restartRequired: false,
            members: [
                PolicyCatalogMember(identity: 0, tag: "Singapore 01", type: "vmess", status: .available),
                PolicyCatalogMember(identity: 1, tag: "Singapore 02", type: "vmess", status: .available)
            ]
        )
        let route = try XCTUnwrap(PolicySelectorPresentation(selector).countryRoutes.first)

        XCTAssertEqual(route.bestMember?.tag, "Singapore 02")
    }

    func testPolicyMemberHealthDoesNotAlterSelectionRoles() {
        let source = selector(runtime: .restartRequired)
        let health = [
            "fast": RuntimeProxyHealth.reachable(
                tag: "fast",
                latencyMilliseconds: 42,
                observedAt: Date(timeIntervalSince1970: 1)
            )!,
            "direct": .unreachable(tag: "direct", observedAt: Date(timeIntervalSince1970: 1))
        ]
        let presentation = PolicySelectorPresentation(source, health: health)

        XCTAssertEqual(presentation.desiredSelection, "fast")
        XCTAssertEqual(presentation.runningSelection, "direct")
        XCTAssertEqual(presentation.configuredDefault, "direct")
        XCTAssertEqual(presentation.members[0].role, .desired)
        XCTAssertEqual(presentation.members[1].role, .running)
        XCTAssertEqual(presentation.members[0].health.latencyMilliseconds, 42)
    }

    @MainActor
    func testProfileSwitchRejectsStaleLatencyProbeResult() async throws {
        let store = try makeStore()
        let first = try store.create(name: "First")
        try store.save(
            json: policyConfiguration(configuredDefault: "first", members: ["first"]),
            for: first.id
        )
        let second = try store.create(name: "Second")
        try store.save(
            json: policyConfiguration(configuredDefault: "second", members: ["second"]),
            for: second.id
        )
        try store.select(first.id)
        let gate = PolicyProbeGate()
        let operations = GatedProbePolicyOperations(store: store, gate: gate)
        let model = ProfileViewModel(store: store, policyOperations: operations)
        let selector = try XCTUnwrap(model.policyCatalog?.selectors.first)

        model.probePolicyLatency(selectorID: selector.id, selectorTag: "group")
        await gate.waitUntilStarted()
        XCTAssertEqual(model.testingPolicySelectorID, selector.id)
        XCTAssertEqual(model.policyHealthBySelector[selector.id]?["first"]?.state, .testing)

        model.requestSelection(second.id)
        await gate.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertNil(model.testingPolicySelectorID)
        XCTAssertTrue(model.policyHealthBySelector.isEmpty)
    }

    @MainActor
    func testParticipatingProfilesMergeTheirNodesByCountry() throws {
        let store = try makeStore()
        let first = try store.create(name: "YOUTU")
        try store.save(
            json: policyConfiguration(
                configuredDefault: "United States 01",
                members: ["United States 01"]
            ),
            for: first.id
        )
        let second = try store.create(name: "SSRDOG")
        try store.save(
            json: policyConfiguration(
                configuredDefault: "United States 02",
                members: ["United States 02", "Japan 01"]
            ),
            for: second.id
        )
        let model = ProfileViewModel(store: store)

        let allRoutes = model.participatingCountryRoutes(profileIDs: [first.id, second.id])
        XCTAssertEqual(allRoutes.first(where: { $0.id == "US" })?.members.count, 2)
        XCTAssertEqual(allRoutes.first(where: { $0.id == "JP" })?.members.count, 1)

        let firstOnly = model.participatingCountryRoutes(profileIDs: [first.id])
        XCTAssertEqual(firstOnly.map(\.id), ["US"])
    }

    @MainActor
    func testCountrySelectionSwitchesToParticipatingProfileAndPersistsItsNode() async throws {
        let store = try makeStore()
        let japan = try store.create(name: "YOUTU")
        try store.save(
            json: policyConfiguration(configuredDefault: "Japan 01", members: ["Japan 01"]),
            for: japan.id
        )
        let unitedStates = try store.create(name: "SSRDOG")
        try store.save(
            json: policyConfiguration(
                configuredDefault: "United States 01",
                members: ["United States 01", "United States 02"]
            ),
            for: unitedStates.id
        )
        try store.select(japan.id)
        let model = ProfileViewModel(store: store)

        model.requestCountrySelection("US", participatingProfileIDs: [japan.id, unitedStates.id])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while model.isSelectingPolicy, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(model.selectedID, unitedStates.id)
        XCTAssertEqual(model.policyCatalog?.selectors.first?.effectiveDesired, "United States 01")
        XCTAssertFalse(model.isSelectingPolicy)
    }

    @MainActor
    func testRuntimeChangeInvalidatesHealthAndRejectsInFlightLatencyResult() async throws {
        let store = try makeStore()
        let profile = try store.create(name: "Runtime")
        try store.save(
            json: policyConfiguration(configuredDefault: "node", members: ["node"]),
            for: profile.id
        )
        let gate = PolicyProbeGate()
        let operations = GatedProbePolicyOperations(store: store, gate: gate)
        let model = ProfileViewModel(store: store, policyOperations: operations)
        let selector = try XCTUnwrap(model.policyCatalog?.selectors.first)

        model.probePolicyLatency(selectorID: selector.id, selectorTag: "group")
        await gate.waitUntilStarted()
        XCTAssertEqual(model.testingPolicySelectorID, selector.id)
        XCTAssertEqual(model.policyHealthBySelector[selector.id]?["node"]?.state, .testing)

        model.refreshPolicyState()
        XCTAssertNil(model.testingPolicySelectorID)
        XCTAssertTrue(model.policyHealthBySelector.isEmpty)

        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.policyHealthBySelector.isEmpty)
    }

    private func selector(runtime: PolicyRuntimeConvergenceState) -> PolicyCatalogSelector {
        PolicyCatalogSelector(
            identity: 0,
            tag: "Fast Group",
            status: .available,
            configuredDefault: "direct",
            targetOverride: "fast",
            overrideValid: true,
            effectiveDesired: "fast",
            runningSelection: runtime == .notRunning ? nil : (runtime == .converged ? "fast" : "direct"),
            runtimeConvergence: runtime,
            restartRequired: runtime == .restartRequired,
            members: [
                PolicyCatalogMember(identity: 0, tag: "fast", type: "vmess", status: .available),
                PolicyCatalogMember(identity: 1, tag: "direct", type: "direct", status: .available)
            ]
        )
    }

    @MainActor
    private func waitForSubscriptionCompletion(_ model: ProfileViewModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while model.isUpdatingSubscription, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(model.isUpdatingSubscription)
    }
}

private struct ViewModelSubscriptionFetcher: ProfileSubscriptionFetching {
    let result: Result<SubscriptionResponse, Error>

    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        try result.get()
    }
}

private actor ViewModelSubscriptionGateFetcher: ProfileSubscriptionFetching {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<SubscriptionResponse, Error>?

    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { responseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func completeNotModified() {
        responseContinuation?.resume(returning: SubscriptionResponse(
            data: Data(), cacheStatus: .notModified, etag: "same", lastModified: nil
        ))
        responseContinuation = nil
    }
}

private actor PolicyProbeGate {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class GatedProbePolicyOperations: TargetPolicyOperating, @unchecked Sendable {
    private let base: TargetPolicyOperations
    private let gate: PolicyProbeGate

    init(store: ProfileStore, gate: PolicyProbeGate) {
        base = TargetPolicyOperations(profileStore: store)
        self.gate = gate
    }

    func readPersisted() throws -> PolicyCatalog { try base.readPersisted() }
    func read() async throws -> PolicyCatalog { try await base.read() }
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog {
        try await base.select(selectorTag: selectorTag, outboundTag: outboundTag)
    }
    func reset() async throws -> PolicyResetResult { try await base.reset() }

    func probeLatency(selectorTag: String) async throws -> PolicyLatencyProbeResult {
        let catalog = try base.readPersisted()
        let selector = try XCTUnwrap(catalog.selectors.first(where: { $0.tag == selectorTag }))
        let profileID = try XCTUnwrap(catalog.profileID)
        let revision = try XCTUnwrap(catalog.profileRevision)
        let fingerprint = try XCTUnwrap(catalog.sourceFingerprint)
        await gate.enter()
        return PolicyLatencyProbeResult(
            profileID: profileID,
            profileRevision: revision,
            sourceFingerprint: fingerprint,
            selector: selectorTag,
            runtimeAvailable: true,
            members: selector.members.compactMap {
                RuntimeProxyHealth.reachable(tag: $0.tag, latencyMilliseconds: 42, observedAt: .now)
            }
        )
    }
}
