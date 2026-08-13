import Foundation

struct RuntimeConnection: Identifiable, Equatable, Sendable {
    let id: String
    let destinationHost: String?
    let destinationIP: String?
    let destinationPort: Int?
    let network: String?
    let inbound: String?
    let outboundChain: [String]
    let uploadBytes: Int64?
    let downloadBytes: Int64?
    let startedAt: Date?

    var destination: String {
        destinationHost ?? destinationIP ?? ""
    }
}

struct RuntimeConnectionsSnapshot: Equatable, Sendable {
    let totals: RuntimeConnectionTotals
    let connections: [RuntimeConnection]
}

struct RuntimeConnectionObservation: Equatable, Sendable {
    let state: RuntimeObservationState
    let connections: [RuntimeConnection]
    let observedAt: Date?

    static let stopped = Self(state: .stopped, connections: [], observedAt: nil)
    static let loading = Self(state: .loading, connections: [], observedAt: nil)
    static let unavailable = Self(state: .unavailable, connections: [], observedAt: nil)
}

struct RuntimeTrafficSample: Identifiable, Equatable, Sendable {
    let observedAt: Date
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double

    var id: Date { observedAt }
}

struct RuntimeTrafficHistory: Equatable, Sendable {
    static let maximumSamples = 90
    private(set) var samples: [RuntimeTrafficSample] = []

    mutating func append(_ observation: RuntimeObservation) {
        guard observation.state == .available,
              let observedAt = observation.observedAt,
              let upload = observation.uploadBytesPerSecond,
              let download = observation.downloadBytesPerSecond else { return }
        samples.append(.init(
            observedAt: observedAt,
            uploadBytesPerSecond: max(0, upload),
            downloadBytesPerSecond: max(0, download)
        ))
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }
}

enum RuntimeByteFormatter {
    static func format(bytes: Double, suffix: String = "") -> String {
        let safe = max(0, bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = safe
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let digits = index == 0 ? 0 : (value < 10 ? 1 : 0)
        return String(format: "%.*f %@%@", digits, value, units[index], suffix)
    }
}

enum RuntimeLogLevel: String, CaseIterable, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
    case neutral
}

struct RuntimeLogEntry: Identifiable, Equatable, Sendable {
    let id: UInt64
    let timestamp: Date
    let level: RuntimeLogLevel
    let message: String
}

/// A small process-local sink. Pipe callbacks only append bounded bytes; completed
/// product entries are redacted before storage and never written to disk.
final class RuntimeLogBuffer: @unchecked Sendable {
    static let maximumEntries = 500
    static let maximumPartialLineBytes = 16 * 1024

    private let lock = NSLock()
    private var entries: [RuntimeLogEntry] = []
    private var partialLine = Data()
    private var nextID: UInt64 = 0

    func append(_ data: Data, timestamp: Date = .now) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        partialLine.append(data)
        while let newline = partialLine.firstIndex(of: 0x0A) {
            let line = partialLine.prefix(upTo: newline)
            partialLine.removeSubrange(...newline)
            appendLine(Data(line), timestamp: timestamp)
        }
        if partialLine.count > Self.maximumPartialLineBytes {
            appendLine(partialLine.prefix(Self.maximumPartialLineBytes), timestamp: timestamp)
            partialLine.removeAll(keepingCapacity: true)
        }
    }

    func snapshot() -> [RuntimeLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        partialLine.removeAll(keepingCapacity: true)
    }

    private func appendLine(_ data: Data, timestamp: Date) {
        let message = String(decoding: EngineLogRedactor.redact(data), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !message.isEmpty else { return }
        nextID &+= 1
        entries.append(.init(id: nextID, timestamp: timestamp, level: Self.level(for: message), message: message))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    private static func level(for message: String) -> RuntimeLogLevel {
        let prefix = message.uppercased()
        if prefix.hasPrefix("DEBUG") { return .debug }
        if prefix.hasPrefix("INFO") { return .info }
        if prefix.hasPrefix("WARN") || prefix.hasPrefix("WARNING") { return .warning }
        if prefix.hasPrefix("ERROR") || prefix.hasPrefix("FATAL") { return .error }
        return .neutral
    }
}

protocol RuntimeConnectionProviding: Sendable {
    func runtimeConnectionAvailability() async -> RuntimeObservationState
    func currentRuntimeConnections() async -> [RuntimeConnection]?
}

protocol RuntimeLogProviding: Sendable {
    func runtimeLogAvailability() async -> RuntimeObservationState
    func runtimeLogs() async -> [RuntimeLogEntry]
    func clearRuntimeLogs() async
}
