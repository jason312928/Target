import Foundation
import XCTest
@testable import Target

final class DeepOptimizationTests: XCTestCase, ProfileTestCaseSupport {
    func testTemporaryDirectoryAliasSharesCoordinatorAndSupportsDurableMutations() throws {
        let root = URL(fileURLWithPath: "/tmp/target-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = URL(fileURLWithPath: ProfileStorageCoordinator.canonicalPath(for: root), isDirectory: true)
        XCTAssertTrue(ProfileStorageCoordinator.shared(for: root) === ProfileStorageCoordinator.shared(for: actual))
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Alias")
        try store.save(json: "{}", for: profile.id)
        let reopened = ProfileStore(rootDirectory: actual, checker: TestChecker(result: .success(())), keyProvider: keys)
        XCTAssertEqual(try reopened.configurationText(for: profile.id), "{}")
    }

    func testFailedSaveRestoresExactAuthenticatedTreeAndSelection() throws {
        for point in [ProfileStorageFaultPoint.mutationAfterCurrentWrite, .mutationAfterRevisionWrite, .manifestWrite, .mutationBeforeCommit] {
            let root = try temporaryDirectory()
            let keys = TestProfileKeyProvider()
            let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
            let first = try store.create(name: "First")
            let second = try store.create(name: "Second")
            try store.select(first.id)
            let original = try treeSnapshot(root)
            let failing = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: TestStorageFaults(failing: point))
            XCTAssertThrowsError(try failing.save(json: #"{"changed":true}"#, for: second.id))
            XCTAssertEqual(try treeSnapshot(root), original, "Rollback must restore all ciphertext bytes at \(point)")
            XCTAssertEqual(try store.selectedProfileID(), first.id)
            XCTAssertEqual(try store.listProfiles().first(where: { $0.id == second.id })?.validRevision, 1)
            XCTAssertNoThrow(try store.snapshot())
        }
    }

    func testInterruptedSaveRecoversBeforeReadAndKeepsSealedCommit() throws {
        for point in [ProfileStorageFaultPoint.mutationAfterSnapshot, .mutationAfterCurrentWrite, .mutationAfterRevisionWrite, .mutationBeforeCommit, .mutationAfterCommit] {
            let root = try temporaryDirectory()
            let keys = TestProfileKeyProvider()
            let initial = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
            let profile = try initial.create(name: "Interrupted")
            let original = try treeSnapshot(root)
            let interrupted = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: MutationCrashFault(point))
            XCTAssertThrowsError(try interrupted.save(json: #"{"committed":true}"#, for: profile.id))
            let reopened = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
            XCTAssertNoThrow(try reopened.snapshot())
            if point == .mutationAfterCommit {
                XCTAssertEqual(try reopened.configurationText(for: profile.id), #"{"committed":true}"#)
                XCTAssertEqual(try reopened.listProfiles().first(where: { $0.id == profile.id })?.validRevision, 2)
            } else {
                XCTAssertEqual(try treeSnapshot(root), original)
                XCTAssertEqual(try reopened.listProfiles().first(where: { $0.id == profile.id })?.validRevision, 1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).mutation").path))
        }
    }

    func testCreateDeleteAndRestoreManifestFailuresRollBack() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let initial = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try initial.create(name: "Persisted")
        try initial.save(json: #"{"revision":2}"#, for: profile.id)
        let original = try treeSnapshot(root)
        let failing = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: TestStorageFaults(failing: .manifestWrite))
        XCTAssertThrowsError(try failing.create(name: "New"))
        XCTAssertEqual(try treeSnapshot(root), original)
        XCTAssertThrowsError(try failing.delete(profile.id))
        XCTAssertEqual(try treeSnapshot(root), original)
        XCTAssertThrowsError(try failing.restorePreviousValidVersion(for: profile.id))
        XCTAssertEqual(try treeSnapshot(root), original)
    }

    func testRouteSelectionAndBindingRollbackTogether() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        try store.save(json: policyConfiguration(configuredDefault: "United States 01", members: ["United States 01"]), for: second.id)
        try store.select(first.id)
        let original = try treeSnapshot(root)
        let binding = try XCTUnwrap(ProfileRouteBinding(domain: "example.com", outboundTag: "United States 01", countryCode: "US"))
        let failing = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: TestStorageFaults(failing: .manifestWrite))
        XCTAssertThrowsError(try failing.bindRouteSelectingProfile(binding, profileID: second.id, expectedRevision: 2))
        XCTAssertEqual(try treeSnapshot(root), original)
        XCTAssertEqual(try store.selectedProfileID(), first.id)
    }

    func testTwoStoreInstancesSerializeConcurrentRevisions() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let first = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let second = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try first.create(name: "Concurrent")
        let group = DispatchGroup()
        let outcomes = OptimizationSaveOutcomes()
        for (index, store) in [first, second].enumerated() {
            group.enter()
            DispatchQueue.global().async {
                do { try store.save(json: "{\"writer\":\(index)}", for: profile.id) }
                catch { outcomes.record(error) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outcomes.count, 0)
        XCTAssertEqual(try first.listProfiles().first(where: { $0.id == profile.id })?.validRevision, 3)
        XCTAssertEqual(try first.availableValidVersions(for: profile.id).map(\.revision), [3, 2, 1])
        XCTAssertNoThrow(try second.snapshot())
    }

    func testTamperedRecoverySnapshotIsRejectedWithoutReplacingLiveState() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let initial = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try initial.create(name: "Recovery")
        let interrupted = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys, storageFaults: MutationCrashFault(.mutationAfterCurrentWrite))
        XCTAssertThrowsError(try interrupted.save(json: #"{"attempted":true}"#, for: profile.id))
        let live = try treeSnapshot(root)
        let backup = root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).mutation/backup/\(profile.id.uuidString)/config.json")
        var data = try Data(contentsOf: backup)
        data[data.count - 1] ^= 1
        try data.write(to: backup)
        XCTAssertThrowsError(try initial.listProfiles()) { XCTAssertEqual($0 as? ProfileStoreError, .profileMutationRecoveryFailed) }
        XCTAssertEqual(try treeSnapshot(root), live)
    }

    func testWarmStorageReadsReuseAuthenticationAndStillRejectTampering() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        let profile = try store.create(name: "Cache")
        for number in 1...6 { try store.save(json: "{\"revision\":\(number)}", for: profile.id) }
        let storage = ProfileEncryptedStorage(root: root, keyProvider: keys)
        try storage.authenticateExistingTree()
        let coldDecodeCount = storage.authenticatedRecordDecodeCount
        XCTAssertGreaterThan(coldDecodeCount, 0)
        for _ in 0..<10 { try storage.authenticateExistingTree() }
        XCTAssertEqual(storage.authenticatedRecordDecodeCount, coldDecodeCount)
        let historical = root.appending(path: "\(profile.id.uuidString)/versions/1.json")
        let originalDate = try FileManager.default.attributesOfItem(atPath: historical.path)[.modificationDate]!
        var data = try Data(contentsOf: historical)
        data[data.count - 1] ^= 1
        try data.write(to: historical)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: historical.path)
        XCTAssertThrowsError(try storage.authenticateExistingTree(), "Restoring mtime cannot bypass ciphertext authentication")
    }

