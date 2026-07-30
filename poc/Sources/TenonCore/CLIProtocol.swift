import Foundation
import TenonIntentCore

/// The newline-delimited JSON contract between `tenon-cli` and the running app.
///
/// One connection carries one request and one response. Domain values use `IntentValue`, so the
/// control socket and the intent dispatcher share one bounded, Sendable JSON representation.
public enum CLIProtocol {
    public static let version = 3
    public static let maxPayloadSize = IntentValueLimits.hardMaximumEncodedBytes

    static let valueLimits = IntentValueLimits(
        maxEncodedBytes: maxPayloadSize,
        maxDepth: 64,
        maxValueCount: 4_096,
        maxCollectionCount: 1_024,
        maxStringBytes: maxPayloadSize,
        maxObjectKeyBytes: 1_024
    )
}

/// Protocol/control failures are closed; intent failures retain their canonical open error code.
public struct CLIErrorCode: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let unsupportedVersion = Self(rawValue: "unsupported_version")
    public static let malformedJSON = Self(rawValue: "malformed_json")
    public static let payloadTooLarge = Self(rawValue: "payload_too_large")
    public static let unknownAction = Self(rawValue: "unknown_action")
    public static let invalidParams = Self(rawValue: "invalid_params")
    public static let intentNotFound = Self(rawValue: "intent_not_found")
    public static let notReady = Self(rawValue: "not_ready")
    public static let internalError = Self(rawValue: "internal_error")
}

public enum CLIErrorSource: String, Codable, Equatable, Sendable {
    case control
    case intent
}

/// A wire-safe failure. Intent failures preserve the kernel's structured diagnostics rather than
/// flattening an open domain error vocabulary into a handful of CLI-only cases.
public struct CLIError: Error, Equatable, Sendable, CustomStringConvertible {
    public let source: CLIErrorSource
    public let code: CLIErrorCode
    public let message: String
    public let details: IntentValue?
    public let retryable: Bool?
    public let retryAfterMilliseconds: UInt64?
    public let outcome: IntentOutcome?
    public let requestID: UUID?
    public let providerID: ProviderID?

    public init(code: CLIErrorCode, message: String) {
        source = .control
        self.code = code
        self.message = message
        details = nil
        retryable = nil
        retryAfterMilliseconds = nil
        outcome = nil
        requestID = nil
        providerID = nil
    }

    public init(intentFailure failure: IntentFailure) {
        source = .intent
        code = CLIErrorCode(rawValue: failure.error.code.rawValue)
        message = Self.intentMessage(failure.error)
        details = failure.error.details
        retryable = failure.error.retryable
        retryAfterMilliseconds = failure.error.retryAfterMilliseconds
        outcome = failure.error.outcome
        requestID = failure.meta.requestID
        providerID = failure.meta.providerID
    }

    init(
        source: CLIErrorSource,
        code: CLIErrorCode,
        message: String,
        details: IntentValue?,
        retryable: Bool?,
        retryAfterMilliseconds: UInt64?,
        outcome: IntentOutcome?,
        requestID: UUID?,
        providerID: ProviderID?
    ) {
        self.source = source
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.outcome = outcome
        self.requestID = requestID
        self.providerID = providerID
    }

    public var description: String {
        "\(code.rawValue): \(message)"
    }

    /// Complete structured form used by the CLI process. Intent failures keep
    /// the kernel error details, retry guidance, outcome, request identity, and
    /// selected provider instead of collapsing to a display string.
    public var intentValue: IntentValue {
        wireValue
    }

    private static func intentMessage(_ error: IntentError) -> String {
        if case let .object(details)? = error.details {
            for key in ["message", "reason"] {
                if case let .string(value)? = details[key], !value.isEmpty {
                    return value
                }
            }
        }
        return "intent failed with \(error.code.rawValue)"
    }
}

/// A validated request envelope. `params` is always an object.
public struct CLIRequest: Equatable, Sendable {
    public let v: Int
    public let id: String
    public let action: String
    public let params: IntentValue

    public init(
        v: Int = CLIProtocol.version,
        id: String,
        action: String,
        params: IntentValue = .object([:])
    ) {
        self.v = v
        self.id = id
        self.action = action
        self.params = params
    }
}

public enum CLIResponse: Equatable, Sendable {
    case success(id: String, result: IntentValue)
    case failure(id: String?, error: CLIError)
}

public enum CLIResult: Equatable, Sendable {
    case ok(IntentValue)
    case error(CLIError)

    public func response(id: String) -> CLIResponse {
        switch self {
        case let .ok(value):
            return .success(id: id, result: value)
        case let .error(error):
            return .failure(id: id, error: error)
        }
    }
}

public enum CLIRequestDecoding: Equatable {
    case ok(CLIRequest)
    case rejected(CLIResponse)
}

/// Pure framing and validation. Socket ownership remains in `TenonApp`.
public enum CLIWireCodec {
    public static func validate(payloadSize: Int) -> CLIErrorCode? {
        payloadSize > CLIProtocol.maxPayloadSize ? .payloadTooLarge : nil
    }

