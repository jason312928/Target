import Foundation
import Observation

@MainActor
@Observable
final class BackendLifecycleModel {
    private let backend: any EngineBackend
    private let serviceManager: (any ServiceLifecycleManaging)?
    private let serviceTester: (any ServiceConnectionTesting)?
    private var operationTask: Task<Void, Never>?

    private(set) var status: BackendStatus
    private(set) var lifecycleState: BackendLifecycleState
    private(set) var error: BackendError?
    private(set) var pingResult: String?

    init(backend: any EngineBackend = TargetServiceBackend()) {
        self.backend = backend
        self.serviceManager = backend as? any ServiceLifecycleManaging
        self.serviceTester = backend as? any ServiceConnectionTesting
        self.status = .mockDefault
        self.lifecycleState = .stopped
        self.error = nil
        self.pingResult = nil
    }

    var isBusy: Bool {
        operationTask != nil
    }

    var canInstall: Bool {
        !isBusy && [.notRegistered, .unavailable, .error].contains(status.serviceInstallation)
    }

    var canRemove: Bool {
        !isBusy && [.requiresApproval, .enabled].contains(status.serviceInstallation)
    }

    var canPing: Bool {
        !isBusy && status.serviceInstallation == .enabled
    }

    var canStart: Bool {
        operationTask == nil && lifecycleState != .running
    }

    var canStop: Bool {
        operationTask == nil && lifecycleState == .running
    }

    var backendStateKey: String { "backend.status.service" }
    var serviceStateKey: String { status.serviceInstallation.localizedKey }
    var engineStateKey: String { status.engineState.localizedKey }
    var errorKey: String? { error?.localizedKey }

    func refresh() {
        run { backend in
            try await backend.queryStatus()
        }
    }

    func installService() {
        guard let serviceManager else {
            finish(with: .serviceUnavailable)
            return
        }
        error = nil
        run { _ in
            try await serviceManager.installService()
        }
    }

    func removeService() {
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
        begin(.stop) { backend in
            try await backend.stopEngine()
        }
    }

    func cancelCurrentOperation() {
        operationTask?.cancel()
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
        lifecycleState = .settled(from: updatedStatus)
        operationTask = nil
    }

    private func finish(with error: BackendError) {
        self.error = error
        if error == .serviceRegistrationFailed {
            status.serviceInstallation = .error
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
}
