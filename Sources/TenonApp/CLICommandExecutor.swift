// @domain: cli-control
import AppKit
import Foundation
import TenonCore
import TenonIntentCore

/// The local control-plane adapter.
///
/// App activation is the only direct shell effect. Discovery and every domain
/// operation cross `AppIntentRuntime`, so the CLI observes the same contracts,
/// policy, provider selection, validation, timeout, and telemetry as every
/// other Intent Bus caller.
@MainActor
enum CLICommandExecutor {
    static func execute(
        _ action: CLIAction,
        runtime: AppIntentRuntime
    ) async -> CLIResult {
        switch action {
        case .ping:
            return .ok(.object([
                "protocolVersion": .integer(Int64(CLIProtocol.version)),
                "pid": .integer(
                    Int64(ProcessInfo.processInfo.processIdentifier)
                ),
                "active": .bool(NSApp.isActive),
            ]))

        case .appFocus:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return .ok(.object(["activated": .bool(true)]))

        case .intentList:
            let snapshot = await runtime.discover(
                as: AppIntentRuntime.cliPrincipal
            )
            return .ok(
                .array(snapshot.items.map(discoverySummary))
            )

        case let .intentDescribe(intentID):
            let snapshot = await runtime.discover(
                as: AppIntentRuntime.cliPrincipal
            )
            guard let item = snapshot.items.first(where: {
                $0.name == intentID
            }) else {
                return .error(
                    CLIError(
                        code: .intentNotFound,
                        message:
                            "intent '\(intentID.rawValue)' is not callable "
                            + "by the CLI principal"
                    )
                )
            }
            return .ok(discoveryDescription(item))

        case let .intentSend(invocation):
            let timeout = invocation.timeoutMilliseconds.map {
                Duration.milliseconds($0)
            }
            let result = await runtime.send(
                invocation.intentID,
                input: invocation.input,
                as: AppIntentRuntime.cliPrincipal,
                scope: invocation.scope,
                target: invocation.target,
                idempotencyKey: invocation.idempotencyKey,
                requestedTimeout: timeout
            )
            switch result {
            case let .success(success):
                return .ok(success.value)
            case let .failure(failure):
                return .error(CLIError(intentFailure: failure))
            }
        }
    }
}

private extension CLICommandExecutor {
    static func discoverySummary(
        _ item: IntentDiscoveryItem
    ) -> IntentValue {
        .object([
            "name": .string(item.name.rawValue),
            "title": item.title.map(IntentValue.string) ?? .null,
            "description":
                item.description.map(IntentValue.string) ?? .null,
            "effects": effectsValue(item.effects),
            "deprecated": .bool(item.deprecated),
            "providers": .array(
                item.activeProviders.map {
                    .string($0.rawValue)
                }
            ),
        ])
    }

    static func discoveryDescription(
        _ item: IntentDiscoveryItem
    ) -> IntentValue {
        .object([
            "name": .string(item.name.rawValue),
            "class": .string(item.contractClass.rawValue),
            "owner": ownerValue(item.owner),
            "title": item.title.map(IntentValue.string) ?? .null,
            "description":
                item.description.map(IntentValue.string) ?? .null,
            "inputSchema": item.inputSchema,
            "outputSchema": item.outputSchema,
            "audiences": .array(
                item.audiences
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { .string($0.rawValue) }
            ),
            "effects": effectsValue(item.effects),
            "deprecated": .bool(item.deprecated),
            "domainErrors": .array(
                item.domainErrors
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { .string($0.rawValue) }
            ),
            "providers": .array(
                item.activeProviders.map {
                    .string($0.rawValue)
                }
            ),
        ])
    }

    static func ownerValue(_ owner: IntentContractOwner) -> IntentValue {
        switch owner {
        case .core:
            .object(["kind": .string("core")])
        case let .plugin(pluginID):
            .object([
                "kind": .string("plugin"),
                "pluginID": .string(pluginID.rawValue),
            ])
        }
    }

    static func effectsValue(_ effects: IntentEffects) -> IntentValue {
        let retention = effects.retentionMilliseconds.flatMap(
            Int64.init(exactly:)
        )
        return .object([
            "kind": .string(effects.kind.rawValue),
            "idempotency": .string(effects.idempotency.rawValue),
            "retentionMs":
                retention.map(IntentValue.integer) ?? .null,
            "confirmation": .string(effects.confirmation.rawValue),
            "external": .bool(effects.external),
        ])
    }
}
