import Foundation
import Network
import SystemConfiguration

enum SystemProxyState: String, Codable, Equatable, Sendable {
    case disabled
    case enabling
    case enabled
    case disabling
    case recoveryRequired = "recovery_required"
    case failed

    var localizedKey: String { "system-proxy.status.\(rawValue)" }
}

enum SystemProxyError: String, Codable, Error, Equatable, Sendable {
    case safeModeBlocked
    case existingNetworkController
    case noActiveNetworkService
    case localProxyUnavailable
    case snapshotFailed
    case invalidSnapshotOwner
    case externalModificationConflict
    case applyFailed
    case verificationFailed
    case recoveryFailed

    var localizedKey: String {
        switch self {
        case .safeModeBlocked: "system-proxy.error.safe-mode-blocked"
        case .existingNetworkController: "system-proxy.error.existing-network-controller"
        case .noActiveNetworkService: "system-proxy.error.no-active-service"
        case .localProxyUnavailable: "system-proxy.error.local-proxy-unavailable"
        case .snapshotFailed: "system-proxy.error.snapshot-failed"
        case .invalidSnapshotOwner: "system-proxy.error.invalid-snapshot-owner"
        case .externalModificationConflict: "system-proxy.error.external-modification-conflict"
        case .applyFailed: "system-proxy.error.apply-failed"
        case .verificationFailed: "system-proxy.error.verification-failed"
        case .recoveryFailed: "system-proxy.error.recovery-failed"
        }
    }
}

struct SystemProxyStatus: Codable, Equatable, Sendable {
    var state: SystemProxyState
    var engineReachable: Bool
    var affectedServiceCount: Int
    var error: SystemProxyError?
    var hasRecoverySnapshot: Bool = false

    static let disabled = SystemProxyStatus(
        state: .disabled,
        engineReachable: false,
        affectedServiceCount: 0,
        error: nil,
        hasRecoverySnapshot: false
    )
}

/// Property-list values used by macOS proxy settings. Keeping this type closed prevents
/// arbitrary objects from crossing the XPC boundary or entering the recovery record.
enum SystemProxyValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case strings([String])
}

extension SystemProxyValue: Codable {
    private enum CodingKeys: String, CodingKey { case kind, string, integer, strings }
    private enum Kind: String, Codable { case string, integer, strings }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .string)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .integer)
        case let .strings(value):
            try container.encode(Kind.strings, forKey: .kind)
            try container.encode(value, forKey: .strings)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        case .integer: self = .integer(try container.decode(Int.self, forKey: .integer))
        case .strings: self = .strings(try container.decode([String].self, forKey: .strings))
        }
    }

    init?(foundationValue: Any) {
        if let value = foundationValue as? String {
            self = .string(value)
        } else if let value = foundationValue as? NSNumber {
            self = .integer(value.intValue)
        } else if let value = foundationValue as? [String] {
            self = .strings(value)
        } else {
            return nil
        }
    }

    var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .integer(value): NSNumber(value: value)
        case let .strings(value): value
        }
    }
}

struct SystemProxySnapshot: Codable, Equatable, Sendable {
    /// An opaque SystemConfiguration service identifier, never a user-visible network name.
    let serviceID: String
    /// Contains only the service's proxy dictionary; it contains no interface, SSID, or path data.
    let properties: [String: SystemProxyValue]
}

struct SystemProxyRecoveryRecord: Codable, Equatable, Sendable {
    let owner: String
    let snapshots: [SystemProxySnapshot]
    let writtenSettings: [String: [String: SystemProxyValue]]
}

protocol SystemProxySystemManaging: Sendable {
    func activeServiceIDs() throws -> [String]
    func proxySettings(for serviceID: String) throws -> [String: SystemProxyValue]
    func setProxySettings(_ settings: [String: SystemProxyValue], for serviceID: String) throws
}

protocol SystemProxyRecoveryStoring: Sendable {
    func load() throws -> SystemProxyRecoveryRecord?
    func save(_ record: SystemProxyRecoveryRecord) throws
    func clear() throws
}

protocol LocalProxyProbing: Sendable {
    func isAvailable() async -> Bool
}

