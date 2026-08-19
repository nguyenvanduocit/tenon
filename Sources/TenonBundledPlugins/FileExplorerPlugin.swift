// @domain: plugin-host, plugin-contributions
import Foundation
import TenonCore
import TenonIntentCore

/// The compiled file tree. Pane state remains generation-owned and instance-scoped; all file,
/// workspace, terminal, and clipboard effects still cross the manifest-declared intent bus.
enum FileExplorerPlugin {
    static let id: PluginID = "dev.tenon.file-explorer"
    private static let viewID = "tree"
    private static let rootSetting = "rootPath"

    private static let listDirectory = try! IntentID("filesystem.directory.list.v2")
    private static let createDirectory = try! IntentID("filesystem.directory.create.v1")
    private static let createFile = try! IntentID("filesystem.file.create.v1")
    private static let movePath = try! IntentID("filesystem.path.move.v1")
    private static let trashPath = try! IntentID("filesystem.path.trash.v1")
    private static let openFileExternally = try! IntentID("file.open.v1")
    private static let revealFile = try! IntentID("file.reveal.v1")
    private static let writeClipboard = try! IntentID("clipboard.write.v1")
    private static let terminalWrite = try! IntentID("terminal.write.v1")
    private static let workspaceState = try! IntentID("workspace.state.v1")
    private static let paneOwner = try! IntentID("workspace.pane.owner.v1")
    private static let contentOpen = try! IntentID("workspace.content.open.v1")
    private static let paneSplit = try! IntentID("workspace.pane.split.v1")
    private static let paneContentSet = try! IntentID("workspace.pane.content.set.v1")
    private static let agentInventory = try! IntentID("agent.inventory.v1")
    private static let agentCommand = try! IntentID("agent.command.v1")
    private static let terminalOpen = try! IntentID("terminal.open.v1")

    /// FC-FR-037: a directory menu item id carries the chosen agent after this prefix, so
    /// `runMenu` can route it without a second declarative menu vocabulary — `RowMenuItem`
    /// has none, and every installed agent's item is generated at render time.
    private static let openInAgentPrefix = "open-in-agent:"

    private static let open = try! IntentID("dev.tenon.file-explorer.open.v1")
    private static let cdRoot = try! IntentID("dev.tenon.file-explorer.cd-root.v1")
    private static let revealRoot = try! IntentID("dev.tenon.file-explorer.reveal-root.v1")
    private static let refresh = try! IntentID("dev.tenon.file-explorer.refresh.v1")
    private static let collapseAll = try! IntentID("dev.tenon.file-explorer.collapse-all.v1")

