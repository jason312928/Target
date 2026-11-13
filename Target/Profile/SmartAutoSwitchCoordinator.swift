import Foundation
import Observation
import TargetCore

/// Only verified, read-only runtime identity is exposed here. No lifecycle or
/// connection-close capability is available to Auto.
protocol SmartAutoRuntimeReading: Sendable {
    func autoSelectionEvidence(catalog: PolicyCatalog) async throws -> PolicySelectionEvidence
}

enum SmartAutoUnavailable: Error { case runtimeUnavailable, identityChanged, selectorUnavailable }

struct SmartAutoExpectation: Sendable {
    let evidence: PolicySelectionEvidence
    let generation: UInt64

    func matches(_ other: PolicySelectionEvidence) -> Bool {
        evidence.catalog == other.catalog && evidence.sessionID == other.sessionID &&
        evidence.selector == other.selector && evidence.currentOutbound == other.currentOutbound
    }
}

struct SmartAutoStatus: Equatable, Sendable {
    enum State: String, Sendable { case off, starting, evaluating, waiting, cooldown, stopping }
    var state: State = .off
    var lastResult: String?
    var lastEvaluatedAt: Date?
    var lastSwitchAt: Date?
    var stopReason: String?
    var enabled: Bool { state != .off && state != .stopping }

    func automationJSON() -> JSONValue {
        .object([
            "enabled": .boolean(enabled), "state": .string(state.rawValue),
            "evaluationIntervalSeconds": .integer(300), "successCooldownSeconds": .integer(900),
            "lastResult": lastResult.map(JSONValue.string) ?? .null,
            "lastEvaluatedAt": lastEvaluatedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "lastSwitchAt": lastSwitchAt.map { .string($0.ISO8601Format()) } ?? .null,
            "stopReason": stopReason.map(JSONValue.string) ?? .null
        ])
    }

    var resultMessageKey: String {
        switch lastResult {
        case "applied": "policy.auto.result.applied"
        case "keepCurrent", "alreadySelected", "cooldown": "policy.auto.result.kept"
        case "lowConfidence", "ambiguousEvidence", "staleEvidence": "policy.auto.result.evidence"
        case "mutationUnconfirmed": "policy.auto.result.unconfirmed"
        case "cancelled": "policy.auto.result.cancelled"
        case nil: "policy.auto.detail"
        default: "policy.auto.result.unavailable"
        }
    }
}

/// One process-local owner, shared by GUI and authenticated local automation.
/// The task includes initialization, evaluation, writes and sleeps. OFF is only
/// confirmed after that entire task has settled, including a dispatched write.
@MainActor
@Observable
final class SmartAutoSwitchCoordinator {
    static let evaluationInterval: TimeInterval = 300
    static let successCooldown: TimeInterval = 900
    private(set) var status = SmartAutoStatus()
    private let policy: any TargetPolicyOperating
    private let runtime: any SmartAutoRuntimeReading
    private let apply: SmartPolicyApplyOperations
    private let uptime: @Sendable () -> TimeInterval
    private let date: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var startWaiters: [CheckedContinuation<SmartAutoStatus, Never>] = []
    // Deliberately survives OFF/ON within this process. Toggling cannot bypass
    // the cooldown; a new application process always starts with Auto OFF.
    private var lastSuccessUptime: TimeInterval?

    init(policy: any TargetPolicyOperating, runtime: any SmartAutoRuntimeReading,
         apply: SmartPolicyApplyOperations,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.policy = policy
        self.runtime = runtime
        self.apply = apply
        self.uptime = uptime
        self.date = date
        self.sleep = sleep
    }

    /// Register GUI intent synchronously so a following OFF or manual intent
    /// can cancel it even before the task gets its first turn.
    func requestOn() {
        guard task == nil else { return }
        status.state = .starting
        status.stopReason = nil
        task = Task { [weak self] in await self?.run() }
    }

