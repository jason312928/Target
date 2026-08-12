import Foundation
import CryptoKit
import TargetCore

enum ProfileValidationStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case valid
    case invalid
}

struct ProfileValidation: Codable, Equatable, Sendable {
    var status: ProfileValidationStatus
    var checkedAt: Date?
    var error: ConfigurationDiagnostic?

    static let notChecked = ProfileValidation(status: .notChecked, checkedAt: nil, error: nil)
}

struct ConfigurationDiagnostic: Error, Codable, Equatable, Sendable {
    var messageKey: String
    var line: Int?
    var column: Int?
}

/// Metadata is deliberately separate from the configuration JSON. The URL is never
/// rendered in logs or diagnostics; it exists only so a future explicit refresh can
/// use the source selected by the user.
enum SubscriptionCacheStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case updated
    case notModified
    case failed
    case cancelled
}

/// Subscription metadata is private application data (the enclosing manifest is
/// owner-readable only). It is never included in diagnostics or application logs.
struct RemoteSubscription: Codable, Equatable, Sendable {
    let url: URL
    var lastUpdatedAt: Date?
    var lastCheckedAt: Date?
    var etag: String?
    var lastModified: String?
    var cacheStatus: SubscriptionCacheStatus
    var lastErrorKey: String?

    init(
        url: URL,
        lastUpdatedAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        cacheStatus: SubscriptionCacheStatus = .notChecked,
        lastErrorKey: String? = nil
    ) {
        self.url = url
        self.lastUpdatedAt = lastUpdatedAt
        self.lastCheckedAt = lastCheckedAt
        self.etag = etag
        self.lastModified = lastModified
        self.cacheStatus = cacheStatus
        self.lastErrorKey = lastErrorKey
    }

    private enum CodingKeys: String, CodingKey {
        case url, lastUpdatedAt, lastCheckedAt, etag, lastModified, cacheStatus, lastErrorKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        lastUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        etag = try values.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try values.decodeIfPresent(String.self, forKey: .lastModified)
        cacheStatus = try values.decodeIfPresent(SubscriptionCacheStatus.self, forKey: .cacheStatus) ?? .notChecked
        lastErrorKey = try values.decodeIfPresent(String.self, forKey: .lastErrorKey)
    }
}

struct ProfileVersionSummary: Identifiable, Equatable, Sendable {
    let revision: Int
    let savedAt: Date?
    var id: Int { revision }
}

struct Profile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var subscription: RemoteSubscription?
    let createdAt: Date
    var updatedAt: Date
    var validation: ProfileValidation
    var validRevision: Int
    /// Target-owned selector choices. These values are encrypted with the
    /// enclosing manifest and never rewrite the user's configuration JSON.
    var policyOverrides: [String: String]

    var hasRemoteSubscription: Bool { subscription != nil }

    init(
        id: UUID,
        name: String,
        subscription: RemoteSubscription?,
        createdAt: Date,
        updatedAt: Date,
        validation: ProfileValidation,
        validRevision: Int,
        policyOverrides: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.subscription = subscription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.validation = validation
        self.validRevision = validRevision
        self.policyOverrides = policyOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, subscription, createdAt, updatedAt, validation, validRevision, policyOverrides
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            subscription: try values.decodeIfPresent(RemoteSubscription.self, forKey: .subscription),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt),
            validation: try values.decode(ProfileValidation.self, forKey: .validation),
            validRevision: try values.decode(Int.self, forKey: .validRevision),
            policyOverrides: try values.decodeIfPresent([String: String].self, forKey: .policyOverrides) ?? [:]
        )
    }
}

