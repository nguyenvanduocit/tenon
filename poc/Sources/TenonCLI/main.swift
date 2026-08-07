// @domain: cli-control
import Foundation
import TenonIntentCore

private let terminalWaitMaximumMilliseconds = 55_000

private func requestID() -> String {
    UUID().uuidString
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        Data("tenon-cli: \(message)\n".utf8)
    )
    exit(2)
}

private struct Flags {
    var paneID: String?
    var workspaceID: String?
    var providerID: String?
    var idempotencyKey: String?
    var inputJSON: String?
    var timeoutMilliseconds: String?
    var waitCondition: String?
    var enter = false
    var positional: [String] = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--pane":
                paneID = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--workspace":
                workspaceID = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--provider":
                providerID = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--idempotency-key":
                idempotencyKey = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--input":
                inputJSON = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--timeout":
                timeoutMilliseconds = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--for":
                waitCondition = Self.value(
                    after: &index,
                    flag: argument,
                    in: arguments
                )
            case "--enter":
                enter = true
            default:
                if argument.hasPrefix("--") {
                    fail("unknown flag '\(argument)'")
                }
                positional.append(argument)
            }
            index += 1
        }
    }

    private static func value(
        after index: inout Int,
        flag: String,
        in arguments: [String]
    ) -> String {
        index += 1
        guard index < arguments.count else {
            fail("\(flag) needs a value")
        }
        return arguments[index]
    }
}

private let usage = """
usage: tenon-cli <command> [args]

  ping
  focus
  intent list
  intent describe <intent-id>
  intent send <intent-id> [--input <json>] [scope/options]

Convenience aliases (all compile to intent.send):
  state
  send [--pane <uuid>] [--enter] <text...>
  read [--pane <uuid>]
  wait [--pane <uuid>] --for exit|tui-idle|command-finished [--timeout <ms>]
  pane-focus --pane <uuid>

Scope/options:
  --workspace <uuid> --pane <uuid>
  --provider <provider-id> --idempotency-key <key> --timeout <ms>

When --pane is absent, $TENON_PANE_ID is used when available. Every wire-level
domain request is intent.send with explicit input and scope objects.
"""

private func buildRequest(
    _ command: String,
    _ arguments: [String]
) -> CLIRequest {
    switch command {
    case "ping":
        guard arguments.isEmpty else {
            fail("ping takes no arguments")
        }
        return CLIRequest(id: requestID(), action: "ping")

    case "focus":
        guard arguments.isEmpty else {
            fail("focus takes no arguments")
        }
        return CLIRequest(id: requestID(), action: "app.focus")

    case "intent":
        return buildIntentRequest(arguments)

    case "state":
        let flags = Flags(arguments)
        requireNoPositionals(flags, command: command)
        return intentSendRequest(
            name: "workspace.state.v1",
            input: .object([:]),
            flags: flags
        )

    case "send":
        let flags = Flags(arguments)
        let suffix = flags.enter ? "\r" : ""
        return intentSendRequest(
            name: "terminal.write.v1",
            input: .object([
                "text": .string(
                    flags.positional.joined(separator: " ") + suffix
                )
            ]),
            flags: flags
        )

    case "read":
        let flags = Flags(arguments)
        requireNoPositionals(flags, command: command)
        return intentSendRequest(
            name: "terminal.viewport.read.v1",
            input: .object([:]),
            flags: flags
        )

    case "wait":
        let flags = Flags(arguments)
        requireNoPositionals(flags, command: command)
        guard let condition = flags.waitCondition else {
            fail(
                "wait needs --for exit|tui-idle|command-finished"
            )
        }
        let waitMilliseconds = timeout(
            flags.timeoutMilliseconds,
            maximum: terminalWaitMaximumMilliseconds
        ) ?? 30_000
        return intentSendRequest(
            name: "terminal.wait.v1",
            input: .object([
                "condition": .string(condition),
                "timeoutMs": .integer(Int64(waitMilliseconds)),
            ]),
            flags: flags,
            requestedTimeoutMilliseconds: min(
                CLIActionParser.maximumTimeoutMilliseconds,
                waitMilliseconds + 1_000
            )
        )

    case "pane-focus":
        let flags = Flags(arguments)
        requireNoPositionals(flags, command: command)
        guard resolvedPaneID(flags) != nil else {
            fail(
                "pane-focus needs --pane or TENON_PANE_ID"
            )
        }
        return intentSendRequest(
            name: "workspace.pane.focus.v1",
            input: .object([:]),
            flags: flags
        )

    default:
        fail("unknown command '\(command)'\n\n\(usage)")
    }
}

