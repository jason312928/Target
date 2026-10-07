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

struct TargetServiceRemovalResult: Equatable, Sendable {
    let systemProxyStatus: SystemProxyStatus
    let serviceInstallation: ServiceInstallationState
}

protocol TargetSystemProxyOperating: Sendable {
    func queryStatus() async throws -> SystemProxyStatus
    func enable() async throws -> SystemProxyStatus
    func disable() async throws -> SystemProxyStatus
    func recover() async throws -> SystemProxyStatus
    func removeService(
        unregisterService: @escaping @Sendable () throws -> Void,
        serviceStatus: @escaping @Sendable () -> ServiceInstallationState
    ) async throws -> TargetServiceRemovalResult
}

extension TargetSystemProxyOperating {
    func removeService(
        unregisterService: @escaping @Sendable () throws -> Void,
        serviceStatus: @escaping @Sendable () -> ServiceInstallationState
    ) async throws -> TargetServiceRemovalResult {
        let status: SystemProxyStatus
        do {
            status = try await queryStatus()
        } catch let error as TargetSystemProxyOperationError {
            throw error
        } catch {
            throw TargetSystemProxyOperationError(
                operationError: .statusUnavailable,
                reconciledStatus: .disabled.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            )
        }
        guard status.isSafeForServiceRemoval else {
            throw TargetSystemProxyOperationError(
                operationError: status.error ?? .verificationFailed,
                reconciledStatus: status
            )
        }
        try unregisterService()
        return TargetServiceRemovalResult(
            systemProxyStatus: status,
            serviceInstallation: serviceStatus()
        )
    }
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
    private let serviceRegistrationStatus: @Sendable () -> ServiceInstallationState
    private var lastAuthoritativeStatus = SystemProxyStatus.disabled
    // Actor isolation is re-entrant across await. Chain each external operation so
    // removal's authoritative read and unregister cannot be interleaved by a mutation.
    private var operationTail: Task<Void, Never>?

    init(
        client: any SystemProxyClient = TargetServiceXPCClient(),
        serviceRegistrationStatus: @escaping @Sendable () -> ServiceInstallationState = { .enabled }
    ) {
        self.client = client
        self.serviceRegistrationStatus = serviceRegistrationStatus
    }

    func queryStatus() async throws -> SystemProxyStatus {
        let client = client
        return try await enqueue { [weak self] in
            do {
                let status = try await client.querySystemProxyStatus()
                await self?.record(status)
                return status
            } catch {
                let fallback = await self?.lastStatus() ?? .disabled
                throw TargetSystemProxyOperationError(
                    operationError: .statusUnavailable,
                    reconciledStatus: fallback.preservingRecoveryEvidenceWhileStatusIsUnavailable()
                )
            }
        }
    }

    func enable() async throws -> SystemProxyStatus {
        try await mutate(.enable)
    }

    func disable() async throws -> SystemProxyStatus {
        try await mutate(.disable)
    }

    func recover() async throws -> SystemProxyStatus {
        try await mutate(.recover)
    }

    func removeService(
        unregisterService: @escaping @Sendable () throws -> Void,
        serviceStatus: @escaping @Sendable () -> ServiceInstallationState
    ) async throws -> TargetServiceRemovalResult {
        let client = client
        return try await enqueue { [weak self] in
            var removalToken: Data?
            let status: SystemProxyStatus
            if let removalClient = client as? any TargetServiceRemovalClient {
                do {
                    let lease = try await removalClient.prepareServiceRemoval()
                    removalToken = lease.token
                    status = lease.status
                    await self?.record(status)
                } catch {
                    let queriedStatus = try? await client.querySystemProxyStatus()
                    let fallback: SystemProxyStatus
                    if let queriedStatus {
                        fallback = queriedStatus
                    } else {
                        fallback = await self?.lastStatus() ?? .disabled
                    }
                    await self?.record(fallback)
                    let operationError = SystemProxyError(serviceError: error) ?? .statusUnavailable
                    let reconciledStatus: SystemProxyStatus
                    if operationError == .serviceRemovalInProgress {
                        reconciledStatus = SystemProxyStatus(
                            state: .failed,
                            engineReachable: fallback.engineReachable,
                            affectedServiceCount: fallback.affectedServiceCount,
                            error: operationError,
                            hasRecoverySnapshot: fallback.hasRecoverySnapshot
                        )
                    } else {
                        reconciledStatus = fallback
                    }
                    throw TargetSystemProxyOperationError(
                        operationError: operationError,
                        reconciledStatus: reconciledStatus
                    )
                }
            } else {
                do {
                    status = try await client.querySystemProxyStatus()
                    await self?.record(status)
                } catch {
                    let fallback = await self?.lastStatus() ?? .disabled
                    throw TargetSystemProxyOperationError(
                        operationError: .statusUnavailable,
                        reconciledStatus: fallback.preservingRecoveryEvidenceWhileStatusIsUnavailable()
                    )
                }
                guard status.isSafeForServiceRemoval else {
                    throw TargetSystemProxyOperationError(
                        operationError: status.error ?? .verificationFailed,
                        reconciledStatus: status
                    )
                }
            }

            do {
                try unregisterService()
            } catch {
                if let removalToken, let removalClient = client as? any TargetServiceRemovalClient {
                    try? await removalClient.cancelServiceRemoval(removalToken)
                }
                throw error
            }
            if let removalToken, let removalClient = client as? any TargetServiceRemovalClient {
                // Unregister succeeded. Completion releases the connection-owned
                // lease promptly; client disappearance releases it via XPC
                // invalidation on the service side.
                try? await removalClient.completeServiceRemoval(removalToken)
            }
            return TargetServiceRemovalResult(
                systemProxyStatus: status,
                serviceInstallation: serviceStatus()
            )
        }
    }

    private func mutate(_ mutation: Mutation) async throws -> SystemProxyStatus {
        let client = client
        let serviceRegistrationStatus = serviceRegistrationStatus
        return try await enqueue { [weak self] in
            guard serviceRegistrationStatus() != .notRegistered else {
                let status = await self?.lastStatus() ?? .disabled
                throw TargetSystemProxyOperationError(
                    operationError: .noActiveNetworkService,
                    reconciledStatus: status
                )
            }
            do {
                let status: SystemProxyStatus
                switch mutation {
                case .enable: status = try await client.enableSystemProxy()
                case .disable: status = try await client.disableSystemProxy()
                case .recover: status = try await client.recoverSystemProxy()
                }
                await self?.record(status)
                return status
            } catch {
                let operationError = SystemProxyError(serviceError: error) ?? mutation.fallbackError
                let reconciledStatus: SystemProxyStatus
                do {
                    reconciledStatus = try await client.querySystemProxyStatus()
                    await self?.record(reconciledStatus)
                } catch {
                    let fallback = await self?.lastStatus() ?? .disabled
                    reconciledStatus = fallback.preservingRecoveryEvidenceWhileStatusIsUnavailable()
                }
                throw TargetSystemProxyOperationError(
                    operationError: operationError,
                    reconciledStatus: reconciledStatus
                )
            }
        }
    }

    private func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = operationTail
        let task = Task<T, Error> {
            if let previous { await previous.value }
            return try await operation()
        }
        operationTail = Task { _ = await task.result }
        return try await task.value
    }

    private func record(_ status: SystemProxyStatus) {
        lastAuthoritativeStatus = status
    }

    private func lastStatus() -> SystemProxyStatus {
        lastAuthoritativeStatus
    }
}
