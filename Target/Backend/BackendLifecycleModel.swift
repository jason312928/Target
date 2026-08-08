import Foundation
import Observation

@MainActor
@Observable
final class BackendLifecycleModel {
    private let backend: any EngineBackend
    private let engineInstaller: (any EngineInstalling)?
    private let serviceManager: (any ServiceLifecycleManaging)?
    private let serviceTester: (any ServiceConnectionTesting)?
    private let systemProxyClient: any SystemProxyClient
    private let systemProxyOperations: any TargetSystemProxyOperating
    private let runtimeOperations: any TargetRuntimeOperating
    private var operationTask: Task<Void, Never>?
    private let hostNetworkSafetyMode: HostNetworkSafetyMode
    private let cancellationReconciliationTimeout = Duration.milliseconds(250)

    private(set) var status: BackendStatus
    private(set) var serviceInstallation: ServiceInstallationState
    private(set) var xpcState: XPCConnectionState
    private(set) var lifecycleState: BackendLifecycleState
    private(set) var error: BackendError?
    private(set) var pingResult: String?
    private(set) var systemProxyStatus = SystemProxyStatus.disabled

    init(
        backend: any EngineBackend = SingBoxBackend(),
        systemProxyClient: any SystemProxyClient = TargetServiceXPCClient(),
        systemProxyOperations: (any TargetSystemProxyOperating)? = nil,
        runtimeOperations: (any TargetRuntimeOperating)? = nil,
        hostNetworkSafetyMode: HostNetworkSafetyMode = TargetValidationPolicy.hostNetworkSafetyMode
    ) {
        self.backend = backend
        self.engineInstaller = backend as? any EngineInstalling
        self.serviceManager = backend as? any ServiceLifecycleManaging
        self.serviceTester = backend as? any ServiceConnectionTesting
        self.systemProxyClient = systemProxyClient
        let resolvedSystemProxyOperations = systemProxyOperations ?? TargetSystemProxyOperations(client: systemProxyClient)
        self.systemProxyOperations = resolvedSystemProxyOperations
        self.runtimeOperations = runtimeOperations ?? TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: systemProxyClient,
            systemProxyOperations: resolvedSystemProxyOperations,
            hostNetworkSafetyMode: hostNetworkSafetyMode
        )
        self.hostNetworkSafetyMode = hostNetworkSafetyMode
        self.status = .mockDefault
        self.serviceInstallation = TargetServiceRegistration.status
        self.xpcState = .unknown
        self.lifecycleState = .stopped
        self.error = nil
        self.pingResult = nil
    }

    var isBusy: Bool {
        operationTask != nil
    }

    var canInstallEngine: Bool { !isBusy && status.engineInstallation != .installed }

    var canStart: Bool {
        !isBusy
            && status.engineInstallation == .installed
            && status.engineState == .stopped
            && status.hasSelectedValidProfile
    }

    var canStop: Bool {
        !isBusy && status.engineState == .running
    }

    var canRestart: Bool { canStop && status.restartRequired }

    var backendStateKey: String { "backend.status.sing-box" }
    var engineInstallationKey: String { status.engineInstallation.localizedKey }
    var engineStateKey: String { status.engineState.localizedKey }
    var serviceInstallationKey: String { serviceInstallation.localizedKey }
    var xpcStateKey: String { xpcState.localizedKey }
    var errorKey: String? { error?.localizedKey }
    var systemProxyStateKey: String { systemProxyStatus.state.localizedKey }
    var systemProxyErrorKey: String? { systemProxyStatus.error?.localizedKey }
    var canEnableSystemProxy: Bool {
        hostNetworkSafetyMode.permitsNetworkWrites && !isBusy && lifecycleState == .running && systemProxyStatus.state != .enabled
    }
    var canDisableSystemProxy: Bool {
        hostNetworkSafetyMode.permitsNetworkWrites && !isBusy && [.enabled, .recoveryRequired, .failed].contains(systemProxyStatus.state)
    }
    var systemProxyRecoveryCapability: SystemProxyRecoveryCapability {
        systemProxyStatus.recoveryCapability(
            hostNetworkSafetyMode: hostNetworkSafetyMode,
            isOperationInProgress: isBusy
        )
    }
    var canRecoverSystemProxy: Bool { systemProxyRecoveryCapability.isAvailable }
    /// Service registration is independent from host-network changes. Keep it
    /// available in Host Safe Mode so a user can approve and repair the bundled
    /// daemon without enabling proxy, DNS, route, firewall, or TUN operations.
    var canManageService: Bool { !isBusy }
    var safeModeKey: String { "host-safety.status.safe" }
    var isHostSafeMode: Bool { !hostNetworkSafetyMode.permitsNetworkWrites }

    func refresh() {
        guard !isBusy else { return }
        operationTask = Task { [weak self, backend] in
            do {
                let engineStatus = try await backend.queryStatus()
                try Task.checkCancellation()
                self?.status = engineStatus
                await self?.refreshServiceStatus()
                await self?.loadSystemProxyStatus()
                try Task.checkCancellation()
                self?.error = nil
                self?.lifecycleState = .settled(from: engineStatus)
                self?.operationTask = nil
            } catch is CancellationError {
                await self?.finishCancellation(afterReconciling: backend)
            } catch let error as BackendError {
                self?.finish(with: error)
            } catch {
                self?.finish(with: .serviceUnavailable)
            }
        }
    }

    func refreshSystemProxyStatus() {
        guard !isBusy else { return }
        operationTask = Task { [weak self] in
            await self?.loadSystemProxyStatus()
            guard !Task.isCancelled else { return }
            self?.operationTask = nil
        }
    }

    func installService() {
        guard canManageService else { return }
        operationTask = Task { [weak self] in
            do {
                try TargetServiceRegistration.register()
                self?.serviceInstallation = TargetServiceRegistration.status
                self?.operationTask = nil
            } catch let error as BackendError {
                self?.finish(with: error)
            } catch {
                self?.finish(with: .serviceRegistrationFailed)
            }
        }
    }

    func installEngine() {
        guard let engineInstaller else {
            finish(with: .engineInstallationFailed)
            return
        }
        error = nil
        run { _ in
            try await engineInstaller.installEngine()
        }
    }

    func validateConfiguration() {
        error = nil
        run { backend in
            try await backend.validateConfiguration(XPCConfigurationRequest(profileName: "Local Direct"))
            return try await backend.queryStatus()
        }
    }

    func removeService() {
        guard canManageService else { return }
        operationTask = Task { [weak self] in
            do {
                try TargetServiceRegistration.unregister()
                self?.serviceInstallation = TargetServiceRegistration.status
                self?.systemProxyStatus = .disabled
                self?.operationTask = nil
            } catch {
                self?.finish(with: .serviceRegistrationFailed)
            }
        }
    }

    func enableSystemProxy() {
        guard canEnableSystemProxy else { return }
        systemProxyStatus = SystemProxyStatus(state: .enabling, engineReachable: true, affectedServiceCount: 0, error: nil)
        operationTask = Task { [weak self] in
            do {
                let status = try await self?.systemProxyOperations.enable()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch let error as TargetSystemProxyOperationError {
                self?.finishSystemProxyFailure(error)
            } catch {
                self?.finishUnknownSystemProxyFailure()
            }
        }
    }

    func disableSystemProxy() {
        guard canDisableSystemProxy else { return }
        systemProxyStatus = SystemProxyStatus(
            state: .disabling,
            engineReachable: systemProxyStatus.engineReachable,
            affectedServiceCount: systemProxyStatus.affectedServiceCount,
            error: nil,
            hasRecoverySnapshot: systemProxyStatus.hasRecoverySnapshot
        )
        operationTask = Task { [weak self] in
            do {
                let status = try await self?.systemProxyOperations.disable()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch let error as TargetSystemProxyOperationError {
                self?.finishSystemProxyFailure(error)
            } catch {
                self?.finishUnknownSystemProxyFailure()
            }
        }
    }

    func recoverSystemProxy() {
        guard canRecoverSystemProxy else { return }
        systemProxyStatus = SystemProxyStatus(
            state: .recoveryRequired,
            engineReachable: systemProxyStatus.engineReachable,
            affectedServiceCount: systemProxyStatus.affectedServiceCount,
            error: systemProxyStatus.error,
            hasRecoverySnapshot: systemProxyStatus.hasRecoverySnapshot
        )
        operationTask = Task { [weak self] in
            do {
                let status = try await self?.systemProxyOperations.recover()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch let error as TargetSystemProxyOperationError {
                self?.finishSystemProxyFailure(error)
            } catch {
                self?.finishUnknownSystemProxyFailure()
            }
        }
    }

    /* Legacy service-backed engine support remains available to alternative backends. */
    private func removeServiceUsingBackend() {
        guard let serviceManager else {
            finish(with: .serviceUnavailable)
            return
        }
        error = nil
        run { _ in
            try await serviceManager.removeService()
        }
    }

    func pingService() {
        guard let serviceTester else {
            finish(with: .serviceUnavailable)
            return
        }
        error = nil
        operationTask = Task { [weak self] in
            do {
                let result = try await serviceTester.pingService()
                guard !Task.isCancelled else { return }
                self?.finishPing(with: result)
            } catch let error as BackendError {
                self?.finish(with: error)
            } catch {
                self?.finish(with: .serviceUnavailable)
            }
        }
    }

    func start() {
        guard canStart else { return }
        do {
            lifecycleState = try BackendLifecycleState.begin(.start, from: lifecycleState)
            error = nil
        } catch let error as BackendError {
            self.error = error
            lifecycleState = .failed(error)
            return
        } catch {
            finish(with: .serviceUnavailable)
            return
        }
        let runtimeOperations = runtimeOperations
        operationTask = Task { [weak self, backend] in
            do {
                let result = try await runtimeOperations.startEngine()
                if Task.isCancelled {
                    await self?.finishCancellation(afterReconciling: backend)
                    return
                }
                self?.systemProxyStatus = result.systemProxyStatus
                self?.finish(with: result.engineStatus)
            } catch is CancellationError {
                await self?.finishCancellation(afterReconciling: backend)
            } catch let error as BackendError {
                self?.finish(with: error)
            } catch {
                self?.finish(with: .serviceUnavailable)
            }
        }
    }

    func stop() {
        guard !isBusy else { return }
        guard status.engineState == .running else {
            finish(with: .invalidLifecycleTransition)
            return
        }
        lifecycleState = .stopping
        error = nil
        let runtimeOperations = runtimeOperations
        operationTask = Task { [weak self, backend] in
            do {
                let result = try await runtimeOperations.stopEngineSafely()
                if Task.isCancelled {
                    await self?.finishCancellation(afterReconciling: backend)
                    return
                }
                if let proxyStatus = result.systemProxyStatus {
                    self?.systemProxyStatus = proxyStatus
                }
                self?.finish(with: result.engineStatus)
            } catch is CancellationError {
                await self?.finishCancellation(afterReconciling: backend)
            } catch let error as BackendError {
                await self?.finishStopFailure(afterReconciling: backend, error: error)
            } catch {
                await self?.finishStopFailure(afterReconciling: backend, error: .serviceUnavailable)
            }
        }
    }

    func restartWithCurrentProfile() {
        guard canRestart else { return }
        lifecycleState = .stopping
        error = nil
        let backend = backend
        let runtimeOperations = runtimeOperations
        operationTask = Task { [weak self] in
            do {
                let stopResult = try await runtimeOperations.stopEngineSafely()
                if let proxyStatus = stopResult.systemProxyStatus {
                    self?.systemProxyStatus = proxyStatus
                }
                try Task.checkCancellation()
                self?.lifecycleState = .starting
                let startResult = try await runtimeOperations.startEngine()
                if Task.isCancelled {
                    await self?.finishCancellation(afterReconciling: backend)
                    return
                }
                self?.systemProxyStatus = startResult.systemProxyStatus
                self?.finish(with: startResult.engineStatus)
            } catch is CancellationError {
                await self?.finishCancellation(afterReconciling: backend)
            } catch let error as BackendError {
                await self?.finishStopFailure(afterReconciling: backend, error: error)
            } catch {
                await self?.finishStopFailure(afterReconciling: backend, error: .serviceUnavailable)
            }
        }
    }

    private func startUsingBackend() {
        begin(.stop) { backend in
            try await backend.startEngine()
        }
    }

    func cancelCurrentOperation() {
        operationTask?.cancel()
    }

    func stopOnApplicationTermination() {
        guard status.engineState == .running else { return }
        Task { [runtimeOperations] in
            _ = try? await runtimeOperations.stopEngineSafely()
        }
    }

    func applyAutomationEngineStatus(_ engineStatus: BackendStatus) {
        guard !isBusy else { return }
        status = engineStatus
        lifecycleState = .settled(from: engineStatus)
        error = nil
    }

    func applyAutomationSystemProxyStatus(_ proxyStatus: SystemProxyStatus) {
        guard !isBusy else { return }
        systemProxyStatus = proxyStatus
    }

    private func begin(
        _ operation: BackendOperation,
        action: @escaping @Sendable (any EngineBackend) async throws -> BackendStatus
    ) {
        guard operationTask == nil else { return }
        do {
            lifecycleState = try BackendLifecycleState.begin(operation, from: lifecycleState)
            error = nil
        } catch let error as BackendError {
            self.error = error
            lifecycleState = .failed(error)
            return
        } catch {
            self.error = .serviceUnavailable
            lifecycleState = .failed(.serviceUnavailable)
            return
        }

        run(action)
    }

    private func run(
        _ action: @escaping @Sendable (any EngineBackend) async throws -> BackendStatus
    ) {
        let backend = backend
        operationTask = Task { [weak self] in
            do {
                let updatedStatus = try await action(backend)
                if Task.isCancelled {
                    await self?.finishCancellation(afterReconciling: backend)
                    return
                }
                self?.finish(with: updatedStatus)
            } catch is CancellationError {
                await self?.finishCancellation(afterReconciling: backend)
            } catch let error as BackendError {
                self?.finish(with: error)
            } catch {
                self?.finish(with: .serviceUnavailable)
            }
        }
    }

    private func finish(with updatedStatus: BackendStatus) {
        status = updatedStatus
        error = nil
        lifecycleState = .settled(from: updatedStatus)
        operationTask = nil
    }

    private func finish(with error: BackendError) {
        self.error = error
        if error == .serviceRegistrationFailed {
            serviceInstallation = .error
        }
        lifecycleState = .failed(error)
        operationTask = nil
    }

    private func finishPing(with result: String) {
        pingResult = result
        operationTask = nil
    }

    private func finishCancellation(afterReconciling backend: any EngineBackend) async {
        if let currentStatus = await reconciledStatus(from: backend) {
            status = currentStatus
            lifecycleState = .settled(from: currentStatus)
        } else {
            lifecycleState = .failed(.operationCancelled)
        }
        if hostNetworkSafetyMode.permitsNetworkWrites {
            await loadSystemProxyStatus()
        }
        error = .operationCancelled
        operationTask = nil
    }

    private func finishStopFailure(afterReconciling backend: any EngineBackend, error: BackendError) async {
        if let currentStatus = await reconciledStatus(from: backend) {
            status = currentStatus
            lifecycleState = .settled(from: currentStatus)
        } else {
            lifecycleState = .failed(error)
        }
        if hostNetworkSafetyMode.permitsNetworkWrites {
            await loadSystemProxyStatus()
        }
        self.error = error
        operationTask = nil
    }

    private func reconciledStatus(from backend: any EngineBackend) async -> BackendStatus? {
        let timeout = cancellationReconciliationTimeout
        let reconciliation = Task.detached { () -> BackendStatus? in
            let results = AsyncStream<BackendStatus?> { continuation in
                Task.detached {
                    do {
                        continuation.yield(try await backend.queryStatus())
                        continuation.finish()
                    } catch {
                        // The timeout below is authoritative when status cannot be read.
                    }
                }
                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                        continuation.yield(nil)
                        continuation.finish()
                    } catch {
                        continuation.finish()
                    }
                }
            }
            var iterator = results.makeAsyncIterator()
            return await iterator.next() ?? nil
        }
        return await reconciliation.value
    }

    private func refreshServiceStatus() async {
        let installation = TargetServiceRegistration.status
        serviceInstallation = installation
        guard installation == .enabled else {
            xpcState = .unknown
            return
        }
        do {
            _ = try await systemProxyClient.ping()
            xpcState = ServiceConnectionAssessment.xpcState(registration: installation, xpcReachable: true)
        } catch {
            xpcState = ServiceConnectionAssessment.xpcState(registration: installation, xpcReachable: false)
        }
    }

    private func loadSystemProxyStatus() async {
        do {
            systemProxyStatus = try await systemProxyOperations.queryStatus()
        } catch let error as TargetSystemProxyOperationError {
            systemProxyStatus = error.reconciledStatus
        } catch {
            systemProxyStatus = systemProxyStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
        }
    }

    private func finishSystemProxyFailure(_ failure: TargetSystemProxyOperationError) {
        var status = failure.reconciledStatus
        if status.error == nil {
            status.error = failure.operationError
        }
        systemProxyStatus = status
        operationTask = nil
    }

    private func finishUnknownSystemProxyFailure() {
        systemProxyStatus = systemProxyStatus.preservingRecoveryEvidenceWhileStatusIsUnavailable()
        operationTask = nil
    }
}
