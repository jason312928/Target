import Foundation

enum AutomationProtocol {
    static let version = 1
    static let maximumMessageBytes = 64 * 1024

    static func decodeRequest(_ data: Data) throws -> AutomationRequest {
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

    static func encodeResponse(_ response: AutomationResponse) -> Data {
        (try? JSONEncoder.stable.encode(response)) ?? Data(
            #"{"error":{"code":"internal_error","message":"Unable to encode response."},"ok":false,"protocolVersion":1}"#.utf8
        )
    }
}

enum AutomationProtocolError: Error, Equatable {
    case malformedRequest
    case oversizedRequest
    case unsupportedVersion
    case unknownAction
}

struct AutomationRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let action: String
    var arguments: [String: String] = [:]
}

struct AutomationErrorPayload: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct AutomationResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let ok: Bool
    let result: JSONValue?
    let error: AutomationErrorPayload?

    init(protocolVersion: Int, ok: Bool, result: JSONValue?, error: AutomationErrorPayload?) {
        self.protocolVersion = protocolVersion
        self.ok = ok
        self.result = result
        self.error = error
    }

    static func success(_ result: JSONValue = .object([:])) -> AutomationResponse {
        AutomationResponse(protocolVersion: AutomationProtocol.version, ok: true, result: result, error: nil)
    }

    static func failure(code: String, message: String) -> AutomationResponse {
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

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        ok = try container.decode(Bool.self, forKey: .ok)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(AutomationErrorPayload.self, forKey: .error)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(ok, forKey: .ok)
        if let result { try container.encode(result, forKey: .result) }
        else { try container.encodeNil(forKey: .result) }
        if let error { try container.encode(error, forKey: .error) }
        else { try container.encodeNil(forKey: .error) }
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
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
