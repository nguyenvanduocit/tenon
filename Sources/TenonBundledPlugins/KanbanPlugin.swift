// @domain: plugin-host, plugin-contributions
import Foundation
import TenonCore
import TenonIntentCore

enum KanbanPlugin {
    static let id: PluginID = "dev.tenon.kanban"
    private static let viewID = "board"

    private static let openIntent = try! IntentID("dev.tenon.kanban.open.v1")
    private static let workspaceContentOpen = try! IntentID("workspace.content.open.v1")
    private static let paneOwner = try! IntentID("workspace.pane.owner.v1")
    private static let fileRead = try! IntentID("filesystem.file.read.v1")
    private static let fileWrite = try! IntentID("filesystem.file.write.v1")
    private static let agentInventory = try! IntentID("agent.inventory.v1")
    private static let agentCommand = try! IntentID("agent.command.v1")
    private static let terminalOpen = try! IntentID("terminal.open.v1")
    private static let terminalViewportRead = try! IntentID("terminal.viewport.read.v1")
    private static let workspacePaneFocus = try! IntentID("workspace.pane.focus.v1")

    private static let kanbanDirectory = ".kanban"
    private static let boardFile = "board.md"
    private static let debounceMilliseconds = 250.0
    private static let trackIntervalMilliseconds = 1_200.0
    private static let maximumQueuedMoves = 4

    // MARK: - Program entry point  @domain: plugin-host

    static func makeProgram() -> BundledPluginProgram {
        let state = State()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: ["workspace.changed"],
            providedIntents: [openIntent],
            viewCallbacks: [
                viewID: BundledPluginViewCallbacks(
                    select: { select, context in
                        await state.select(select, context: context)
                    },
                    open: { instanceID, context in
                        await state.open(instanceID: instanceID, context: context)
                    },
                    close: { instanceID, _ in
                        await state.close(instanceID: instanceID)
                    }
                ),
            ],
            activate: { _ in await state.contribution() },
            receiveEvent: { event, _, context in
                guard event == "workspace.changed" else { return nil }
                return await state.workspaceChanged(context: context)
            },
            invokeIntent: { envelope, providerContext, _ in
                guard envelope.name == openIntent else {
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
                let result = await providerContext.send(
                    IntentProviderSendRequest(
                        intentID: workspaceContentOpen,
                        input: .object([
                            "content": .object([
                                "kind": .string("plugin"),
                                "pluginID": .string(id.rawValue),
                                "viewID": .string(viewID),
                            ]),
                        ])
                    )
                )
                switch result {
                case .success:
                    return .success(.object([:]))
                case let .failure(failure):
                    return .failure(
                        IntentProviderFailure(
                            code: .kernel(.handlerFailed),
                            details: .object([
                                "message": .string(failure.error.code.rawValue),
                            ])
                        )
                    )
                }
            }
        )
    }

    // MARK: - Instance state and contributions  @domain: plugin-contributions