enum ProfileStoreError: LocalizedError, Equatable {
    case noSelectedProfile
    case profileNotFound
    case noValidVersion
    case profileInUse
    case invalidName
    case unsafePath
    case invalidJSON(ConfigurationDiagnostic)
    case validationFailed(ConfigurationDiagnostic)
    case invalidStoredMetadata
    case invalidStoredSelection
    case keychainReadFailed
    case encryptedStoreKeyMissing
    case invalidEncryptionKey
    case encryptionFailed
    case invalidEncryptedEnvelope
    case unsupportedStorageVersion
    case encryptedStorageAuthenticationFailed
    case encryptedStorageAADMismatch
    case mixedOrDowngradedStorage
    case missingEncryptedRecord
    case plaintextMigrationValidationFailed
    case plaintextMigrationCommitFailed
    case plaintextMigrationRecoveryFailed
    case profileImportTransactionFailed
    case profileImportRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .noSelectedProfile: "No Profile is selected."
        case .profileNotFound: "Profile not found."
        case .noValidVersion: "The Profile has no valid configuration version."
        case .profileInUse: "Stop the running engine before deleting this Profile."
        case .invalidName: "A profile name is required."
        case .unsafePath: "The requested path is outside Target-managed storage."
        case .invalidJSON, .validationFailed: "The configuration could not be validated."
        case .invalidStoredMetadata, .invalidStoredSelection: "Profile metadata is invalid."
        case .keychainReadFailed, .encryptedStoreKeyMissing, .invalidEncryptionKey,
             .encryptionFailed, .invalidEncryptedEnvelope, .unsupportedStorageVersion,
             .encryptedStorageAuthenticationFailed, .encryptedStorageAADMismatch,
             .mixedOrDowngradedStorage, .missingEncryptedRecord,
             .plaintextMigrationValidationFailed, .plaintextMigrationCommitFailed,
             .plaintextMigrationRecoveryFailed, .profileImportTransactionFailed,
             .profileImportRecoveryFailed:
            "Profile storage could not be loaded safely."
        }
    }
}

/// A launch always uses an immutable version rather than the editor's working
/// document. The bytes are intentionally opaque so unknown sing-box fields are
/// retained exactly in the user-managed source file.
struct ProfileConfigurationVersion: Sendable {
    let profile: Profile
    let revision: Int
    let data: Data
}

/// Credential-safe, allowlisted view of a persisted sing-box Profile. Raw
/// configuration dictionaries never cross this domain boundary.
struct PolicyCatalog: Equatable, Sendable {
    let formatVersion: Int
    let profileID: UUID?
    let profileRevision: Int?
    let sourceFingerprint: String?
    /// Count of all encrypted Target-owned overrides, including entries that no
    /// longer correspond to a selector in the current source Profile.
    let storedOverrideCount: Int
    let selectors: [PolicyCatalogSelector]
}

struct PolicyResetResult: Equatable, Sendable {
    let clearedOverrideCount: Int
    let catalog: PolicyCatalog
}

struct PolicyCatalogSelector: Equatable, Sendable, Identifiable {
    /// The persisted array position is deliberately part of identity: malformed
    /// input is represented verbatim, including duplicate or absent tags.
    let identity: Int
    let tag: String?
    let status: PolicyCatalogStructuralStatus
    let configuredDefault: String?
    let targetOverride: String?
    let overrideValid: Bool
    let effectiveDesired: String?
    let runningSelection: String?
    let runtimeConvergence: PolicyRuntimeConvergenceState
    let restartRequired: Bool
    let members: [PolicyCatalogMember]
    var id: Int { identity }

    var isMutable: Bool {
        status == .available && tag != nil && !members.isEmpty
            && members.allSatisfy { $0.status == .available }
    }
}

struct PolicyCatalogMember: Equatable, Sendable, Identifiable {
    /// The persisted member position preserves duplicate references for SwiftUI.
    let identity: Int
    let tag: String
    let type: String?
    let status: PolicyCatalogStructuralStatus
    var id: Int { identity }
}

enum PolicyCatalogStructuralStatus: String, Equatable, Sendable {
    case available, missingReference, duplicateTag, malformedMembers, invalidTag, unavailable
}

enum PolicyRuntimeConvergenceState: String, Equatable, Sendable {
    case notRunning, converged, restartRequired, unavailable
}

enum PolicyRuntimeEvidence: Equatable, Sendable {
    case stopped
    case running(
        profileID: UUID,
        profileRevision: Int,
        sourceFingerprint: String,
        configuration: Data,
        liveSelections: [String: String]? = nil
    )
    case unavailable
}

protocol PolicyRuntimeEvidenceProviding: Sendable {
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence
}

struct StoppedPolicyRuntimeEvidenceProvider: PolicyRuntimeEvidenceProviding {
    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence { .stopped }
}

