import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let status: Int32
    let output: String
    let timedOut: Bool
}

private final class BoundedProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard data.count < maximumBytes else { return }
        data.append(chunk.prefix(maximumBytes - data.count))
    }

    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Runs only a Process object created by Target and always returns within a
/// bounded interval. Output is collected with a cap so a noisy child cannot
/// block on a full pipe or cause unbounded memory growth.
enum BoundedProcessRunner {
    static let defaultTimeout: TimeInterval = 10
    private static let outputLimit = 64 * 1_024
    private static let terminationGrace: DispatchTimeInterval = .milliseconds(250)

    static func run(_ process: Process, timeout: TimeInterval = defaultTimeout) throws -> BoundedProcessResult {
        let output = Pipe()
        let collector = BoundedProcessOutputCollector(maximumBytes: outputLimit)
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        process.standardOutput = output
        process.standardError = output

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }

        var timedOut = false
        if termination.wait(timeout: .now() + dispatchInterval(timeout)) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            if termination.wait(timeout: .now() + terminationGrace) == .timedOut,
               process.isRunning {
                // The PID belongs to the Process launched above. Do not signal
                // any PID recovered from a profile or external state.
                _ = kill(pid_t(process.processIdentifier), SIGKILL)
                _ = termination.wait(timeout: .now() + terminationGrace)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        return BoundedProcessResult(
            status: process.terminationStatus,
            output: collector.string(),
            timedOut: timedOut
        )
    }

    private static func dispatchInterval(_ timeout: TimeInterval) -> DispatchTimeInterval {
        let bounded = max(0.001, min(timeout, 2_147_483.647))
        return .milliseconds(max(1, Int(bounded * 1_000)))
    }
}

protocol SingBoxConfigurationChecking: Sendable {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic>
}

struct SingBoxConfigurationChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    private let executableURL: URL?
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = BoundedProcessRunner.defaultTimeout) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> {
        let executable = executableURL ?? Self.defaultExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.engine-unavailable", line: nil, column: nil))
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["check", "-c", configurationURL.path]
        do {
            let result = try BoundedProcessRunner.run(process, timeout: timeout)
            guard !result.timedOut else {
                return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: nil, column: nil))
            }
            guard result.status == 0 else {
                // sing-box output can contain configuration values and local paths. Do
                // not persist or display it; only retain its optional line/column.
                let location = ConfigurationDiagnosticParser.location(in: result.output)
                return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: location.line, column: location.column))
            }
        } catch {
            return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: nil, column: nil))
        }
        return .success(())
    }

    private static var defaultExecutableURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Target/sing-box/bin/sing-box")
    }
}

enum JSONSyntaxChecker {
    static func validate(_ text: String) -> ConfigurationDiagnostic? {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8))
            return nil
        } catch {
            let nsError = error as NSError
            let offset = (nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int)
                ?? characterOffset(in: nsError.localizedDescription)
            let position = offset.map { lineAndColumn(in: text, characterOffset: $0) }
            return ConfigurationDiagnostic(
                messageKey: "profile.validation.json-syntax",
                line: position?.line,
                column: position?.column
            )
        }
    }

    private static func characterOffset(in description: String) -> Int? {
        let pattern = #"(?i)(?:character|offset)\s+(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)),
              let range = Range(match.range(at: 1), in: description) else { return nil }
        return Int(description[range])
    }

    static func lineAndColumn(in text: String, characterOffset: Int) -> (line: Int, column: Int) {
        let clamped = max(0, min(characterOffset, text.utf16.count))
        let prefix = (text as NSString).substring(to: clamped)
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        return (max(1, lines.count), (lines.last?.count ?? 0) + 1)
    }
}

enum ConfigurationDiagnosticParser {
    static func location(in output: String) -> (line: Int?, column: Int?) {
        let pattern = #"(?i)(?:line\s*|:)(\d+)(?:\s*(?:,|:)\s*(?:column\s*)?(\d+))?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) else {
            return (nil, nil)
        }
        func integer(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: output) else { return nil }
            return Int(output[swiftRange])
        }
        return (integer(1), integer(2))
    }
}