    private actor State {
        private struct Agent: Sendable, Equatable {
            let id: String
            let label: String
        }

        private struct Run: Sendable, Equatable {
            var paneID: String
            var agent: String?
            var exited = false
            var tail = ""
            var error = ""
        }

        private struct Pane: Sendable {
            let id: String
            var workspaceID: String?
            var workspacePath = ""
            var boardPath = ""
            var watchDir = ""
            var watch: BundledPluginWatchHandle?
            var debounceHandle: BundledPluginTimerHandle?
            var trackHandle: BundledPluginTimerHandle?
            var columns: [KanbanBoardFormat.Column] = []
            var rawBoard: String?
            var error = ""
            var writeError = ""
            var openTask: String?
            var detail: KanbanBoardFormat.Detail?
            var runs: [String: Run] = [:]
            var agents: [Agent] = []
            var generation = 0
            var queuedMoves = 0
        }

        private var panes: [String: Pane] = [:]

        func contribution() -> BundledPluginContribution {
            BundledPluginContribution(
                viewRegistrations: [
                    BundledPluginViewRegistration(
                        viewID: KanbanPlugin.viewID,
                        title: "Kanban",
                        instanced: true
                    ),
                ],
                viewBodies: panes.values.sorted { $0.id < $1.id }.map { pane in
                    BundledPluginViewBody(
                        viewID: KanbanPlugin.viewID,
                        instanceID: pane.id,
                        body: KanbanBoardView.body(
                            columns: pane.columns,
                            writeError: pane.writeError,
                            error: pane.error
                        ),
                        header: KanbanBoardView.header(boardPath: pane.boardPath),
                        modal: modal(for: pane)
                    )
                }
            )
        }

        // MARK: - View lifecycle and events  @domain: plugin-host

        func open(
            instanceID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution {
            panes[instanceID] = Pane(id: instanceID)
            let owner = await owningWorkspace(instanceID, context: context)
            guard var pane = panes[instanceID] else { return contribution() }
            pane.workspaceID = owner.id
            pane.workspacePath = owner.path
            pane.boardPath = PluginPath.join(owner.path, KanbanPlugin.kanbanDirectory, KanbanPlugin.boardFile)
            panes[instanceID] = pane
            await watchBoard(instanceID: instanceID, context: context)
            await refresh(instanceID: instanceID, context: context)
            return contribution()
        }

        func close(instanceID: String) async -> BundledPluginContribution {
            guard var pane = panes.removeValue(forKey: instanceID) else { return contribution() }
            await release(&pane, context: nil)
            return contribution()
        }

        func workspaceChanged(context: BundledPluginContext) async -> BundledPluginContribution {
            for instanceID in Array(panes.keys) {
                let owner = await owningWorkspace(instanceID, context: context)
                guard var pane = panes[instanceID],
                      owner.id != pane.workspaceID
                else { continue }
                await stopTracking(&pane)
                pane.workspaceID = owner.id
                pane.workspacePath = owner.path
                pane.boardPath = PluginPath.join(owner.path, KanbanPlugin.kanbanDirectory, KanbanPlugin.boardFile)
                pane.openTask = nil
                pane.detail = nil
                pane.runs = [:]
                panes[instanceID] = pane
                await watchBoard(instanceID: instanceID, context: context)
                await refresh(instanceID: instanceID, context: context)
            }
            return contribution()
        }

        // MARK: - View actions  @domain: plugin-contributions

        func select(
            _ selection: BundledPluginViewSelect,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard let instanceID = selection.instanceID,
                  panes[instanceID] != nil
            else { return nil }
            let action = selection.itemID

            if action.hasPrefix("start:") {
                let rest = String(action.dropFirst("start:".count))
                if let separator = rest.firstIndex(of: ":") {
                    let agent = String(rest[..<separator])
                    let taskID = String(rest[rest.index(after: separator)...])
                    if let task = task(instanceID: instanceID, id: taskID) {
                        await startAgent(instanceID: instanceID, agentID: agent, task: task, context: context)
                    }
                    return contribution()
                }
                if let task = task(instanceID: instanceID, id: rest) {
                    await startUnnamedAgent(instanceID: instanceID, task: task, context: context)
                }
                return contribution()
            }

            if action.hasPrefix("more:") {
                await openDetail(instanceID: instanceID, id: String(action.dropFirst("more:".count)), context: context)
                return contribution()
            }

            if action == "close-detail" {
                guard var pane = panes[instanceID] else { return nil }
                await stopTracking(&pane)
                pane.openTask = nil
                pane.detail = nil
                panes[instanceID] = pane
                return contribution()
            }

            if action.hasPrefix("focus:") {
                let taskID = String(action.dropFirst("focus:".count))
                if let paneID = panes[instanceID]?.runs[taskID]?.paneID,
                   let uuid = UUID(uuidString: paneID)
                {
                    _ = await context.intents.send(
                        PluginIntentSendRequest(
                            intentID: KanbanPlugin.workspacePaneFocus,
                            input: .object([:]),
                            scopeOverride: InvocationScopeOverride(paneID: uuid)
                        )
                    )
                }
                return nil
            }

            if action.hasPrefix("move-left:") {
                await moveTask(
                    instanceID: instanceID,
                    context: context
                ) { text in
                    KanbanBoardFormat.relocateTaskLine(
                        text,
                        id: String(action.dropFirst("move-left:".count)),
                        delta: -1
                    )
                }
                return contribution()
            }

            if action.hasPrefix("move-right:") {
                await moveTask(
                    instanceID: instanceID,
                    context: context
                ) { text in
                    KanbanBoardFormat.relocateTaskLine(
                        text,
                        id: String(action.dropFirst("move-right:".count)),
                        delta: 1
                    )
                }
                return contribution()
            }

            if action.hasPrefix("drop-into:") {
                let rawColumn = String(action.dropFirst("drop-into:".count))
                guard let column = Int(rawColumn),
                      let id = selection.value?.kanbanStringValue,
                      !id.isEmpty
                else { return nil }
                await moveTask(instanceID: instanceID, context: context) { text in
                    KanbanBoardFormat.relocateTaskLineToColumn(text, id: id, column: column)
                }
                return contribution()
            }

            return nil
        }

        // MARK: - Board reads and writes  @domain: plugin-contributions

        private func refresh(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            guard var pane = panes[instanceID], !pane.boardPath.isEmpty else { return }
            pane.generation += 1
            let generation = pane.generation
            let boardPath = pane.boardPath
            panes[instanceID] = pane

            let read = await readFile(boardPath, context: context)
            guard panes[instanceID]?.generation == generation,
                  var current = panes[instanceID]
            else { return }

            switch read {
            case let .success(text):
                let previous = current.rawBoard
                current.rawBoard = text
                current.columns = KanbanBoardFormat.parseBoard(text).columns
                current.error = ""
                panes[instanceID] = current
                if let previous, previous != text {
                    try? await context.emit(
                        event: "board.changed",
                        payload: .object(["path": .string(boardPath)])
                    )
                }
            case .missing:
                current.columns = []
                current.error = "No board at \(current.boardPath)"
                panes[instanceID] = current
            case let .failure(reason):
                current.columns = []
                current.error = "Board read failed: \(reason)"
                panes[instanceID] = current
            }

            guard var refreshed = panes[instanceID],
                  let openTask = refreshed.openTask
            else { return }
            guard let task = task(in: refreshed, id: openTask) else {
                refreshed.openTask = nil
                refreshed.detail = nil
                panes[instanceID] = refreshed
                return
            }
            let taskPath = PluginPath.join(
                refreshed.workspacePath,
                KanbanPlugin.kanbanDirectory,
                task.path.replacingOccurrences(of: #"^\./"#, with: "", options: .regularExpression)
            )
            let detailRead = await readFile(taskPath, context: context)
            guard panes[instanceID]?.generation == generation,
                  var detailed = panes[instanceID]
            else { return }
            if case let .success(text) = detailRead {
                detailed.detail = KanbanBoardFormat.parseTask(text)
            } else {
                detailed.detail = nil
            }
            panes[instanceID] = detailed
        }

        private func moveTask(
            instanceID: String,
            context: BundledPluginContext,
            relocate: (String) -> KanbanBoardFormat.Relocation
        ) async {
            guard var pane = panes[instanceID] else { return }
            guard pane.queuedMoves < KanbanPlugin.maximumQueuedMoves else {
                pane.writeError = "Move refused: too-many-queued-moves"
                panes[instanceID] = pane
                return
            }
            pane.queuedMoves += 1
            pane.writeError = ""
            let path = pane.boardPath
            panes[instanceID] = pane
            defer {
                if var settled = panes[instanceID] {
                    settled.queuedMoves = max(0, settled.queuedMoves - 1)
                    panes[instanceID] = settled
                }
            }

            let read = await readFile(path, context: context)
            guard panes[instanceID] != nil else { return }
            let text: String
            switch read {
            case let .success(value):
                text = value
            case .missing:
                if var current = panes[instanceID] {
                    current.writeError = "Move failed: board-missing"
                    panes[instanceID] = current
                }
                await refresh(instanceID: instanceID, context: context)
                return
            case let .failure(reason):
                if var current = panes[instanceID] {
                    current.writeError = "Move failed: \(reason)"
                    panes[instanceID] = current
                }
                await refresh(instanceID: instanceID, context: context)
                return
            }

            switch relocate(text) {
            case .unchanged:
                await refresh(instanceID: instanceID, context: context)
            case let .failure(reason):
                if var current = panes[instanceID] {
                    current.writeError = "Move failed: \(reason)"
                    panes[instanceID] = current
                }
                await refresh(instanceID: instanceID, context: context)
            case let .text(moved):
                if let failure = await writeFile(path: path, text: moved, context: context),
                   var current = panes[instanceID]
                {
                    current.writeError = "Board write failed: \(failure)"
                    panes[instanceID] = current
                }
                await refresh(instanceID: instanceID, context: context)
            }
        }

        // MARK: - Detail modal and agent runs  @domain: plugin-contributions

        private func openDetail(
            instanceID: String,
            id: String,
            context: BundledPluginContext
        ) async {
            guard var pane = panes[instanceID] else { return }
            pane.openTask = id
            pane.detail = nil
            panes[instanceID] = pane
            await loadAgents(instanceID: instanceID, context: context)
            guard panes[instanceID]?.openTask == id else { return }
            await refresh(instanceID: instanceID, context: context)
            guard var refreshed = panes[instanceID],
                  refreshed.openTask == id
            else { return }
            if refreshed.runs[id]?.exited == false {
                await startTracking(&refreshed, context: context)
                panes[instanceID] = refreshed
            }
        }

        private func startUnnamedAgent(
            instanceID: String,
            task: KanbanBoardFormat.Task,
            context: BundledPluginContext
        ) async {
            await loadAgents(instanceID: instanceID, context: context)
            guard let pane = panes[instanceID] else { return }
            if pane.agents.count == 1, let agent = pane.agents.first {
                await startAgent(instanceID: instanceID, agentID: agent.id, task: task, context: context)
            } else {
                await openDetail(instanceID: instanceID, id: task.id, context: context)
            }
        }

        private func startAgent(
            instanceID: String,
            agentID: String,
            task: KanbanBoardFormat.Task,
            context: BundledPluginContext
        ) async {
            guard let pane = panes[instanceID] else { return }
            let relative = PluginPath.join(
                KanbanPlugin.kanbanDirectory,
                task.path.replacingOccurrences(of: #"^\./"#, with: "", options: .regularExpression)
            )
            let prompt = "Do task \(task.id) described in \(relative). Follow the workflow protocol in CLAUDE.md: claim it on the board before touching a file, and release the claim when you finish."
            let composed = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: KanbanPlugin.agentCommand,
                    input: .object([
                        "agent": .string(agentID),
                        "prompt": .string(prompt),
                    ])
                )
            )
            guard panes[instanceID] != nil else { return }
            guard let command = successValue(composed)?.kanbanObjectValue?["commandLine"]?.kanbanStringValue else {
                if var current = panes[instanceID] {
                    current.writeError = "Start failed: \(failureCode(composed))"
                    panes[instanceID] = current
                }
                await openDetail(instanceID: instanceID, id: task.id, context: context)
                return
            }
            let opened = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: KanbanPlugin.terminalOpen,
                    input: .object([
                        "command": .string(command),
                        "workingDirectory": .string(pane.workspacePath),
                    ])
                )
            )
            guard panes[instanceID] != nil else { return }
            if let paneID = successValue(opened)?.kanbanObjectValue?["paneID"]?.kanbanStringValue {
                var current = panes[instanceID]!
                current.runs[task.id] = Run(paneID: paneID, agent: agentID)
                panes[instanceID] = current
            } else if var current = panes[instanceID] {
                current.writeError = "Start failed: \(failureCode(opened))"
                panes[instanceID] = current
            }
            await openDetail(instanceID: instanceID, id: task.id, context: context)
        }