/// Immutable identity of a selected Profile revision at the runtime boundary.
/// It must cross every asynchronous controller operation so the backend never
/// infers identity from a later Profile selection.
struct ExpectedPolicyRuntimeIdentity: Equatable, Sendable {
    let profileID: UUID
    let profileRevision: Int
    let sourceFingerprint: String
}

protocol RuntimePolicyApplying: Sendable {
    func applyLivePolicySelection(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        selectorTag: String,
        outboundTag: String
    ) async -> Bool
}

enum RuntimeProxyHealthState: String, Codable, Equatable, Sendable {
    case unknown
    case testing
    case reachable
    case unreachable
    case runtimeUnavailable
}

struct RuntimeProxyHealth: Equatable, Sendable {
    static let maximumLatencyMilliseconds = Int(UInt16.max)

    let tag: String
    let state: RuntimeProxyHealthState
    let latencyMilliseconds: Int?
    let observedAt: Date?

    static func unknown(tag: String) -> RuntimeProxyHealth {
        RuntimeProxyHealth(tag: tag, state: .unknown, latencyMilliseconds: nil, observedAt: nil)
    }

    static func testing(tag: String) -> RuntimeProxyHealth {
        RuntimeProxyHealth(tag: tag, state: .testing, latencyMilliseconds: nil, observedAt: nil)
    }

    static func reachable(
        tag: String,
        latencyMilliseconds: Int,
        observedAt: Date
    ) -> RuntimeProxyHealth? {
        guard (1...maximumLatencyMilliseconds).contains(latencyMilliseconds) else { return nil }
        return RuntimeProxyHealth(
            tag: tag,
            state: .reachable,
            latencyMilliseconds: latencyMilliseconds,
            observedAt: observedAt
        )
    }

    static func unreachable(tag: String, observedAt: Date) -> RuntimeProxyHealth {
        RuntimeProxyHealth(tag: tag, state: .unreachable, latencyMilliseconds: nil, observedAt: observedAt)
    }

    static func runtimeUnavailable(tag: String) -> RuntimeProxyHealth {
        RuntimeProxyHealth(tag: tag, state: .runtimeUnavailable, latencyMilliseconds: nil, observedAt: nil)
    }
}

enum RuntimePolicyHealthProbeOutcome: Equatable, Sendable {
    case runtimeUnavailable
    case results([RuntimeProxyHealth])
}

protocol RuntimePolicyHealthProbing: Sendable {
    func probePolicyMemberLatency(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        outboundTags: [String]
    ) async throws -> RuntimePolicyHealthProbeOutcome
}

struct PolicyLatencyProbeResult: Equatable, Sendable {
    let profileID: UUID
    let profileRevision: Int
    let sourceFingerprint: String
    let selector: String
    let runtimeAvailable: Bool
    let members: [RuntimeProxyHealth]

    var expectedRuntimeIdentity: ExpectedPolicyRuntimeIdentity {
        ExpectedPolicyRuntimeIdentity(
            profileID: profileID,
            profileRevision: profileRevision,
            sourceFingerprint: sourceFingerprint
        )
    }
}

enum TargetPolicyOperationError: Error, Equatable {
    case selectorNotFound
    case selectorAmbiguous
    case selectorUnavailable
    case outboundNotFound
    case outboundUnavailable
    case persistenceFailed
}

enum PolicySelectionValidator {
    static func validate(
        selectorTag: String,
        outboundTag: String,
        in catalog: PolicyCatalog
    ) throws {
        let matches = catalog.selectors.filter { $0.tag == selectorTag }
        guard !matches.isEmpty else { throw TargetPolicyOperationError.selectorNotFound }
        guard matches.count == 1 else { throw TargetPolicyOperationError.selectorAmbiguous }
        let selector = matches[0]
        guard selector.status != .duplicateTag else { throw TargetPolicyOperationError.selectorAmbiguous }
        guard selector.status == .available else { throw TargetPolicyOperationError.selectorUnavailable }
        let outboundMatches = selector.members.filter { $0.tag == outboundTag }
        guard !outboundMatches.isEmpty else { throw TargetPolicyOperationError.outboundNotFound }
        guard outboundMatches.count == 1, outboundMatches[0].status == .available else {
            throw TargetPolicyOperationError.outboundUnavailable
        }
        guard selector.isMutable else { throw TargetPolicyOperationError.selectorUnavailable }
    }
}

