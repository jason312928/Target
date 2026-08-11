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
        do {
            let request = AutomationRequest(
                protocolVersion: AutomationProtocol.version,
                action: parsed.action,
                arguments: parsed.arguments
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
}

exit(TargetCtl.run(arguments: Array(CommandLine.arguments.dropFirst())))
