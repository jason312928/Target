import Darwin
import Foundation

enum TargetCtl {
    static func run(arguments: [String]) -> Int32 {
        let parsed: (action: String, arguments: [String: String])
        do {
            parsed = try parse(arguments)
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

    private static func parse(_ arguments: [String]) throws -> (String, [String: String]) {
        var values = arguments
        guard values.last == "--json" else { throw AutomationSocketError.unavailable }
        values.removeLast()
        switch values {
        case ["capabilities"]: return ("capabilities", [:])
        case ["status"]: return ("status", [:])
        case ["profile", "list"]: return ("profile.list", [:])
        case ["engine", "status"]: return ("engine.status", [:])
        case ["engine", "start"]: return ("engine.start", [:])
        case ["engine", "stop"]: return ("engine.stop", [:])
        case ["service", "status"]: return ("service.status", [:])
        case ["service", "install"]: return ("service.install", [:])
        case ["service", "ping"]: return ("service.ping", [:])
        case ["service", "remove"]: return ("service.remove", [:])
        case ["proxy", "status"]: return ("proxy.status", [:])
        case ["proxy", "enable"]: return ("proxy.enable", [:])
        case ["proxy", "disable"]: return ("proxy.disable", [:])
        case ["proxy", "recover"]: return ("proxy.recover", [:])
        default: break
        }
        if values.count == 6, values[0...1] == ["profile", "import"],
           values[2] == "--file", values[4] == "--name" {
            return ("profile.import", ["file": values[3], "name": values[5]])
        }
        if values.count == 5, values[0...1] == ["profile", "delete"], values[3] == "--confirm" {
            return ("profile.delete", ["id": values[2], "confirm": values[4]])
        }
        throw AutomationSocketError.unavailable
    }

    private static func emit(_ response: AutomationResponse) {
        FileHandle.standardOutput.write(AutomationProtocol.encodeResponse(response))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

exit(TargetCtl.run(arguments: Array(CommandLine.arguments.dropFirst())))
