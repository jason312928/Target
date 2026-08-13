import Darwin
import Foundation
import TargetCore

enum TargetCtl {
    static func run(arguments: [String]) -> Int32 {
        let parsed: (action: String, arguments: [String: String])
        do {
            parsed = try TargetCtlCommandParser.parse(arguments)
        } catch {
            emit(.failure(code: "invalid_arguments", message: "The command arguments are invalid."))
            return 2
        }
        var requestArguments = parsed.arguments
        do {
            if parsed.action == "profile.subscribe" {
                requestArguments = try subscriptionArguments(from: requestArguments)
            }
        } catch {
            emit(.failure(code: "invalid_subscription_url", message: "A single UTF-8 subscription URL is required on stdin."))
            return 2
        }
        do {
            let request = AutomationRequest(
                protocolVersion: AutomationProtocol.version,
                action: parsed.action,
                arguments: requestArguments
            )
            let data = try LocalAutomationClient.send(request)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            let response = try JSONDecoder().decode(AutomationResponse.self, from: data)
            return response.ok ? 0 : 1
        } catch {
            emit(.failure(code: "target_unavailable", message: "The running Target application is unavailable."))
            return 1
        }
    }

    private static func emit(_ response: AutomationResponse) {
        FileHandle.standardOutput.write(AutomationProtocol.encodeResponse(response))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func subscriptionArguments(from arguments: [String: String]) throws -> [String: String] {
        guard arguments["urlStdin"] == "true" else { throw AutomationSocketError.unavailable }
        guard let data = try FileHandle.standardInput.read(upToCount: TargetCtlSubscriptionInput.maximumBytes + 1) else {
            throw AutomationSocketError.unavailable
        }
        let trimmed = try TargetCtlSubscriptionInput.parse(data)
        var result = arguments
        result.removeValue(forKey: "urlStdin")
        result["url"] = trimmed
        return result
    }
}

exit(TargetCtl.run(arguments: Array(CommandLine.arguments.dropFirst())))
