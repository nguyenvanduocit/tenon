// @domain: plugin-host, plugin-contributions
import Foundation
import TenonCore
import TenonIntentCore

enum ClaudeSessionsPlugin {
    static let id: PluginID = "dev.tenon.claude-sessions"
    static let viewID = ClaudeSessionsView.viewID

    private static let open = try! IntentID("dev.tenon.claude-sessions.open.v1")
    private static let refresh = try! IntentID("dev.tenon.claude-sessions.refresh.v1")
    private static let favouritesKey = "favourites"
    private static let contentOpen = try! IntentID("workspace.content.open.v1")
    private static let agentCommand = try! IntentID("agent.command.v1")
    private static let terminalOpen = try! IntentID("terminal.open.v1")

    static func makeProgram() -> BundledPluginProgram {
        let state = State()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: ["settings.changed", "workspace.changed"],
            providedIntents: [open, refresh],
            viewCallbacks: [
                viewID: BundledPluginViewCallbacks(
                    select: { selection, context in
                        await state.select(selection, context: context)
                    },
                    open: { instanceID, context in
                        await state.open(instanceID: instanceID, context: context)
                    },
                    close: { instanceID, _ in
                        await state.close(instanceID: instanceID)
                        return nil
                    }
                ),
            ],
            activate: { context in
                await state.activate(context: context)
            },
            receiveEvent: { event, payload, context in
                await state.receiveEvent(event, payload: payload, context: context)
            },
            invokeIntent: { envelope, providerContext, context in
                try await state.invokeIntent(
                    envelope,
                    providerContext: providerContext,
                    context: context
                )
            }
        )
    }

    private actor State {
        private var panes: [String: ClaudeSessionsPaneState] = [:]
        private var favourites: [ClaudeFavouriteRecord] = []

        func activate(context: BundledPluginContext) -> BundledPluginContribution {
            favourites = ClaudeSessionsScan.readFavourites(context.storageValue(favouritesKey))
            return ClaudeSessionsView.registration()
        }

        func open(
            instanceID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            let caller = directCaller(context)
            let owner = await ClaudeSessionsScan.owningWorkspace(
                instanceID: instanceID,
                caller: caller
            )
            var pane = ClaudeSessionsPaneState(id: instanceID)
            pane.workspaceID = owner.id
            pane.workspacePath = owner.path
            panes[instanceID] = pane
            return await scan(instanceID: instanceID, context: context, caller: caller)
        }

        func close(instanceID: String) {
            panes.removeValue(forKey: instanceID)
        }

        func select(
            _ selection: BundledPluginViewSelect,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard let pane = panes[selection.instanceID ?? ""] else { return nil }
            let chosen = selection.itemID == "new"
                ? selection.value?.claudeStringValue ?? ""
                : selection.itemID
            let caller = directCaller(context)

            if chosen == "refresh" {
                return await scan(instanceID: pane.id, context: context, caller: caller)
            }
            if chosen.hasPrefix("start:") {
                _ = await launch(
                    pane: pane,
                    agentID: String(chosen.dropFirst("start:".count)),
                    caller: caller,
                    context: context
                )
                return contribution()
            }
            if chosen.hasPrefix("details:") {
                await openRecorded(
                    pane: pane,
                    sessionID: String(chosen.dropFirst("details:".count)),
                    caller: caller,
                    context: context
                )
                return contribution()
            }
            if chosen.hasPrefix("fav:") {
                let mark = String(chosen.dropFirst("fav:".count))
                guard let separator = mark.firstIndex(of: ":"), separator > mark.startIndex else {
                    return nil
                }
                let provider = ClaudeSessionRecord.Provider(rawValue: String(mark[..<separator]))
                let sessionID = String(mark[mark.index(after: separator)...])
                guard let provider else { return nil }
                return await toggleFavourite(
                    pane: pane,
                    provider: provider,
                    sessionID: sessionID,
                    context: context
                )
            }
            if chosen.hasPrefix("open:") {
                let rest = chosen.dropFirst("open:".count)
                guard let separator = rest.firstIndex(of: ":"), separator > rest.startIndex else {
                    return nil
                }
                let agentID = String(rest[..<separator])
                let sessionID = String(rest[rest.index(after: separator)...])
                await continueSession(
                    pane: pane,
                    agentID: agentID,
                    sessionID: sessionID,
                    caller: caller,
                    context: context
                )
                return contribution()
            }
            return nil
        }

        func receiveEvent(
            _ event: String,
            payload: IntentValue,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            let caller = directCaller(context)
            switch event {
            case "settings.changed":
                for instanceID in Array(panes.keys) {
                    _ = await scan(instanceID: instanceID, context: context, caller: caller)
                }
            case "workspace.changed":
                for instanceID in Array(panes.keys) {
                    guard let current = panes[instanceID] else { continue }
                    let owner = await ClaudeSessionsScan.owningWorkspace(
                        instanceID: instanceID,
                        caller: caller
                    )
                    guard owner.id != nil,
                          owner.id != current.workspaceID || owner.path != current.workspacePath
                    else { continue }
                    var updated = current
                    updated.workspaceID = owner.id
                    updated.workspacePath = owner.path
                    panes[instanceID] = updated
                    _ = await scan(instanceID: instanceID, context: context, caller: caller)
                }
            default:
                break
            }
            _ = payload
            return contribution()
        }

        func invokeIntent(
            _ envelope: IntentEnvelope,
            providerContext: IntentProviderContext,
            context: BundledPluginContext
        ) async throws -> IntentProviderReply {
            switch envelope.name {
            case ClaudeSessionsPlugin.open:
                let result = await providerContext.send(
                    IntentProviderSendRequest(
                        intentID: ClaudeSessionsPlugin.contentOpen,
                        input: .object([
                            "content": .object([
                                "kind": .string("plugin"),
                                "pluginID": .string(ClaudeSessionsPlugin.id.rawValue),
                                "viewID": .string(ClaudeSessionsPlugin.viewID),
                            ]),
                        ])
                    )
                )
                return providerReply(from: result)
            case ClaudeSessionsPlugin.refresh:
                let caller = ClaudeSessionsIntentCaller { intentID, input in
                    await providerContext.send(
                        IntentProviderSendRequest(intentID: intentID, input: input)
                    )
                }
                for instanceID in Array(panes.keys) {
                    _ = await scan(instanceID: instanceID, context: context, caller: caller)
                }
                await context.publishContribution(contribution())
                return .success(.object([:]))
            default:
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        }

        private func scan(
            instanceID: String,
            context: BundledPluginContext,
            caller: ClaudeSessionsIntentCaller
        ) async -> BundledPluginContribution? {
            guard var pane = panes[instanceID] else { return nil }
            pane.project = (context.setting("projectPath")?.claudeStringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if pane.project.isEmpty { pane.project = pane.workspacePath }
            pane.generation &+= 1
            pane.notice = "Scanning…"
            pane.scanError = nil
            pane.favouriteError = nil
            panes[instanceID] = pane

            guard !pane.project.isEmpty else {
                var empty = pane
                empty.sessions = []
                empty.notice = "Open a workspace to see its agent sessions."
                panes[instanceID] = empty
                return contribution()
            }

            let generation = pane.generation
            let agents = await ClaudeSessionsScan.loadAgents(
                caller: caller,
                log: context.log
            )
            guard isCurrent(instanceID, generation: generation) else { return nil }
            panes[instanceID]?.agents = agents

            let limit = sessionLimit(context: context)
            let claude = await ClaudeSessionsScan.scanClaude(
                project: pane.project,
                claudeHome: setting(context, key: "claudeHome", default: "~/.claude"),
                favourites: favourites,
                limit: limit,
                caller: caller,
                log: context.log
            )
            guard isCurrent(instanceID, generation: generation) else { return nil }
            let codex = await ClaudeSessionsScan.scanCodex(
                project: pane.project,
                codexHome: setting(context, key: "codexHome", default: "~/.codex"),
                favourites: favourites,
                limit: limit,
                caller: caller,
                log: context.log
            )
            guard isCurrent(instanceID, generation: generation) else { return nil }

            var found = claude.sessions + codex
            found.sort { $0.mtime > $1.mtime }
            var marked: [ClaudeSessionRecord] = []
            var recent: [ClaudeSessionRecord] = []
            for session in found {
                if ClaudeSessionsScan.isFavourite(
                    favourites,
                    project: pane.project,
                    provider: session.provider,
                    sessionID: session.id
                ) {
                    marked.append(session)
                } else {
                    recent.append(session)
                }
            }
            panes[instanceID]?.sessions = marked + recent.prefix(limit)
            panes[instanceID]?.scanError = claude.error
            panes[instanceID]?.notice = claude.error ?? ""
            return contribution()
        }

        private func toggleFavourite(
            pane: ClaudeSessionsPaneState,
            provider: ClaudeSessionRecord.Provider,
            sessionID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution {
            guard !pane.project.isEmpty else { return contribution() }
            let key = ClaudeSessionsScan.favouriteKey(provider: provider, sessionID: sessionID)
            var next = favourites
            if let index = next.firstIndex(where: { $0.key == key && $0.project == pane.project }) {
                next.remove(at: index)
            } else {
                next.append(
                    ClaudeFavouriteRecord(
                        key: key,
                        project: pane.project,
                        at: Int(Date().timeIntervalSince1970)
                    )
                )
                while next.count > 200 {
                    let keep = next.count - 1
                    let oldest = next.indices.filter { $0 != keep }.min {
                        next[$0].at < next[$1].at
                    } ?? 0
                    next.remove(at: oldest)
                }
            }
            favourites = next
            if let current = panes[pane.id] { panes[pane.id]?.favouriteError = nil; _ = current }
            await context.publishContribution(contribution())
            do {
                let value: IntentValue = .array(next.map { favouriteValue($0) })
                try await context.setStorageValue(ClaudeSessionsPlugin.favouritesKey, value)
            } catch {
                favourites = ClaudeSessionsScan.readFavourites(
                    context.storageValue(ClaudeSessionsPlugin.favouritesKey)
                )
                panes[pane.id]?.favouriteError = "Could not save that favourite: \(error)"
                await context.publishContribution(contribution())
            }
            return contribution()
        }

        private func launch(
            pane: ClaudeSessionsPaneState,
            agentID: String,
            caller: ClaudeSessionsIntentCaller,
            context: BundledPluginContext
        ) async -> IntentResult {
            let composed = await caller.send(
                ClaudeSessionsPlugin.agentCommand,
                .object(["agent": .string(agentID)])
            )
            guard case let .success(success) = composed,
                  let commandLine = success.value.claudeObjectValue?["commandLine"]?.claudeStringValue
            else {
                let code = failureCode(composed)
                panes[pane.id]?.notice = "Could not start \(agentLabel(pane, id: agentID)): \(code)"
                await context.publishContribution(contribution())
                return composed
            }
            let opened = await caller.send(
                ClaudeSessionsPlugin.terminalOpen,
                .object([
                    "command": .string(commandLine),
                    "workingDirectory": .string(pane.project),
                ])
            )
            if case let .failure(failure) = opened {
                panes[pane.id]?.notice = "Could not open a pane: \(failure.error.code.rawValue)"
                await context.publishContribution(contribution())
            }
            return opened
        }

        private func continueSession(
            pane: ClaudeSessionsPaneState,
            agentID: String,
            sessionID: String,
            caller: ClaudeSessionsIntentCaller,
            context: BundledPluginContext
        ) async {
            guard let session = pane.sessions.first(where: { $0.id == sessionID }) else { return }
            var input: [String: IntentValue] = [
                "agent": .string(agentID),
                "session": .object([
                    "agent": .string(session.provider.rawValue),
                    "sessionID": .string(session.id),
                ]),
            ]
            if session.provider.rawValue != agentID {
                let path = await ClaudeSessionsScan.transcriptPath(
                    for: session,
                    codexHome: setting(context, key: "codexHome", default: "~/.codex"),
                    project: pane.project,
                    caller: caller
                )
                guard !path.isEmpty else {
                    panes[pane.id]?.notice = "No transcript on disk for that session, so \(agentLabel(pane, id: agentID)) would have nothing to read."
                    await context.publishContribution(contribution())
                    return
                }
                input["session"] = .object([
                    "agent": .string(session.provider.rawValue),
                    "sessionID": .string(session.id),
                    "transcriptPath": .string(path),
                ])
            }
            let result = await caller.send(ClaudeSessionsPlugin.agentCommand, .object(input))
            guard case let .success(success) = result,
                  let commandLine = success.value.claudeObjectValue?["commandLine"]?.claudeStringValue
            else {
                panes[pane.id]?.notice = "Could not start \(agentLabel(pane, id: agentID)): \(failureCode(result))"
                await context.publishContribution(contribution())
                return
            }
            let opened = await caller.send(
                ClaudeSessionsPlugin.terminalOpen,
                .object([
                    "command": .string(commandLine),
                    "workingDirectory": .string(pane.project),
                ])
            )
            if case let .failure(failure) = opened {
                panes[pane.id]?.notice = "Could not open a pane: \(failure.error.code.rawValue)"
                await context.publishContribution(contribution())
            }
        }

        private func openRecorded(
            pane: ClaudeSessionsPaneState,
            sessionID: String,
            caller: ClaudeSessionsIntentCaller,
            context: BundledPluginContext
        ) async {
            guard let session = pane.sessions.first(where: { $0.id == sessionID }) else { return }
            let path = session.path.isEmpty
                ? await ClaudeSessionsScan.transcriptPath(
                    for: session,
                    codexHome: setting(context, key: "codexHome", default: "~/.codex"),
                    project: pane.project,
                    caller: caller
                )
                : session.path
            guard !path.isEmpty else {
                panes[pane.id]?.notice = "No transcript on disk for that session, so there is nothing to read."
                await context.publishContribution(contribution())
                return
            }
            let result = await caller.send(
                ClaudeSessionsPlugin.contentOpen,
                .object([
                    "content": .object([
                        "kind": .string("agentSession"),
                        "provider": .string(session.provider.rawValue),
                        "sessionID": .string(session.id),
                        "transcriptPath": .string(path),
                        "title": .string(sessionTitle(session)),
                    ]),
                ])
            )
            if case let .failure(failure) = result {
                panes[pane.id]?.notice = "Could not open that session: \(failure.error.code.rawValue)"
                await context.publishContribution(contribution())
            }
        }

        private func isCurrent(_ instanceID: String, generation: UInt64) -> Bool {
            panes[instanceID]?.generation == generation
        }

        private func contribution() -> BundledPluginContribution {
            ClaudeSessionsView.contribution(
                panes: Array(panes.values),
                favourites: favourites
            )
        }

        private func directCaller(_ context: BundledPluginContext) -> ClaudeSessionsIntentCaller {
            ClaudeSessionsIntentCaller { intentID, input in
                await context.intents.send(
                    PluginIntentSendRequest(intentID: intentID, input: input)
                )
            }
        }

        private func setting(
            _ context: BundledPluginContext,
            key: String,
            default fallback: String
        ) -> String {
            let value = context.setting(key)?.claudeStringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }

        private func sessionLimit(context: BundledPluginContext) -> Int {
            let value = Int(context.setting("limit")?.claudeStringValue ?? "25") ?? 25
            return max(10, min(100, value))
        }

        private func agentLabel(_ pane: ClaudeSessionsPaneState, id: String) -> String {
            pane.agents.first(where: { $0.id == id })?.label ?? id
        }

        private func favouriteValue(_ favourite: ClaudeFavouriteRecord) -> IntentValue {
            .object([
                "key": .string(favourite.key),
                "project": .string(favourite.project),
                "at": .integer(Int64(favourite.at)),
            ])
        }

        private func sessionTitle(_ session: ClaudeSessionRecord) -> String {
            if !session.title.isEmpty { return session.title }
            return session.provider == .codex ? "Untitled Codex session" : "Untitled Claude session"
        }

        private func failureCode(_ result: IntentResult) -> String {
            guard case let .failure(failure) = result else { return "the request failed" }
            return failure.error.code.rawValue
        }

        private func providerReply(from result: IntentResult) -> IntentProviderReply {
            switch result {
            case .success:
                return .success(.object([:]))
            case let .failure(failure):
                return .failure(
                    IntentProviderFailure(
                        code: .kernel(.handlerFailed),
                        details: .object(["message": .string(failure.error.code.rawValue)])
                    )
                )
            }
        }
    }
}

private extension IntentValue {
    var claudeObjectValue: [String: IntentValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var claudeStringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
