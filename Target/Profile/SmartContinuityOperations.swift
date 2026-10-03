import Foundation
import TargetCore

enum SmartContinuityClassification: String, Sendable {
    case protect, replaceable, unknown
    // Uncertainty always preserves the connection. This is not close authority.
    var preservesConnection: Bool { self != .replaceable }
}

struct SmartContinuityEvidence: Sendable {
    let identity: EngineRuntimeRecord
    let snapshot: RuntimeConnectionsSnapshot
    let observedAt: Date
}

enum SmartContinuityRuntimeResult: Sendable {
    case available(SmartContinuityEvidence)
    case stopped
    case unavailable
}

protocol SmartContinuityRuntimeReading: Sendable {
    func collectContinuityEvidence() async throws -> SmartContinuityRuntimeResult
}

struct UnavailableSmartContinuityRuntime: SmartContinuityRuntimeReading {
    func collectContinuityEvidence() async throws -> SmartContinuityRuntimeResult { .unavailable }
}

struct SmartContinuitySummary: Sendable {
    let state: String
    let observedAt: Date?
    let sampleCount: Int
    let observedConnectionCount: Int
    let protectCount: Int
    let replaceableCount: Int
    let unknownCount: Int
    let snapshotTruncated: Bool
    let snapshotUnavailable: Bool
    let reasonCodes: [String]

    static func unavailable(_ reason: String, state: String = "unavailable") -> Self {
        .init(state: state, observedAt: nil, sampleCount: 0, observedConnectionCount: 0,
              protectCount: 0, replaceableCount: 0, unknownCount: 0,
              snapshotTruncated: false, snapshotUnavailable: true, reasonCodes: [reason])
    }

    func automationJSON() -> JSONValue {
        .object([
            "state": .string(state),
            "observedAt": observedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "sampleCount": .integer(sampleCount), "observedConnectionCount": .integer(observedConnectionCount),
            "protectCount": .integer(protectCount), "replaceableCount": .integer(replaceableCount),
            "unknownCount": .integer(unknownCount), "snapshotTruncated": .boolean(snapshotTruncated),
            "snapshotUnavailable": .boolean(snapshotUnavailable),
            "reasonCodes": .array(reasonCodes.map(JSONValue.string))
        ])
    }
}

/// Deterministic, process-local short windows. No destination data or history is retained.
struct SmartContinuityClassifier {
    static let window: TimeInterval = 30
    static let maximumSampleGap: TimeInterval = 10
    static let longLivedAge: TimeInterval = 300
    static let sustainedBytes: Int64 = 1_024
    static let lowRiskTotalBytes: Int64 = 4_096
    static let maximumConnections = RuntimeConnectionsParser.maximumDetailedConnections
    static let maximumSamples = 7
    static let maximumFieldBytes = 256
    static let maximumChainLength = 32

    private struct Sample {
        let time: Date
        let upload: Int64
        let download: Int64
    }
    private struct Flow {
        let startedAt: Date
        let network: String
        let chain: [String]
        var samples: [Sample]
    }
    private var identity: EngineRuntimeRecord?
    private var times: [Date] = []
    private var flows: [String: Flow] = [:]
    var retainedConnectionCount: Int { flows.count }
    var retainedSampleCount: Int { flows.values.reduce(0) { $0 + $1.samples.count } }

    mutating func reset() { identity = nil; times.removeAll(); flows.removeAll() }

    mutating func observe(_ evidence: SmartContinuityEvidence) -> SmartContinuitySummary {
        let now = evidence.observedAt
        guard now.timeIntervalSince1970.isFinite else { reset(); return .unavailable("clockUnavailable") }
        var reasons = Set<String>()
        if identity != evidence.identity {
            reset(); identity = evidence.identity; reasons.insert("runtimeWindowStarted")
        }
        if let last = times.last, now <= last || now.timeIntervalSince(last) > Self.maximumSampleGap {
            times.removeAll(); flows.removeAll(); reasons.insert("samplingDiscontinuity")
        }
        times.append(now)
        Self.trim(&times, now: now, time: { $0 })
        let connections = Array(evidence.snapshot.connections.prefix(Self.maximumConnections))
        let truncated = evidence.snapshot.isTruncated || evidence.snapshot.connections.count > Self.maximumConnections
        if truncated { reasons.insert("snapshotTruncated"); reasons.insert("preserveUnobserved") }
        // Even a truncated snapshot cannot extend an absent ID's window.
        let present = Set(connections.map(\.id))
        flows = flows.filter { present.contains($0.key) }
        var counts: [SmartContinuityClassification: Int] = [:]
        let duplicates = Set(Dictionary(grouping: connections, by: \.id).filter { $0.value.count > 1 }.keys)
        for connection in connections {
            let result: (SmartContinuityClassification, String)
            if duplicates.contains(connection.id) {
                flows.removeValue(forKey: connection.id); result = (.unknown, "duplicateID")
            } else {
                result = classify(connection, now: now, truncated: truncated)
            }
            counts[result.0, default: 0] += 1
            reasons.insert(result.1)
        }
        return .init(state: truncated ? "partial" : "available", observedAt: now, sampleCount: times.count,
                     observedConnectionCount: connections.count, protectCount: counts[.protect, default: 0],
                     replaceableCount: counts[.replaceable, default: 0], unknownCount: counts[.unknown, default: 0],
                     snapshotTruncated: truncated, snapshotUnavailable: false, reasonCodes: reasons.sorted())
    }

