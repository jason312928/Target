import Foundation

actor MockBackend: EngineBackend {
    private var status: BackendStatus
    private let operationDelay: Duration?

    init(
        initialStatus: BackendStatus = .mockDefault,
        operationDelay: Duration? = nil
    ) {
        self.status = initialStatus
        self.operationDelay = operationDelay
    }

    func queryStatus() async throws -> BackendStatus {
        try Task.checkCancellation()
        return status
    }

    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {
        try Task.checkCancellation()
        _ = try request.validated()
    }

    func startEngine() async throws -> BackendStatus {
        guard status.serviceInstallation == .enabled else {
            throw BackendError.serviceNotInstalled
        }
        guard status.engineState == .stopped else {
            throw BackendError.invalidLifecycleTransition
        }

        status.engineState = .starting
        try await waitForOperationIfNeeded()
        status.engineState = .running
        return status
    }

    func stopEngine() async throws -> BackendStatus {
        guard status.engineState == .running else {
            throw BackendError.invalidLifecycleTransition
        }

        status.engineState = .stopping
        try await waitForOperationIfNeeded()
        status.engineState = .stopped
        return status
    }

    private func waitForOperationIfNeeded() async throws {
        try Task.checkCancellation()
        if let operationDelay {
            try await Task.sleep(for: operationDelay)
        }
        try Task.checkCancellation()
    }
}
