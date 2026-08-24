import Foundation

/// Shared production parser for the deliberately narrow `targetctl` command line.
/// Keeping it with the protocol makes the real executable parser directly testable
/// without adding a second test-only grammar.
public enum TargetCtlCommandParser {
    public static func parse(_ arguments: [String]) throws -> (action: String, arguments: [String: String]) {
        var values = arguments
        guard values.last == "--json" else { throw AutomationSocketError.unavailable }
        values.removeLast()
        switch values {
        case ["capabilities"]: return ("capabilities", [:])
        case ["status"]: return ("status", [:])
        case ["runtime", "status"]: return ("runtime.status", [:])
        case ["profile", "list"]: return ("profile.list", [:])
        case ["policy", "list"]: return ("policy.list", [:])
        case ["policy", "reset"]: return ("policy.reset", [:])
        case ["route", "list"]: return ("route.list", [:])
        case ["engine", "status"]: return ("engine.status", [:])
        case ["engine", "start"]: return ("engine.start", [:])
        case ["engine", "stop"]: return ("engine.stop", [:])
        case ["connect"]: return ("connection.start", [:])
        case ["disconnect"]: return ("connection.stop", [:])
        case ["restart"]: return ("connection.restart", [:])
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
        if values.count == 6, values[0...1] == ["profile", "subscribe"],
           values[2] == "--name", values[4] == "--url-stdin", values[5] == "--confirm" {
            return ("profile.subscribe", ["name": values[3], "confirm": "true", "urlStdin": "true"])
        }
        if values.count == 5, values[0...1] == ["profile", "subscription-update"],
           values[3] == "--confirm", values[2] == values[4] {
            return ("profile.subscription-update", ["id": values[2], "confirm": values[4]])
        }
        if values.count == 5, values[0...1] == ["profile", "delete"], values[3] == "--confirm" {
            return ("profile.delete", ["id": values[2], "confirm": values[4]])
        }
        if values.count == 6, values[0...1] == ["policy", "select"],
           values[2] == "--selector", values[4] == "--outbound" {
            return ("policy.select", ["selector": values[3], "outbound": values[5]])
        }
        if values.count == 4, values[0...1] == ["policy", "probe"],
           values[2] == "--selector" {
            return ("policy.probe", ["selector": values[3]])
        }
        if values.count == 8, values[0...1] == ["route", "bind"],
           values[2] == "--url", values[4] == "--country", values[6] == "--outbound" {
            return ("route.bind", ["url": values[3], "country": values[5], "outbound": values[7]])
        }
        if values.count == 4, values[0...1] == ["route", "remove"], values[2] == "--domain" {
            return ("route.remove", ["domain": values[3]])
        }
        throw AutomationSocketError.unavailable
    }
}

public enum TargetCtlSubscriptionInput {
    public static let maximumBytes = 8 * 1_024

    public static func parse(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw AutomationSocketError.unavailable
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }),
              let url = URL(string: trimmed), url.absoluteString == trimmed else {
            throw AutomationSocketError.unavailable
        }
        return trimmed
    }
}

public enum AutomationProtocol {
    public static let version = 1
    public static let maximumMessageBytes = 64 * 1024

    public static func decodeRequest(_ data: Data) throws -> AutomationRequest {
        guard !data.isEmpty, data.count <= maximumMessageBytes else {
            throw AutomationProtocolError.oversizedRequest
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AutomationProtocolError.malformedRequest
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: ["protocolVersion", "action", "arguments"]),
              dictionary["protocolVersion"] is Int,
              dictionary["action"] is String else {
            throw AutomationProtocolError.malformedRequest
        }
        if let arguments = dictionary["arguments"] {
            guard let values = arguments as? [String: Any], values.values.allSatisfy({ $0 is String }) else {
                throw AutomationProtocolError.malformedRequest
            }
        }
        do {
            return try JSONDecoder().decode(AutomationRequest.self, from: data)
        } catch {
            throw AutomationProtocolError.malformedRequest
        }
    }

    public static func encodeResponse(_ response: AutomationResponse) -> Data {
        (try? JSONEncoder.stable.encode(response)) ?? Data(
            #"{"error":{"code":"internal_error","message":"Unable to encode response."},"ok":false,"protocolVersion":1}"#.utf8
        )
    }
}

public enum AutomationProtocolError: Error, Equatable {
    case malformedRequest
    case oversizedRequest
    case unsupportedVersion
    case unknownAction
}

public struct AutomationRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let action: String
    public var arguments: [String: String] = [:]

    public init(protocolVersion: Int, action: String, arguments: [String: String] = [:]) {
        self.protocolVersion = protocolVersion
        self.action = action
        self.arguments = arguments
    }
}

public struct AutomationErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AutomationResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let ok: Bool
    public let result: JSONValue?
    public let error: AutomationErrorPayload?

    public init(protocolVersion: Int, ok: Bool, result: JSONValue?, error: AutomationErrorPayload?) {
        self.protocolVersion = protocolVersion
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ result: JSONValue = .object([:])) -> AutomationResponse {
        AutomationResponse(protocolVersion: AutomationProtocol.version, ok: true, result: result, error: nil)
    }

    public static func failure(code: String, message: String) -> AutomationResponse {
        AutomationResponse(
            protocolVersion: AutomationProtocol.version,
            ok: false,
            result: nil,
            error: AutomationErrorPayload(code: code, message: message)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, ok, result, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        ok = try container.decode(Bool.self, forKey: .ok)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(AutomationErrorPayload.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(ok, forKey: .ok)
        if let result { try container.encode(result, forKey: .result) }
        else { try container.encodeNil(forKey: .result) }
        if let error { try container.encode(error, forKey: .error) }
        else { try container.encodeNil(forKey: .error) }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONEncoder {
    fileprivate static var stable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
