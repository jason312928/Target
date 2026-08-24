import XCTest
@testable import Target

@MainActor
final class BackendArchitectureTests: XCTestCase {
    func testSystemProxySnapshotRestoresEveryProxySetting() async throws {
        let original: [String: SystemProxyValue] = [
            "HTTPEnable": .integer(0),
            "HTTPProxy": .string("proxy.example"),
            "HTTPPort": .integer(3128),
            "HTTPSEnable": .integer(1),
            "HTTPSProxy": .string("secure.example"),
            "HTTPSPort": .integer(8443),
            "SOCKSEnable": .integer(1),
            "SOCKSProxy": .string("socks.example"),
            "SOCKSPort": .integer(1080),
            "ProxyAutoConfigEnable": .integer(1),
            "ProxyAutoConfigURLString": .string("https://pac.example/proxy.pac"),
            "ProxyAutoDiscoveryEnable": .integer(1),
            "ExceptionsList": .strings(["localhost", "*.internal"])
        ]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let store = InMemoryRecoveryStore()
        let probe = TogglePortProbe(available: true)
        let coordinator = testCoordinator(system: system, store: store, probe: probe)

        let enabled = try await coordinator.enableSystemProxy()
        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a")["HTTPProxy"], .string("127.0.0.1"))
        let disabled = try await coordinator.disableSystemProxy()
        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
        XCTAssertNil(try store.load())
    }

    func testSystemProxyPartialApplyFailureRollsBack() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(
            serviceIDs: ["service-a", "service-b"],
            settings: ["service-a": original, "service-b": original],
            failOnWrite: 2
        )
        let store = InMemoryRecoveryStore()
        let coordinator = testCoordinator(system: system, store: store, probe: TogglePortProbe(available: true))

