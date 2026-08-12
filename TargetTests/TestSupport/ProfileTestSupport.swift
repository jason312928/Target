import Foundation
import XCTest

@testable import Target

protocol ProfileTestCaseSupport: AnyObject {}

extension ProfileTestCaseSupport where Self: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = container.appending(path: "Workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return url
    }

    func makeStore(checker: TestChecker = TestChecker(result: .success(()))) throws -> ProfileStore {
        ProfileStore(rootDirectory: try temporaryDirectory(), checker: checker, keyProvider: TestProfileKeyProvider())
    }

    var singBoxExecutable: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/sing-box/bin/sing-box")
    }
}

func treeSnapshot(_ root: URL) throws -> [String: String] {
    var snapshot: [String: String] = [:]
    for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
        let url = root.appending(path: relative)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            snapshot[relative] = "directory"
        } else if values.isRegularFile == true {
            snapshot[relative] = try Data(contentsOf: url).base64EncodedString()
        }
    }
    return snapshot
}

func policyConfiguration(configuredDefault defaultMember: String, members: [String]) -> String {
    let memberJSON = members.map { "\"\($0)\"" }.joined(separator: ",")
    let outboundJSON = Array(Set(members)).sorted().map { member in
        "{\"type\":\"direct\",\"tag\":\"\(member)\"}"
    }.joined(separator: ",")
    return "{\"inbounds\":[{\"type\":\"mixed\",\"tag\":\"local\",\"listen\":\"127.0.0.1\",\"listen_port\":0}],\"outbounds\":[{\"type\":\"selector\",\"tag\":\"group\",\"outbounds\":[\(memberJSON)],\"default\":\"\(defaultMember)\"},\(outboundJSON)],\"route\":{\"final\":\"group\"}}"
}

func recursiveData(in root: URL) throws -> Data {
    let urls = try FileManager.default.subpathsOfDirectory(atPath: root.path)
    return try urls.reduce(into: Data()) { result, relative in
        let url = root.appending(path: relative)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { result += try Data(contentsOf: url) }
    }
}

func writeLegacyFixture(root: URL) throws -> (first: Profile, second: Profile, firstConfig: String, firstVersion: String) {
    let time = Date(timeIntervalSince1970: 1_700_000_000)
    let first = Profile(id: UUID(), name: "Legacy One", subscription: RemoteSubscription(url: URL(string: "https://fixture-subscription-secret@example.invalid/sub")!, etag: "fixture-etag", lastModified: "fixture-last-modified", cacheStatus: .updated), createdAt: time, updatedAt: time, validation: ProfileValidation(status: .valid, checkedAt: time, error: nil), validRevision: 2)
    let second = Profile(id: UUID(), name: "Legacy Two", subscription: nil, createdAt: time, updatedAt: time, validation: .notChecked, validRevision: 1)
    let firstVersion = "{ \"z\": 1, \"unknown\": [ true ] }\n"
    let firstConfig = "{\n  \"unknown\" : [ true ], \"z\": 2\n}\n"
    let secondConfig = "{\"inbounds\":[],\"outbounds\":[],\"route\":{}}\n"
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode([first, second]).write(to: root.appending(path: "profiles.json"))
    try JSONEncoder().encode(second.id.uuidString).write(to: root.appending(path: "selected-profile.json"))
    for (profile, config, versions) in [(first, firstConfig, [firstVersion, firstConfig]), (second, secondConfig, [secondConfig])] {
        let directory = root.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "versions"), withIntermediateDirectories: true)
        try Data(config.utf8).write(to: directory.appending(path: "config.json"))
        for (index, version) in versions.enumerated() { try Data(version.utf8).write(to: directory.appending(path: "versions/\(index + 1).json")) }
    }
    try Data("discard".utf8).write(to: root.appending(path: "\(first.id.uuidString)/.pending-check.json"))
    return (first, second, firstConfig, firstVersion)
}