    @discardableResult
    func on() async -> SmartAutoStatus {
        if task != nil { return status }
        requestOn()
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    /// Synchronous invalidation at the moment a GUI intent arrives. Call off()
    /// before performing that intent to also drain an already dispatched write.
    func requestStop(reason: String = "userOff") {
        guard task != nil else { return }
        status.state = .stopping
        status.stopReason = ["userOff", "manualSelection", "identityChanged", "applicationTermination"].contains(reason) ? reason : "identityChanged"
        task?.cancel()
    }

    @discardableResult
    func off(reason: String = "userOff") async -> SmartAutoStatus {
        requestStop(reason: reason)
        let pending = task
        await pending?.value
        return status
    }

    private func finishStarting() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    private func run() async {
        defer {
            status.state = .off
            task = nil
            finishStarting()
        }
        do {
            try Task.checkCancellation()
            let generation = policy.selectionGeneration()
            let catalog = try policy.readPersisted()
            let identity = try await runtime.autoSelectionEvidence(catalog: catalog)
            try Task.checkCancellation()
            guard identity.catalog == catalog, try policy.readPersisted() == catalog,
                  policy.selectionGeneration() == generation else {
                status.lastResult = "identityChanged"
                status.stopReason = "identityChanged"
                return
            }
            var expected = SmartAutoExpectation(evidence: identity, generation: generation)
            status.state = .waiting
            finishStarting()
            while true {
                try Task.checkCancellation()
                let coolingDown: Bool
                if let lastSuccessUptime {
                    let elapsed = uptime() - lastSuccessUptime
                    guard elapsed.isFinite, elapsed >= 0 else { throw SmartAutoUnavailable.identityChanged }
                    coolingDown = elapsed < Self.successCooldown
                } else { coolingDown = false }
                guard policy.selectionGeneration() == expected.generation,
                      try policy.readPersisted() == expected.evidence.catalog else {
                    throw SmartAutoUnavailable.identityChanged
                }
                status.state = .evaluating
                let result = await apply.apply(expected: expected, allowSelection: !coolingDown)
                // Do not turn an acknowledged success into "cancelled" if OFF
                // arrived while its controller reply was in flight.
                status.lastEvaluatedAt = date()
                status.lastResult = Self.safeResult(result.reasonCode)
                if result.applied {
                    lastSuccessUptime = uptime()
                    status.lastSwitchAt = date()
                    guard let receipt = result.receipt,
                          receipt.identity.runtimeConfigurationID == expected.evidence.sessionID,
                          receipt.preSelectionCatalog == expected.evidence.catalog,
                          receipt.selector == expected.evidence.selector,
                          receipt.oldOutbound == expected.evidence.currentOutbound,
                          receipt.newOutbound == result.after else {
                        status.stopReason = "identityChanged"
                        return
                    }
                    expected = .init(evidence: .init(catalog: receipt.catalog,
                        sessionID: receipt.identity.runtimeConfigurationID, selector: receipt.selector,
                        currentOutbound: receipt.newOutbound, observedAt: date()), generation: receipt.generation)
                }
                try Task.checkCancellation()
                guard result.applied || ["lowConfidence", "ambiguousEvidence", "staleEvidence", "keepCurrent", "alreadySelected", "cooldown"].contains(result.reasonCode) else {
                    status.stopReason = "safetyRefusal"
                    return
                }
                status.state = result.applied || coolingDown ? .cooldown : .waiting
                try await sleep(Self.evaluationInterval)
            }
        } catch is CancellationError {
            // Keep the last completed result. Cancellation has no rollback semantics.
        } catch {
            switch error {
            case SmartAutoUnavailable.runtimeUnavailable: status.lastResult = "runtimeUnavailable"
            case SmartAutoUnavailable.identityChanged: status.lastResult = "identityChanged"
            case SmartAutoUnavailable.selectorUnavailable: status.lastResult = "invalidRecommendation"
            default: status.lastResult = "operationUnavailable"
            }
            status.stopReason = "safetyRefusal"
        }
    }

    private static func safeResult(_ reason: String) -> String {
        let allowed = ["applied", "keepCurrent", "alreadySelected", "cooldown", "lowConfidence", "ambiguousEvidence", "staleEvidence",
                       "cancelled", "identityChanged", "profileChanged", "selectionChanged", "liveSelectionChanged",
                       "runtimeUnavailable", "engineStopped", "mutationInProgress", "applyInProgress", "evaluationInProgress",
                       "invalidRecommendation", "mutationUnconfirmed", "operationUnavailable"]
        return allowed.contains(reason) ? reason : "operationUnavailable"
    }
}
