import Foundation

enum SystemProxyRecoveryBlocker: String, Codable, Equatable, Sendable {
    case hostSafeMode = "host_safe_mode"
    case operationInProgress = "operation_in_progress"
    case statusUnavailable = "status_unavailable"
    case invalidSnapshotOwner = "invalid_snapshot_owner"
    case unreadableRecoveryRecord = "unreadable_recovery_record"
    case externalModificationConflict = "external_modification_conflict"
    case recoverySnapshotMissing = "recovery_snapshot_missing"
    case recoveryNotRequired = "recovery_not_required"
}

struct SystemProxyRecoveryCapability: Equatable, Sendable {
    let isAvailable: Bool
    let blocker: SystemProxyRecoveryBlocker?
}

extension SystemProxyStatus {
    func recoveryCapability(
        hostNetworkSafetyMode: HostNetworkSafetyMode,
        isOperationInProgress: Bool
    ) -> SystemProxyRecoveryCapability {
        if !hostNetworkSafetyMode.permitsNetworkWrites {
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .hostSafeMode)
        }
        if isOperationInProgress {
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .operationInProgress)
        }
        switch error {
        case .statusUnavailable:
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .statusUnavailable)
        case .invalidSnapshotOwner:
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .invalidSnapshotOwner)
        case .snapshotFailed:
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .unreadableRecoveryRecord)
        case .externalModificationConflict:
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .externalModificationConflict)
        default:
            break
        }
        guard state == .recoveryRequired else {
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .recoveryNotRequired)
        }
        guard hasRecoverySnapshot else {
            return SystemProxyRecoveryCapability(isAvailable: false, blocker: .recoverySnapshotMissing)
        }
        return SystemProxyRecoveryCapability(isAvailable: true, blocker: nil)
    }

    func preservingRecoveryEvidenceWhileStatusIsUnavailable() -> SystemProxyStatus {
        SystemProxyStatus(
            state: .failed,
            engineReachable: engineReachable,
            affectedServiceCount: affectedServiceCount,
            error: .statusUnavailable,
            hasRecoverySnapshot: hasRecoverySnapshot
        )
    }
}

struct TargetSystemProxyOperationError: Error, Equatable, Sendable {
    let operationError: SystemProxyError
    let reconciledStatus: SystemProxyStatus
}

protocol TargetSystemProxyOperating: Sendable {
    func queryStatus() async throws -> SystemProxyStatus
    func enable() async throws -> SystemProxyStatus
    func disable() async throws -> SystemProxyStatus
    func recover() async throws -> SystemProxyStatus
}

actor TargetSystemProxyOperations: TargetSystemProxyOperating {
    private enum Mutation {
        case enable
        case disable
        case recover

        var fallbackError: SystemProxyError {
            switch self {
            case .enable: .applyFailed
            case .disable, .recover: .recoveryFailed
            }
        }
    }

    private let client: any SystemProxyClient
    private var lastAuthoritativeStatus = SystemProxyStatus.disabled

    init(client: any SystemProxyClient = TargetServiceXPCClient()) {
        self.client = client
    }

    func queryStatus() async throws -> SystemProxyStatus {
        do {
            return try await authoritativeStatus()
        } catch {
            throw TargetSystemProxyOperationError(
                operationError: .statusUnavailable,
                reconciledStatus: lastAuthoritativeStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            )
        }
    }

    func enable() async throws -> SystemProxyStatus {
        try await mutate(.enable) { try await client.enableSystemProxy() }
    }

    func disable() async throws -> SystemProxyStatus {
        try await mutate(.disable) { try await client.disableSystemProxy() }
    }

    func recover() async throws -> SystemProxyStatus {
        try await mutate(.recover) { try await client.recoverSystemProxy() }
    }

    private func mutate(
        _ mutation: Mutation,
        action: () async throws -> SystemProxyStatus
    ) async throws -> SystemProxyStatus {
        do {
            let status = try await action()
            lastAuthoritativeStatus = status
            return status
        } catch {
            let operationError = SystemProxyError(serviceError: error) ?? mutation.fallbackError
            let reconciledStatus: SystemProxyStatus
            do {
                reconciledStatus = try await authoritativeStatus()
            } catch {
                reconciledStatus = lastAuthoritativeStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            }
            throw TargetSystemProxyOperationError(
                operationError: operationError,
                reconciledStatus: reconciledStatus
            )
        }
    }

    private func authoritativeStatus() async throws -> SystemProxyStatus {
        let status = try await client.querySystemProxyStatus()
        lastAuthoritativeStatus = status
        return status
    }
}
