// @domain: cli-control
import AppKit
import Foundation
import TenonCore
import TenonIntentCore

/// What the kernel says about the process that opened this connection.
///
/// The only identity material the control plane has, and deliberately so: the CLI envelope
/// is closed in both directions and carries no credential field, so a caller cannot type its
/// way into being someone. `nil` means the socket could not name the peer, and every rule
/// downstream reads that as "the ordinary CLI user".
struct CLIRequestOrigin: Equatable, Sendable {
    let peerProcessID: Int32?

    /// A request whose peer was never named — an in-process caller, or a connection the
    /// kernel would not answer for.
    static let unknown = Self(peerProcessID: nil)
}

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
        runtime: AppIntentRuntime,
        origin: CLIRequestOrigin = .unknown,
        agentPanes: () async -> [AgentPaneCandidate] = { [] },
        ancestry: (Int32) -> [Int32] = AgentCallerProvenance.ancestry(ofProcess:)
    ) async -> CLIResult {
        let caller = await callerPrincipal(
            origin: origin,
            runtime: runtime,
            agentPanes: agentPanes,
            ancestry: ancestry
        )
        switch action {
        case .ping:
            return .ok(
                pingPayload(
                    protocolVersion: CLIProtocol.version,
                    processID: ProcessInfo.processInfo.processIdentifier,
                    isActive: NSApp.isActive,
                    version: AppVersion.current,
                    socketPath: pingSocketPath(
                        for: (try? AppInstanceChannel.resolve()) ?? .production
                    )
                )
            )

        case .appFocus:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return .ok(.object(["activated": .bool(true)]))

        case .intentList:
            let snapshot = await runtime.discover(
                as: caller
            )
            return .ok(
                .array(snapshot.items.map(discoverySummary))
            )

        case let .intentDescribe(intentID):
            let snapshot = await runtime.discover(
                as: caller
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
                as: caller,
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

extension CLICommandExecutor {
    /// Who is on the other end of this connection (`AC-FR-037`).
    ///
    /// Tenon has two users and, until this function, one identity: every call an agent made
    /// arrived wearing the human's `cli:local-user`, which left
    /// `IntentDispatcher.effectiveConfirmation`'s agent hardening testing a condition the
    /// tree never constructed.
    ///
    /// Nothing a caller sends is read here. The chain is entirely made of host observations
    /// — the kernel's `LOCAL_PEERPID` for the connection, `proc_bsdinfo.pbi_ppid` for the
    /// walk outward, and the host's own read of which process each pane is running — and
    /// every link that fails to prove a pane answers with the CLI principal. A process that
    /// merely *claims* to be an agent gets exactly what it had before.
    static func callerPrincipal(
        origin: CLIRequestOrigin,
        runtime: AppIntentRuntime,
        agentPanes: () async -> [AgentPaneCandidate],
        ancestry: (Int32) -> [Int32]
    ) async -> IntentPrincipal {
        guard let peer = origin.peerProcessID else {
            return AppIntentRuntime.cliPrincipal
        }
        let candidates = await agentPanes()
        guard !candidates.isEmpty,
              let paneID = AgentCallerAdmission.admit(
                  peerAncestry: ancestry(peer),
                  candidates: candidates
              )
        else { return AppIntentRuntime.cliPrincipal }
        return await runtime.agentPrincipal(forPane: paneID)
    }

    /// The exact `ping` answer, as a pure value.
    ///
    /// Everything here is a fact about this *process*: which wire it speaks, which pid it
    /// is, whether it holds the foreground, which build it is, and where its control socket
    /// lives. `CLI-FR-027` keeps that boundary — a caller cannot read provider, plugin, or
    /// health readiness out of a liveness probe, which is what `CLI-FR-014` meant by
    /// "without claiming provider readiness" and what `DRM-FR-043` walls off separately.
    nonisolated static func pingPayload(
        protocolVersion: Int,
        processID: Int32,
        isActive: Bool,
        version: AppVersion,
        socketPath: String
    ) -> IntentValue {
        .object([
            "protocolVersion": .integer(Int64(protocolVersion)),
            "pid": .integer(Int64(processID)),
            "active": .bool(isActive),
            // Two fields rather than `AppVersion.summary`: a script comparing releases
            // wants the bare version, and a build with no `Info.plist` still has to say
            // so — `swift run tenon` reports the em dash rather than a shipped nothing.
            "version": .string(version.short),
            "build": .string(version.build),
            "socketPath": .string(socketPath),
        ])
    }

    /// The socket this channel's server binds. Derived from the same
    /// `AppInstanceChannel.socketPath()` `CLISocketServer.clientSocketPath` uses, so ping
    /// cannot answer with a path belonging to the other channel.
    nonisolated static func pingSocketPath(for channel: AppInstanceChannel) -> String {
        channel.socketPath()
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