        private func loadAgents(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            let result = await context.intents.send(
                PluginIntentSendRequest(intentID: KanbanPlugin.agentInventory, input: .object([:]))
            )
            guard var pane = panes[instanceID] else { return }
            if let agents = successValue(result)?.kanbanObjectValue?["agents"]?.kanbanArrayValue {
                pane.agents = agents.compactMap { value in
                    guard let object = value.kanbanObjectValue,
                          let id = object["id"]?.kanbanStringValue
                    else { return nil }
                    return Agent(id: id, label: object["label"]?.kanbanStringValue ?? id)
                }
            } else {
                pane.agents = []
                await context.log("kanban: could not list agents: \(failureCode(result))")
            }
            panes[instanceID] = pane
        }

        private func startTracking(
            _ pane: inout Pane,
            context: BundledPluginContext
        ) async {
            await stopTracking(&pane)
            let instanceID = pane.id
            pane.trackHandle = try? await context.timers.every(
                KanbanPlugin.trackIntervalMilliseconds,
                ownedBy: instanceID
            ) { [weakState = self] in
                if let contribution = await weakState.trackOnce(instanceID: instanceID, context: context) {
                    await context.publishContribution(contribution)
                }
            }
            panes[instanceID] = pane
            if let contribution = await trackOnce(instanceID: instanceID, context: context) {
                await context.publishContribution(contribution)
            }
        }