    static func makeProgram() -> BundledPluginProgram {
        let state = State()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: [
                "settings.changed",
                "workspace.changed",
                "pane.cwd-changed",
                "workspace.slot-focused",
                "workspace.slot-closed",
            ],
            // T-182: this handler only schedules a debounced recheck (`scheduleWorkspaceOwnershipRecheck`)
            // and never reads the payload, so a burst of firings needs at most one pending.
            coalescableEvents: ["workspace.changed"],
            providedIntents: [open, cdRoot, revealRoot, refresh, collapseAll],
            viewCallbacks: [
                viewID: BundledPluginViewCallbacks(
                    select: { selection, context in
                        try await state.select(selection, context: context)
                    },
                    submit: { submission, context in
                        try await state.submit(submission, context: context)
                    },
                    open: { instanceID, context in
                        try await state.open(instanceID: instanceID, context: context)
                    },
                    close: { instanceID, context in
                        await state.close(instanceID: instanceID)
                        return await state.contribution()
                    }
                ),
            ],
            activate: { _ in
                await state.contribution()
            },
            receiveEvent: { event, payload, context in
                try await state.receiveEvent(event, payload: payload, context: context)
            },
            invokeIntent: { envelope, _, context in
                try await state.invokeIntent(envelope, context: context)
            }
        )
    }

    // MARK: - Instance lifecycle and view callbacks  @domain: plugin-host
    private actor State {
        private struct Draft: Sendable {
            let parent: String
            let isDirectory: Bool
        }

        private struct Pane: Sendable {
            let id: String
            var workspaceID: String?
            var workspacePath = ""
            var root = ""
            var expanded: Set<String> = []
            var selectedPath: String?
            var renaming: String?
            var draft: Draft?
            var directoryPaths: Set<String> = []
            var rows: [TreeRowItem] = []
            var renderGeneration = 0
            var followedRoot = ""
            var focusedSlot: String?
            var lifecycleToken = UUID()
            /// FC-FR-037: read once per pane, not once per render — `render` fires on every
            /// expand, rename, and workspace/cwd churn event, and a churn burst is exactly
            /// where one more intent round trip per render is least affordable.
            var installedAgents: [InstalledAgent] = []
        }

        private var panes: [String: Pane] = [:]
        private var paneRoots: [String: String] = [:]
        /// T-182: debounces `"workspace.changed"` re-verification across every open pane —
        /// not per-instance, since one `"workspace.changed"` firing is already plugin-wide.
        private var workspaceChangeRecheckHandle: BundledPluginTimerHandle?
        private static let workspaceChangeDebounceMilliseconds = 250.0

        func contribution() -> BundledPluginContribution {
            BundledPluginContribution(
                viewRegistrations: [
                    BundledPluginViewRegistration(
                        viewID: FileExplorerPlugin.viewID,
                        title: "Files",
                        instanced: true
                    ),
                ],
                viewBodies: panes.values.sorted { $0.id < $1.id }.map { pane in
                    BundledPluginViewBody(
                        viewID: FileExplorerPlugin.viewID,
                        instanceID: pane.id,
                        items: pane.rows,
                        header: header(for: pane)
                    )
                }
            )
        }

        func open(
            instanceID: String,
            context: BundledPluginContext
        ) async throws -> BundledPluginContribution {
            let pane = Pane(id: instanceID, workspaceID: nil)
            let lifecycleToken = pane.lifecycleToken
            panes[instanceID] = pane
            let owner = await owningWorkspace(instanceID, context: context)
            guard panes[instanceID]?.lifecycleToken == lifecycleToken,
                  var current = panes[instanceID]
            else { return contribution() }
            current.workspaceID = owner.id
            current.workspacePath = owner.path
            current.root = resolveRoot(for: current, context: context)
            current.installedAgents = await installedAgents(context: context)
            guard panes[instanceID]?.lifecycleToken == lifecycleToken else { return contribution() }
            panes[instanceID] = current
            _ = await render(instanceID: instanceID, context: context)
            return contribution()
        }

        func close(instanceID: String) {
            panes.removeValue(forKey: instanceID)
        }

        func select(
            _ selection: BundledPluginViewSelect,
            context: BundledPluginContext
        ) async throws -> BundledPluginContribution? {
            guard let instanceID = selection.instanceID,
                  panes[instanceID] != nil
            else { return nil }

            let itemID = selection.itemID
            if itemID == "reveal-root" {
                let root = panes[instanceID]?.root ?? ""
                let result = await send(
                    FileExplorerPlugin.revealFile,
                    input: .object(["path": .string(root)]),
                    context: context
                )
                await logFailure("reveal \(root)", result, context: context)
                return nil
            }
            if itemID == "draft" { return nil }
            if let action = selection.value?.stringValue {
                try await runMenu(
                    action,
                    instanceID: instanceID,
                    path: itemID,
                    context: context
                )
                return contribution()
            }

            guard var pane = panes[instanceID] else { return nil }
            if pane.directoryPaths.contains(itemID) {
                if pane.expanded.contains(itemID) {
                    pane.expanded.remove(itemID)
                } else {
                    pane.expanded.insert(itemID)
                }
                panes[instanceID] = pane
            } else {
                try await openFile(
                    path: itemID,
                    instanceID: instanceID,
                    forceSplit: false,
                    context: context
                )
                return contribution()
            }
            _ = await render(instanceID: instanceID, context: context)
            return contribution()
        }

        func submit(
            _ submission: BundledPluginViewSubmit,
            context: BundledPluginContext
        ) async throws -> BundledPluginContribution? {
            guard let instanceID = submission.instanceID,
                  var pane = panes[instanceID]
            else { return nil }

            let name = submission.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if submission.itemID == "draft" {
                let pending = pane.draft
                pane.draft = nil
                panes[instanceID] = pane
                if let pending, !name.isEmpty {
                    let target = PluginPath.join(pending.parent, name)
                    let intent = pending.isDirectory
                        ? FileExplorerPlugin.createDirectory
                        : FileExplorerPlugin.createFile
                    let created = await send(
                        intent,
                        input: .object(["path": .string(target)]),
                        context: context
                    )
                    await logFailure("create \(target)", created, context: context)
                    if isSuccess(created), !pending.isDirectory {
                        try await openFile(
                            path: target,
                            instanceID: instanceID,
                            forceSplit: false,
                            context: context
                        )
                        return contribution()
                    }
                }
                _ = await render(instanceID: instanceID, context: context)
                return contribution()
            }

            let path = pane.renaming
            pane.renaming = nil
            panes[instanceID] = pane
            if let path,
               !name.isEmpty,
               name != PluginPath.basename(path)
            {
                let destination = PluginPath.join(PluginPath.dirname(path), name)
                let moved = await send(
                    FileExplorerPlugin.movePath,
                    input: .object([
                        "sourcePath": .string(path),
                        "destinationPath": .string(destination),
                    ]),
                    context: context
                )
                if let movedPath = successValue(moved)?.objectValue?["path"]?.stringValue {
                    guard var updated = panes[instanceID] else { return nil }
                    if updated.expanded.remove(path) != nil {
                        updated.expanded.insert(movedPath)
                    }
                    if updated.selectedPath == path {
                        updated.selectedPath = movedPath
                    }
                    panes[instanceID] = updated
                } else {
                    await logFailure("rename \(path)", moved, context: context)
                }
            }
            _ = await render(instanceID: instanceID, context: context)
            return contribution()
        }

        func receiveEvent(
            _ event: String,
            payload: IntentValue,
            context: BundledPluginContext
        ) async throws -> BundledPluginContribution? {
            switch event {
            case "settings.changed":
                guard payload.objectValue?["key"]?.stringValue == FileExplorerPlugin.rootSetting
                else { return nil }
                for instanceID in Array(panes.keys) {
                    try await retarget(instanceID: instanceID, path: nil, context: context)
                }
            case "workspace.changed":
                // T-182: this event fires on every workspace mutation anywhere in the app, not
                // just ones relevant to a file-explorer pane, and used to re-verify ownership
                // for every open pane on every single firing — an unbroken run of
                // `owningWorkspace` round trips whose combined latency, under a churn burst
                // (several panes open, several mutations in a row), let the callback mailbox
                // outrun its 256-entry cap and fail the whole generation permanently, since a
                // compiled plugin has no hot-reload path to recover. Same debounce shape as
                // `KanbanPlugin.debouncedRefresh`: collapse a burst of firings into one
                // deferred pass instead of one full per-pane pass per event.
                await scheduleWorkspaceOwnershipRecheck(context: context)
            case "pane.cwd-changed":
                guard let fields = payload.objectValue,
                      let slot = fields["slotId"]?.stringValue
                else { return nil }
                let projectRoot = fields["projectRoot"]?.stringValue
                    .flatMap { $0.isEmpty ? nil : $0 }
                if let projectRoot {
                    paneRoots[slot] = projectRoot
                } else {
                    paneRoots.removeValue(forKey: slot)
                }
                for instanceID in Array(panes.keys) {
                    guard panes[instanceID]?.focusedSlot == slot else { continue }
                    var updated = panes[instanceID]!
                    updated.followedRoot = projectRoot ?? ""
                    panes[instanceID] = updated
                    try await retarget(instanceID: instanceID, path: nil, context: context)
                }
            case "workspace.slot-focused":
                guard let fields = payload.objectValue,
                      let slot = fields["slotId"]?.stringValue
                else { return nil }
                let workspaceID = fields["workspaceId"]?.stringValue
                for instanceID in Array(panes.keys) {
                    guard var pane = panes[instanceID] else { continue }
                    if let workspaceID,
                       let paneWorkspaceID = pane.workspaceID,
                       workspaceID != paneWorkspaceID
                    { continue }
                    pane.focusedSlot = slot
                    panes[instanceID] = pane
                    guard let projectRoot = paneRoots[slot] else { continue }
                    pane.followedRoot = projectRoot
                    panes[instanceID] = pane
                    try await retarget(instanceID: instanceID, path: nil, context: context)
                }
            case "workspace.slot-closed":
                if let slot = payload.objectValue?["slotId"]?.stringValue {
                    paneRoots.removeValue(forKey: slot)
                }
            default:
                return nil
            }
            return contribution()
        }

        func invokeIntent(
            _ envelope: IntentEnvelope,
            context: BundledPluginContext
        ) async throws -> IntentProviderReply {
            switch envelope.name {
            case FileExplorerPlugin.open:
                let result = await send(
                    FileExplorerPlugin.contentOpen,
                    input: .object([
                        "content": .object([
                            "kind": .string("plugin"),
                            "pluginID": .string(FileExplorerPlugin.id.rawValue),
                            "viewID": .string(FileExplorerPlugin.viewID),
                        ]),
                    ]),
                    context: context
                )
                guard isSuccess(result) else { throw PluginRuntimeError.providerHandlerUnavailable(envelope.name) }
            case FileExplorerPlugin.cdRoot:
                guard let pane = await commandTarget(context: context) else {
                    return .success(.object([:]))
                }
                let result = await send(
                    FileExplorerPlugin.terminalWrite,
                    input: .object(["text": .string(shellPath(pane.root) + "\n")]),
                    context: context
                )
                guard isSuccess(result) else { throw PluginRuntimeError.providerHandlerUnavailable(envelope.name) }
            case FileExplorerPlugin.revealRoot:
                guard let pane = await commandTarget(context: context) else {
                    return .success(.object([:]))
                }
                let result = await send(
                    FileExplorerPlugin.revealFile,
                    input: .object(["path": .string(pane.root)]),
                    context: context
                )
                guard isSuccess(result) else { throw PluginRuntimeError.providerHandlerUnavailable(envelope.name) }
            case FileExplorerPlugin.refresh:
                for instanceID in Array(panes.keys) {
                    guard var pane = panes[instanceID] else { continue }
                    pane.installedAgents = await installedAgents(context: context)
                    panes[instanceID] = pane
                    _ = await render(instanceID: instanceID, context: context)
                }
            case FileExplorerPlugin.collapseAll:
                for instanceID in Array(panes.keys) {
                    guard var pane = panes[instanceID] else { continue }
                    pane.expanded.removeAll()
                    panes[instanceID] = pane
                    _ = await render(instanceID: instanceID, context: context)
                }
            default:
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
            await context.publishContribution(contribution())
            return .success(.object([:]))
        }

        private func runMenu(
            _ action: String,
            instanceID: String,
            path: String,
            context: BundledPluginContext
        ) async throws {
            switch action {
            case "open":
                try await openFile(path: path, instanceID: instanceID, forceSplit: false, context: context)
            case "open-side":
                try await openFile(path: path, instanceID: instanceID, forceSplit: true, context: context)
            case "open-external":
                let result = await send(FileExplorerPlugin.openFileExternally, input: .object(["path": .string(path)]), context: context)
                await logFailure("open externally \(path)", result, context: context)
            case "reveal":
                let result = await send(FileExplorerPlugin.revealFile, input: .object(["path": .string(path)]), context: context)
                await logFailure("reveal \(path)", result, context: context)
            case "copy-path":
                let result = await send(FileExplorerPlugin.writeClipboard, input: .object(["text": .string(path)]), context: context)
                await logFailure("copy path", result, context: context)
            case "cd":
                let result = await send(FileExplorerPlugin.terminalWrite, input: .object(["text": .string(shellPath(path) + "\n")]), context: context)
                await logFailure("cd \(path)", result, context: context)
            case "new-file", "new-folder":
                guard var pane = panes[instanceID] else { return }
                pane.renaming = nil
                pane.draft = Draft(parent: path, isDirectory: action == "new-folder")
                pane.expanded.insert(path)
                panes[instanceID] = pane
                _ = await render(instanceID: instanceID, context: context)
            case "rename":
                guard var pane = panes[instanceID] else { return }
                pane.draft = nil
                pane.renaming = path
                panes[instanceID] = pane
                _ = await render(instanceID: instanceID, context: context)
            case "trash":
                let result = await send(FileExplorerPlugin.trashPath, input: .object(["path": .string(path)]), context: context)
                if isSuccess(result) {
                    guard var pane = panes[instanceID] else { return }
                    pane.expanded.remove(path)
                    if pane.selectedPath == path { pane.selectedPath = nil }
                    panes[instanceID] = pane
                } else {
                    await logFailure("trash \(path)", result, context: context)
                }
                _ = await render(instanceID: instanceID, context: context)
            case let action where action.hasPrefix(FileExplorerPlugin.openInAgentPrefix):
                await openInAgent(
                    agentID: String(action.dropFirst(FileExplorerPlugin.openInAgentPrefix.count)),
                    directory: path,
                    context: context
                )
            default:
                await context.log("file-explorer: unknown menu action \(action)")
            }
        }

        private func openFile(
            path: String,
            instanceID: String,
            forceSplit: Bool,
            context: BundledPluginContext
        ) async throws {
            guard var pane = panes[instanceID] else { return }
            pane.selectedPath = path
            panes[instanceID] = pane
            var result: IntentResult
            if forceSplit {
                result = await send(
                    FileExplorerPlugin.paneSplit,
                    input: .object(["axis": .string("horizontal")]),
                    context: context
                )
                if isSuccess(result) {
                    result = await send(
                        FileExplorerPlugin.paneContentSet,
                        input: .object([
                            "content": .object(["kind": .string("file"), "path": .string(path)]),
                        ]),
                        context: context
                    )
                }
            } else {
                result = await send(
                    FileExplorerPlugin.contentOpen,
                    input: .object([
                        "content": .object(["kind": .string("file"), "path": .string(path)]),
                    ]),
                    context: context
                )
            }
            if !isSuccess(result) {
                await logFailure("open \(path)", result, context: context)
            }
            _ = await render(instanceID: instanceID, context: context)
        }

        /// T-182: collapses a burst of `"workspace.changed"` firings into one deferred pass,
        /// same shape as `KanbanPlugin.debouncedRefresh`. A pending timer already covers the
        /// next firing, so rescheduling per event (rather than a fresh timer per firing) is
        /// exactly what keeps a churn burst from costing more than one pass.
        private func scheduleWorkspaceOwnershipRecheck(
            context: BundledPluginContext
        ) async {
            guard workspaceChangeRecheckHandle == nil else { return }
            workspaceChangeRecheckHandle = try? await context.timers.after(
                Self.workspaceChangeDebounceMilliseconds
            ) { [weak self] in
                guard let self else { return }
                await self.recheckWorkspaceOwnership(context: context)
            }
        }

        /// Re-verifies every open pane's owning workspace in one pass, fanning the
        /// independent `owningWorkspace` reads out concurrently rather than one-at-a-time —
        /// a debounced pass still touches every pane, so it should not itself be slow.
        private func recheckWorkspaceOwnership(context: BundledPluginContext) async {
            workspaceChangeRecheckHandle = nil
            let instanceIDs = Array(panes.keys)
            let owners = await withTaskGroup(
                of: (String, (id: String?, path: String)).self
            ) { group in
                for instanceID in instanceIDs {
                    group.addTask {
                        (instanceID, await self.owningWorkspace(instanceID, context: context))
                    }
                }
                var results: [String: (id: String?, path: String)] = [:]
                for await (instanceID, owner) in group {
                    results[instanceID] = owner
                }
                return results
            }
            for instanceID in instanceIDs {
                guard let current = panes[instanceID], let owner = owners[instanceID]
                else { continue }
                guard owner.id != nil,
                      owner.id != current.workspaceID || owner.path != current.workspacePath
                else { continue }
                var updated = current
                updated.workspaceID = owner.id
                updated.workspacePath = owner.path
                updated.followedRoot = ""
                updated.focusedSlot = nil
                panes[instanceID] = updated
                try? await retarget(instanceID: instanceID, path: nil, context: context)
            }
            await context.publishContribution(contribution())
        }

        private func retarget(
            instanceID: String,
            path: String?,
            context: BundledPluginContext
        ) async throws {
            guard var pane = panes[instanceID] else { return }
            let nextRoot = path ?? resolveRoot(for: pane, context: context)
            guard nextRoot != pane.root else { return }
            pane.root = nextRoot
            pane.expanded.removeAll()
            pane.selectedPath = nil
            pane.renaming = nil
            pane.draft = nil
            panes[instanceID] = pane
            _ = await render(instanceID: instanceID, context: context)
        }

        private func render(
            instanceID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard var pane = panes[instanceID], !pane.root.isEmpty else { return nil }
            pane.renderGeneration &+= 1
            let generation = pane.renderGeneration
            pane.directoryPaths.removeAll()
            let agents = pane.installedAgents
            panes[instanceID] = pane
            guard let built = await appendRows(
                instanceID: instanceID,
                directory: pane.root,
                depth: 0,
                generation: generation,
                agents: agents,
                context: context
            ) else { return nil }
            guard var current = panes[instanceID], current.renderGeneration == generation else {
                return nil
            }
            current.directoryPaths = built.directories
            current.rows = built.rows
            panes[instanceID] = current
            return contribution()
        }

        private func appendRows(
            instanceID: String,
            directory: String,
            depth: Int,
            generation: Int,
            agents: [InstalledAgent],
            context: BundledPluginContext
        ) async -> (rows: [TreeRowItem], directories: Set<String>)? {
            guard let pane = panes[instanceID], pane.renderGeneration == generation else { return nil }
            var rows: [TreeRowItem] = []
            var directories: Set<String> = [directory]
            if let draft = pane.draft, draft.parent == directory {
                rows.append(
                    TreeRowItem(
                        id: "draft",
                        label: "",
                        depth: depth,
                        icon: draft.isDirectory ? "folder.fill" : "doc.text",
                        editing: true,
                        placeholder: draft.isDirectory ? "Folder name" : "File name"
                    )
                )
            }
            guard let entries = await listEntries(directory, context: context),
                  let current = panes[instanceID], current.renderGeneration == generation
            else { return nil }

            let ordered = FileExplorerTree.orderedEntries(
                entries.map { FileExplorerTree.Entry(name: $0.name, isDirectory: $0.isDirectory) }
            )
            for entry in ordered {
                let path = PluginPath.join(directory, entry.name)
                if entry.isDirectory { directories.insert(path) }
                let menu = entry.isDirectory ? directoryMenu(agents: agents) : fileMenu
                rows.append(
                    FileExplorerTree.row(
                        for: entry,
                        path: path,
                        depth: depth,
                        expanded: current.expanded.contains(path),
                        menu: menu,
                        editing: current.renaming == path,
                        selected: !entry.isDirectory && current.selectedPath == path
                    )
                )
                if entry.isDirectory, current.expanded.contains(path) {
                    guard let nested = await appendRows(
                        instanceID: instanceID,
                        directory: path,
                        depth: depth + 1,
                        generation: generation,
                        agents: agents,
                        context: context
                    ) else { return nil }
                    rows.append(contentsOf: nested.rows)
                    directories.formUnion(nested.directories)
                }
            }
            return (rows, directories)
        }

        private func listEntries(
            _ path: String,
            context: BundledPluginContext
        ) async -> [FileExplorerTree.Entry]? {
            var entries: [FileExplorerTree.Entry] = []
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                if let cursor, !seenCursors.insert(cursor).inserted {
                    await context.log("file-explorer: list \(path) failed: cursor cycle")
                    return nil
                }
                var input: [String: IntentValue] = [
                    "path": .string(path),
                    "limit": .integer(256),
                ]
                if let cursor { input["cursor"] = .string(cursor) }
                let result = await send(
                    FileExplorerPlugin.listDirectory,
                    input: .object(input),
                    context: context
                )
                guard let value = successValue(result)?.objectValue else {
                    await logFailure("list \(path)", result, context: context)
                    return nil
                }
                if let page = value["entries"]?.arrayValue {
                    entries.append(contentsOf: page.compactMap { item in
                        guard let fields = item.objectValue,
                              let name = fields["name"]?.stringValue
                        else { return nil }
                        return FileExplorerTree.Entry(
                            name: name,
                            isDirectory: fields["isDirectory"]?.boolValue == true
                        )
                    })
                }
                cursor = value["nextCursor"]?.stringValue
            } while cursor != nil
            return entries
        }

        private func commandTarget(
            context: BundledPluginContext
        ) async -> Pane? {
            var cursor: String?
            var selectedWorkspace: String?
            for _ in 0 ..< 16 where selectedWorkspace == nil {
                var input: [String: IntentValue] = ["limit": .integer(256)]
                if let cursor { input["cursor"] = .string(cursor) }
                let result = await send(
                    FileExplorerPlugin.workspaceState,
                    input: .object(input),
                    context: context
                )
                guard let value = successValue(result)?.objectValue else { break }
                for node in value["nodes"]?.arrayValue ?? [] {
                    guard let fields = node.objectValue,
                          fields["kind"]?.stringValue == "workspace",
                          fields["selected"]?.boolValue == true
                    else { continue }
                    selectedWorkspace = fields["id"]?.stringValue
                    break
                }
                cursor = value["nextCursor"]?.stringValue
                if cursor == nil { break }
            }
            if let selectedWorkspace,
               let pane = panes.values.first(where: { $0.workspaceID == selectedWorkspace })
            { return pane }
            return panes.values.first
        }

        private func owningWorkspace(
            _ instanceID: String,
            context: BundledPluginContext
        ) async -> (id: String?, path: String) {
            let result = await send(
                FileExplorerPlugin.paneOwner,
                input: .object(["paneID": .string(instanceID)]),
                context: context
            )
            guard let fields = successValue(result)?.objectValue else {
                return (nil, "")
            }
            return (
                fields["workspaceID"]?.stringValue,
                fields["workspacePath"]?.stringValue ?? ""
            )
        }

        private func resolveRoot(
            for pane: Pane,
            context: BundledPluginContext
        ) -> String {
            let configured = context.setting(FileExplorerPlugin.rootSetting)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return configured.isEmpty
                ? (pane.followedRoot.isEmpty ? (pane.workspacePath.isEmpty ? "~" : pane.workspacePath) : pane.followedRoot)
                : configured
        }

        private func send(
            _ intentID: IntentID,
            input: IntentValue,
            context: BundledPluginContext
        ) async -> IntentResult {
            await context.intents.send(
                PluginIntentSendRequest(intentID: intentID, input: input)
            )
        }

        private func logFailure(
            _ operation: String,
            _ result: IntentResult,
            context: BundledPluginContext
        ) async {
            guard case let .failure(failure) = result else { return }
            await context.log(
                "file-explorer: \(operation) failed: \(failure.error.code.rawValue)"
            )
        }

        private func successValue(_ result: IntentResult) -> IntentValue? {
            guard case let .success(success) = result else { return nil }
            return success.value
        }

        private func isSuccess(_ result: IntentResult) -> Bool {
            if case .success = result { return true }
            return false
        }

        private func shellPath(_ path: String) -> String {
            path == "~" ? "~" : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private func header(for pane: Pane) -> PaneHeader {
            PaneHeader(
                leading: [
                    .label(
                        id: "root",
                        text: pane.root,
                        weight: .regular,
                        color: .muted,
                        truncation: .head,
                        tooltip: nil
                    ),
                ],
                trailing: [
                    .iconButton(
                        id: "reveal-root",
                        systemName: "arrow.up.forward.app",
                        tint: .default,
                        isEnabled: true,
                        tooltip: "Reveal in Finder",
                        accessibilityID: nil
                    ),
                ]
            )
        }

        private var fileMenu: [RowMenuItem] {
            [
                RowMenuItem(id: "open", label: "Open"),
                RowMenuItem(id: "open-side", label: "Open to the Side"),
                RowMenuItem(id: "open-external", label: "Open in Default App", separatorBefore: true),
                RowMenuItem(id: "reveal", label: "Reveal in Finder"),
                RowMenuItem(id: "copy-path", label: "Copy Path"),
                RowMenuItem(id: "rename", label: "Rename", separatorBefore: true),
                RowMenuItem(id: "trash", label: "Move to Trash", destructive: true),
            ]
        }

        /// FC-FR-037: one item per agent `agent.inventory.v1` reports installed — the same
        /// list the Launcher already offers — so a machine with none simply omits the group
        /// rather than showing a disabled or empty entry.
        private func directoryMenu(agents: [InstalledAgent]) -> [RowMenuItem] {
            var items: [RowMenuItem] = [
                RowMenuItem(id: "open-external", label: "Open in Default App"),
                RowMenuItem(id: "reveal", label: "Reveal in Finder"),
                RowMenuItem(id: "copy-path", label: "Copy Path"),
                RowMenuItem(id: "cd", label: "cd Here", separatorBefore: true),
            ]
            for (index, agent) in agents.enumerated() {
                items.append(
                    RowMenuItem(
                        id: FileExplorerPlugin.openInAgentPrefix + agent.id,
                        label: "Open in \(agent.label)",
                        separatorBefore: index == 0
                    )
                )
            }
            items.append(contentsOf: [
                RowMenuItem(id: "new-file", label: "New File…", separatorBefore: true),
                RowMenuItem(id: "new-folder", label: "New Folder…"),
                RowMenuItem(id: "rename", label: "Rename", separatorBefore: true),
                RowMenuItem(id: "trash", label: "Move to Trash", destructive: true),
            ])
            return items
        }

        /// One agent `agent.inventory.v1` reports installed, carrying only what the menu
        /// needs to label and route it — never an executable path or shell history.
        private struct InstalledAgent: Sendable {
            let id: String
            let label: String
        }

        private func installedAgents(context: BundledPluginContext) async -> [InstalledAgent] {
            let result = await send(
                FileExplorerPlugin.agentInventory,
                input: .object([:]),
                context: context
            )
            guard let list = successValue(result)?.objectValue?["agents"]?.arrayValue else {
                return []
            }
            return list.compactMap { item in
                guard let object = item.objectValue,
                      let id = object["id"]?.stringValue,
                      let label = object["label"]?.stringValue
                else { return nil }
                return InstalledAgent(id: id, label: label)
            }
        }

        /// FC-FR-037: compose the chosen agent's command line only through `agent.command.v1`
        /// (invariant 9 — a plugin never assembles one itself) and open it with
        /// `terminal.open.v1` at this folder. A composition failure never opens a pane.
        private func openInAgent(
            agentID: String,
            directory: String,
            context: BundledPluginContext
        ) async {
            let composed = await send(
                FileExplorerPlugin.agentCommand,
                input: .object(["agent": .string(agentID)]),
                context: context
            )
            guard let commandLine = successValue(composed)?.objectValue?["commandLine"]?.stringValue else {
                await logFailure("compose agent \(agentID)", composed, context: context)
                return
            }
            let opened = await send(
                FileExplorerPlugin.terminalOpen,
                input: .object([
                    "workingDirectory": .string(directory),
                    "command": .string(commandLine),
                ]),
                context: context
            )
            await logFailure("open agent \(agentID) at \(directory)", opened, context: context)
        }
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

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}
