// @domain: command-surface, workspace-model
import Foundation
import TenonCore
import TenonIntentCore

enum CoreCommandsPlugin {
    static let id: PluginID = "dev.tenon.core-commands"

    private static let providedIntents = Set([
        "dev.tenon.core-commands.tab.new.v1",
        "dev.tenon.core-commands.terminal.new.v1",
        "dev.tenon.core-commands.pane.split-right.v1",
        "dev.tenon.core-commands.pane.split-down.v1",
        "dev.tenon.core-commands.pane.close.v2",
        "dev.tenon.core-commands.changes.open.v1",
        "dev.tenon.core-commands.automation.open.v1",
        "dev.tenon.core-commands.tab.next.v1",
        "dev.tenon.core-commands.tab.previous.v1",
        "dev.tenon.core-commands.pane.focus-next.v1",
        "dev.tenon.core-commands.workspace.switch.v1",
    ].map { try! IntentID($0) })

    static func makeProgram() -> BundledPluginProgram {
        BundledPluginProgram(
            id: id,
            subscribedEvents: [],
            providedIntents: providedIntents,
            activate: { _ in .empty },
            receiveEvent: { _, _, _ in nil },
            invokeIntent: invoke
        )
    }

    private static func invoke(
        envelope: IntentEnvelope,
        context: IntentProviderContext
    ) async throws -> IntentProviderReply {
        switch envelope.name.rawValue {
        case "dev.tenon.core-commands.tab.new.v1":
            return await send("workspace.tab.create.v1", input: .object([:]), context: context)
        case "dev.tenon.core-commands.terminal.new.v1":
            return await send(
                "workspace.tab.create.v1",
                input: .object(["content": .object(["kind": .string("terminal")])]),
                context: context
            )
        case "dev.tenon.core-commands.pane.split-right.v1":
            return await send(
                "workspace.pane.split.v1",
                input: .object(["axis": .string("horizontal")]),
                context: context
            )
        case "dev.tenon.core-commands.pane.split-down.v1":
            return await send(
                "workspace.pane.split.v1",
                input: .object(["axis": .string("vertical")]),
                context: context
            )
        case "dev.tenon.core-commands.pane.close.v2":
            return await send("workspace.pane.close.v2", input: .object([:]), context: context)
        case "dev.tenon.core-commands.changes.open.v1":
            return await send(
                "workspace.tab.create.v1",
                input: .object(["content": .object(["kind": .string("changes")])]),
                context: context
            )
        case "dev.tenon.core-commands.automation.open.v1":
            return await send(
                "workspace.tab.create.v1",
                input: .object(["content": .object(["kind": .string("automation")])]),
                context: context
            )
        case "dev.tenon.core-commands.tab.next.v1":
            return await send("workspace.tab.next.v1", input: .object([:]), context: context)
        case "dev.tenon.core-commands.tab.previous.v1":
            return await send("workspace.tab.previous.v1", input: .object([:]), context: context)
        case "dev.tenon.core-commands.pane.focus-next.v1":
            return await send(
                "workspace.pane.focus-next.v1",
                input: .object([:]),
                context: context
            )
        case "dev.tenon.core-commands.workspace.switch.v1":
            return await switchWorkspace(context: context)
        default:
            throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
        }
    }

    private static func send(
        _ rawIntentID: String,
        input: IntentValue,
        scopeOverride: InvocationScopeOverride? = nil,
        context: IntentProviderContext
    ) async -> IntentProviderReply {
        let result = await context.send(
            IntentProviderSendRequest(
                intentID: try! IntentID(rawIntentID),
                input: input,
                scopeOverride: scopeOverride
            )
        )
        return emptyReply(from: result)
    }

    private static func switchWorkspace(
        context: IntentProviderContext
    ) async -> IntentProviderReply {
        var workspaces: [[String: IntentValue]] = []
        var cursor: String?

        for _ in 0 ..< 16 {
            var input: [String: IntentValue] = ["limit": .integer(256)]
            if let cursor {
                input["cursor"] = .string(cursor)
            }
            let result = await context.send(
                IntentProviderSendRequest(
                    intentID: try! IntentID("workspace.state.v1"),
                    input: .object(input)
                )
            )
            let value: IntentValue
            switch result {
            case let .success(success):
                value = success.value
            case let .failure(failure):
                return handlerFailure(for: failure.error)
            }

            let object = value.objectValue ?? [:]
            let nodes = object["nodes"]?.arrayValue ?? []
            workspaces.append(contentsOf: nodes.compactMap { node in
                guard let object = node.objectValue,
                      object["kind"]?.stringValue == "workspace"
                else {
                    return nil
                }
                return object
            })
            cursor = object["nextCursor"]?.stringValue
            if cursor == nil || cursor?.isEmpty == true {
                break
            }
        }

        guard !workspaces.isEmpty else { return .success(.object([:])) }
        let items = workspaces.compactMap { workspace -> IntentValue? in
            guard let itemID = workspace["id"]?.stringValue,
                  let name = workspace["name"]?.stringValue
            else {
                return nil
            }
            var item: [String: IntentValue] = [
                "id": .string(itemID),
                "label": .string(name),
                "icon": .string("square.stack"),
            ]
            if let path = workspace["path"]?.stringValue {
                item["detail"] = .string(path)
            }
            return .object(item)
        }
        let picked = await context.send(
            IntentProviderSendRequest(
                intentID: try! IntentID("ui.pick.v1"),
                input: .object([
                    "items": .array(items),
                    "placeholder": .string("Switch workspace"),
                ])
            )
        )
        guard case let .success(success) = picked,
              let selected = success.value.objectValue?["selectedID"]?.stringValue
        else {
            return .success(.object([:]))
        }
        guard let workspaceID = UUID(uuidString: selected) else {
            return .failure(
                IntentProviderFailure(
                    code: .kernel(.handlerFailed),
                    details: .object(["message": .string("selected workspace id is not a UUID")])
                )
            )
        }
        return await send(
            "workspace.select.v1",
            input: .object([:]),
            scopeOverride: InvocationScopeOverride(workspaceID: workspaceID),
            context: context
        )
    }

    private static func emptyReply(from result: IntentResult) -> IntentProviderReply {
        switch result {
        case .success:
            .success(.object([:]))
        case let .failure(failure):
            handlerFailure(for: failure.error)
        }
    }

    private static func handlerFailure(for error: IntentError) -> IntentProviderReply {
        .failure(
            IntentProviderFailure(
                code: .kernel(.handlerFailed),
                details: .object(["message": .string(error.code.rawValue)])
            )
        )
    }
}

private extension IntentValue {
    var objectValue: [String: IntentValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [IntentValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