private func buildIntentRequest(_ arguments: [String]) -> CLIRequest {
    guard let operation = arguments.first else {
        fail("intent needs list, describe, or send")
    }
    let flags = Flags(Array(arguments.dropFirst()))
    switch operation {
    case "list":
        requireNoFlagsOrPositionals(flags, command: "intent list")
        return CLIRequest(id: requestID(), action: "intent.list")

    case "describe":
        requireDiscoveryOnly(flags, command: "intent describe")
        guard flags.positional.count == 1 else {
            fail("intent describe needs exactly one intent id")
        }
        return CLIRequest(
            id: requestID(),
            action: "intent.describe",
            params: .object([
                "name": .string(flags.positional[0])
            ])
        )

    case "send":
        guard flags.positional.count == 1 else {
            fail("intent send needs exactly one intent id")
        }
        return intentSendRequest(
            name: flags.positional[0],
            input: parseInput(flags.inputJSON),
            flags: flags
        )

    default:
        fail("unknown intent operation '\(operation)'")
    }
}

private func intentSendRequest(
    name: String,
    input: IntentValue,
    flags: Flags,
    requestedTimeoutMilliseconds: Int? = nil
) -> CLIRequest {
    var params: [String: IntentValue] = [
        "name": .string(name),
        "input": input,
        "scope": scopeValue(flags),
    ]
    if let providerID = flags.providerID {
        params["target"] = .string(providerID)
    }
    if let idempotencyKey = flags.idempotencyKey {
        params["idempotencyKey"] = .string(idempotencyKey)
    }
    let requested = requestedTimeoutMilliseconds
        ?? timeout(
            flags.timeoutMilliseconds,
            maximum: CLIActionParser.maximumTimeoutMilliseconds
        )
    if let requested {
        params["timeoutMs"] = .integer(Int64(requested))
    }
    return CLIRequest(
        id: requestID(),
        action: "intent.send",
        params: .object(params)
    )
}

private func scopeValue(_ flags: Flags) -> IntentValue {
    var scope: [String: IntentValue] = [:]
    if let workspaceID = flags.workspaceID {
        scope["workspaceID"] = .string(validUUID(workspaceID, "--workspace"))
    }
    if let paneID = resolvedPaneID(flags) {
        scope["paneID"] = .string(validUUID(paneID, "--pane"))
    }
    return .object(scope)
}

private func resolvedPaneID(_ flags: Flags) -> String? {
    if let paneID = flags.paneID {
        return paneID
    }
    let environment = ProcessInfo.processInfo.environment
    guard let paneID = environment["TENON_PANE_ID"],
          !paneID.isEmpty
    else {
        return nil
    }
    return paneID
}

private func validUUID(_ rawValue: String, _ flag: String) -> String {
    guard let value = UUID(uuidString: rawValue) else {
        fail("\(flag) must be a UUID")
    }
    return value.uuidString
}

private func timeout(_ rawValue: String?, maximum: Int) -> Int? {
    guard let rawValue else {
        return nil
    }
    guard let milliseconds = Int(rawValue),
          (1 ... maximum).contains(milliseconds)
    else {
        fail("--timeout must be an integer from 1 through \(maximum)")
    }
    return milliseconds
}

private func parseInput(_ rawValue: String?) -> IntentValue {
    guard let rawValue else {
        return .object([:])
    }
    do {
        return try IntentValue(jsonData: Data(rawValue.utf8))
    } catch {
        fail("--input must contain one bounded JSON value")
    }
}

private func requireNoPositionals(_ flags: Flags, command: String) {
    guard flags.positional.isEmpty else {
        fail("\(command) takes no positional arguments")
    }
}

private func requireDiscoveryOnly(_ flags: Flags, command: String) {
    guard flags.paneID == nil,
          flags.workspaceID == nil,
          flags.providerID == nil,
          flags.idempotencyKey == nil,
          flags.inputJSON == nil,
          flags.timeoutMilliseconds == nil,
          flags.waitCondition == nil,
          !flags.enter
    else {
        fail("\(command) does not accept dispatch flags")
    }
}

private func requireNoFlagsOrPositionals(
    _ flags: Flags,
    command: String
) {
    requireDiscoveryOnly(flags, command: command)
    requireNoPositionals(flags, command: command)
}

private func printJSON(_ value: IntentValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted,
        .sortedKeys,
        .withoutEscapingSlashes,
    ]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8)
    else {
        fail("could not encode the response")
    }
    print(text)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

let request = buildRequest(command, Array(arguments.dropFirst()))

do {
    switch try CLIClient.send(request) {
    case let .success(_, result):
        printJSON(result)
        exit(0)
    case let .failure(_, error):
        printJSON(error.intentValue)
        exit(1)
    }
} catch {
    FileHandle.standardError.write(
        Data("tenon-cli: \(error)\n".utf8)
    )
    exit(1)
}