    func testChangedKeyInvalidatesWarmCache() throws {
        let root = try temporaryDirectory()
        let keys = TestProfileKeyProvider()
        let store = ProfileStore(rootDirectory: root, checker: TestChecker(result: .success(())), keyProvider: keys)
        _ = try store.create(name: "Key")
        XCTAssertNoThrow(try store.snapshot())
        keys.replaceKey(Data(repeating: 0xAC, count: 32))
        XCTAssertThrowsError(try store.snapshot())
    }

    func testRouteChangesRequireRestartAndOrderDoesNotChangeIdentity() throws {
        let store = try makeStore()
        var profile = try store.create(name: "Routes")
        let source = Data(try store.configurationText(for: profile.id).utf8)
        let first = try XCTUnwrap(ProfileRouteBinding(domain: "example.com", outboundTag: "US", countryCode: "US"))
        let second = try XCTUnwrap(ProfileRouteBinding(domain: "example.org", outboundTag: "JP", countryCode: "JP"))
        var record = EngineRuntimeRecord(pid: 42, executablePath: "/fixture", executableFingerprint: "fixture", endpoint: .init(port: 50_001), profileID: profile.id, profileRevision: profile.validRevision, sourceConfigurationFingerprint: TargetConfigurationFingerprint.sha256(source), configurationFingerprint: "fixture", startedAt: .now, runtimeConfigurationID: UUID())
        XCTAssertFalse(EngineRuntimeProfileState.requiresRestart(record: record, selected: .init(profile: profile, revision: profile.validRevision, data: source)))
        profile.routeBindings = [first, second]
        XCTAssertTrue(EngineRuntimeProfileState.requiresRestart(record: record, selected: .init(profile: profile, revision: profile.validRevision, data: source)))
        record.routeBindingsFingerprint = ProfileRouteBinding.fingerprint([second, first])
        XCTAssertFalse(EngineRuntimeProfileState.requiresRestart(record: record, selected: .init(profile: profile, revision: profile.validRevision, data: source)))
        profile.routeBindings.removeAll()
        XCTAssertTrue(EngineRuntimeProfileState.requiresRestart(record: record, selected: .init(profile: profile, revision: profile.validRevision, data: source)))
    }