        do {
            _ = try await coordinator.enableSystemProxy()
            XCTFail("Expected transactional apply to fail")
        } catch let error as SystemProxyError {
            XCTAssertEqual(error, .applyFailed)
        }
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
        XCTAssertEqual(try system.proxySettings(for: "service-b"), original)
        XCTAssertNil(try store.load())
    }

    func testSystemProxyEnableDisableIsIdempotent() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let coordinator = testCoordinator(system: system, store: InMemoryRecoveryStore(), probe: TogglePortProbe(available: true))

        let firstEnable = try await coordinator.enableSystemProxy()
        let secondEnable = try await coordinator.enableSystemProxy()
        XCTAssertEqual(firstEnable.state, .enabled)
        XCTAssertEqual(secondEnable.state, .enabled)
        XCTAssertEqual(system.writeCount, 1)
        let firstDisable = try await coordinator.disableSystemProxy()
        let secondDisable = try await coordinator.disableSystemProxy()
        XCTAssertEqual(firstDisable.state, .disabled)
        XCTAssertEqual(secondDisable.state, .disabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
    }

    func testDisableRestoresManagedProxyEvenWhenEnvironmentNowReportsConfiguredProxy() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let store = InMemoryRecoveryStore()
        let probe = TogglePortProbe(available: true)
        let enabling = testCoordinator(system: system, store: store, probe: probe)
        _ = try await enabling.enableSystemProxy()

        let disabling = SystemProxyCoordinator(
            system: system,
            recoveryStore: store,
            portProbe: probe,
            environment: FixedHostEnvironment(proxyConfigured: true, proxyApplicationRunning: false),
            safetyMode: .authorizedNetworkTest,
            endpointProvider: { LocalEngineEndpoint(port: 51_234) }
        )
        let status = try await disabling.disableSystemProxy()
        XCTAssertEqual(status.state, .disabled)
        XCTAssertEqual(try system.proxySettings(for: "service-a"), original)
    }

    func testSystemProxyAutomaticallyRestoresWhenLocalPortDisappears() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let probe = TogglePortProbe(available: true)
        let store = InMemoryRecoveryStore()
        let coordinator = testCoordinator(system: system, store: store, probe: probe)

        _ = try await coordinator.enableSystemProxy()
        await probe.setAvailable(false)
        await coordinator.checkPortHealth()
        XCTAssertNotEqual(try system.proxySettings(for: "service-a"), original)
        XCTAssertNotNil(try store.load())
        let status = await coordinator.querySystemProxyStatus()
        XCTAssertEqual(status.state, .recoveryRequired)
    }

    func testSystemProxyXPCPayloadRejectsUnknownState() {
        let invalid = Data(#"{"state":"shell","engineReachable":true,"affectedServiceCount":1}"#.utf8)
        XCTAssertThrowsError(try XPCPayloadCodec.decodeSystemProxyStatus(invalid))
    }

    func testSystemProxyStatesExposeRequiredTransitions() async throws {
        XCTAssertEqual(SystemProxyState.disabled.rawValue, "disabled")
        XCTAssertEqual(SystemProxyState.enabling.rawValue, "enabling")
        XCTAssertEqual(SystemProxyState.enabled.rawValue, "enabled")
        XCTAssertEqual(SystemProxyState.disabling.rawValue, "disabling")
        XCTAssertEqual(SystemProxyState.recoveryRequired.rawValue, "recovery_required")
        XCTAssertEqual(SystemProxyState.failed.rawValue, "failed")
    }

    func testSafeModeBlocksNetworkWrites() async throws {
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]])
        let coordinator = SystemProxyCoordinator(
            system: system,
            recoveryStore: InMemoryRecoveryStore(),
            portProbe: TogglePortProbe(available: true),
            safetyMode: .safe
        )
        await XCTAssertThrowsErrorAsync(try await coordinator.enableSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .safeModeBlocked)
        }
        XCTAssertEqual(system.writeCount, 0)
    }

    func testUnreadableRecoverySnapshotRequiresManualReview() async {
        let coordinator = SystemProxyCoordinator(
            system: InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]]),
            recoveryStore: ThrowingRecoveryStore(),
            portProbe: TogglePortProbe(available: false)
        )

        let status = await coordinator.querySystemProxyStatus()
        XCTAssertEqual(status.state, .recoveryRequired)
        XCTAssertEqual(status.error, .snapshotFailed)
        XCTAssertFalse(status.hasRecoverySnapshot)
    }

    func testHostNetworkProbeTreatsSurgeAsAnExistingNetworkController() {
        let probe = HostNetworkEnvironmentProbe(
            system: InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]]),
            runningBundleIdentifiers: { ["com.nssurge.surge-mac"] }
        )

        XCTAssertTrue(probe.inspect().hasRunningProxyApplication)
        XCTAssertFalse(probe.inspect().mayTakeOverNetwork)
    }

    func testExistingProxyApplicationRefusesTakeover() async throws {
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]])
        let coordinator = SystemProxyCoordinator(
            system: system,
            recoveryStore: InMemoryRecoveryStore(),
            portProbe: TogglePortProbe(available: true),
            environment: FixedHostEnvironment(proxyConfigured: false, proxyApplicationRunning: true),
            safetyMode: .authorizedNetworkTest
        )
        await XCTAssertThrowsErrorAsync(try await coordinator.enableSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .existingNetworkController)
        }
        XCTAssertEqual(system.writeCount, 0)
    }

    func testRecoveryRequiresTargetOwnedSnapshotAndUnmodifiedSettings() async throws {
        let original = ["HTTPEnable": SystemProxyValue.integer(0)]
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": original])
        let store = InMemoryRecoveryStore()
        let coordinator = testCoordinator(system: system, store: store, probe: TogglePortProbe(available: true))
        _ = try await coordinator.enableSystemProxy()
        system.forceSettings(["HTTPEnable": .integer(0)], for: "service-a")
        await XCTAssertThrowsErrorAsync(try await coordinator.recoverSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .externalModificationConflict)
        }
        XCTAssertEqual(try system.proxySettings(for: "service-a"), ["HTTPEnable": .integer(0)])
        XCTAssertNotNil(try store.load())
        let foreign = SystemProxyRecoveryRecord(owner: "foreign", snapshots: [], writtenSettings: [:])
        try store.save(foreign)
        await XCTAssertThrowsErrorAsync(try await coordinator.recoverSystemProxy()) { error in
            XCTAssertEqual(error as? SystemProxyError, .invalidSnapshotOwner)
        }
        XCTAssertEqual(try store.load(), foreign)
    }

    func testNoSnapshotDisablesRecovery() async throws {
        let coordinator = testCoordinator(
            system: InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]]),
            store: InMemoryRecoveryStore(),
            probe: TogglePortProbe(available: true)
        )
        let status = await coordinator.querySystemProxyStatus()
        XCTAssertFalse(status.hasRecoverySnapshot)
    }
    func testLifecycleStateTransitions() throws {
        XCTAssertEqual(try BackendLifecycleState.begin(.start, from: .stopped), .starting)
        XCTAssertEqual(try BackendLifecycleState.begin(.stop, from: .running), .stopping)
        XCTAssertThrowsError(try BackendLifecycleState.begin(.stop, from: .stopped)) { error in
            XCTAssertEqual(error as? BackendError, .invalidLifecycleTransition)
        }
    }

    func testServiceRegistrationAndXPCStatusAreIndependent() {
        XCTAssertEqual(ServiceConnectionAssessment.xpcState(registration: .requiresApproval, xpcReachable: false), .unknown)
        XCTAssertEqual(ServiceConnectionAssessment.xpcState(registration: .enabled, xpcReachable: false), .unavailable)
        XCTAssertEqual(ServiceConnectionAssessment.xpcState(registration: .enabled, xpcReachable: true), .connected)
    }

    func testProcessWithoutOwnedPortIsNotReportedAsRunning() {
        XCTAssertEqual(EngineRuntimeReadiness.visibleState(processIsOwned: true, portIsListening: false), .stopped)
        XCTAssertEqual(EngineRuntimeReadiness.startupFailure(processStillRunning: true), .enginePortUnavailable)
    }

    func testEngineRuntimeRecordRequiresHighDynamicPort() {
        let lowPort = runtimeRecord(port: 2080)
        let highPort = runtimeRecord(port: 51_234)
        XCTAssertFalse(lowPort.isValid)
        XCTAssertTrue(highPort.isValid)
    }

    func testOwnedRuntimeRejectsUnmatchedProcessEvenWhenPortListens() async {
        let record = runtimeRecord(port: 51_234)
        let ownership = EngineRuntimeOwnership(
            store: FixedEngineRuntimeStore(record: record),
            processInspector: FixedEngineProcessInspector(shouldMatch: false),
            portProbe: FixedEnginePortProbe(listening: true)
        )
        let endpoint = await ownership.ownedEndpoint()
        XCTAssertNil(endpoint)
    }

    func testCrossUIDRuntimeStoreAcceptsOnlyFixedOwnedRuntime() throws {
        let fixture = try CrossUIDRuntimeFixture()
        defer { fixture.remove() }
        let store = UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home)
        XCTAssertEqual(try store.load(), fixture.record)
    }

    func testCrossUIDRuntimeStoreRejectsWrongUID() throws {
        let fixture = try CrossUIDRuntimeFixture()
        defer { fixture.remove() }
        let store = UserEngineRuntimeStore(uid: geteuid() &+ 1, homeDirectory: fixture.home)
        XCTAssertThrowsError(try store.load())
    }

    func testServicePeerAuthorizationRejectsRootAndUnrelatedUser() {
        XCTAssertTrue(TargetServicePeerAuthorization.allows(peerUID: 501, consoleUID: 501))
        XCTAssertFalse(TargetServicePeerAuthorization.allows(peerUID: 0, consoleUID: 0))
        XCTAssertFalse(TargetServicePeerAuthorization.allows(peerUID: 502, consoleUID: 501))
    }

    func testCrossUIDRuntimeStoreRejectsWrongExecutableAndArbitraryPath() throws {
        let fixture = try CrossUIDRuntimeFixture(executablePath: "/private/etc/hosts")
        defer { fixture.remove() }
        let store = UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home)
        XCTAssertThrowsError(try store.load())
    }

    func testCrossUIDRuntimeStoreRejectsSymlinkedRecord() throws {
        let fixture = try CrossUIDRuntimeFixture()
        defer { fixture.remove() }
        let external = fixture.home.appending(path: "external.json")
        try FileManager.default.moveItem(at: fixture.recordURL, to: external)
        try FileManager.default.createSymbolicLink(at: fixture.recordURL, withDestinationURL: external)
        let store = UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home)
        XCTAssertThrowsError(try store.load())
    }

    func testCrossUIDRuntimeStoreIsReadOnly() throws {
        let fixture = try CrossUIDRuntimeFixture()
        defer { fixture.remove() }
        let store = UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home)
        XCTAssertThrowsError(try store.save(fixture.record))
        XCTAssertThrowsError(try store.clear())
    }

    func testCrossUIDOwnershipRejectsWrongPID() async throws {
        let fixture = try CrossUIDRuntimeFixture(pid: Int32.max)
        defer { fixture.remove() }
        let ownership = EngineRuntimeOwnership(
            store: UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home),
            processInspector: FixedEngineProcessInspector(shouldMatch: true),
            portProbe: FixedEnginePortProbe(listening: true)
        )
        guard case .processExited = try await ownership.recordDisposition() else {
            return XCTFail("A missing PID must not produce an owned endpoint")
        }
    }

    func testCrossUIDOwnershipRejectsWrongExecutableProof() async throws {
        let fixture = try CrossUIDRuntimeFixture(pid: getpid())
        defer { fixture.remove() }
        let ownership = EngineRuntimeOwnership(
            store: UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home),
            processInspector: FixedEngineProcessInspector(shouldMatch: false),
            portProbe: FixedEnginePortProbe(listening: true)
        )
        guard case .liveUnproven = try await ownership.recordDisposition() else {
            return XCTFail("An executable mismatch must remain live but unproven")
        }
    }

    func testCrossUIDOwnershipRejectsWrongSHA() async throws {
        let fixture = try CrossUIDRuntimeFixture(pid: getpid(), executableFingerprint: "wrong")
        defer { fixture.remove() }
        let ownership = EngineRuntimeOwnership(
            store: UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home),
            processInspector: FixedEngineProcessInspector(shouldMatch: true),
            portProbe: FixedEnginePortProbe(listening: true)
        )
        guard case .liveUnproven = try await ownership.recordDisposition() else {
            return XCTFail("A fingerprint mismatch must remain live but unproven")
        }
    }

    func testCrossUIDOwnershipRejectsMissingListener() async throws {
        let fixture = try CrossUIDRuntimeFixture(pid: getpid())
        defer { fixture.remove() }
        let ownership = EngineRuntimeOwnership(
            store: UserEngineRuntimeStore(uid: geteuid(), homeDirectory: fixture.home),
            processInspector: FixedEngineProcessInspector(shouldMatch: true),
            portProbe: FixedEnginePortProbe(listening: false)
        )
        guard case .liveUnproven = try await ownership.recordDisposition() else {
            return XCTFail("A missing listener must remain live but unproven")
        }
    }

    func testDynamicPortSelectorReturnsHighPort() throws {
        XCTAssertGreaterThanOrEqual(try DynamicHighLocalPortSelector().selectAvailablePort(), LocalEngineEndpoint.minimumDynamicPort)
    }

    func testEditedProfileRequiresExplicitRestart() {
        let id = UUID()
        let original = Data("{\"inbounds\":[]}".utf8)
        let record = EngineRuntimeRecord(
            pid: 42, executablePath: "/tmp/target-sing-box", executableFingerprint: "identity",
            endpoint: LocalEngineEndpoint(port: 51_234), profileID: id, profileRevision: 1,
            sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(original),
            configurationFingerprint: "runtime", startedAt: Date(), runtimeConfigurationID: UUID()
        )
        let profile = Profile(id: id, name: "Edited", subscription: nil, createdAt: Date(), updatedAt: Date(), validation: .notChecked, validRevision: 2)
        let selected = ProfileConfigurationVersion(profile: profile, revision: 2, data: Data("{\"inbounds\":[{}]}".utf8))
        XCTAssertTrue(EngineRuntimeProfileState.requiresRestart(record: record, selected: selected))
    }

    func testFailedLaunchCleansTemporaryConfigurationAndRuntimeRecord() async throws {
        let root = try temporaryDirectory()
        let executable = root.appending(path: "sing-box")
        let script = "#!/bin/sh\nif [ \"$1\" = \"version\" ]; then echo 'sing-box version test'; exit 0; fi\nif [ \"$1\" = \"check\" ]; then exit 1; fi\nexit 1\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let store = ProfileStore(rootDirectory: root.appending(path: "Profiles"), checker: FixedConfigurationChecker(), keyProvider: TestProfileKeyProvider())
        _ = try store.create(name: "Failure")
        let backend = SingBoxBackend(profileStore: store, engineDirectory: root, executableURL: executable)
        do {
            _ = try await backend.startEngine()
            XCTFail("Expected configuration check failure")
        } catch let error as BackendError {
            XCTAssertEqual(error, .configurationCheckFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "runtime").path))
    }

    func testSingBoxStatusPropagatesSelectedValidProfileReadiness() async throws {
        let root = try temporaryDirectory()
        let executable = root.appending(path: "sing-box")
        let script = "#!/bin/sh\nif [ \"$1\" = \"version\" ]; then echo 'sing-box version test'; exit 0; fi\nexit 1\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let store = ProfileStore(
            rootDirectory: root.appending(path: "Profiles"),
            checker: FixedConfigurationChecker(),
            keyProvider: TestProfileKeyProvider()
        )
        let ownership = EngineRuntimeOwnership(store: FileEngineRuntimeStore(directory: root.appending(path: "Ownership")))
        let backend = SingBoxBackend(
            runtimeOwnership: ownership,
            profileStore: store,
            engineDirectory: root,
            executableURL: executable
        )

        let emptyStatus = try await backend.queryStatus()
        XCTAssertFalse(emptyStatus.hasSelectedValidProfile)
        let profile = try store.create(name: "Selected")
        try store.select(profile.id)
        let selectedStatus = try await backend.queryStatus()
        XCTAssertTrue(selectedStatus.hasSelectedValidProfile)
    }

    func testBackendStatusDecodingMissingProfileReadinessDefaultsToFalse() throws {
        let status = try XPCPayloadCodec.decodeStatus(statusPayload(removing: "hasSelectedValidProfile"))

        XCTAssertEqual(status.serviceInstallation, .enabled)
        XCTAssertEqual(status.engineState, .stopped)
        XCTAssertEqual(status.engineInstallation, .installed)
        XCTAssertFalse(status.restartRequired)
        XCTAssertFalse(status.hasSelectedValidProfile)
    }

    func testBackendStatusDecodingFalseProfileReadiness() throws {
        let status = try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "hasSelectedValidProfile", with: false))

        XCTAssertFalse(status.hasSelectedValidProfile)
    }

    func testBackendStatusDecodingTrueProfileReadiness() throws {
        let status = try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "hasSelectedValidProfile", with: true))

        XCTAssertTrue(status.hasSelectedValidProfile)
    }

    func testBackendStatusDecodingRejectsEmptyPayload() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(Data("{}".utf8)))
    }

    func testBackendStatusDecodingRejectsMissingServiceInstallation() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(removing: "serviceInstallation")))
    }

    func testBackendStatusDecodingRejectsMissingEngineState() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(removing: "engineState")))
    }

    func testBackendStatusDecodingRejectsMissingEngineInstallation() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(removing: "engineInstallation")))
    }

    func testBackendStatusDecodingRejectsMissingRestartRequired() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(removing: "restartRequired")))
    }

    func testBackendStatusDecodingRejectsNullProfileReadiness() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "hasSelectedValidProfile", with: NSNull())))
    }

    func testBackendStatusDecodingRejectsStringProfileReadiness() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "hasSelectedValidProfile", with: "true")))
    }

    func testBackendStatusDecodingRejectsNumberProfileReadiness() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "hasSelectedValidProfile", with: 1)))
    }

    func testBackendStatusDecodingRejectsUnknownExistingEnumValue() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "engineState", with: "unknown")))
    }

    func testBackendStatusDecodingRejectsMalformedOptionalField() {
        XCTAssertThrowsError(try XPCPayloadCodec.decodeStatus(statusPayload(replacing: "enginePort", with: "invalid")))
    }

    func testServiceRegistrationRejectsDerivedDataBundlePath() {
        let temporaryApp = URL(fileURLWithPath: "/tmp/DerivedData/Target/Build/Products/Release/Target.app")
        XCTAssertFalse(TargetServiceBundleLocation.isStable(temporaryApp))
    }

    func testServiceV2UsesFreshMachServiceAndAppleRecommendedExecutableLayout() throws {
        XCTAssertEqual(TargetServiceIdentifiers.machService, "com.jason312928.Target.TargetService.v2")
        XCTAssertEqual(TargetServiceIdentifiers.launchDaemonPlistName, "com.jason312928.Target.TargetService.v2.plist")
        XCTAssertEqual(TargetServiceIdentifiers.executableBundlePath, "Contents/MacOS/TargetService")
        XCTAssertNotEqual(TargetServiceIdentifiers.machService, TargetServiceIdentifiers.legacyMachService)
        XCTAssertNotEqual(
            TargetServiceIdentifiers.launchDaemonPlistName,
            TargetServiceIdentifiers.legacyLaunchDaemonPlistName
        )

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let launchDaemons = root.appending(path: "TargetService")
        let current = try XCTUnwrap(
            NSDictionary(
                contentsOf: launchDaemons.appending(path: TargetServiceIdentifiers.launchDaemonPlistName)
            ) as? [String: Any]
        )
        XCTAssertEqual(current["Label"] as? String, TargetServiceIdentifiers.machService)
        XCTAssertEqual(current["BundleProgram"] as? String, TargetServiceIdentifiers.executableBundlePath)
        XCTAssertEqual(
            (current["MachServices"] as? [String: Bool])?[TargetServiceIdentifiers.machService],
            true
        )

        let legacy = try XCTUnwrap(
            NSDictionary(
                contentsOf: launchDaemons.appending(path: TargetServiceIdentifiers.legacyLaunchDaemonPlistName)
            ) as? [String: Any]
        )
        XCTAssertEqual(legacy["Label"] as? String, TargetServiceIdentifiers.legacyMachService)
        XCTAssertEqual(legacy["BundleProgram"] as? String, TargetServiceIdentifiers.executableBundlePath)
    }

    func testProjectEmbedsServiceInMacOSAndBothMigrationPlistsInLaunchDaemons() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appending(path: "Target.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("dstPath = \"\"; dstSubfolderSpec = 6; files = (A1000000000000000000000E"))
        XCTAssertTrue(project.contains("com.jason312928.Target.TargetService.v2.plist in Embed LaunchDaemon Definition"))
        XCTAssertFalse(project.contains("dstPath = \"Contents/Library/HelperTools\""))
    }

    func testMockBackendStartsAndStopsWhenServiceIsInstalled() async throws {
        let backend = MockBackend(initialStatus: BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: true))

        let runningStatus = try await backend.startEngine()
        XCTAssertEqual(runningStatus.engineState, .running)

        let stoppedStatus = try await backend.stopEngine()
        XCTAssertEqual(stoppedStatus.engineState, .stopped)
    }

    private func statusPayload(
        removing keyToRemove: String? = nil,
        replacing keyToReplace: String? = nil,
        with replacement: Any? = nil
    ) -> Data {
        var fields: [String: Any] = [
            "serviceInstallation": "enabled",
            "engineState": "stopped",
            "engineInstallation": "installed",
            "restartRequired": false,
            "hasSelectedValidProfile": false,
            "enginePort": 51_234
        ]
        if let keyToRemove {
            fields.removeValue(forKey: keyToRemove)
        }
        if let keyToReplace, let replacement {
            fields[keyToReplace] = replacement
        }
        return try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    func testMockBackendReportsServiceNotInstalled() async throws {
        let backend = MockBackend()

        do {
            _ = try await backend.startEngine()
            XCTFail("Expected a service-not-installed error")
        } catch let error as BackendError {
            XCTAssertEqual(error, .serviceNotInstalled)
        }
    }

    func testHostNetworkBuildPolicyMatrix() {
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode(
            buildChannel: .local, isDebugBuild: true, hasUTMValidationCondition: false
        ), .safe)
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode(
            buildChannel: .local, isDebugBuild: false, hasUTMValidationCondition: false
        ), .safe)
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode(
            buildChannel: TargetBuildChannel(bundleValue: "unknown"),
            isDebugBuild: false,
            hasUTMValidationCondition: false
        ), .safe)
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode(
            buildChannel: .developmentPreview, isDebugBuild: false, hasUTMValidationCondition: false
        ), .normalUser)
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode(
            buildChannel: .stable, isDebugBuild: false, hasUTMValidationCondition: false
        ), .normalUser)
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode(
            buildChannel: .local, isDebugBuild: true, hasUTMValidationCondition: true
        ), .authorizedNetworkTest)
    }

    func testCurrentLocalBuildChannelIsHostSafeInDebugAndReleaseTests() {
        let model = BackendLifecycleModel(backend: MockBackend())
#if DEBUG && TARGET_UTM_VALIDATION
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode, .authorizedNetworkTest)
        XCTAssertFalse(TargetValidationPolicy.isHostSafeMode)
        XCTAssertFalse(model.isHostSafeMode)
