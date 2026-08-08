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

protocol TargetRuntimeOperating: Sendable {
    func startEngine() async throws -> EngineStartResult
    func stopEngineSafely() async throws -> EngineStopResult
}

actor TargetRuntimeOperations: TargetRuntimeOperating {
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
        let engineStatus = try await backend.stopEngine()
        return EngineStopResult(engineStatus: engineStatus, systemProxyStatus: finalProxyStatus)
    }
}
