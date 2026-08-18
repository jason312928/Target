import Foundation

protocol SystemProxyClient: Sendable {
    func ping() async throws -> String
    func querySystemProxyStatus() async throws -> SystemProxyStatus
    func enableSystemProxy() async throws -> SystemProxyStatus
    func disableSystemProxy() async throws -> SystemProxyStatus
    func recoverSystemProxy() async throws -> SystemProxyStatus
}

struct EngineStopResult: Equatable, Sendable {
    let engineStatus: BackendStatus
    let systemProxyStatus: SystemProxyStatus?
}

struct EngineStartResult: Equatable, Sendable {
    let engineStatus: BackendStatus
    let systemProxyStatus: SystemProxyStatus
}

struct TargetConnectionResult: Equatable, Sendable {
    let engineStatus: BackendStatus
    let systemProxyStatus: SystemProxyStatus
}

struct TargetConnectionOperationError: Error, Equatable, Sendable {
    let operationError: SystemProxyError
    let engineStatus: BackendStatus
    let systemProxyStatus: SystemProxyStatus
    let engineWasStopped: Bool
}

protocol TargetRuntimeOperating: Sendable {
    func startEngine() async throws -> EngineStartResult
    func stopEngineSafely() async throws -> EngineStopResult
}

protocol TargetConnectionOperating: Sendable {
    func connect() async throws -> TargetConnectionResult
    func disconnect() async throws -> EngineStopResult
    func restart() async throws -> TargetConnectionResult
}

actor UnavailableTargetConnectionOperations: TargetConnectionOperating {
    func connect() async throws -> TargetConnectionResult { throw BackendError.notImplemented }
    func disconnect() async throws -> EngineStopResult { throw BackendError.notImplemented }
    func restart() async throws -> TargetConnectionResult { throw BackendError.notImplemented }
}