    public static func decodeRequest(_ data: Data) -> CLIRequestDecoding {
        guard validate(payloadSize: data.count) == nil else {
            return .rejected(.failure(
                id: nil,
                error: CLIError(
                    code: .payloadTooLarge,
                    message: "request exceeds \(CLIProtocol.maxPayloadSize) bytes"
                )
            ))
        }

        let root: IntentValue
        do {
            root = try IntentValue(
                jsonData: data,
                limits: CLIProtocol.valueLimits
            )
        } catch {
            return .rejected(.failure(
                id: nil,
                error: CLIError(
                    code: .malformedJSON,
                    message: "request must be a bounded JSON object"
                )
            ))
        }

        guard case let .object(object) = root else {
            return rejected(nil, .malformedJSON, "request must be a JSON object")
        }
        let id = object.string("id")
        guard object.keys.allSatisfy({ ["v", "id", "action", "params"].contains($0) }) else {
            return rejected(id, .malformedJSON, "request contains an unknown field")
        }
        guard let rawVersion = object.integer("v"),
              let version = Int(exactly: rawVersion)
        else {
            return rejected(id, .malformedJSON, "missing integer field 'v'")
        }
        guard version == CLIProtocol.version else {
            return rejected(
                id,
                .unsupportedVersion,
                "protocol version \(version) is unsupported; this app speaks \(CLIProtocol.version)"
            )
        }
        guard let id, !id.isEmpty, id.utf8.count <= 128 else {
            return rejected(nil, .malformedJSON, "field 'id' must be a non-empty string up to 128 bytes")
        }
        guard let action = object.string("action"),
              !action.isEmpty,
              action.utf8.count <= 128
        else {
            return rejected(id, .malformedJSON, "field 'action' must be a non-empty string up to 128 bytes")
        }
        let params = object["params"] ?? .object([:])
        guard case .object = params else {
            return rejected(id, .invalidParams, "'params' must be an object")
        }

        return .ok(
            CLIRequest(v: version, id: id, action: action, params: params)
        )
    }

    public static func encodeRequest(_ request: CLIRequest) throws -> Data {
        var object: [String: IntentValue] = [
            "v": .integer(Int64(request.v)),
            "id": .string(request.id),
            "action": .string(request.action),
        ]
        if request.params != .object([:]) {
            object["params"] = request.params
        }
        return try line(.object(object))
    }

    public static func decodeResponse(_ data: Data) -> CLIResponse? {
        guard validate(payloadSize: data.count) == nil,
              let root = try? IntentValue(
                  jsonData: data,
                  limits: CLIProtocol.valueLimits
              ),
              case let .object(object) = root,
              object.integer("v") == Int64(CLIProtocol.version),
              let ok = object.bool("ok")
        else {
            return nil
        }

        let id = object.string("id")
        if ok {
            guard let id else { return nil }
            return .success(id: id, result: object["result"] ?? .null)
        }
        guard let rawError = object["error"],
              let error = CLIError(wireValue: rawError)
        else {
            return nil
        }
        return .failure(id: id, error: error)
    }

    public static func encode(_ response: CLIResponse) throws -> Data {
        var object: [String: IntentValue] = [
            "v": .integer(Int64(CLIProtocol.version)),
        ]
        switch response {
        case let .success(id, result):
            object["id"] = .string(id)
            object["ok"] = .bool(true)
            object["result"] = result
        case let .failure(id, error):
            object["id"] = id.map(IntentValue.string) ?? .null
            object["ok"] = .bool(false)
            object["error"] = error.wireValue
        }
        return try line(.object(object))
    }

    private static func rejected(
        _ id: String?,
        _ code: CLIErrorCode,
        _ message: String
    ) -> CLIRequestDecoding {
        .rejected(.failure(
            id: id,
            error: CLIError(code: code, message: message)
        ))
    }

    private static func line(_ value: IntentValue) throws -> Data {
        var data = try value.canonicalJSONData(limits: CLIProtocol.valueLimits)
        data.append(0x0A)
        return data
    }
}

private extension Dictionary where Key == String, Value == IntentValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func integer(_ key: String) -> Int64? {
        guard case let .integer(value)? = self[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else { return nil }
        return value
    }
}

private extension CLIError {
    var wireValue: IntentValue {
        var object: [String: IntentValue] = [
            "source": .string(source.rawValue),
            "code": .string(code.rawValue),
            "message": .string(message),
        ]
        if let details {
            object["details"] = details
        }
        if let retryable {
            object["retryable"] = .bool(retryable)
        }
        if let retryAfterMilliseconds,
           let exact = Int64(exactly: retryAfterMilliseconds)
        {
            object["retryAfterMs"] = .integer(exact)
        }
        if let outcome {
            object["outcome"] = .string(outcome.rawValue)
        }
        if let requestID {
            object["requestID"] = .string(requestID.uuidString)
        }
        if let providerID {
            object["providerID"] = .string(providerID.rawValue)
        }
        return .object(object)
    }

    init?(wireValue: IntentValue) {
        guard case let .object(object) = wireValue,
              let sourceRaw = object.string("source"),
              let source = CLIErrorSource(rawValue: sourceRaw),
              let code = object.string("code"),
              let message = object.string("message")
        else {
            return nil
        }

        let retryAfterMilliseconds: UInt64?
        if let raw = object.integer("retryAfterMs") {
            guard raw >= 0 else { return nil }
            retryAfterMilliseconds = UInt64(raw)
        } else {
            retryAfterMilliseconds = nil
        }

        let outcome: IntentOutcome?
        if let raw = object.string("outcome") {
            guard let decoded = IntentOutcome(rawValue: raw) else { return nil }
            outcome = decoded
        } else {
            outcome = nil
        }

        let requestID: UUID?
        if let raw = object.string("requestID") {
            guard let decoded = UUID(uuidString: raw) else { return nil }
            requestID = decoded
        } else {
            requestID = nil
        }

        let providerID: ProviderID?
        if let raw = object.string("providerID") {
            guard let decoded = try? ProviderID(raw) else { return nil }
            providerID = decoded
        } else {
            providerID = nil
        }

        self.init(
            source: source,
            code: CLIErrorCode(rawValue: code),
            message: message,
            details: object["details"],
            retryable: object.bool("retryable"),
            retryAfterMilliseconds: retryAfterMilliseconds,
            outcome: outcome,
            requestID: requestID,
            providerID: providerID
        )
    }
}