enum PolicyCatalogParser {
    static func parse(
        _ data: Data,
        profileID: UUID? = nil,
        profileRevision: Int? = nil,
        overrides: [String: String] = [:]
    ) -> PolicyCatalog {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outbounds = root["outbounds"] as? [Any] else {
            return PolicyCatalog(
                formatVersion: 2,
                profileID: profileID,
                profileRevision: profileRevision,
                sourceFingerprint: TargetConfigurationFingerprint.sha256(data),
                storedOverrideCount: overrides.count,
                selectors: []
            )
        }
        let objects = outbounds.compactMap { $0 as? [String: Any] }
        var tagged: [String: [[String: Any]]] = [:]
        for object in objects { if let tag = nonemptyString(object["tag"]) { tagged[tag, default: []].append(object) } }
        return PolicyCatalog(
            formatVersion: 2,
            profileID: profileID,
            profileRevision: profileRevision,
            sourceFingerprint: TargetConfigurationFingerprint.sha256(data),
            storedOverrideCount: overrides.count,
            selectors: outbounds.enumerated().compactMap { selectorIndex, value in
            guard let selector = value as? [String: Any] else { return nil }
            guard nonemptyString(selector["type"]) == "selector" else { return nil }
            let tag = nonemptyString(selector["tag"])
            let status: PolicyCatalogStructuralStatus
            if tag == nil { status = .invalidTag }
            else if tagged[tag!]?.count != 1 { status = .duplicateTag }
            else { status = .available }
            guard let rawMembers = selector["outbounds"] as? [Any], rawMembers.allSatisfy({ nonemptyString($0) != nil }) else {
                return PolicyCatalogSelector(
                    identity: selectorIndex, tag: tag,
                    status: status == .available ? .malformedMembers : status,
                    configuredDefault: nil, targetOverride: tag.flatMap { overrides[$0] },
                    overrideValid: false, effectiveDesired: nil, runningSelection: nil,
                    runtimeConvergence: .notRunning, restartRequired: false, members: []
                )
            }
            let memberNames = rawMembers.compactMap(nonemptyString)
            let memberCounts = Dictionary(grouping: memberNames, by: { $0 }).mapValues(\.count)
            let members = rawMembers.compactMap(nonemptyString).enumerated().map { memberIndex, name -> PolicyCatalogMember in
                guard memberCounts[name] == 1 else {
                    return PolicyCatalogMember(identity: memberIndex, tag: name, type: nil, status: .duplicateTag)
                }
                guard let matches = tagged[name] else { return PolicyCatalogMember(identity: memberIndex, tag: name, type: nil, status: .missingReference) }
                guard matches.count == 1 else { return PolicyCatalogMember(identity: memberIndex, tag: name, type: nil, status: .duplicateTag) }
                guard let type = nonemptyString(matches[0]["type"]) else {
                    return PolicyCatalogMember(identity: memberIndex, tag: name, type: nil, status: .unavailable)
                }
                return PolicyCatalogMember(identity: memberIndex, tag: name, type: type, status: .available)
            }
            let configuredDefault = nonemptyString(selector["default"]).flatMap { candidate in
                members.first(where: { $0.tag == candidate && $0.status == .available })?.tag
            }
            let isMutable = status == .available && !members.isEmpty && members.allSatisfy { $0.status == .available }
            let targetOverride = tag.flatMap { overrides[$0] }
            let validOverride = isMutable && targetOverride.map { candidate in
                members.contains { $0.tag == candidate && $0.status == .available }
            } == true
            let desired = isMutable ? (validOverride ? targetOverride : configuredDefault ?? members.first?.tag) : nil
            return PolicyCatalogSelector(
                identity: selectorIndex, tag: tag, status: status,
                configuredDefault: configuredDefault, targetOverride: targetOverride,
                overrideValid: validOverride, effectiveDesired: desired,
                runningSelection: nil, runtimeConvergence: .notRunning,
                restartRequired: false, members: members
            )
            }
        )
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }; return value
    }
}