func containsExportTemporaryFile(in directory: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".target-profile-export-") }
}

final class TestChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    var result: Result<Void, ConfigurationDiagnostic>
    init(result: Result<Void, ConfigurationDiagnostic>) { self.result = result }
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> { result }
}

enum TemporaryTestError: Error {
    case expected
}

final class TestProfileKeyProvider: ProfileEncryptionKeyProviding {
    private var key: Data?
    private(set) var createCount = 0
    init(key: Data? = Data(repeating: 7, count: 32)) { self.key = key }
    func loadMasterKey() throws -> Data? { key }
    func createMasterKey() throws -> Data {
        createCount += 1
        if key == nil { key = Data(repeating: 9, count: 32) }
        return key!
    }
    func removeKey() { key = nil }
    func replaceKey(_ value: Data) { key = value }
}

final class TestStorageFaults: ProfileStorageFaultInjecting {
    let failing: ProfileStorageFaultPoint
    init(failing: ProfileStorageFaultPoint) { self.failing = failing }
    func check(_ point: ProfileStorageFaultPoint) throws { if point == failing { throw NSError(domain: "TestStorageFaults", code: 1) } }
}

final class MutableProfileStorageFaults: ProfileStorageFaultInjecting {
    var failing: ProfileStorageFaultPoint?
    func check(_ point: ProfileStorageFaultPoint) throws {
        if point == failing { throw NSError(domain: "MutableProfileStorageFaults", code: 1) }
    }
}

final class BlockingInitialManifestWriteFault: ProfileStorageFaultInjecting, @unchecked Sendable {
    private let manifestWriteEntered = DispatchSemaphore(value: 0)
    private let continueManifestWrite = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func check(_ point: ProfileStorageFaultPoint) throws {
        guard point == .manifestWrite else { return }
        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()
        guard shouldBlock else { return }
        manifestWriteEntered.signal()
        _ = continueManifestWrite.wait(timeout: .now() + 5)
    }

    func waitUntilManifestWrite() -> DispatchTimeoutResult {
        manifestWriteEntered.wait(timeout: .now() + 2)
    }

    func release() {
        continueManifestWrite.signal()
    }
}

final class BlockingManifestWriteFault: ProfileStorageFaultInjecting, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false

    func armNextManifestWrite() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func check(_ point: ProfileStorageFaultPoint) throws {
        guard point == .manifestWrite else { return }
        lock.lock()
        let shouldBlock = armed
        armed = false
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        _ = continuation.wait(timeout: .now() + 5)
    }

    func waitUntilBlocked() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 2)
    }

    func release() {
        continuation.signal()
    }
}

final class ConcurrentProfileReadResults: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Result<[Profile], Error>?
    private var second: Result<[Profile], Error>?

    var firstResult: Result<[Profile], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    var secondResult: Result<[Profile], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return second
    }

    func recordFirst(_ result: Result<[Profile], Error>) {
        lock.lock()
        first = result
        lock.unlock()
    }

    func recordSecond(_ result: Result<[Profile], Error>) {
        lock.lock()
        second = result
        lock.unlock()
    }
}

final class TestTransferFaults: ProfileTransferFaultInjecting {
    let points: Set<ProfileTransferFaultPoint>
    init(points: Set<ProfileTransferFaultPoint>) { self.points = points }
    func check(_ point: ProfileTransferFaultPoint) throws {
        if points.contains(point) { throw NSError(domain: "TestTransferFaults", code: 1) }
    }
}

final class ActionTransferFaults: ProfileTransferFaultInjecting {
    private let action: (ProfileTransferFaultPoint) throws -> Void
    init(_ action: @escaping (ProfileTransferFaultPoint) throws -> Void) { self.action = action }
    func check(_ point: ProfileTransferFaultPoint) throws { try action(point) }
}

struct FixedPortSelector: LocalEnginePortSelecting {
    let port: UInt16
    func selectAvailablePort() throws -> UInt16 { port }
}