        private func stopTracking(_ pane: inout Pane) async {
            if let handle = pane.trackHandle {
                await handle.cancel()
                pane.trackHandle = nil
            }
        }

        private func trackOnce(
            instanceID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard let pane = panes[instanceID],
                  let taskID = pane.openTask,
                  var run = pane.runs[taskID],
                  !run.exited
            else {
                if var pane = panes[instanceID] {
                    await stopTracking(&pane)
                    panes[instanceID] = pane
                }
                return contribution()
            }
            guard let uuid = UUID(uuidString: run.paneID) else { return nil }
            let result = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: KanbanPlugin.terminalViewportRead,
                    input: .object([:]),
                    scopeOverride: InvocationScopeOverride(paneID: uuid)
                )
            )
            guard var current = panes[instanceID],
                  current.openTask == taskID,
                  current.runs[taskID]?.paneID == run.paneID
            else { return nil }
            if let value = successValue(result)?.kanbanObjectValue {
                run.tail = KanbanBoardFormat.tail(of: value["text"]?.kanbanStringValue ?? "")
                run.exited = value["exited"]?.kanbanBoolValue == true
                if run.exited {
                    await stopTracking(&current)
                }
            } else {
                run.exited = true
                run.error = failureCode(result)
                await stopTracking(&current)
            }
            current.runs[taskID] = run
            panes[instanceID] = current
            return contribution()
        }

        // MARK: - Watchers and timers  @domain: plugin-host

        private func debouncedRefresh(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            guard var pane = panes[instanceID] else { return }
            if let handle = pane.debounceHandle {
                await handle.cancel()
            }
            pane.debounceHandle = try? await context.timers.after(
                KanbanPlugin.debounceMilliseconds,
                ownedBy: instanceID
            ) { [weakState = self] in
                if let contribution = await weakState.refreshFromTimer(instanceID: instanceID, context: context) {
                    await context.publishContribution(contribution)
                }
            }
            panes[instanceID] = pane
        }

        private func refreshFromTimer(
            instanceID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard var pane = panes[instanceID] else { return nil }
            pane.debounceHandle = nil
            panes[instanceID] = pane
            await refresh(instanceID: instanceID, context: context)
            return contribution()
        }

        private func watchBoard(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            guard var pane = panes[instanceID] else { return }
            let directory = PluginPath.join(pane.workspacePath, KanbanPlugin.kanbanDirectory)
            if pane.watchDir == directory, pane.watch != nil { return }
            if let watch = pane.watch {
                await watch.cancel()
                pane.watch = nil
            }
            pane.watch = await context.fs.watch(
                directory,
                recursive: true,
                ownedBy: instanceID
            ) { [weakState = self] _ in
                await weakState.debouncedRefresh(instanceID: instanceID, context: context)
            }
            pane.watchDir = pane.watch == nil ? "" : directory
            panes[instanceID] = pane
        }

        private func release(
            _ pane: inout Pane,
            context: BundledPluginContext?
        ) async {
            if let watch = pane.watch {
                await watch.cancel()
                pane.watch = nil
            }
            if let debounce = pane.debounceHandle {
                await debounce.cancel()
                pane.debounceHandle = nil
            }
            await stopTracking(&pane)
            pane.watchDir = ""
        }

        private func owningWorkspace(
            _ instanceID: String,
            context: BundledPluginContext
        ) async -> (id: String?, path: String) {
            let result = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: KanbanPlugin.paneOwner,
                    input: .object(["paneID": .string(instanceID)])
                )
            )
            guard let object = successValue(result)?.kanbanObjectValue else {
                return (nil, "")
            }
            return (
                object["workspaceID"]?.kanbanStringValue,
                object["workspacePath"]?.kanbanStringValue ?? ""
            )
        }

        private func modal(for pane: Pane) -> PluginViewModal? {
            guard let openTask = pane.openTask else { return nil }
            let task = task(in: pane, id: openTask)
            let run = pane.runs[openTask].map {
                KanbanBoardView.Run(
                    paneID: $0.paneID,
                    agent: $0.agent,
                    exited: $0.exited,
                    tail: $0.tail,
                    error: $0.error
                )
            }
            return KanbanBoardView.modal(
                task: task,
                detail: pane.detail,
                run: run,
                agents: pane.agents.map { ($0.id, $0.label) }
            )
        }

        private func task(instanceID: String, id: String) -> KanbanBoardFormat.Task? {
            guard let pane = panes[instanceID] else { return nil }
            return task(in: pane, id: id)
        }

        private func task(in pane: Pane, id: String) -> KanbanBoardFormat.Task? {
            for column in pane.columns {
                if let task = column.tasks.first(where: { $0.id == id }) {
                    return task
                }
            }
            return nil
        }

        private enum FileReadResult: Equatable {
            case success(String)
            case missing
            case failure(String)
        }

        private func readFile(
            _ path: String,
            context: BundledPluginContext
        ) async -> FileReadResult {
            for _ in 0 ..< KanbanBoardFormat.maximumReadRestarts {
                var text = ""
                var cursor: String?
                var invalidated = false

                for _ in 0 ..< KanbanBoardFormat.maximumReadPages {
                    var input: [String: IntentValue] = ["path": .string(path)]
                    if let cursor { input["cursor"] = .string(cursor) }
                    let result = await context.intents.send(
                        PluginIntentSendRequest(
                            intentID: KanbanPlugin.fileRead,
                            input: .object(input)
                        )
                    )
                    guard let value = successValue(result)?.kanbanObjectValue else {
                        return readFailure(result)
                    }
                    if value["invalidated"]?.kanbanBoolValue == true {
                        invalidated = true
                        break
                    }
                    guard let content = value["content"]?.kanbanObjectValue,
                          content["kind"]?.kanbanStringValue == "inline"
                    else {
                        return .failure("unexpected-content-shape")
                    }
                    text += content["text"]?.kanbanStringValue ?? ""
                    guard let next = value["cursor"]?.kanbanStringValue else {
                        return .success(text)
                    }
                    cursor = next
                }

                if !invalidated {
                    return .failure("file-larger-than-\(KanbanBoardFormat.maximumReadPages)-pages")
                }
            }
            return .failure("file-kept-changing-mid-read")
        }

        private func readFailure(_ result: IntentResult) -> FileReadResult {
            guard case let .failure(failure) = result else { return .failure("unknown") }
            if failure.error.code.rawValue == "dev.tenon.core.path-not-found" {
                return .missing
            }
            return .failure(
                failure.error.details?.kanbanObjectValue?["reason"]?.kanbanStringValue
                    ?? failure.error.code.rawValue
            )
        }

        private func writeFile(
            path: String,
            text: String,
            context: BundledPluginContext
        ) async -> String? {
            let pages = KanbanBoardFormat.splitWritePages(text)
            guard pages.count <= KanbanBoardFormat.maximumWritePages else {
                return "board-larger-than-\(KanbanBoardFormat.maximumWritePages)-pages"
            }
            if pages.count == 1 {
                let result = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: KanbanPlugin.fileWrite,
                        input: .object([
                            "path": .string(path),
                            "content": .object([
                                "kind": .string("inline"),
                                "text": .string(pages[0]),
                            ]),
                        ])
                    )
                )
                return successValue(result) == nil ? writeFailure(result) : nil
            }

            var cursor: String?
            for (index, page) in pages.enumerated() {
                let last = index == pages.index(before: pages.endIndex)
                var input: [String: IntentValue] = [
                    "path": .string(path),
                    "content": .object([
                        "kind": .string("inline"),
                        "text": .string(page),
                    ]),
                ]
                if let cursor {
                    input["cursor"] = .string(cursor)
                }
                if !last {
                    input["commit"] = .bool(false)
                }
                let result = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: KanbanPlugin.fileWrite,
                        input: .object(input)
                    )
                )
                guard let value = successValue(result) else {
                    return writeFailure(result)
                }
                if last { return nil }
                guard let next = value.kanbanObjectValue?["cursor"]?.kanbanStringValue else {
                    return "staged-write-lost-its-cursor"
                }
                cursor = next
            }
            return nil
        }

        private func writeFailure(_ result: IntentResult) -> String {
            guard case let .failure(failure) = result else { return "unknown" }
            return failure.error.details?.kanbanObjectValue?["reason"]?.kanbanStringValue
                ?? failure.error.code.rawValue
        }

        private func successValue(_ result: IntentResult) -> IntentValue? {
            guard case let .success(success) = result else { return nil }
            return success.value
        }

        private func failureCode(_ result: IntentResult) -> String {
            guard case let .failure(failure) = result else { return "unknown" }
            return failure.error.code.rawValue
        }
    }
}

private extension IntentValue {
    var kanbanObjectValue: [String: IntentValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var kanbanArrayValue: [IntentValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var kanbanStringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var kanbanBoolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}