    func testJSONTokensPreserveStringPrecedenceAndUnicodeOffsets() {
        let source = #"{"数值": "true 42", "enabled": true, "count": -42}"#
        let tokens = JSONSyntaxTokens.tokens(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(tokens.count, 6)
        XCTAssertEqual(tokens.filter { if case .number = $0.kind { return true }; return false }.count, 1)
        XCTAssertEqual(tokens.filter { if case .key = $0.kind { return true }; return false }.count, 3)
        XCTAssertEqual((source as NSString).substring(with: tokens.last!.range), "-42")
    }

    func testActivitySnapshotProvidesSummaryAndDetailsFromOneRead() async {
        let provider = OptimizationSnapshotProvider()
        let operations = TargetRuntimeObservationOperations(provider: provider)
        let activity = await operations.readActivity()
        XCTAssertEqual(activity.summary.activeConnectionCount, 1_234)
        XCTAssertEqual(activity.snapshot?.totals.uploadTotalBytes, 42)
        let counts = await provider.counts()
        XCTAssertEqual(counts.snapshots, 1)
        XCTAssertEqual(counts.totals, 0)
    }

    @MainActor
    func testSlowSaveRunsOffMainThreadAndBlocksReplacementUntilCommitted() async throws {
        let root = try temporaryDirectory()
        let checker = OptimizationBlockingChecker()
        let store = ProfileStore(rootDirectory: root, checker: checker, keyProvider: TestProfileKeyProvider())
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        try store.select(first.id)
        let model = ProfileViewModel(store: store)
        checker.shouldBlock = true
        addTeardownBlock { checker.release.signal() }
        model.updateEditor(#"{"saved":true}"#)
        model.save()
        let started = await Task.detached { checker.waitUntilStarted() }.value
        XCTAssertEqual(started, .success)
        XCTAssertFalse(checker.checkedOnMainThread)
        XCTAssertTrue(model.isPerformingPersistence)
        // This MainActor assertion executes while the checker is still blocked.
        model.requestSelection(second.id)
        XCTAssertEqual(model.selectedID, first.id)
        checker.release.signal()
        try await waitForProfileWork(model)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try store.configurationText(for: first.id), #"{"saved":true}"#)
        XCTAssertEqual(model.selectedID, first.id)
    }
}

private struct MutationCrashFault: ProfileStorageFaultInjecting {
    let point: ProfileStorageFaultPoint
    init(_ point: ProfileStorageFaultPoint) { self.point = point }
    func check(_ current: ProfileStorageFaultPoint) throws {
        if current == point { throw ProfileMutationInterruption.simulated }
    }
}

private final class OptimizationBlockingChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    var shouldBlock = false
    private(set) var checkedOnMainThread = false
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitUntilStarted() -> DispatchTimeoutResult { started.wait(timeout: .now() + 2) }
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> {
        guard shouldBlock else { return .success(()) }
        checkedOnMainThread = Thread.isMainThread
        started.signal()
        _ = release.wait(timeout: .now() + 3)
        return .success(())
    }
}

private actor OptimizationSnapshotProvider: RuntimeSnapshotProviding {
    private var snapshotReads = 0
    private var totalReads = 0
    func runtimeObservationAvailability() async -> RuntimeObservationState { .loading }
    func currentRuntimeConnectionTotals() async -> RuntimeConnectionTotals? {
        totalReads += 1
        return nil
    }
    func currentRuntimeSnapshot() async -> RuntimeConnectionsSnapshot? {
        snapshotReads += 1
        return .init(totals: .init(uploadTotalBytes: 42, downloadTotalBytes: 84, activeConnectionCount: 1_234), connections: [])
    }
    func counts() -> (snapshots: Int, totals: Int) { (snapshotReads, totalReads) }
}

private final class OptimizationSaveOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
}