actor TargetRuntimeOperations: TargetRuntimeOperating, TargetConnectionOperating {
    private let backend: any EngineBackend
    private let systemProxyClient: any SystemProxyClient
    private let systemProxyOperations: any TargetSystemProxyOperating
    private let hostNetworkSafetyMode: HostNetworkSafetyMode

    init(
        backend: any EngineBackend,
        systemProxyClient: any SystemProxyClient = TargetServiceXPCClient(),
        systemProxyOperations: (any TargetSystemProxyOperating)? = nil,
        hostNetworkSafetyMode: HostNetworkSafetyMode = TargetValidationPolicy.hostNetworkSafetyMode
    ) {
        self.backend = backend
        self.systemProxyClient = systemProxyClient
        self.systemProxyOperations = systemProxyOperations ?? TargetSystemProxyOperations(client: systemProxyClient)
        self.hostNetworkSafetyMode = hostNetworkSafetyMode
    }

    func startEngine() async throws -> EngineStartResult {
        let engineStatus = try await backend.startEngine()
        let proxyStatus: SystemProxyStatus
        do {
            proxyStatus = try await systemProxyOperations.queryStatus()
        } catch let error as TargetSystemProxyOperationError {
            proxyStatus = error.reconciledStatus
        } catch {
            proxyStatus = SystemProxyStatus.disabled.preservingRecoveryEvidenceWhileStatusIsUnavailable()
        }
        return EngineStartResult(engineStatus: engineStatus, systemProxyStatus: proxyStatus)
    }

    func connect() async throws -> TargetConnectionResult {
        let started = try await startEngine()
        guard hostNetworkSafetyMode.permitsNetworkWrites else {
            return TargetConnectionResult(engineStatus: started.engineStatus, systemProxyStatus: started.systemProxyStatus)
        }
        if started.systemProxyStatus.state == .enabled,
           started.systemProxyStatus.error == nil,
           started.systemProxyStatus.hasRecoverySnapshot {
            return TargetConnectionResult(engineStatus: started.engineStatus, systemProxyStatus: started.systemProxyStatus)
        }
        do {
            let enabled = try await systemProxyOperations.enable()
            guard enabled.state == .enabled, enabled.error == nil, enabled.hasRecoverySnapshot else {
                throw SystemProxyError.verificationFailed
            }
            return TargetConnectionResult(engineStatus: started.engineStatus, systemProxyStatus: enabled)
        } catch let error as TargetSystemProxyOperationError {
            return try await rollbackConnectionFailure(
                operationError: error.operationError,
                engineStatus: started.engineStatus,
                systemProxyStatus: error.reconciledStatus
            )
        } catch let error as SystemProxyError {
            let status = (try? await systemProxyOperations.queryStatus()) ?? started.systemProxyStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            return try await rollbackConnectionFailure(operationError: error, engineStatus: started.engineStatus, systemProxyStatus: status)
        } catch {
            let status = (try? await systemProxyOperations.queryStatus()) ?? started.systemProxyStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            return try await rollbackConnectionFailure(operationError: .applyFailed, engineStatus: started.engineStatus, systemProxyStatus: status)
        }
    }

    func disconnect() async throws -> EngineStopResult { try await stopEngineSafely() }

    func restart() async throws -> TargetConnectionResult {
        let wasProxyEnabled: Bool
        if hostNetworkSafetyMode.permitsNetworkWrites {
            if let status = try? await systemProxyOperations.queryStatus() {
                wasProxyEnabled = status.state == .enabled && status.error == nil && status.hasRecoverySnapshot
            } else {
                wasProxyEnabled = false
            }
        } else {
            wasProxyEnabled = false
        }
        _ = try await stopEngineSafely()
        let started = try await startEngine()
        guard wasProxyEnabled, hostNetworkSafetyMode.permitsNetworkWrites else {
            return TargetConnectionResult(engineStatus: started.engineStatus, systemProxyStatus: started.systemProxyStatus)
        }
        do {
            let enabled = try await systemProxyOperations.enable()
            guard enabled.state == .enabled, enabled.error == nil, enabled.hasRecoverySnapshot else {
                throw SystemProxyError.verificationFailed
            }
            return TargetConnectionResult(engineStatus: started.engineStatus, systemProxyStatus: enabled)
        } catch let error as TargetSystemProxyOperationError {
            return try await rollbackConnectionFailure(operationError: error.operationError, engineStatus: started.engineStatus, systemProxyStatus: error.reconciledStatus)
        } catch let error as SystemProxyError {
            let status = (try? await systemProxyOperations.queryStatus()) ?? started.systemProxyStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            return try await rollbackConnectionFailure(operationError: error, engineStatus: started.engineStatus, systemProxyStatus: status)
        } catch {
            let status = (try? await systemProxyOperations.queryStatus()) ?? started.systemProxyStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
            return try await rollbackConnectionFailure(operationError: .applyFailed, engineStatus: started.engineStatus, systemProxyStatus: status)
        }
    }

    private func rollbackConnectionFailure(
        operationError: SystemProxyError,
        engineStatus: BackendStatus,
        systemProxyStatus: SystemProxyStatus
    ) async throws -> TargetConnectionResult {
        if systemProxyStatus.state == .disabled && !systemProxyStatus.hasRecoverySnapshot {
            do {
                let stopped = try await backend.stopEngine()
                throw TargetConnectionOperationError(operationError: operationError, engineStatus: stopped, systemProxyStatus: systemProxyStatus, engineWasStopped: true)
            } catch let error as TargetConnectionOperationError { throw error }
            catch {
                let reconciledEngineStatus = (try? await backend.queryStatus()) ?? engineStatus
                throw TargetConnectionOperationError(
                    operationError: operationError,
                    engineStatus: reconciledEngineStatus,
                    systemProxyStatus: systemProxyStatus,
                    engineWasStopped: reconciledEngineStatus.engineState == .stopped
                )
            }
        }
        throw TargetConnectionOperationError(operationError: operationError, engineStatus: engineStatus, systemProxyStatus: systemProxyStatus, engineWasStopped: false)
    }

    func stopEngineSafely() async throws -> EngineStopResult {
        var finalProxyStatus: SystemProxyStatus?

        if hostNetworkSafetyMode.permitsNetworkWrites {
            let currentProxyStatus = try await systemProxyClient.querySystemProxyStatus()
            try Task.checkCancellation()

            if currentProxyStatus.state == .disabled && !currentProxyStatus.hasRecoverySnapshot {
                finalProxyStatus = currentProxyStatus
            } else {
                let restoredProxyStatus = try await systemProxyClient.disableSystemProxy()
                guard restoredProxyStatus.state == .disabled,
                      !restoredProxyStatus.hasRecoverySnapshot,
                      restoredProxyStatus.error == nil else {
                    throw SystemProxyError.verificationFailed
                }
                finalProxyStatus = restoredProxyStatus
            }
        }

        // Cancellation after restoration intentionally leaves the engine running
        // with the host proxy already restored to its exact baseline.
        try Task.checkCancellation()
        let currentEngineStatus = try await backend.queryStatus()
        if currentEngineStatus.engineState == .stopped {
            return EngineStopResult(engineStatus: currentEngineStatus, systemProxyStatus: finalProxyStatus)
        }
        let engineStatus = try await backend.stopEngine()
        return EngineStopResult(engineStatus: engineStatus, systemProxyStatus: finalProxyStatus)
    }
}