struct PolicyCatalogOperation: @unchecked Sendable {
    private let profileStore: ProfileStore
    init(profileStore: ProfileStore) { self.profileStore = profileStore }
    func read() throws -> PolicyCatalog {
        let version = try profileStore.selectedValidVersion()
        return PolicyCatalogParser.parse(
            version.data,
            profileID: version.profile.id,
            profileRevision: version.revision,
            overrides: version.profile.policyOverrides
        )
    }
}

enum PolicyCatalogReconciler {
    static func reconcile(_ desired: PolicyCatalog, evidence: PolicyRuntimeEvidence) -> PolicyCatalog {
        let runningCatalog: PolicyCatalog?
        let liveSelections: [String: String]?
        let evidenceMatchesSelected: Bool
        switch evidence {
        case .stopped:
            runningCatalog = nil
            liveSelections = nil
            evidenceMatchesSelected = false
        case .unavailable:
            runningCatalog = nil
            liveSelections = nil
            evidenceMatchesSelected = false
        case .running(let profileID, let revision, let sourceFingerprint, let configuration, let selections):
            evidenceMatchesSelected = desired.profileID == profileID
                && desired.profileRevision == revision
                && desired.sourceFingerprint == sourceFingerprint
            liveSelections = selections
            runningCatalog = PolicyCatalogParser.parse(
                configuration,
                profileID: profileID,
                profileRevision: revision
            )
        }

        return PolicyCatalog(
            formatVersion: desired.formatVersion,
            profileID: desired.profileID,
            profileRevision: desired.profileRevision,
            sourceFingerprint: desired.sourceFingerprint,
            storedOverrideCount: desired.storedOverrideCount,
            selectors: desired.selectors.map { selector in
                let running: String?
                let convergence: PolicyRuntimeConvergenceState
                let restartRequired: Bool
                switch evidence {
                case .stopped:
                    running = nil
                    convergence = .notRunning
                    restartRequired = false
                case .unavailable:
                    running = nil
                    convergence = .unavailable
                    restartRequired = selector.isMutable
                case .running:
                    if evidenceMatchesSelected,
                       let liveSelections,
                       let tag = selector.tag,
                       let runningSelection = liveSelections[tag],
                       let runningSelector = runningCatalog?.selectors.first(where: { $0.tag == tag && $0.isMutable }),
                       runningSelector.members.contains(where: { $0.tag == runningSelection && $0.status == .available }) {
                        running = runningSelection
                        restartRequired = running != selector.effectiveDesired
                        convergence = restartRequired ? .restartRequired : .converged
                    } else {
                        running = nil
                        convergence = .unavailable
                        restartRequired = selector.isMutable
                    }
                }
                return PolicyCatalogSelector(
                    identity: selector.identity, tag: selector.tag, status: selector.status,
                    configuredDefault: selector.configuredDefault,
                    targetOverride: selector.targetOverride,
                    overrideValid: selector.overrideValid,
                    effectiveDesired: selector.effectiveDesired,
                    runningSelection: running,
                    runtimeConvergence: convergence,
                    restartRequired: restartRequired,
                    members: selector.members
                )
            }
        )
    }
}

protocol TargetPolicyOperating: Sendable {
    func readPersisted() throws -> PolicyCatalog
    func read() async throws -> PolicyCatalog
    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog
    func reset() async throws -> PolicyResetResult
    func probeLatency(selectorTag: String) async throws -> PolicyLatencyProbeResult
}

extension TargetPolicyOperating {
    func probeLatency(selectorTag: String) async throws -> PolicyLatencyProbeResult {
        throw TargetPolicyOperationError.selectorUnavailable
    }
}

final class TargetPolicyOperations: TargetPolicyOperating, @unchecked Sendable {
    private let profileStore: ProfileStore
    private let runtimeEvidenceProvider: any PolicyRuntimeEvidenceProviding
    private let mutationLock = NSLock()

    init(
        profileStore: ProfileStore,
        runtimeEvidenceProvider: any PolicyRuntimeEvidenceProviding = StoppedPolicyRuntimeEvidenceProvider()
    ) {
        self.profileStore = profileStore
        self.runtimeEvidenceProvider = runtimeEvidenceProvider
    }

    func readPersisted() throws -> PolicyCatalog {
        try PolicyCatalogOperation(profileStore: profileStore).read()
    }