    private static func trim<T>(_ samples: inout [T], now: Date, time: (T) -> Date) {
        // Retain one boundary anchor, but never more than seven samples.
        while samples.count > 1, now.timeIntervalSince(time(samples[1])) >= window { samples.removeFirst() }
        if samples.count > maximumSamples { samples.removeFirst(samples.count - maximumSamples) }
    }

    private mutating func classify(_ connection: RuntimeConnection, now: Date, truncated: Bool) -> (SmartContinuityClassification, String) {
        let id = connection.id
        guard !id.isEmpty, id.utf8.count <= Self.maximumFieldBytes,
              let start = connection.startedAt, start.timeIntervalSince1970.isFinite, start <= now,
              let upload = connection.uploadBytes, let download = connection.downloadBytes, upload >= 0, download >= 0,
              let network = connection.network?.lowercased(), ["tcp", "udp"].contains(network),
              !connection.outboundChain.isEmpty, connection.outboundChain.count <= Self.maximumChainLength,
              connection.outboundChain.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumFieldBytes }) else {
            flows.removeValue(forKey: id); return (.unknown, "missingEvidence")
        }
        let sample = Sample(time: now, upload: upload, download: download)
        var flow = flows[id] ?? Flow(startedAt: start, network: network, chain: connection.outboundChain, samples: [])
        var resetReason: String?
        if flow.startedAt != start || flow.network != network || flow.chain != connection.outboundChain {
            resetReason = "connectionIdentityChanged"
        } else if let previous = flow.samples.last, upload < previous.upload || download < previous.download {
            resetReason = "counterReset"
        }
        if resetReason != nil { flow = Flow(startedAt: start, network: network, chain: connection.outboundChain, samples: []) }
        flow.samples.append(sample)
        Self.trim(&flow.samples, now: now, time: { $0.time })
        flows[id] = flow
        if let resetReason { return (.unknown, resetReason) }
        let age = now.timeIntervalSince(start)
        guard age >= Self.window else { return (.unknown, "justCreated") }
        guard flow.samples.count >= 2 else { return (.unknown, "warmingWindow") }
        let deltas = zip(flow.samples, flow.samples.dropFirst()).map { ($1.upload - $0.upload, $1.download - $0.download) }
        if network == "udp", deltas.contains(where: { $0.0 > 0 || $0.1 > 0 }) { return (.protect, "recentUDP") }
        let recent = deltas.suffix(2)
        if recent.count == 2, recent.allSatisfy({ $0.0 >= Self.sustainedBytes && $0.1 >= Self.sustainedBytes }) {
            return (.protect, "sustainedBidirectional")
        }
        if recent.count == 2, recent.allSatisfy({ $0.1 >= Self.sustainedBytes }) { return (.protect, "sustainedDownload") }
        if deltas.contains(where: { $0.0 > 0 || $0.1 > 0 }) { return (.protect, "recentActivity") }
        if age >= Self.longLivedAge { return (.unknown, "longLivedFlow") }
        guard !truncated, network == "tcp", upload <= Self.lowRiskTotalBytes, download <= Self.lowRiskTotalBytes - upload,
              flow.samples.count >= 4, let first = flow.samples.first,
              now.timeIntervalSince(first.time) >= Self.window else { return (.unknown, "insufficientIdleEvidence") }
        return (.replaceable, "continuousIdleLowRisk")
    }
}

/// One verified read per invocation, no timers, background tasks or mutations.
actor SmartContinuityOperations {
    private let runtime: any SmartContinuityRuntimeReading
    private var classifier = SmartContinuityClassifier()
    private var evaluating = false
    init(runtime: any SmartContinuityRuntimeReading) { self.runtime = runtime }

    func evaluate() async -> SmartContinuitySummary {
        guard !evaluating else { return .unavailable("evaluationInProgress") }
        evaluating = true
        defer { evaluating = false }
        do {
            try Task.checkCancellation()
            let result = try await runtime.collectContinuityEvidence()
            try Task.checkCancellation()
            switch result {
            case .available(let evidence): return classifier.observe(evidence)
            case .stopped: classifier.reset(); return .unavailable("engineStopped", state: "stopped")
            case .unavailable: classifier.reset(); return .unavailable("runtimeUnavailable")
            }
        } catch {
            classifier.reset()
            return .unavailable(error is CancellationError ? "cancelled" : "runtimeUnavailable")
        }
    }
    func retainedConnectionCount() -> Int { classifier.retainedConnectionCount }
}
