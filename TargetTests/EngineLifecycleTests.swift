import CFNetwork
import Darwin
import Foundation
import XCTest
@testable import Target

@MainActor
final class EngineLifecycleTests: XCTestCase {
    func testUnreadableRuntimePolicyEvidenceDoesNotAddRestartForProfileWithoutSelectors() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening)
        do {
            _ = try await fixture.backend.startEngine()
            let record = try XCTUnwrap(fixture.ownership.currentRecord())
            let runtimeURL = fixture.runtimeDirectory.appending(
                path: "\(record.runtimeConfigurationID.uuidString).json"
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: runtimeURL.path
            )

            let status = try await fixture.backend.queryStatus()
            XCTAssertEqual(status.engineState, .running)
            XCTAssertFalse(status.restartRequired)

            _ = try await fixture.backend.stopEngine()
            try await fixture.assertStoppedAndClean()
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testPolicySelectionHotSwitchesVerifiedRunningRuntime() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening)
        do {
            let source = #"{"inbounds":[{"type":"mixed","tag":"local","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"selector","tag":"group","outbounds":["first","second"],"default":"first"},{"type":"direct","tag":"first"},{"type":"block","tag":"second"}],"route":{"final":"group"}}"#
            try fixture.store.save(json: source, for: fixture.profile.id)
            let policy = TargetPolicyOperations(
                profileStore: fixture.store,
                runtimeEvidenceProvider: fixture.backend
            )
            let started = try await fixture.backend.startEngine()
            XCTAssertEqual(started.engineState, .running)
            var catalog = try await policy.read()
            XCTAssertEqual(catalog.selectors[0].runningSelection, "first")
            XCTAssertEqual(catalog.selectors[0].runtimeConvergence, .converged)
            let originalRecord = try XCTUnwrap(fixture.ownership.currentRecord())

            catalog = try await policy.select(selectorTag: "group", outboundTag: "second")
            XCTAssertEqual(fixture.ownership.currentRecord(), originalRecord)
            XCTAssertEqual(catalog.selectors[0].effectiveDesired, "second")
            XCTAssertEqual(catalog.selectors[0].runningSelection, "second")
            XCTAssertEqual(catalog.selectors[0].runtimeConvergence, .converged)
            XCTAssertFalse(catalog.selectors[0].restartRequired)
            let mismatchStatus = try await fixture.backend.queryStatus()
            XCTAssertFalse(mismatchStatus.restartRequired)

            _ = try await fixture.backend.stopEngine()
            _ = try await fixture.backend.startEngine()
            catalog = try await policy.read()
            XCTAssertEqual(catalog.selectors[0].effectiveDesired, "second")
            XCTAssertEqual(catalog.selectors[0].runningSelection, "second")
            XCTAssertEqual(catalog.selectors[0].runtimeConvergence, .converged)
            XCTAssertFalse(catalog.selectors[0].restartRequired)
            let convergedStatus = try await fixture.backend.queryStatus()
            XCTAssertFalse(convergedStatus.restartRequired)

            _ = try await fixture.backend.stopEngine()
            try await fixture.assertStoppedAndClean()
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testRefreshStartRevisionRestartStopAndCleanup() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening)
        do {
            let model = BackendLifecycleModel(backend: fixture.backend)
            model.refresh()
            try await waitUntil { !model.isBusy }
            XCTAssertTrue(model.canStart)

            model.start()
            try await waitUntil { !model.isBusy }
            let started = model.status
            XCTAssertEqual(model.lifecycleState, .running)
            XCTAssertEqual(started.engineState, .running)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(started.enginePort), Int(LocalEngineEndpoint.minimumDynamicPort))
            XCTAssertEqual(started.runningProfileID, fixture.profile.id)
            XCTAssertEqual(started.runningProfileRevision, 1)

            let record = try XCTUnwrap(fixture.ownership.currentRecord())
            XCTAssertEqual(record.executablePath, fixture.executable.resolvingSymlinksInPath().path)
            XCTAssertEqual(record.executableFingerprint, try EngineExecutableFingerprint.sha256(of: fixture.executable))
            XCTAssertEqual(record.profileID, fixture.profile.id)
            XCTAssertEqual(record.profileRevision, 1)
            XCTAssertEqual(record.sourceConfigurationFingerprint, TargetConfigurationFingerprint.sha256(try fixture.store.validVersion(for: fixture.profile.id, revision: 1).data))

            try fixture.store.save(json: SafeExampleConfiguration.json(), for: fixture.profile.id)
            model.refresh()
            try await waitUntil { !model.isBusy }
            XCTAssertTrue(model.status.restartRequired)
            XCTAssertEqual(model.status.runningProfileRevision, 1)

            model.restartWithCurrentProfile()
            try await waitUntil { !model.isBusy }
            XCTAssertEqual(model.lifecycleState, .running)
            XCTAssertEqual(model.status.runningProfileRevision, 2)
            XCTAssertFalse(model.status.restartRequired)

            model.stop()
            try await waitUntil { !model.isBusy }
            XCTAssertEqual(model.lifecycleState, .stopped)
            XCTAssertEqual(model.status.engineState, .stopped)
            try await fixture.assertStoppedAndClean()
            await fixture.removeRoot()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testModelCannotStartWithoutSelectedValidProfile() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening)
        do {
            try fixture.store.select(nil)
            let model = BackendLifecycleModel(backend: fixture.backend)
            model.refresh()
            try await waitUntil { !model.isBusy }
            XCTAssertFalse(model.status.hasSelectedValidProfile)
            XCTAssertFalse(model.canStart)
            model.start()
            XCTAssertFalse(model.isBusy)
            XCTAssertEqual(model.status.engineState, .stopped)
            XCTAssertNil(fixture.ownership.currentRecord())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeDirectory.path))
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testFailedLaunchModesDoNotLeaveOwnershipOrRuntimeConfiguration() async throws {
        for (mode, expected) in [
            (EngineLifecycleFixture.Mode.checkFails, BackendError.configurationCheckFailed),
            (.earlyExit, .enginePortUnavailable),
            (.neverReady, .enginePortUnavailable)
        ] {
            let fixture = try EngineLifecycleFixture(mode: mode, readinessTimeout: .milliseconds(250), forcePortReadiness: false)
            do {
                do {
                    _ = try await fixture.backend.startEngine()
                    XCTFail("Expected \(mode) to fail")
                } catch let error as BackendError {
                    XCTAssertEqual(error, expected)
                }
                try await fixture.assertStoppedAndClean()
                await fixture.removeRoot()
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testExitedOwnedProcessIsPurgedWithoutTouchingProfiles() async throws {
        let fixture = try EngineLifecycleFixture(mode: .exitAfterReady)
        do {
            _ = try await fixture.backend.startEngine()
            // A cold virtualized runner can spend more than two seconds entering
            // Xcode's Python runtime before the fixture's intentional exit.
            try await waitUntil(timeout: .seconds(4)) {
                let status = try? await fixture.backend.queryStatus()
                return status?.engineState == .stopped
            }
            XCTAssertNil(fixture.ownership.currentRecord())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeDirectory.path))
            XCTAssertEqual(try fixture.store.listProfiles().map(\.id), [fixture.profile.id])
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testUnprovenStaleRecordDoesNotTerminateExternalProcess() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening, permissiveOwnershipInspector: false)
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["10"]
        try external.run()
        do {
            let version = try fixture.store.selectedValidVersion()
            let runtimeID = UUID()
            try fixture.ownership.recordLaunchedProcess(
                pid: external.processIdentifier,
                executableURL: fixture.executable,
                port: 51_234,
                profileID: version.profile.id,
                profileRevision: version.revision,
                sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(version.data),
                configurationFingerprint: "test-runtime",
                runtimeConfigurationID: runtimeID
            )
            do {
                _ = try await fixture.backend.stopEngine()
                XCTFail("An unproven record must not be stopped")
            } catch let error as BackendError {
                XCTAssertEqual(error, .invalidLifecycleTransition)
            }
            XCTAssertTrue(external.isRunning)
            XCTAssertNotNil(fixture.ownership.currentRecord())
            external.terminate()
            try await waitUntil { !external.isRunning }
            _ = try await fixture.backend.queryStatus()
            XCTAssertNil(fixture.ownership.currentRecord())
            await fixture.removeRoot()
        } catch {
            if external.isRunning { external.terminate() }
            await fixture.cleanup()
            throw error
        }
    }

    func testLiveUnprovenRecordBlocksStartAndPreservesRecoveryEvidence() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening, permissiveOwnershipInspector: false, forcePortReadiness: false)
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["10"]
        try external.run()
        do {
            let version = try fixture.store.selectedValidVersion()
            let runtimeID = UUID()
            let runtimeConfiguration = try RuntimeConfigurationStore(directory: fixture.runtimeDirectory)
                .write(Data("recovery evidence".utf8), id: runtimeID)
            try fixture.ownership.recordLaunchedProcess(
                pid: external.processIdentifier,
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                port: 51_234,
                profileID: version.profile.id,
                profileRevision: version.revision,
                sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(version.data),
                configurationFingerprint: "test-runtime",
                runtimeConfigurationID: runtimeID
            )
            let recordURL = fixture.root.appending(path: "Ownership/runtime.json")
            let recordBeforeStart = try Data(contentsOf: recordURL)
            let runtimeConfigurationBeforeStart = try Data(contentsOf: runtimeConfiguration.url)

            XCTAssertTrue(external.isRunning)
            let stopped = try await fixture.backend.queryStatus()
            XCTAssertEqual(stopped.engineState, .stopped)
            XCTAssertNotNil(fixture.ownership.currentRecord())

            do {
                _ = try await fixture.backend.startEngine()
                XCTFail("A live record without listener proof must block start")
            } catch let error as BackendError {
                XCTAssertEqual(error, .invalidLifecycleTransition)
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.candidateLaunchMarker.path))
            XCTAssertTrue(external.isRunning)
            XCTAssertEqual(try Data(contentsOf: recordURL), recordBeforeStart)
            XCTAssertEqual(try Data(contentsOf: runtimeConfiguration.url), runtimeConfigurationBeforeStart)

            external.terminate()
            try await waitUntil { !external.isRunning }
            _ = try await fixture.backend.queryStatus()
            XCTAssertNil(fixture.ownership.currentRecord())
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeConfiguration.url.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeDirectory.path))
            await fixture.removeRoot()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        } catch {
            if external.isRunning {
                external.terminate()
                try? await waitUntil { !external.isRunning }
            }
            await fixture.cleanup()
            throw error
        }
    }

    func testCancelledRefreshLeavesModelSettled() async throws {
        let status = BackendStatus(serviceInstallation: .notRegistered, engineState: .stopped, engineInstallation: .installed, hasSelectedValidProfile: true)
        let model = BackendLifecycleModel(backend: DelayedQueryBackend(status: status))
        model.refresh()
        try await waitUntil { model.isBusy }
        model.cancelCurrentOperation()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.error, .operationCancelled)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.lifecycleState, .stopped)
    }

    func testCancelledRefreshWithUnresponsiveReconciliationLeavesModelNotBusy() async throws {
        let backend = ReconciliationTimeoutBackend()
        let model = BackendLifecycleModel(backend: backend)
        model.refresh()
        try await waitUntilAsync { await backend.didBeginFirstQuery() }
        model.cancelCurrentOperation()
        try await waitUntil(timeout: .seconds(1)) { !model.isBusy }
        XCTAssertEqual(model.error, .operationCancelled)
        XCTAssertEqual(model.lifecycleState, .failed(.operationCancelled))
    }

    func testCancelledStartCleansUncommittedProcessAndReconcilesStoppedState() async throws {
        let fixture = try EngineLifecycleFixture(mode: .neverReady, readinessTimeout: .seconds(2))
        do {
            let model = BackendLifecycleModel(backend: fixture.backend)
            model.refresh()
            try await waitUntil { !model.isBusy }
            model.start()
            try await waitUntil { model.lifecycleState == .starting }
            model.cancelCurrentOperation()
            try await waitUntil(timeout: .seconds(2)) { !model.isBusy }
            XCTAssertEqual(model.error, .operationCancelled)
            XCTAssertEqual(model.lifecycleState, .stopped)
            XCTAssertEqual(model.status.engineState, .stopped)
            try await fixture.assertStoppedAndClean()
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testCancelledAfterCommittedStartReconcilesRunningState() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening)
        let delayed = DelayedStartReturnBackend(wrapping: fixture.backend)
        do {
            let model = BackendLifecycleModel(backend: delayed)
            model.refresh()
            try await waitUntil { !model.isBusy }
            model.start()
            try await waitUntilAsync { await delayed.didCommitStart() }
            model.cancelCurrentOperation()
            try await waitUntil(timeout: .seconds(2)) { !model.isBusy }
            XCTAssertEqual(model.error, .operationCancelled)
            XCTAssertEqual(model.lifecycleState, .running)
            XCTAssertEqual(model.status.engineState, .running)
            _ = try await fixture.backend.stopEngine()
            try await fixture.assertStoppedAndClean()
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testCancelledStopAndRestartReconcileActualBackendState() async throws {
        let fixture = try EngineLifecycleFixture(mode: .listening)
        let delayed = DelayedStopReturnBackend(wrapping: fixture.backend)
        do {
            let model = BackendLifecycleModel(backend: delayed)
            model.refresh()
            try await waitUntil { !model.isBusy }
            model.start()
            try await waitUntil { !model.isBusy }

            model.stop()
            try await waitUntilAsync { await delayed.didCommitStop() }
            model.cancelCurrentOperation()
            try await waitUntil(timeout: .seconds(2)) { !model.isBusy }
            XCTAssertEqual(model.error, .operationCancelled)
            XCTAssertEqual(model.status.engineState, .stopped)

            model.start()
            try await waitUntil { !model.isBusy }
            try fixture.store.save(json: SafeExampleConfiguration.json(), for: fixture.profile.id)
            model.refresh()
            try await waitUntil { !model.isBusy }
            XCTAssertTrue(model.canRestart)

            await delayed.resetStopCommit()
            model.restartWithCurrentProfile()
            try await waitUntilAsync { await delayed.didCommitStop() }
            model.cancelCurrentOperation()
            try await waitUntil(timeout: .seconds(2)) { !model.isBusy }
            XCTAssertEqual(model.error, .operationCancelled)
            XCTAssertEqual(model.status.engineState, .stopped)
            try await fixture.assertStoppedAndClean()
            await fixture.removeRoot()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    func testRealSingBoxLoopbackSmoke() async throws {
        let executable = realSingBoxExecutable()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("No executable sing-box was supplied for the loopback smoke test.")
        }
        let root = try makeRoot()
        let server = try LoopbackHTTPFixture(body: Data("loopback-ok".utf8))
        let profileRoot = root.appending(path: "Profiles", directoryHint: .isDirectory)
        let ownership = EngineRuntimeOwnership(store: FileEngineRuntimeStore(directory: root.appending(path: "Ownership")))
        let store = ProfileStore(rootDirectory: profileRoot, keyProvider: TestProfileKeyProvider())
        let profile = try store.create(name: "Loopback Smoke")
        let backend = SingBoxBackend(runtimeOwnership: ownership, profileStore: store, engineDirectory: root, executableURL: executable, readinessTimeout: .seconds(2))

        do {
            let running = try await backend.startEngine()
            XCTAssertEqual(running.engineState, .running)
            XCTAssertEqual(running.runningProfileID, profile.id)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 2
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: LocalEngineEndpoint.host,
                kCFNetworkProxiesHTTPPort as String: try XCTUnwrap(running.enginePort)
            ]
            let url = URL(string: "http://127.0.0.1:\(server.port)/smoke")!
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, Data("loopback-ok".utf8))

            let stopped = try await backend.stopEngine()
            XCTAssertEqual(stopped.engineState, .stopped)
            XCTAssertNil(ownership.currentRecord())
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "runtime").path))
            server.stop()
            try FileManager.default.removeItem(at: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        } catch {
            _ = try? await backend.stopEngine()
            server.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { throw LifecycleTestError.timedOut("\(file):\(line)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            guard clock.now < deadline else { throw LifecycleTestError.timedOut("\(file):\(line)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            guard clock.now < deadline else { throw LifecycleTestError.timedOut("\(file):\(line)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "TargetEngineLifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func realSingBoxExecutable() -> URL {
        if let configured = ProcessInfo.processInfo.environment["TARGET_REAL_SING_BOX_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/sing-box/bin/sing-box")
    }
}

private enum LifecycleTestError: Error {
    case timedOut(String)
}

private final class EngineLifecycleFixture: @unchecked Sendable {
    enum Mode: String {
        case listening
        case checkFails = "check-fails"
        case earlyExit = "early-exit"
        case neverReady = "never-ready"
        case exitAfterReady = "exit-after-ready"
    }

    let root: URL
    let executable: URL
    let runtimeDirectory: URL
    let candidateLaunchMarker: URL
    let ownership: EngineRuntimeOwnership
    let store: ProfileStore
    let profile: Profile
    let backend: SingBoxBackend
    let runtimeControl = LifecycleRuntimeControlClient()

    init(
        mode: Mode,
        readinessTimeout: Duration = .seconds(1),
        permissiveOwnershipInspector: Bool = true,
        forcePortReadiness: Bool = true
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TargetEngineLifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        let engineDirectory = root.appending(path: "Engine", directoryHint: .isDirectory)
        executable = engineDirectory.appending(path: "sing-box")
        runtimeDirectory = engineDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        candidateLaunchMarker = engineDirectory.appending(path: "candidate-launches")
        try FileManager.default.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        try Data(Self.script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(mode.rawValue.utf8).write(to: engineDirectory.appending(path: "mode"))

        let ownershipStore = FileEngineRuntimeStore(directory: root.appending(path: "Ownership", directoryHint: .isDirectory))
        let portProbe: any LocalEnginePortProbing = forcePortReadiness ? AlwaysListeningPortProbe() : NeverListeningPortProbe()
        ownership = EngineRuntimeOwnership(
            store: ownershipStore,
            processInspector: permissiveOwnershipInspector ? PermissiveProcessInspector() : DarwinEngineProcessInspector(),
            portProbe: portProbe
        )
        store = ProfileStore(
            rootDirectory: root.appending(path: "Profiles", directoryHint: .isDirectory),
            checker: LifecycleConfigurationChecker(),
            keyProvider: TestProfileKeyProvider()
        )
        profile = try store.create(name: "Lifecycle")
        backend = SingBoxBackend(
            portProbe: portProbe,
            runtimeOwnership: ownership,
            profileStore: store,
            engineDirectory: engineDirectory,
            executableURL: executable,
            readinessTimeout: readinessTimeout,
            runtimeControlClient: runtimeControl
        )
    }

    func assertStoppedAndClean() async throws {
        let status = try await backend.queryStatus()
        XCTAssertEqual(status.engineState, .stopped)
        XCTAssertNil(ownership.currentRecord())
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDirectory.path))
    }

    func cleanup() async {
        _ = try? await backend.stopEngine()
        try? FileManager.default.removeItem(at: root)
    }

    func removeRoot() async {
        _ = try? await backend.stopEngine()
        try? FileManager.default.removeItem(at: root)
    }

    private static let script = """
    #!/bin/sh
    case "$1" in
      version)
        echo 'sing-box version lifecycle-fixture'
        exit 0
        ;;
      check)
        mode=$(cat "$(dirname "$(dirname "$3")")/mode")
        [ "$mode" = "check-fails" ] && exit 1
        exit 0
        ;;
      run)
        printf '%s\\n' "$$" >> "$(dirname "$(dirname "$3")")/candidate-launches"
        mode=$(cat "$(dirname "$(dirname "$3")")/mode")
        case "$mode" in
          early-exit) exit 0 ;;
          never-ready) exec /usr/bin/python3 -c 'import time; time.sleep(30)' ;;
          listening|exit-after-ready)
            exec /usr/bin/python3 - "$3" "$mode" <<'PY'
    import json
    import signal
    import socket
    import sys
    import time

    with open(sys.argv[1], encoding='utf-8') as configuration:
        port = json.load(configuration)['inbounds'][0]['listen_port']
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(8)
    if sys.argv[2] == 'exit-after-ready':
        time.sleep(1.2)
        sys.exit(0)
    signal.signal(signal.SIGTERM, lambda _signal, _frame: sys.exit(0))
    while True:
        connection, _ = listener.accept()
        connection.close()
    PY
            ;;
        esac
        ;;
    esac
    exit 1
    """
}

private actor LifecycleRuntimeControlClient: RuntimeControlClient {
    private var selected = "first"
    func selectors(using descriptor: RuntimeControlDescriptor) async throws -> [String: RuntimeSelectorState] {
        ["group": RuntimeSelectorState(tag: "group", selected: selected, members: ["first", "second"])]
    }
    func select(selector: String, outbound: String, using descriptor: RuntimeControlDescriptor) async throws {
        selected = outbound
    }
    func connectionTotals(using descriptor: RuntimeControlDescriptor) async throws -> RuntimeConnectionTotals {
        RuntimeConnectionTotals(uploadTotalBytes: 0, downloadTotalBytes: 0, activeConnectionCount: 0)
    }
}

private struct LifecycleConfigurationChecker: SingBoxConfigurationChecking {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { .success(()) }
}

private struct PermissiveProcessInspector: EngineProcessInspecting {
    func matches(pid: Int32, executablePath: String) -> Bool { pid > 0 && kill(pid_t(pid), 0) == 0 }
}

private struct AlwaysListeningPortProbe: LocalEnginePortProbing {
    func isListening(on port: UInt16) async -> Bool { true }
}

private struct NeverListeningPortProbe: LocalEnginePortProbing {
    func isListening(on port: UInt16) async -> Bool { false }
}

private actor DelayedQueryBackend: EngineBackend {
    private let status: BackendStatus

    init(status: BackendStatus) { self.status = status }

    func queryStatus() async throws -> BackendStatus {
        try await Task.sleep(for: .milliseconds(100))
        return status
    }

    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {}
    func startEngine() async throws -> BackendStatus { status }
    func stopEngine() async throws -> BackendStatus { status }
}

private actor ReconciliationTimeoutBackend: EngineBackend {
    private var queryCount = 0
    private let status = BackendStatus(
        serviceInstallation: .notRegistered,
        engineState: .stopped,
        engineInstallation: .installed,
        hasSelectedValidProfile: true
    )

    func queryStatus() async throws -> BackendStatus {
        queryCount += 1
        if queryCount == 1 {
            try await Task.sleep(for: .seconds(1))
            return status
        }
        try? await Task.sleep(for: .seconds(10))
        return status
    }

    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {}
    func startEngine() async throws -> BackendStatus { status }
    func stopEngine() async throws -> BackendStatus { status }
    func didBeginFirstQuery() -> Bool { queryCount >= 1 }
}

private actor DelayedStartReturnBackend: EngineBackend {
    private let backend: SingBoxBackend
    private var committedStart = false

    init(wrapping backend: SingBoxBackend) { self.backend = backend }

    func queryStatus() async throws -> BackendStatus { try await backend.queryStatus() }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws { try await backend.validateConfiguration(request) }
    func startEngine() async throws -> BackendStatus {
        let status = try await backend.startEngine()
        committedStart = true
        try await Task.sleep(for: .seconds(1))
        return status
    }
    func stopEngine() async throws -> BackendStatus { try await backend.stopEngine() }
    func didCommitStart() -> Bool { committedStart }
}

private actor DelayedStopReturnBackend: EngineBackend {
    private let backend: SingBoxBackend
    private var committedStop = false

    init(wrapping backend: SingBoxBackend) { self.backend = backend }

    func queryStatus() async throws -> BackendStatus { try await backend.queryStatus() }
    func validateConfiguration(_ request: XPCConfigurationRequest) async throws { try await backend.validateConfiguration(request) }
    func startEngine() async throws -> BackendStatus { try await backend.startEngine() }
    func stopEngine() async throws -> BackendStatus {
        let status = try await backend.stopEngine()
        committedStop = true
        try await Task.sleep(for: .seconds(1))
        return status
    }
    func didCommitStop() -> Bool { committedStop }
    func resetStopCommit() { committedStop = false }
}

private final class LoopbackHTTPFixture: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let body: Data
    private let queue = DispatchQueue(label: "TargetTests.LoopbackHTTPFixture")

    init(body: Data) throws {
        self.body = body
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw LifecycleTestError.timedOut("socket") }
        var reuse: Int32 = 1
        guard setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(socketDescriptor)
            throw LifecycleTestError.timedOut("setsockopt")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketDescriptor, 8) == 0 else {
            close(socketDescriptor)
            throw LifecycleTestError.timedOut("bind")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
        }
        guard named == 0 else {
            close(socketDescriptor)
            throw LifecycleTestError.timedOut("getsockname")
        }
        port = UInt16(bigEndian: assigned.sin_port)
        descriptor = socketDescriptor
        source = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.serveConnection() }
        source.resume()
    }

    func stop() {
        source.cancel()
        close(descriptor)
    }

    private func serveConnection() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var request = [UInt8](repeating: 0, count: 4_096)
        _ = recv(client, &request, request.count, 0)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + body
        _ = response.withUnsafeBytes { send(client, $0.baseAddress, response.count, 0) }
    }
}