final class UserDefaultsSystemProxyRecoveryStore: SystemProxyRecoveryStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "system-proxy-recovery-v1"

    init(defaults: UserDefaults = UserDefaults(suiteName: "com.jason312928.Target.TargetService") ?? .standard) {
        self.defaults = defaults
    }

    func load() throws -> SystemProxyRecoveryRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(SystemProxyRecoveryRecord.self, from: data)
    }

    func save(_ record: SystemProxyRecoveryRecord) throws {
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: key)
    }

    func clear() throws {
        defaults.removeObject(forKey: key)
    }
}

final class SystemConfigurationProxyManager: SystemProxySystemManaging, @unchecked Sendable {
    private let preferencesName = "com.jason312928.Target.TargetService"

    func activeServiceIDs() throws -> [String] {
        guard let preferences = SCPreferencesCreate(nil, preferencesName as CFString, nil),
              let networkSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService] else {
            throw SystemProxyError.noActiveNetworkService
        }

        let enabled = Set(services.compactMap { service -> String? in
            guard SCNetworkServiceGetEnabled(service), let identifier = SCNetworkServiceGetServiceID(service) else {
                return nil
            }
            return identifier as String
        })
        let active = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { key -> String? in
            guard let state = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any] else { return nil }
            return state[kSCDynamicStorePropNetPrimaryService as String] as? String
        }
        let serviceIDs = Array(Set(active)).filter { enabled.contains($0) }
        guard !serviceIDs.isEmpty else { throw SystemProxyError.noActiveNetworkService }
        return serviceIDs
    }

    func proxySettings(for serviceID: String) throws -> [String: SystemProxyValue] {
        let protocolReference = try proxyProtocol(for: serviceID)
        let configuration = (SCNetworkProtocolGetConfiguration(protocolReference) as? [String: Any]) ?? [:]
        var result: [String: SystemProxyValue] = [:]
        for (key, value) in configuration {
            guard let proxyValue = SystemProxyValue(foundationValue: value) else {
                throw SystemProxyError.snapshotFailed
            }
            result[key] = proxyValue
        }
        return result
    }

    func setProxySettings(_ settings: [String: SystemProxyValue], for serviceID: String) throws {
        guard let preferences = SCPreferencesCreate(nil, preferencesName as CFString, nil) else {
            throw SystemProxyError.applyFailed
        }
        let protocolReference = try proxyProtocol(for: serviceID, preferences: preferences)
        let configuration = settings.mapValues(\.foundationValue) as CFDictionary
        guard SCNetworkProtocolSetConfiguration(protocolReference, configuration),
              SCPreferencesCommitChanges(preferences),
              SCPreferencesApplyChanges(preferences) else {
            throw SystemProxyError.applyFailed
        }
    }

    private func proxyProtocol(for serviceID: String, preferences: SCPreferences? = nil) throws -> SCNetworkProtocol {
        let preferences = preferences ?? SCPreferencesCreate(nil, preferencesName as CFString, nil)
        guard let preferences,
              let networkSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService],
              let service = services.first(where: { SCNetworkServiceGetServiceID($0) as String? == serviceID }),
              let protocolReference = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            throw SystemProxyError.applyFailed
        }
        return protocolReference
    }
}

private final class TCPPortProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

struct TCPPort2080Probe: LocalProxyProbing {
    func isAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: 2080, using: .tcp)
            let completion = TCPPortProbeCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                    connection.cancel()
                case .failed, .cancelled:
                    completion.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                completion.finish(false)
                connection.cancel()
            }
        }
    }
}

