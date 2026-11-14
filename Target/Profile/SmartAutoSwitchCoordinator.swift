import CoreFoundation
import Foundation
import Observation
import TargetCore

/// Only verified, read-only runtime identity is exposed here. No lifecycle or
/// connection-close capability is available to Auto.
protocol SmartAutoRuntimeReading: Sendable {
    func autoSelectionEvidence(catalog: PolicyCatalog) async throws -> PolicySelectionEvidence
}

enum SmartAutoUnavailable: Error { case runtimeUnavailable, identityChanged, selectorUnavailable }

/// Inspect the verified launch document, never a possibly newer source Profile.
/// A selector configured to interrupt inbound flows is not eligible for Auto.
enum SmartAutoSelectorSafety {
    static func preservesConnections(configuration: Data, selector: String) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: configuration)) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else { return false }
        let matches = outbounds.filter { $0["tag"] as? String == selector }
        guard matches.count == 1, matches[0]["type"] as? String == "selector" else { return false }
        guard let raw = matches[0]["interrupt_exist_connections"] else { return true }
        // JSON numbers/strings/null must not be mistaken for the boolean false.
        guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return !flag.boolValue
    }
}

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

    static let maximumEvidenceRounds = 32
    static let maximumEvidenceResponseBytes = 16 * 1024
    private var evidenceEnabled = false
    private var evidenceEpoch: UInt64 = 0
    private var evidenceSequence = 0
    private var evidenceTruncated = false
    private var evidenceRounds: [SmartAutoEvidenceRound] = []

    /// Independent of Auto lifecycle; no persistence, I/O or additional work task.
    func evidenceResponse(action: String) -> AutomationResponse {
        if action == "smart.auto.evidence.on" || action == "smart.auto.evidence.off" {
            evidenceEpoch &+= 1
            evidenceEnabled = action == "smart.auto.evidence.on"
            evidenceRounds.removeAll()
            evidenceSequence = 0
            evidenceTruncated = false
        }
        // Measure the complete protocol envelope. SHOW trims a copy, so repeated
        // reads cannot alter either Auto or the retained evidence.
        var rounds = evidenceRounds
        var truncated = evidenceTruncated
        while true {
            let response = AutomationResponse.success(.object([
                "enabled": .boolean(evidenceEnabled),
                "maximumRounds": .integer(Self.maximumEvidenceRounds),
                "maximumResponseBytes": .integer(Self.maximumEvidenceResponseBytes),
                "truncated": .boolean(truncated),
                "unavailableObservations": .array([
                    "controllerDispatchTime", "manualSelectionFinalOutcome", "independentRequestOutcome",
                    "egressAttribution", "counterfactualOutcome"
                ].map(JSONValue.string)),
                "rounds": .array(rounds.map { .object($0.fields) })
            ]))
            if AutomationProtocol.encodeResponse(response).count <= Self.maximumEvidenceResponseBytes { return response }
            guard !rounds.isEmpty else {
                return .failure(code: "evidence_unavailable", message: "Evidence is unavailable.")
            }
            rounds.removeFirst()
            truncated = true
        }
    }

    private func beginEvidenceRound() -> SmartAutoEvidenceRound? {
        guard evidenceEnabled else { return nil }
        evidenceSequence += 1
        return SmartAutoEvidenceRound(epoch: evidenceEpoch, number: evidenceSequence,
            startedAt: uptime())
    }

    private func finishEvidenceRound(_ round: SmartAutoEvidenceRound?) -> Bool {
        guard var round, evidenceEnabled, round.epoch == evidenceEpoch else { return false }
        let end = uptime()
        round.fields["endedUptimeSeconds"] = round.startedAt.isFinite && end.isFinite && end >= round.startedAt ? .number(end) : .null
        round.fields["cancellationRequested"] = .boolean(Task.isCancelled)
        round.fields["stopReason"] = status.stopReason.map(JSONValue.string) ?? .null
        evidenceRounds.append(round)
        if evidenceRounds.count > Self.maximumEvidenceRounds {
            evidenceRounds.removeFirst(evidenceRounds.count - Self.maximumEvidenceRounds)
            evidenceTruncated = true
        }
        return true
    }

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
        var lastRecorded: (epoch: UInt64, number: Int)?
        defer {
            if let lastRecorded, lastRecorded.epoch == evidenceEpoch,
               evidenceRounds.last?.number == lastRecorded.number {
                evidenceRounds[evidenceRounds.count - 1].fields["autoStopped"] = .boolean(true)
                evidenceRounds[evidenceRounds.count - 1].fields["stopReason"] = status.stopReason.map(JSONValue.string) ?? .null
            }
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
                var round = beginEvidenceRound()
                do {
                    defer {
                        if finishEvidenceRound(round), let round { lastRecorded = (round.epoch, round.number) }
                    }
                    do {
                        let coolingDown: Bool
                        if let lastSuccessUptime {
                            let elapsed = uptime() - lastSuccessUptime
                            guard elapsed.isFinite, elapsed >= 0 else { throw SmartAutoUnavailable.identityChanged }
                            coolingDown = elapsed < Self.successCooldown
                        } else { coolingDown = false }
                        round?.fields["successCooldown"] = .boolean(coolingDown)
                        round?.fields["selectionAllowedByCooldown"] = .boolean(!coolingDown)
                        guard policy.selectionGeneration() == expected.generation,
                              try policy.readPersisted() == expected.evidence.catalog else {
                            round?.fields["result"] = .string("identityChanged")
                            throw SmartAutoUnavailable.identityChanged
                        }
                        status.state = .evaluating
                        let result = await apply.apply(expected: expected, allowSelection: !coolingDown)
                        round?.observe(result, safeReason: Self.safeResult(result.reasonCode))
                        // Do not turn an acknowledged success into "cancelled" if OFF
                        // arrived while its controller reply was in flight.
                        status.lastEvaluatedAt = date()
                        status.lastResult = Self.safeResult(result.reasonCode)
                        if result.applied {
                            lastSuccessUptime = uptime()
                            status.lastSwitchAt = date()
                            round?.fields["receiptValidated"] = .boolean(false)
                            guard let receipt = result.receipt,
                                  receipt.identity.runtimeConfigurationID == expected.evidence.sessionID,
                                  receipt.preSelectionCatalog == expected.evidence.catalog,
                                  receipt.selector == expected.evidence.selector,
                                  receipt.oldOutbound == expected.evidence.currentOutbound,
                                  receipt.newOutbound == result.after else {
                                status.stopReason = "identityChanged"
                                return
                            }
                            round?.fields["receiptValidated"] = .boolean(true)
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
                    } catch {
                        if round?.fields["evaluationCompleted"] != .boolean(true) {
                            round?.fields["result"] = .string(error is CancellationError ? "cancelled" :
                                (error is SmartAutoUnavailable ? "identityChanged" : "operationUnavailable"))
                        }
                        throw error
                    }
                }
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

/// Deliberately stores only scalar aggregates and fixed vocabulary. Never retain
/// a recommendation, catalog, receipt, runtime identity, tag or connection object.
private struct SmartAutoEvidenceRound {
    let epoch: UInt64
    let number: Int
    let startedAt: TimeInterval
    var fields: [String: JSONValue]

    init(epoch: UInt64, number: Int, startedAt: TimeInterval) {
        self.epoch = epoch; self.number = number; self.startedAt = startedAt
        fields = [
            "round": .integer(number), "startedUptimeSeconds": startedAt.isFinite ? .number(startedAt) : .null,
            "endedUptimeSeconds": .null, "result": .string("operationUnavailable"),
            "evaluationCompleted": .boolean(false), "candidateCount": .null,
            "probeSuccessCount": .null, "probeFailureCount": .null, "ambiguousProbeCount": .null,
            "connectionSnapshotAvailable": .null, "connectionSnapshotTruncated": .null,
            "confidence": .null, "keepCurrent": .null, "successCooldown": .null,
            "selectionAllowedByCooldown": .null, "selectionAttempted": .null,
            "applied": .null, "receiptValidated": .null, "cancellationRequested": .boolean(false),
            "autoStopped": .boolean(false), "stopReason": .null
        ]
    }

    mutating func observe(_ result: SmartPolicyApplyResult, safeReason: String) {
        fields["result"] = .string(safeReason)
        fields["selectionAttempted"] = .boolean(result.selectionAttempted)
        fields["applied"] = .boolean(result.applied)
        guard let value = result.recommendation else { return }
        fields["evaluationCompleted"] = .boolean(true)
        fields["candidateCount"] = .integer(value.candidateCount)
        // Early unavailable recommendations contain placeholder zeros/booleans,
        // not observations of probes or connections.
        guard value.state == "available" else { return }
        fields["probeSuccessCount"] = .integer(value.probeSuccessCount)
        fields["probeFailureCount"] = .integer(value.probeFailureCount)
        fields["ambiguousProbeCount"] = .integer(value.ambiguousProbeCount)
        fields["connectionSnapshotAvailable"] = .boolean(value.connectionSnapshotAvailable)
        fields["connectionSnapshotTruncated"] = .boolean(value.connectionSnapshotTruncated)
        fields["confidence"] = .string(value.confidence.rawValue)
        fields["keepCurrent"] = .boolean(value.keepCurrent)
    }
}
