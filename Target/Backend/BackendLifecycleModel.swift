import Foundation
import Observation

@MainActor
@Observable
final class BackendLifecycleModel {
    private let backend: any EngineBackend
    private let engineInstaller: (any EngineInstalling)?
    private let serviceManager: (any ServiceLifecycleManaging)?
    private let serviceTester: (any ServiceConnectionTesting)?
    private let systemProxyClient = TargetServiceXPCClient()
    private var operationTask: Task<Void, Never>?
    private let hostSafeMode = true

    private(set) var status: BackendStatus
    private(set) var serviceInstallation: ServiceInstallationState
    private(set) var xpcState: XPCConnectionState
    private(set) var lifecycleState: BackendLifecycleState
    private(set) var error: BackendError?
    private(set) var pingResult: String?
    private(set) var systemProxyStatus = SystemProxyStatus.disabled

    init(backend: any EngineBackend = SingBoxBackend()) {
        self.backend = backend
        self.engineInstaller = backend as? any EngineInstalling
        self.serviceManager = backend as? any ServiceLifecycleManaging
        self.serviceTester = backend as? any ServiceConnectionTesting
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
        operationTask == nil && lifecycleState != .running
    }

    var canStop: Bool {
        operationTask == nil && lifecycleState == .running
    }

    var backendStateKey: String { "backend.status.sing-box" }
    var engineInstallationKey: String { status.engineInstallation.localizedKey }
    var engineStateKey: String { status.engineState.localizedKey }
    var serviceInstallationKey: String { serviceInstallation.localizedKey }
    var xpcStateKey: String { xpcState.localizedKey }
    var errorKey: String? { error?.localizedKey }
    var systemProxyStateKey: String { systemProxyStatus.state.localizedKey }
    var systemProxyErrorKey: String? { systemProxyStatus.error?.localizedKey }
    var canEnableSystemProxy: Bool {
        !hostSafeMode && !isBusy && lifecycleState == .running && systemProxyStatus.state != .enabled
    }
    var canDisableSystemProxy: Bool {
        !hostSafeMode && !isBusy && [.enabled, .recoveryRequired, .failed].contains(systemProxyStatus.state)
    }
    var canRecoverSystemProxy: Bool { !hostSafeMode && !isBusy && systemProxyStatus.hasRecoverySnapshot }
    /// Service registration is independent from host-network changes. Keep it
    /// available in Host Safe Mode so a user can approve and repair the bundled
    /// daemon without enabling proxy, DNS, route, firewall, or TUN operations.
    var canManageService: Bool { !isBusy }
    var safeModeKey: String { "host-safety.status.safe" }

    func refresh() {
        guard !isBusy else { return }
        operationTask = Task { [weak self, backend] in
            do {
                let engineStatus = try await backend.queryStatus()
                guard !Task.isCancelled else { return }
                self?.status = engineStatus
                await self?.refreshServiceStatus()
                self?.error = nil
                self?.lifecycleState = .settled(from: engineStatus)
                self?.operationTask = nil
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
            do {
                let status = try await self?.systemProxyClient.querySystemProxyStatus()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch {
                self?.systemProxyStatus = SystemProxyStatus(state: .failed, engineReachable: false, affectedServiceCount: 0, error: .recoveryFailed)
                self?.operationTask = nil
            }
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
                let status = try await self?.systemProxyClient.enableSystemProxy()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch {
                self?.systemProxyStatus = SystemProxyStatus(state: .failed, engineReachable: false, affectedServiceCount: 0, error: .applyFailed)
                self?.operationTask = nil
            }
        }
    }

    func disableSystemProxy() {
        guard canDisableSystemProxy else { return }
        systemProxyStatus = SystemProxyStatus(state: .disabling, engineReachable: lifecycleState == .running, affectedServiceCount: systemProxyStatus.affectedServiceCount, error: nil)
        operationTask = Task { [weak self] in
            do {
                let status = try await self?.systemProxyClient.disableSystemProxy()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch {
                self?.systemProxyStatus = SystemProxyStatus(state: .recoveryRequired, engineReachable: self?.lifecycleState == .running, affectedServiceCount: self?.systemProxyStatus.affectedServiceCount ?? 0, error: .recoveryFailed)
                self?.operationTask = nil
            }
        }
    }

    func recoverSystemProxy() {
        guard canRecoverSystemProxy else { return }
        systemProxyStatus = SystemProxyStatus(state: .recoveryRequired, engineReachable: lifecycleState == .running, affectedServiceCount: systemProxyStatus.affectedServiceCount, error: nil)
        operationTask = Task { [weak self] in
            do {
                let status = try await self?.systemProxyClient.recoverSystemProxy()
                guard !Task.isCancelled, let status else { return }
                self?.systemProxyStatus = status
                self?.operationTask = nil
            } catch {
                self?.systemProxyStatus.error = .recoveryFailed
                self?.operationTask = nil
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
        begin(.start) { backend in
            try await backend.startEngine()
        }
    }

    func stop() {
        guard operationTask == nil else { return }
        guard lifecycleState == .running else {
            finish(with: .invalidLifecycleTransition)
            return
        }
        lifecycleState = .stopping
        error = nil
        operationTask = Task { [weak self, backend] in
            do {
                let status = try await backend.stopEngine()
                guard !Task.isCancelled else { return }
                self?.finish(with: status)
            } catch {
                self?.systemProxyStatus = SystemProxyStatus(
                    state: .recoveryRequired,
                    engineReachable: true,
                    affectedServiceCount: self?.systemProxyStatus.affectedServiceCount ?? 0,
                    error: .recoveryFailed
                )
                self?.finish(with: .serviceUnavailable)
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
        guard lifecycleState == .running else { return }
        Task { [backend] in
            _ = try? await backend.stopEngine()
        }
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
                guard !Task.isCancelled else { return }
                self?.finish(with: updatedStatus)
            } catch is CancellationError {
                self?.finishCancellation()
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

    private func finishCancellation() {
        error = .operationCancelled
        lifecycleState = .failed(.operationCancelled)
        operationTask = nil
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
}