    func read() async throws -> PolicyCatalog {
        let desired = try readPersisted()
        return PolicyCatalogReconciler.reconcile(
            desired,
            evidence: await runtimeEvidenceProvider.currentPolicyRuntimeEvidence()
        )
    }

    func select(selectorTag: String, outboundTag: String) async throws -> PolicyCatalog {
        let committed = try commitSelection(selectorTag: selectorTag, outboundTag: outboundTag)
        if let runtimeController = runtimeEvidenceProvider as? any RuntimePolicyApplying,
           let expectedRuntime = committed.expectedRuntimeIdentity {
            _ = await runtimeController.applyLivePolicySelection(
                expectedRuntime: expectedRuntime,
                selectorTag: selectorTag,
                outboundTag: outboundTag
            )
        }
        return PolicyCatalogReconciler.reconcile(
            committed,
            evidence: await runtimeEvidenceProvider.currentPolicyRuntimeEvidence()
        )
    }

    func reset() async throws -> PolicyResetResult {
        let committed = try commitReset()
        if let runtimeController = runtimeEvidenceProvider as? any RuntimePolicyApplying,
           let expectedRuntime = committed.catalog.expectedRuntimeIdentity {
            for selector in committed.catalog.selectors where selector.isMutable {
                guard let tag = selector.tag, let desired = selector.effectiveDesired else { continue }
                _ = await runtimeController.applyLivePolicySelection(
                    expectedRuntime: expectedRuntime,
                    selectorTag: tag,
                    outboundTag: desired
                )
            }
        }
        let reconciled = PolicyCatalogReconciler.reconcile(
            committed.catalog,
            evidence: await runtimeEvidenceProvider.currentPolicyRuntimeEvidence()
        )
        return PolicyResetResult(
            clearedOverrideCount: committed.clearedOverrideCount,
            catalog: reconciled
        )
    }

    func probeLatency(selectorTag: String) async throws -> PolicyLatencyProbeResult {
        let catalog = try readPersisted()
        let matches = catalog.selectors.filter { $0.tag == selectorTag }
        guard !matches.isEmpty else { throw TargetPolicyOperationError.selectorNotFound }
        guard matches.count == 1, matches[0].status != .duplicateTag else {
            throw TargetPolicyOperationError.selectorAmbiguous
        }
        let selector = matches[0]
        guard selector.status == .available else { throw TargetPolicyOperationError.selectorUnavailable }
        let members = selector.members.filter { $0.status == .available }
        guard !members.isEmpty,
              let expectedRuntime = catalog.expectedRuntimeIdentity else {
            throw TargetPolicyOperationError.selectorUnavailable
        }

        let outcome: RuntimePolicyHealthProbeOutcome
        if let runtimeProber = runtimeEvidenceProvider as? any RuntimePolicyHealthProbing {
            outcome = try await runtimeProber.probePolicyMemberLatency(
                expectedRuntime: expectedRuntime,
                outboundTags: members.map(\.tag)
            )
        } else {
            outcome = .runtimeUnavailable
        }
        try Task.checkCancellation()

        let runtimeAvailable: Bool
        let health: [RuntimeProxyHealth]
        switch outcome {
        case .runtimeUnavailable:
            runtimeAvailable = false
            health = members.map { .runtimeUnavailable(tag: $0.tag) }
        case .results(let results):
            guard results.count == members.count,
                  zip(results, members).allSatisfy({ pair in pair.0.tag == pair.1.tag }) else {
                runtimeAvailable = false
                health = members.map { .runtimeUnavailable(tag: $0.tag) }
                break
            }
            runtimeAvailable = true
            health = results
        }
        return PolicyLatencyProbeResult(
            profileID: expectedRuntime.profileID,
            profileRevision: expectedRuntime.profileRevision,
            sourceFingerprint: expectedRuntime.sourceFingerprint,
            selector: selectorTag,
            runtimeAvailable: runtimeAvailable,
            members: health
        )
    }