actor SystemProxyCoordinator {
    static let localHost = "127.0.0.1"
    static let localPort = 2080

    private let system: any SystemProxySystemManaging
    private let recoveryStore: any SystemProxyRecoveryStoring
    private let portProbe: any LocalProxyProbing
    private let environment: any HostNetworkEnvironmentChecking
    private let safetyMode: HostNetworkSafetyMode
    private var monitoringTask: Task<Void, Never>?

    init(
        system: any SystemProxySystemManaging = SystemConfigurationProxyManager(),
        recoveryStore: any SystemProxyRecoveryStoring = UserDefaultsSystemProxyRecoveryStore(),
        portProbe: any LocalProxyProbing = TCPPort2080Probe(),
        environment: any HostNetworkEnvironmentChecking = HostNetworkEnvironmentProbe(),
        safetyMode: HostNetworkSafetyMode = .safe
    ) {
        self.system = system
        self.recoveryStore = recoveryStore
        self.portProbe = portProbe
        self.environment = environment
        self.safetyMode = safetyMode
    }

    deinit { monitoringTask?.cancel() }

    func start() async {
        // Deliberately do not recover automatically. A host change is never a safe
        // response to a port-health observation.
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.observePortHealth()
            }
        }
    }

    func querySystemProxyStatus() async -> SystemProxyStatus {
        guard let record = try? recoveryStore.load() else {
            return SystemProxyStatus(state: .disabled, engineReachable: await portProbe.isAvailable(), affectedServiceCount: 0, error: nil, hasRecoverySnapshot: false)
        }
        guard record.owner == TargetServiceIdentifiers.snapshotOwner else {
            return SystemProxyStatus(state: .recoveryRequired, engineReachable: await portProbe.isAvailable(), affectedServiceCount: record.snapshots.count, error: .invalidSnapshotOwner, hasRecoverySnapshot: false)
        }
        let snapshots = record.snapshots
        let reachable = await portProbe.isAvailable()
        guard reachable else {
            return SystemProxyStatus(state: .recoveryRequired, engineReachable: false, affectedServiceCount: snapshots.count, error: .localProxyUnavailable, hasRecoverySnapshot: true)
        }
        do {
            let managed = try settingsMatchLastWrite(record)
            return SystemProxyStatus(
                state: managed ? .enabled : .recoveryRequired,
                engineReachable: true,
                affectedServiceCount: snapshots.count,
                error: managed ? nil : .externalModificationConflict,
                hasRecoverySnapshot: true
            )
        } catch {
            return SystemProxyStatus(state: .recoveryRequired, engineReachable: true, affectedServiceCount: snapshots.count, error: .externalModificationConflict, hasRecoverySnapshot: true)
        }
    }

    func enableSystemProxy() async throws -> SystemProxyStatus {
        try requireNetworkWritePermission()
        guard await portProbe.isAvailable() else { throw SystemProxyError.localProxyUnavailable }

        if let existing = try recoveryStore.load() {
            guard existing.owner == TargetServiceIdentifiers.snapshotOwner else { throw SystemProxyError.invalidSnapshotOwner }
            let isAlreadyEnabled = try settingsMatchLastWrite(existing)
            if isAlreadyEnabled {
                return SystemProxyStatus(state: .enabled, engineReachable: true, affectedServiceCount: existing.snapshots.count, error: nil, hasRecoverySnapshot: true)
            }
            throw SystemProxyError.externalModificationConflict
        }

        let serviceIDs = try system.activeServiceIDs()
        let snapshots = try serviceIDs.map { serviceID in
            SystemProxySnapshot(serviceID: serviceID, properties: try system.proxySettings(for: serviceID))
        }
        guard !snapshots.isEmpty else { throw SystemProxyError.noActiveNetworkService }
        let writtenSettings = Dictionary(uniqueKeysWithValues: snapshots.map { snapshot in
            (snapshot.serviceID, managedSettings(from: snapshot.properties))
        })
        let record = SystemProxyRecoveryRecord(owner: TargetServiceIdentifiers.snapshotOwner, snapshots: snapshots, writtenSettings: writtenSettings)
        try recoveryStore.save(record)

        do {
            for snapshot in snapshots {
                try system.setProxySettings(managedSettings(from: snapshot.properties), for: snapshot.serviceID)
            }
            guard try settingsMatchLastWrite(record) else {
                throw SystemProxyError.verificationFailed
            }
            return SystemProxyStatus(state: .enabled, engineReachable: true, affectedServiceCount: snapshots.count, error: nil, hasRecoverySnapshot: true)
        } catch {
            do {
                try restore(record)
                try recoveryStore.clear()
            } catch {
                throw SystemProxyError.recoveryFailed
            }
            throw (error as? SystemProxyError) ?? .applyFailed
        }
    }

    func disableSystemProxy() async throws -> SystemProxyStatus {
        try requireNetworkWritePermission()
        guard let record = try recoveryStore.load() else {
            return SystemProxyStatus(state: .disabled, engineReachable: await portProbe.isAvailable(), affectedServiceCount: 0, error: nil, hasRecoverySnapshot: false)
        }
        guard record.owner == TargetServiceIdentifiers.snapshotOwner else { throw SystemProxyError.invalidSnapshotOwner }
        do {
            guard try settingsMatchLastWrite(record) else { throw SystemProxyError.externalModificationConflict }
            try restore(record)
            try recoveryStore.clear()
            return SystemProxyStatus(state: .disabled, engineReachable: await portProbe.isAvailable(), affectedServiceCount: 0, error: nil, hasRecoverySnapshot: false)
        } catch let error as SystemProxyError {
            throw error
        } catch {
            throw SystemProxyError.recoveryFailed
        }
    }

    func recoverSystemProxy() async throws -> SystemProxyStatus {
        try await disableSystemProxy()
    }

    func checkPortHealth() async {
        await observePortHealth()
    }

    private func observePortHealth() async {
        _ = await portProbe.isAvailable()
    }

    private func restore(_ record: SystemProxyRecoveryRecord) throws {
        for snapshot in record.snapshots {
            try system.setProxySettings(snapshot.properties, for: snapshot.serviceID)
        }
        guard try record.snapshots.allSatisfy({ try system.proxySettings(for: $0.serviceID) == $0.properties }) else {
            throw SystemProxyError.verificationFailed
        }
    }

    private func requireNetworkWritePermission() throws {
        guard safetyMode.permitsNetworkWrites else { throw SystemProxyError.safeModeBlocked }
        guard environment.inspect().mayTakeOverNetwork else { throw SystemProxyError.existingNetworkController }
    }

    private func settingsMatchLastWrite(_ record: SystemProxyRecoveryRecord) throws -> Bool {
        try record.snapshots.allSatisfy { snapshot in
            guard let expected = record.writtenSettings[snapshot.serviceID] else { return false }
            return try system.proxySettings(for: snapshot.serviceID) == expected
        }
    }

    private func managedSettings(from original: [String: SystemProxyValue]) -> [String: SystemProxyValue] {
        var settings = original
        let localHost = SystemProxyValue.string(Self.localHost)
        let localPort = SystemProxyValue.integer(Self.localPort)
        settings[kSCPropNetProxiesHTTPEnable as String] = .integer(1)
        settings[kSCPropNetProxiesHTTPProxy as String] = localHost
        settings[kSCPropNetProxiesHTTPPort as String] = localPort
        settings[kSCPropNetProxiesHTTPSEnable as String] = .integer(1)
        settings[kSCPropNetProxiesHTTPSProxy as String] = localHost
        settings[kSCPropNetProxiesHTTPSPort as String] = localPort
        settings[kSCPropNetProxiesSOCKSEnable as String] = .integer(1)
        settings[kSCPropNetProxiesSOCKSProxy as String] = localHost
        settings[kSCPropNetProxiesSOCKSPort as String] = localPort
        settings[kSCPropNetProxiesProxyAutoConfigEnable as String] = .integer(0)
        settings[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] = .integer(0)
        return settings
    }

    private func isManagedProxy(_ settings: [String: SystemProxyValue]) throws -> Bool {
        let host = SystemProxyValue.string(Self.localHost)
        let port = SystemProxyValue.integer(Self.localPort)
        return settings[kSCPropNetProxiesHTTPEnable as String] == .integer(1)
            && settings[kSCPropNetProxiesHTTPProxy as String] == host
            && settings[kSCPropNetProxiesHTTPPort as String] == port
            && settings[kSCPropNetProxiesHTTPSEnable as String] == .integer(1)
            && settings[kSCPropNetProxiesHTTPSProxy as String] == host
            && settings[kSCPropNetProxiesHTTPSPort as String] == port
            && settings[kSCPropNetProxiesSOCKSEnable as String] == .integer(1)
            && settings[kSCPropNetProxiesSOCKSProxy as String] == host
            && settings[kSCPropNetProxiesSOCKSPort as String] == port
            && settings[kSCPropNetProxiesProxyAutoConfigEnable as String] == .integer(0)
            && settings[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] == .integer(0)
    }
}