#else
        XCTAssertEqual(TargetValidationPolicy.buildChannel, .local)
        XCTAssertEqual(TargetValidationPolicy.hostNetworkSafetyMode, .safe)
        XCTAssertTrue(TargetValidationPolicy.isHostSafeMode)
        XCTAssertTrue(model.isHostSafeMode)
#endif
    }

    func testNormalUserModeWritesOnlyAfterExplicitEnableAction() async throws {
        let system = InMemorySystemProxySystem(serviceIDs: ["service-a"], settings: ["service-a": [:]])
        let coordinator = testCoordinator(
            system: system,
            store: InMemoryRecoveryStore(),
            probe: TogglePortProbe(available: true),
            safetyMode: .normalUser
        )

        XCTAssertEqual(system.writeCount, 0)
        _ = try await coordinator.enableSystemProxy()
        XCTAssertEqual(system.writeCount, 1)
    }

    func testStartupRefreshSettlesWhenEnabledServicePingNeverReplies() async throws {
        let service = FakeTargetService(pingDelay: nil)
        let connection = FakeTargetServiceConnection(service: service)
        let client = TargetServiceXPCClient(
            timeouts: .init(read: 0.03, mutation: 0.05),
            connectionFactory: { connection }
        )
        let proxyOperations = StartupSystemProxyOperation()
        let backendStatus = BackendStatus(
            serviceInstallation: .enabled,
            engineState: .stopped,
            engineInstallation: .installed,
            hasSelectedValidProfile: true
        )
        let model = BackendLifecycleModel(
            backend: MockBackend(initialStatus: backendStatus),
            systemProxyClient: client,
            systemProxyOperations: proxyOperations,
            hostNetworkSafetyMode: .normalUser,
            serviceRegistrationStatusProvider: { .enabled }
        )

        model.refresh()
        try await waitUntil(timeout: .seconds(1)) { !model.isBusy }

        XCTAssertEqual(model.xpcState, .unavailable)
        XCTAssertTrue(model.canStart)
        let startupEnableCount = await proxyOperations.enableCount
        XCTAssertEqual(startupEnableCount, 0)
        XCTAssertGreaterThanOrEqual(connection.invalidationCount, 1)
    }

    func testXPCReplyBeforeTimeoutSucceeds() async throws {
        let service = FakeTargetService(pingDelay: 0, proxyDelay: 0)
        let connection = FakeTargetServiceConnection(service: service)
        let client = makeXPCClient(connection: connection)

        let ping = try await client.ping()
        let proxyStatus = try await client.querySystemProxyStatus()
        XCTAssertEqual(ping, "target-service")
        XCTAssertEqual(proxyStatus, .disabled)
    }

    func testXPCReadWithoutReplyFailsWithinBoundAndInvalidatesConnection() async {
        let connection = FakeTargetServiceConnection(service: FakeTargetService(pingDelay: nil))
        let client = makeXPCClient(connection: connection)
        let clock = ContinuousClock()
        let start = clock.now

        await XCTAssertThrowsErrorAsync(try await client.ping()) { error in
            XCTAssertEqual(error as? BackendError, .serviceUnavailable)
        }

        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        XCTAssertGreaterThanOrEqual(connection.invalidationCount, 1)
    }

    func testXPCStatusWithoutReplyFailsWithinBound() async {
        let connection = FakeTargetServiceConnection(
            service: FakeTargetService(statusDelay: nil)
        )
        let client = makeXPCClient(connection: connection)

        await XCTAssertThrowsErrorAsync(try await client.queryStatus()) { error in
            XCTAssertEqual(error as? BackendError, .serviceUnavailable)
        }
        XCTAssertGreaterThanOrEqual(connection.invalidationCount, 1)
    }

    func testXPCTimeoutThenLateReplyIsIgnored() async throws {
        let service = FakeTargetService(pingDelay: 0.08)
        let connection = FakeTargetServiceConnection(service: service)
        let client = makeXPCClient(connection: connection)

        await XCTAssertThrowsErrorAsync(try await client.ping()) { error in
            XCTAssertEqual(error as? BackendError, .serviceUnavailable)
        }
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(service.pingReplyCount, 1)
        XCTAssertGreaterThanOrEqual(connection.invalidationCount, 1)
    }

    func testXPCConnectionInvalidationFailsPendingCall() async {
        let connection = FakeTargetServiceConnection(
            service: FakeTargetService(pingDelay: nil),
            invalidateOnResume: true
        )
        let client = makeXPCClient(connection: connection)

        await XCTAssertThrowsErrorAsync(try await client.ping()) { error in
            XCTAssertEqual(error as? BackendError, .serviceUnavailable)
        }
    }

    func testAllSystemProxyCallsTimeoutAndSettle() async {
        let connection = FakeTargetServiceConnection(service: FakeTargetService(proxyDelay: nil))
        let client = makeXPCClient(connection: connection)
        let actions: [() async throws -> SystemProxyStatus] = [
            { try await client.querySystemProxyStatus() },
            { try await client.enableSystemProxy() },
            { try await client.disableSystemProxy() },
            { try await client.recoverSystemProxy() }
        ]

        for action in actions {
            await XCTAssertThrowsErrorAsync(try await action()) { error in
                XCTAssertEqual(error as? BackendError, .serviceUnavailable)
            }
        }
        XCTAssertGreaterThanOrEqual(connection.invalidationCount, actions.count)
    }

    func testModelPresentsStartErrorWhenDefaultServiceIsMissing() async throws {
        let model = BackendLifecycleModel(backend: MockBackend(initialStatus: BackendStatus(serviceInstallation: .notRegistered, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: true)))
        model.refresh()
        try await waitUntil { !model.isBusy }
        model.start()

        try await waitUntil { model.error == .serviceNotInstalled }
        XCTAssertEqual(model.status.serviceInstallation, .notRegistered)
        XCTAssertEqual(model.status.engineState, .stopped)
        XCTAssertEqual(model.lifecycleState, .failed(.serviceNotInstalled))
    }

    func testCanStartIsFalseWhenTrustedRunningStatusHasFailedLifecycle() async throws {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .running, engineInstallation: .installed, hasSelectedValidProfile: true)
        let model = BackendLifecycleModel(backend: ErroringBackend(status: status))
        model.refresh()
        try await waitUntil { !model.isBusy }
        model.validateConfiguration()
        try await waitUntil { model.lifecycleState == .failed(.serviceUnavailable) }

        XCTAssertEqual(model.status.engineState, .running)
        XCTAssertFalse(model.canStart)
        XCTAssertTrue(model.canStop)
    }

    func testCanStartIsFalseWithoutSelectedValidProfile() async throws {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: false)
        let model = BackendLifecycleModel(backend: MockBackend(initialStatus: status))
        model.refresh()
        try await waitUntil { !model.isBusy }

        XCTAssertFalse(model.canStart)
    }

    func testCanStartIsFalseWhenEngineIsNotInstalled() async throws {
        let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped, engineInstallation: .notInstalled, hasSelectedValidProfile: true)
        let model = BackendLifecycleModel(backend: MockBackend(initialStatus: status))
        model.refresh()
        try await waitUntil { !model.isBusy }

        XCTAssertFalse(model.canStart)
    }

    func testSuccessfulRefreshClearsOldBackendError() async throws {
        let backend = MockBackend(initialStatus: BackendStatus(serviceInstallation: .enabled, engineState: .stopped))
        let model = BackendLifecycleModel(backend: backend)
        model.stop()
        XCTAssertEqual(model.error, .invalidLifecycleTransition)
        model.refresh()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.error)
    }

    func testConfigurationRequestValidationRejectsUnsupportedFieldsAndPaths() throws {
        let valid = XPCConfigurationRequest(profileName: "Default Profile")
        XCTAssertEqual(try XPCConfigurationRequest.decodeAndValidate(valid.encoded()), valid)

        let pathLikeRequest = XPCConfigurationRequest(profileName: "../Library/LaunchDaemons")
        XCTAssertThrowsError(try pathLikeRequest.validated()) { error in
            XCTAssertEqual(error as? BackendError, .invalidConfiguration(.invalidProfileName))
        }

        let unexpectedField = Data(#"{"version":1,"profileName":"Default","command":"sh"}"#.utf8)
        XCTAssertThrowsError(try XPCConfigurationRequest.decodeAndValidate(unexpectedField)) { error in
            XCTAssertEqual(error as? BackendError, .invalidConfiguration(.malformedRequest))
        }
    }

    func testEngineLogRedactorRemovesIPv4Addresses() {
        let result = String(decoding: EngineLogRedactor.redact(Data("dial 203.0.113.42 [2001:db8::1] /Users/example/secret".utf8)), as: UTF8.self)
        XCTAssertFalse(result.contains("203.0.113.42"))
        XCTAssertFalse(result.contains("2001:db8"))
        XCTAssertFalse(result.contains("/Users/example"))
    }

    func testPrivilegedServicePingAndStatusWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["RUN_PRIVILEGED_SERVICE_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_PRIVILEGED_SERVICE_INTEGRATION_TESTS=1 after approving the service.")
        }

        let client = TargetServiceXPCClient()
        let ping = try await client.ping()
        XCTAssertEqual(ping, "target-service")

        let status = try await client.queryStatus()
        XCTAssertEqual(status.serviceInstallation, .enabled)
        XCTAssertEqual(status.engineState, .stopped)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func testCoordinator(
        system: InMemorySystemProxySystem,
        store: InMemoryRecoveryStore,
        probe: TogglePortProbe,
        safetyMode: HostNetworkSafetyMode = .authorizedNetworkTest
    ) -> SystemProxyCoordinator {
        SystemProxyCoordinator(
            system: system,
            recoveryStore: store,
            portProbe: probe,
            environment: FixedHostEnvironment(proxyConfigured: false, proxyApplicationRunning: false),
            safetyMode: safetyMode,
            endpointProvider: { LocalEngineEndpoint(port: 51_234) }
        )
    }

    private func makeXPCClient(connection: FakeTargetServiceConnection) -> TargetServiceXPCClient {
        TargetServiceXPCClient(
            timeouts: .init(read: 0.03, mutation: 0.04),
            connectionFactory: { connection }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func runtimeRecord(port: UInt16) -> EngineRuntimeRecord {
        EngineRuntimeRecord(
            pid: 42,
            executablePath: "/tmp/target-sing-box",
            executableFingerprint: "test-identity",
            endpoint: LocalEngineEndpoint(port: port),
            profileID: UUID(),
            profileRevision: 1,
            sourceConfigurationFingerprint: "source",
            configurationFingerprint: "runtime",
            startedAt: Date(),
            runtimeConfigurationID: UUID()
        )
    }
}

private final class FixedEngineRuntimeStore: EngineRuntimeStoring, @unchecked Sendable {
    private let record: EngineRuntimeRecord?

    init(record: EngineRuntimeRecord?) {
        self.record = record
    }

    func load() throws -> EngineRuntimeRecord? { record }
    func save(_ record: EngineRuntimeRecord) throws { XCTFail("Unexpected runtime record write") }
    func clear() throws { XCTFail("Unexpected runtime record removal") }
}

private final class CrossUIDRuntimeFixture {
    let home: URL
    let recordURL: URL
    let record: EngineRuntimeRecord

    init(
        pid: Int32 = 42,
        executablePath: String? = nil,
        executableFingerprint: String? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "TargetCrossUID-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = home
            .appending(path: "Library/Application Support/Target/sing-box", directoryHint: .isDirectory)
        let executable = runtime.appending(path: "bin/sing-box")
        recordURL = runtime.appending(path: "runtime.json")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let fingerprint: String
        if let executableFingerprint {
            fingerprint = executableFingerprint
        } else {
            fingerprint = try EngineExecutableFingerprint.sha256(of: executable)
        }
        record = EngineRuntimeRecord(
            pid: pid,
            executablePath: executablePath ?? executable.path,
            executableFingerprint: fingerprint,
            endpoint: LocalEngineEndpoint(port: 51_234),
            profileID: UUID(),
            profileRevision: 1,
            sourceConfigurationFingerprint: "source",
            configurationFingerprint: "runtime",
            startedAt: Date(),
            runtimeConfigurationID: UUID()
        )
        try JSONEncoder().encode(record).write(to: recordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private struct FixedEngineProcessInspector: EngineProcessInspecting {
    let shouldMatch: Bool

    func matches(pid: Int32, executablePath: String) -> Bool { shouldMatch }
}

private struct FixedEnginePortProbe: LocalEnginePortProbing {
    let listening: Bool

    func isListening(on port: UInt16) async -> Bool { listening }
}

private struct FixedConfigurationChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}

private actor ErroringBackend: EngineBackend {
    private let status: BackendStatus

    init(status: BackendStatus) {
        self.status = status
    }

    func queryStatus() async throws -> BackendStatus { status }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws { throw BackendError.serviceUnavailable }
    func startEngine() async throws -> BackendStatus { throw BackendError.serviceUnavailable }
    func stopEngine() async throws -> BackendStatus { throw BackendError.serviceUnavailable }
}

private final class InMemorySystemProxySystem: SystemProxySystemManaging, @unchecked Sendable {
    private let serviceIDs: [String]
    private var settings: [String: [String: SystemProxyValue]]
    private var failOnWrite: Int?
    private(set) var writeCount = 0

    init(serviceIDs: [String], settings: [String: [String: SystemProxyValue]], failOnWrite: Int? = nil) {
        self.serviceIDs = serviceIDs
        self.settings = settings
        self.failOnWrite = failOnWrite
    }

    func activeServiceIDs() throws -> [String] { serviceIDs }

    func proxySettings(for serviceID: String) throws -> [String: SystemProxyValue] {
        guard let settings = settings[serviceID] else { throw SystemProxyError.noActiveNetworkService }
        return settings
    }

    func setProxySettings(_ settings: [String: SystemProxyValue], for serviceID: String) throws {
        writeCount += 1
        if writeCount == failOnWrite {
            failOnWrite = nil
            throw SystemProxyError.applyFailed
        }
        self.settings[serviceID] = settings
    }

    func forceSettings(_ settings: [String: SystemProxyValue], for serviceID: String) {
        self.settings[serviceID] = settings
    }
}

private final class InMemoryRecoveryStore: SystemProxyRecoveryStoring, @unchecked Sendable {
    private var record: SystemProxyRecoveryRecord?

    func load() throws -> SystemProxyRecoveryRecord? { record }
    func save(_ record: SystemProxyRecoveryRecord) throws { self.record = record }
    func clear() throws { record = nil }
}

private struct ThrowingRecoveryStore: SystemProxyRecoveryStoring {
    func load() throws -> SystemProxyRecoveryRecord? { throw SystemProxyError.snapshotFailed }
    func save(_ record: SystemProxyRecoveryRecord) throws {}
    func clear() throws {}
}

private actor TogglePortProbe: LocalProxyProbing {
    private var available: Bool

    init(available: Bool) { self.available = available }
    func isAvailable() async -> Bool { available }
    func setAvailable(_ available: Bool) { self.available = available }
}

private struct FixedHostEnvironment: HostNetworkEnvironmentChecking {
    let proxyConfigured: Bool
    let proxyApplicationRunning: Bool

    func inspect() -> HostNetworkEnvironmentStatus {
        HostNetworkEnvironmentStatus(
            hasConfiguredSystemProxy: proxyConfigured,
            hasRunningProxyApplication: proxyApplicationRunning
        )
    }
}

private actor StartupSystemProxyOperation: TargetSystemProxyOperating {
    private(set) var enableCount = 0

    func queryStatus() async throws -> SystemProxyStatus { .disabled }
    func enable() async throws -> SystemProxyStatus {
        enableCount += 1
        return .disabled
    }
    func disable() async throws -> SystemProxyStatus { .disabled }
    func recover() async throws -> SystemProxyStatus { .disabled }
}

private final class FakeTargetServiceConnection: TargetServiceXPCConnecting, @unchecked Sendable {
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?

    private let service: FakeTargetService
    private let invalidateOnResume: Bool
    private let lock = NSLock()
    private var storedInvalidationCount = 0

    init(service: FakeTargetService, invalidateOnResume: Bool = false) {
        self.service = service
        self.invalidateOnResume = invalidateOnResume
    }

    var invalidationCount: Int {
        lock.withLock { storedInvalidationCount }
    }

    func resume() {
        if invalidateOnResume {
            invalidationHandler?()
        }
    }

    func invalidate() {
        lock.withLock { storedInvalidationCount += 1 }
    }

    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        service
    }
}

private final class FakeTargetService: NSObject, TargetServiceXPCProtocol, @unchecked Sendable {
    private let pingDelay: TimeInterval?
    private let statusDelay: TimeInterval?
    private let proxyDelay: TimeInterval?
    private let lock = NSLock()
    private var storedPingReplyCount = 0

    init(
        pingDelay: TimeInterval? = 0,
        statusDelay: TimeInterval? = 0,
        proxyDelay: TimeInterval? = 0
    ) {
        self.pingDelay = pingDelay
        self.statusDelay = statusDelay
        self.proxyDelay = proxyDelay
    }

    var pingReplyCount: Int {
        lock.withLock { storedPingReplyCount }
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        schedule(after: pingDelay) { [self] in
            lock.withLock { storedPingReplyCount += 1 }
            reply("target-service")
        }
    }

    func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        schedule(after: statusDelay) {
            let status = BackendStatus(serviceInstallation: .enabled, engineState: .stopped)
            reply(try? XPCPayloadCodec.encodeStatus(status), nil)
        }
    }

    func validateConfiguration(_ request: Data, withReply reply: @escaping (NSError?) -> Void) {
        reply(nil)
    }

    func startEngine(withReply reply: @escaping (Data?, NSError?) -> Void) {
        queryStatus(withReply: reply)
    }

    func stopEngine(withReply reply: @escaping (Data?, NSError?) -> Void) {
        queryStatus(withReply: reply)
    }

    func querySystemProxyStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        replyWithProxyStatus(after: proxyDelay, reply: reply)
    }

    func enableSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void) {
        replyWithProxyStatus(after: proxyDelay, reply: reply)
    }

    func disableSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void) {
        replyWithProxyStatus(after: proxyDelay, reply: reply)
    }

    func recoverSystemProxy(withReply reply: @escaping (Data?, NSError?) -> Void) {
        replyWithProxyStatus(after: proxyDelay, reply: reply)
    }

    private func replyWithProxyStatus(
        after delay: TimeInterval?,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        schedule(after: delay) {
            reply(try? XPCPayloadCodec.encodeSystemProxyStatus(.disabled), nil)
        }
    }

    private func schedule(after delay: TimeInterval?, action: @escaping () -> Void) {
        guard let delay else { return }
        if delay == 0 {
            action()
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: action)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        handler(error)
    }
}
