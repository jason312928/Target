import Foundation
import XCTest

@testable import Target

final class ProfileStoreTests: XCTestCase {
    func testRawJSONPreservesUnknownFieldsWithoutCodableRoundTrip() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Preservation")
        let source = "{\n  \"inbounds\": [],\n  \"outbounds\": [],\n  \"route\": {},\n  \"future_extension\": { \"new_field\": [1, true, \"unchanged\"] }\n}\n"

        try store.save(json: source, for: profile.id)

        XCTAssertEqual(try store.configurationText(for: profile.id), source)
        let object = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        XCTAssertNotNil((object?["future_extension"] as? [String: Any])?["new_field"])
    }

    func testInvalidConfigurationDoesNotReplaceLastValidVersion() throws {
        let checker = TestChecker(result: .success(()))
        let store = try makeStore(checker: checker)
        let profile = try store.create(name: "Safe")
        let valid = "{\"inbounds\":[],\"outbounds\":[],\"route\":{}}"
        try store.save(json: valid, for: profile.id)
        checker.result = .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: 3, column: 9))

        XCTAssertThrowsError(try store.save(json: "{\"inbounds\": [}", for: profile.id))
        XCTAssertEqual(try store.configurationText(for: profile.id), valid)
        XCTAssertEqual(try store.listProfiles().first?.validation.status, .invalid)
    }

    func testJSONSyntaxDiagnosticHasLineAndColumn() {
        let diagnostic = JSONSyntaxChecker.validate("{\n  \"inbounds\": [\n}")
        XCTAssertNotNil(diagnostic?.line)
        XCTAssertNotNil(diagnostic?.column)
    }

    func testProfileCRUDSelectionAndRemoteSubscriptionModel() throws {
        let store = try makeStore()
        let created = try store.create(name: "Original", subscriptionURL: URL(string: "https://user:secret@example.invalid/sub")!)
        XCTAssertEqual(try store.selectedProfileID(), created.id)
        XCTAssertTrue(try XCTUnwrap(store.listProfiles().first).hasRemoteSubscription)

        let duplicate = try store.duplicate(created.id, name: "Copy")
        try store.rename(duplicate.id, to: "Renamed")
        try store.select(duplicate.id)
        XCTAssertEqual(try store.selectedProfileID(), duplicate.id)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first { $0.id == duplicate.id }).name, "Renamed")
        try store.delete(created.id)
        XCTAssertEqual(try store.listProfiles().map(\.id), [duplicate.id])
    }

    func testRedactionNeverReturnsSecretsOrPaths() {
        let input = "url=https://alice:secret@example.invalid/sub uuid=123e4567-e89b-12d3-a456-426614174000 \"password\":\"hunter2\" \"private_key\":\"private\" /Users/person/Library/Application Support/Target/config.json"
        let redacted = String(decoding: EngineLogRedactor.redact(Data(input.utf8)), as: UTF8.self)
        for secret in ["alice", "secret", "123e4567", "hunter2", "\"private\"", "/Users/person"] {
            XCTAssertFalse(redacted.contains(secret))
        }
    }

    func testConfigurationVersionsCanRestorePreviousValidVersion() throws {
        let store = try makeStore()
        let profile = try store.create(name: "History")
        let first = "{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"version\":1}"
        let second = "{\"inbounds\":[],\"outbounds\":[],\"route\":{},\"version\":2}"
        try store.save(json: first, for: profile.id)
        try store.save(json: second, for: profile.id)
        try store.restorePreviousValidVersion(for: profile.id)
        XCTAssertEqual(try store.configurationText(for: profile.id), first)
        XCTAssertEqual(try XCTUnwrap(store.listProfiles().first).validRevision, 2)
    }

    func testPathsAreConfinedToTargetManagedRoot() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.safeManagedURL("../outside.json")) { error in
            XCTAssertEqual(error as? ProfileStoreError, .unsafePath)
        }
        XCTAssertThrowsError(try store.safeManagedURL("/tmp/outside.json"))
        XCTAssertNoThrow(try store.safeManagedURL("metadata.json"))
    }

    func testNoSelectedProfileCannotProvideLaunchVersion() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.selectedValidVersion()) { error in
            XCTAssertEqual(error as? ProfileStoreError, .noSelectedProfile)
        }
    }

    func testMissingRecentValidVersionCannotProvideLaunchVersion() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Missing Version")
        let version = try store.safeManagedURL("\(profile.id.uuidString)/versions/1.json")
        try FileManager.default.removeItem(at: version)
        XCTAssertThrowsError(try store.selectedValidVersion()) { error in
            XCTAssertEqual(error as? ProfileStoreError, .noValidVersion)
        }
    }

    func testRuntimeCopyReplacesOnlyLocalPortAndLeavesSourceUntouched() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Dynamic Port")
        let source = SafeExampleConfiguration.json(port: 1080)
        try store.save(json: source, for: profile.id)
        let prepared = try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234))
            .prepare(store.selectedValidVersion())
        XCTAssertEqual(try store.configurationText(for: profile.id), source)
        let runtime = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let inbound = try XCTUnwrap((runtime["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["listen_port"] as? Int, 51_234)
        XCTAssertEqual(prepared.primaryPort, 51_234)
    }

    func testUnsafeOrInvalidProfileCannotPrepareRuntimeCopy() throws {
        let profile = Profile(
            id: UUID(), name: "Unsafe", subscription: nil, createdAt: Date(), updatedAt: Date(),
            validation: .notChecked, validRevision: 1
        )
        let version = ProfileConfigurationVersion(
            profile: profile, revision: 1,
            data: Data(#"{"inbounds":[{"type":"tun","listen":"127.0.0.1","listen_port":1}],"outbounds":[]}"#.utf8)
        )
        XCTAssertThrowsError(try ProfileRuntimeConfigurationPreparer(portSelector: FixedPortSelector(port: 51_234)).prepare(version)) { error in
            XCTAssertEqual(error as? ProfileRuntimeConfigurationError, .unsafeConfiguration)
        }
    }

    func testRunningProfileCannotBeDeleted() throws {
        let usage = FixedProfileUsage(inUse: true)
        let store = ProfileStore(rootDirectory: try temporaryDirectory(), checker: TestChecker(result: .success(())), runtimeUsage: usage)
        let profile = try store.create(name: "Active")
        XCTAssertThrowsError(try store.delete(profile.id)) { error in
            XCTAssertEqual(error as? ProfileStoreError, .profileInUse)
        }
    }

    func testRuntimeConfigurationCleanupRemovesOnlyEphemeralCopy() throws {
        let root = try temporaryDirectory()
        let runtime = RuntimeConfigurationStore(directory: root.appending(path: "runtime", directoryHint: .isDirectory))
        let temporary = try runtime.write(Data("{}".utf8))
        XCTAssertTrue(runtime.exists(id: temporary.id))
        runtime.remove(id: temporary.id)
        XCTAssertFalse(runtime.exists(id: temporary.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testSingBoxCheckSubcommandIntegration() throws {
        let root = try temporaryDirectory()
        let executable = root.appending(path: "sing-box")
        let script = "#!/bin/sh\n[ \"$1\" = \"check\" ] && [ \"$2\" = \"-c\" ] && [ -f \"$3\" ]\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let configuration = root.appending(path: "config.json")
        try Data("{\"inbounds\":[],\"outbounds\":[],\"route\":{}}".utf8).write(to: configuration)
        let checker = SingBoxConfigurationChecker(executableURL: executable)
        if case .failure(let diagnostic) = checker.check(configurationURL: configuration) {
            XCTFail("check unexpectedly failed with \(diagnostic.messageKey)")
        }
    }

    func testInstalledSingBoxChecksSafeExampleConfigurationWhenRequested() throws {
        guard FileManager.default.isExecutableFile(atPath: singBoxExecutable.path) else {
            throw XCTSkip("sing-box is not installed for localhost integration testing.")
        }
        let root = try temporaryDirectory()
        let configuration = root.appending(path: "safe-example.json")
        try Data(SafeExampleConfiguration.json().utf8).write(to: configuration)
        if case .failure(let diagnostic) = SingBoxConfigurationChecker().check(configurationURL: configuration) {
            XCTFail("sing-box check failed with \(diagnostic.messageKey)")
        }
    }

    private func makeStore(checker: TestChecker = TestChecker(result: .success(()))) throws -> ProfileStore {
        ProfileStore(rootDirectory: try temporaryDirectory(), checker: checker)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var singBoxExecutable: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/sing-box/bin/sing-box")
    }
}

private final class TestChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    var result: Result<Void, ConfigurationDiagnostic>
    init(result: Result<Void, ConfigurationDiagnostic>) { self.result = result }
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { result }
}

private struct FixedPortSelector: LocalEnginePortSelecting {
    let port: UInt16
    func selectAvailablePort() throws -> UInt16 { port }
}

private struct FixedProfileUsage: ProfileRuntimeUsageChecking {
    let inUse: Bool
    func isProfileInUse(_ id: UUID) -> Bool { inUse }
}
