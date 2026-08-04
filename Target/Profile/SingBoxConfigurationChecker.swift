import Foundation

protocol SingBoxConfigurationChecking: Sendable {
    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic>
}

struct SingBoxConfigurationChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    private let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> {
        let executable = executableURL ?? Self.defaultExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.engine-unavailable", line: nil, column: nil))
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["check", "-c", configurationURL.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: nil, column: nil))
        }
        guard process.terminationStatus == 0 else {
            // sing-box output can contain configuration values and local paths. Do
            // not persist or display it; only retain its optional line/column.
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let location = ConfigurationDiagnosticParser.location(in: text)
            return .failure(ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: location.line, column: location.column))
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