    private func commitSelection(selectorTag: String, outboundTag: String) throws -> PolicyCatalog {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        do {
            let desired = try readPersisted()
            try PolicySelectionValidator.validate(
                selectorTag: selectorTag,
                outboundTag: outboundTag,
                in: desired
            )
            guard let profileID = desired.profileID, let revision = desired.profileRevision else {
                throw ProfileStoreError.noValidVersion
            }
            do {
                try profileStore.persistPolicyOverride(
                    profileID: profileID,
                    expectedRevision: revision,
                    selectorTag: selectorTag,
                    outboundTag: outboundTag
                )
            } catch {
                throw TargetPolicyOperationError.persistenceFailed
            }
            return try readPersisted()
        } catch {
            throw error
        }
    }

    private func commitReset() throws -> PolicyResetResult {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let desired = try readPersisted()
        guard let profileID = desired.profileID, let revision = desired.profileRevision else {
            throw ProfileStoreError.noValidVersion
        }
        do {
            let cleared = try profileStore.clearPolicyOverrides(
                profileID: profileID,
                expectedRevision: revision
            )
            return PolicyResetResult(clearedOverrideCount: cleared, catalog: try readPersisted())
        } catch let error as ProfileStoreError where error == .noSelectedProfile || error == .noValidVersion {
            throw error
        } catch {
            throw TargetPolicyOperationError.persistenceFailed
        }
    }
}

private extension PolicyCatalog {
    var expectedRuntimeIdentity: ExpectedPolicyRuntimeIdentity? {
        guard let profileID, let profileRevision, let sourceFingerprint else { return nil }
        return ExpectedPolicyRuntimeIdentity(
            profileID: profileID,
            profileRevision: profileRevision,
            sourceFingerprint: sourceFingerprint
        )
    }
}

extension PolicyCatalog {
    func automationJSON() -> JSONValue {
        .object(["formatVersion": .integer(formatVersion),
                 "profileID": profileID.map { .string($0.uuidString.lowercased()) } ?? .null,
                 "profileRevision": profileRevision.map(JSONValue.integer) ?? .null,
                 "restartRequired": .boolean(selectors.contains(where: \.restartRequired)),
                 "storedOverrideCount": .integer(storedOverrideCount),
                 "selectors": .array(selectors.map { selector in
            .object(["configuredDefault": selector.configuredDefault.map(JSONValue.string) ?? .null,
                     "desiredSelection": selector.effectiveDesired.map(JSONValue.string) ?? .null,
                     "members": .array(selector.members.map { member in .object(["status": .string(member.status.rawValue), "tag": .string(member.tag), "type": member.type.map(JSONValue.string) ?? .null]) }),
                     "overrideValid": .boolean(selector.overrideValid),
                     "runningSelection": selector.runningSelection.map(JSONValue.string) ?? .null,
                     "runtimeConvergence": .string(selector.runtimeConvergence.rawValue),
                     "restartRequired": .boolean(selector.restartRequired),
                     "status": .string(selector.status.rawValue),
                     "tag": selector.tag.map(JSONValue.string) ?? .null,
                     "targetOverride": selector.targetOverride.map(JSONValue.string) ?? .null])
        })])
    }
}

extension PolicyLatencyProbeResult {
    func automationJSON() -> JSONValue {
        .object([
            "formatVersion": .integer(1),
            "members": .array(members.map { member in
                .object([
                    "latencyMilliseconds": member.latencyMilliseconds.map(JSONValue.integer) ?? .null,
                    "state": .string(member.state.rawValue),
                    "tag": .string(member.tag)
                ])
            }),
            "profileID": .string(profileID.uuidString.lowercased()),
            "profileRevision": .integer(profileRevision),
            "runtimeAvailable": .boolean(runtimeAvailable),
            "selector": .string(selector)
        ])
    }
}

enum TargetConfigurationFingerprint {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SafeExampleConfiguration {
    /// This configuration is intentionally limited to a dynamic loopback listener
    /// and the direct outbound. It does not enable system proxy, DNS, TUN, routes,
    /// or firewall changes.
    static func json(port: Int = 0) -> String {
        """
        {
          "log": { "level": "error" },
          "inbounds": [
            {
              "type": "mixed",
              "tag": "local-mixed",
              "listen": "127.0.0.1",
              "listen_port": \(port)
            }
          ],
          "outbounds": [
            { "type": "direct", "tag": "direct" }
          ],
          "route": { "final": "direct" }
        }
        """
    }
}
