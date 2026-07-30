import Foundation
import TenonIntentCore

/// One explicit invocation crossing the local CLI control socket.
///
/// The control protocol only transports this kernel-shaped value. User-facing
/// convenience commands are compiled into `intent.send` by `tenon-cli`; the app
/// never implements a second workspace or terminal command path.
public struct CLIIntentInvocation: Equatable, Sendable {
    public let intentID: IntentID
    public let input: IntentValue
    public let scope: InvocationScope
    public let target: ProviderID?
    public let idempotencyKey: String?
    public let timeoutMilliseconds: Int?

    public init(
        intentID: IntentID,
        input: IntentValue,
        scope: InvocationScope,
        target: ProviderID? = nil,
        idempotencyKey: String? = nil,
        timeoutMilliseconds: Int? = nil
    ) {
        self.intentID = intentID
        self.input = input
        self.scope = scope
        self.target = target
        self.idempotencyKey = idempotencyKey
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

/// Closed control-plane vocabulary for protocol v3.
///
/// `ping` and `app.focus` are local process controls. Every domain operation is
/// either discovery or a single canonical intent dispatch.
public enum CLIAction: Equatable, Sendable {
    case ping
    case appFocus
    case intentList
    case intentDescribe(IntentID)
    case intentSend(CLIIntentInvocation)
}

/// Pure, strict parsing from a validated wire request to the closed action set.
public enum CLIActionParser {
    public static let maximumTimeoutMilliseconds = 60_000
    public static let maximumIdempotencyKeyBytes = 512

    public static func parse(_ request: CLIRequest) -> Result<CLIAction, CLIError> {
        do {
            return .success(try action(for: request))
        } catch let error as CLIError {
            return .failure(error)
        } catch {
            return .failure(
                CLIError(code: .internalError, message: "\(error)")
            )
        }
    }

    private static func action(for request: CLIRequest) throws -> CLIAction {
        let params = try object(request.params, field: "params")
        switch request.action {
        case "ping":
            try requireOnly(params, allowed: [])
            return .ping
        case "app.focus":
            try requireOnly(params, allowed: [])
            return .appFocus
        case "intent.list":
            try requireOnly(params, allowed: [])
            return .intentList
        case "intent.describe":
            try requireOnly(params, allowed: ["name"])
            return .intentDescribe(
                try intentID(try string(params, "name"), field: "name")
            )
        case "intent.send":
            try requireOnly(
                params,
                allowed: [
                    "name",
                    "input",
                    "scope",
                    "target",
                    "idempotencyKey",
                    "timeoutMs",
                ]
            )
            guard let input = params["input"] else {
                throw invalid("missing required param 'input'")
            }
            guard let rawScope = params["scope"] else {
                throw invalid("missing required param 'scope'")
            }
            return .intentSend(
                CLIIntentInvocation(
                    intentID: try intentID(
                        try string(params, "name"),
                        field: "name"
                    ),
                    input: input,
                    scope: try scope(rawScope),
                    target: try optionalProviderID(params, "target"),
                    idempotencyKey: try optionalIdempotencyKey(
                        params,
                        "idempotencyKey"
                    ),
                    timeoutMilliseconds: try optionalTimeout(
                        params,
                        "timeoutMs"
                    )
                )
            )
        default:
            throw CLIError(
                code: .unknownAction,
                message: "unknown action '\(request.action)'"
            )
        }
    }

    private static func scope(_ value: IntentValue) throws -> InvocationScope {
        let object = try object(value, field: "scope")
        guard object["userGestureID"] == nil else {
            throw invalid("param 'scope.userGestureID' is host-owned")
        }
        try requireOnly(
            object,
            allowed: ["workspaceID", "paneID"]
        )
        return InvocationScope(
            workspaceID: try optionalUUID(object, "workspaceID"),
            paneID: try optionalUUID(object, "paneID")
        )
    }

    private static func object(
        _ value: IntentValue,
        field: String
    ) throws -> [String: IntentValue] {
        guard case let .object(object) = value else {
            throw invalid("'\(field)' must be an object")
        }
        return object
    }

    private static func string(
        _ params: [String: IntentValue],
        _ key: String
    ) throws -> String {
        guard let raw = params[key] else {
            throw invalid("missing required param '\(key)'")
        }
        guard case let .string(value) = raw else {
            throw invalid("param '\(key)' must be a string")
        }
        guard !value.isEmpty else {
            throw invalid("param '\(key)' must not be empty")
        }
        return value
    }

    private static func intentID(
        _ rawValue: String,
        field: String
    ) throws -> IntentID {
        guard let value = try? IntentID(rawValue) else {
            throw invalid("param '\(field)' is not a valid versioned intent id")
        }
        return value
    }

    private static func optionalProviderID(
        _ params: [String: IntentValue],
        _ key: String
    ) throws -> ProviderID? {
        guard params[key] != nil else {
            return nil
        }
        let rawValue = try string(params, key)
        guard let value = try? ProviderID(rawValue) else {
            throw invalid("param '\(key)' is not a valid provider id")
        }
        return value
    }

    private static func optionalIdempotencyKey(
        _ params: [String: IntentValue],
        _ key: String
    ) throws -> String? {
        guard params[key] != nil else {
            return nil
        }
        let value = try string(params, key)
        guard value.utf8.count <= maximumIdempotencyKeyBytes else {
            throw invalid(
                "param '\(key)' exceeds \(maximumIdempotencyKeyBytes) bytes"
            )
        }
        return value
    }

    private static func optionalTimeout(
        _ params: [String: IntentValue],
        _ key: String
    ) throws -> Int? {
        guard let raw = params[key] else {
            return nil
        }
        guard case let .integer(integer) = raw,
              let value = Int(exactly: integer),
              (1 ... maximumTimeoutMilliseconds).contains(value)
        else {
            throw invalid(
                "param '\(key)' must be an integer from 1 through "
                    + "\(maximumTimeoutMilliseconds)"
            )
        }
        return value
    }

    private static func optionalUUID(
        _ params: [String: IntentValue],
        _ key: String
    ) throws -> UUID? {
        guard params[key] != nil else {
            return nil
        }
        let rawValue = try string(params, key)
        guard let value = UUID(uuidString: rawValue) else {
            throw invalid("param '\(key)' is not a valid UUID")
        }
        return value
    }

    private static func requireOnly(
        _ params: [String: IntentValue],
        allowed: Set<String>
    ) throws {
        let unknown = Set(params.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw invalid("unknown param '\(unknown.sorted()[0])'")
        }
    }

    private static func invalid(_ message: String) -> CLIError {
        CLIError(code: .invalidParams, message: message)
    }
}
