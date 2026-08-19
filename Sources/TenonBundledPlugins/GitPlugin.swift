// @domain: plugin-host, plugin-contributions, repository-read
import Foundation
import TenonCore
import TenonIntentCore

/// Compiled Swift port of the shipped git panel. It stays a manifest-backed plugin: every
/// repository read or mutation still crosses the same declared intent boundary the JavaScript
/// implementation used, and the host still receives only CONTRIBUTION values.
enum GitPlugin {
    static let id: PluginID = "dev.tenon.git"
    static let viewID = "git"

    private static let refreshIntent = try! IntentID("dev.tenon.git.refresh.v1")
    private static let switchBranchIntent = try! IntentID("dev.tenon.git.switch-branch.v1")
    private static let fetchIntent = try! IntentID("dev.tenon.git.fetch.v1")
    private static let pullIntent = try! IntentID("dev.tenon.git.pull.v1")
    private static let pushIntent = try! IntentID("dev.tenon.git.push.v1")
    private static let stageAllIntent = try! IntentID("dev.tenon.git.stage-all.v1")

    fileprivate static let processExec = try! IntentID("process.exec.v1")
    fileprivate static let workspaceState = try! IntentID("workspace.state.v1")
    fileprivate static let paneOwner = try! IntentID("workspace.pane.owner.v1")
    fileprivate static let contentOpen = try! IntentID("workspace.content.open.v1")
    fileprivate static let uiPick = try! IntentID("ui.pick.v1")
    fileprivate static let uiPrompt = try! IntentID("ui.prompt.v1")
    fileprivate static let uiConfirm = try! IntentID("ui.confirm.v1")
    fileprivate static let uiToast = try! IntentID("ui.toast.v1")

    static func makeProgram() -> BundledPluginProgram {
        let state = State()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: [
                "settings.changed",
                "workspace.selected",
                "workspace.changed",
                "pane.cwd-changed",
                "workspace.slot-focused",
                "workspace.slot-closed",
            ],
            // T-182: `"workspace.changed"` only triggers an ownership recheck here and never
            // reads the payload, so a burst of firings needs at most one pending.
            coalescableEvents: ["workspace.changed"],
            providedIntents: [
                refreshIntent,
                switchBranchIntent,
                fetchIntent,
                pullIntent,
                pushIntent,
                stageAllIntent,
            ],
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

    struct Pane: Sendable {
        let id: String
        var workspaceID: String?
        var workspacePath = ""
        var repoPath: String?
        var model = GitStatusModel.empty
        var commitMessage = ""
        var followedRepo = ""
        var focusedSlot: String?
        var watchedRepo: String?
        var watch: BundledPluginWatchHandle?
        var debounce: BundledPluginTimerHandle?
        var lifecycleToken = UUID()
    }

    // MARK: - Generation state  @domain: plugin-host

    private actor State {
        private var panes: [String: Pane] = [:]
        private var bar = Pane(id: "")
        private var paneRoots: [String: String] = [:]
        private var pollTimer: BundledPluginTimerHandle?

        func activate(context: BundledPluginContext) async -> BundledPluginContribution {
            await ensurePollTimer(context: context)
            await refreshBar(context: context)
            return contribution()
        }

        func open(
            instanceID: String,
            context: BundledPluginContext
        ) async -> BundledPluginContribution {
            var pane = Pane(id: instanceID)
            let token = pane.lifecycleToken
            panes[instanceID] = pane
            let owner = await owningWorkspace(
                instanceID: instanceID,
                client: .plugin(context)
            )
            guard panes[instanceID]?.lifecycleToken == token,
                  panes[instanceID] != nil
            else { return contribution() }
            pane.workspaceID = owner.id
            pane.workspacePath = owner.path
            panes[instanceID] = pane
            await refreshPane(instanceID, context: context)
            await watchRepo(instanceID: instanceID, context: context)
            await ensurePollTimer(context: context)
            return contribution()
        }

        func close(instanceID: String) async -> BundledPluginContribution? {
            guard var pane = panes.removeValue(forKey: instanceID) else { return nil }
            if let watch = pane.watch { await watch.cancel() }
            if let debounce = pane.debounce { await debounce.cancel() }
            pane.watch = nil
            pane.debounce = nil
            return contribution()
        }

        func select(
            _ selection: BundledPluginViewSelect,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard let instanceID = selection.instanceID,
                  panes[instanceID] != nil
            else { return nil }

            if selection.action == "refresh" {
                await refreshPane(instanceID, context: context)
                return contribution()
            }

            guard case let .structured(value) = selection.action,
                  let action = objectValue(value),
                  let verb = stringValue(action["do"])
            else { return nil }

            let path = stringValue(action["path"]) ?? ""
            switch verb {
            case "open":
                await openDiff(
                    instanceID: instanceID,
                    section: stringValue(action["section"]) ?? "",
                    path: path,
                    context: context
                )
                return nil
            case "stage":
                await op(instanceID: instanceID, args: ["add", "--", path], label: "Stage", context: context)
            case "unstage":
                let hasHead = panes[instanceID]?.model.hasHead ?? true
                let args = hasHead
                    ? ["restore", "--staged", "--", path]
                    : ["rm", "--cached", "--", path]
                await op(instanceID: instanceID, args: args, label: "Unstage", context: context)
            case "discard":
                await discard(instanceID: instanceID, path: path, context: context)
            case "stageAll":
                await op(instanceID: instanceID, args: ["add", "-A"], label: "Stage all", context: context)
            case "unstageAll":
                let hasHead = panes[instanceID]?.model.hasHead ?? true
                let args = hasHead
                    ? ["restore", "--staged", "--", "."]
                    : ["rm", "--cached", "-r", "--", "."]
                await op(instanceID: instanceID, args: args, label: "Unstage all", context: context)
            case "discardAll":
                await discardAll(instanceID: instanceID, context: context)
            case "commit":
                await commit(instanceID: instanceID, includeAll: false, context: context)
            case "commitAll":
                await commit(instanceID: instanceID, includeAll: true, context: context)
            case "commitMsg":
                panes[instanceID]?.commitMessage = stringValue(selection.value) ?? ""
            case "switchBranch":
                await switchBranch(instanceID: instanceID, client: .plugin(context), context: context)
            case "fetch":
                await op(instanceID: instanceID, args: ["fetch", "--all", "--prune"], label: "Fetch", context: context)
            case "pull":
                await op(instanceID: instanceID, args: ["pull", "--ff-only"], label: "Pull", context: context)
            case "push":
                await op(instanceID: instanceID, args: ["push"], label: "Push", context: context)
            case "stash":
                await op(instanceID: instanceID, args: ["stash", "push", "--include-untracked"], label: "Stash", context: context)
            case "stashPop":
                await op(instanceID: instanceID, args: ["stash", "pop"], label: "Pop stash", context: context)
            case "newBranch":
                let name = (stringValue(selection.value) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    await op(instanceID: instanceID, args: ["switch", "-c", name], label: "Create branch \(name)", context: context)
                }
            default:
                return nil
            }
            return contribution()
        }

        func receiveEvent(
            _ event: String,
            payload: IntentValue,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            await ensurePollTimer(context: context)
            switch event {
            case "settings.changed":
                guard stringValue(objectValue(payload)?["key"]) == "repoPath" else {
                    return nil
                }
                bar.repoPath = nil
                await refreshBar(context: context)
                for id in panes.keys.sorted() {
                    panes[id]?.repoPath = nil
                    await refreshPane(id, context: context)
                    await watchRepo(instanceID: id, context: context)
                }
            case "workspace.selected":
                bar.repoPath = nil
                bar.followedRepo = ""
                bar.focusedSlot = nil
                await refreshBar(context: context)
            case "workspace.changed":
                for id in panes.keys.sorted() {
                    let owner = await owningWorkspace(
                        instanceID: id,
                        client: .plugin(context)
                    )
                    guard owner.id != nil,
                          var pane = panes[id],
                          owner.id != pane.workspaceID || owner.path != pane.workspacePath
                    else { continue }
                    pane.workspaceID = owner.id
                    pane.workspacePath = owner.path
                    pane.repoPath = nil
                    pane.followedRepo = ""
                    pane.focusedSlot = nil
                    panes[id] = pane
                    await refreshPane(id, context: context)
                    await watchRepo(instanceID: id, context: context)
                }
            case "pane.cwd-changed":
                let object = objectValue(payload)
                guard let slot = stringValue(object?["slotId"]) else { return nil }
                let root = stringValue(object?["projectRoot"]) ?? ""
                if root.isEmpty { paneRoots.removeValue(forKey: slot) }
                else { paneRoots[slot] = root }
                if bar.focusedSlot == slot {
                    await followRepo(.bar, root: root, context: context)
                }
                for id in panes.keys.sorted()
                    where panes[id]?.focusedSlot == slot
                {
                    await followRepo(.pane(id), root: root, context: context)
                }
            case "workspace.slot-focused":
                let object = objectValue(payload)
                guard let slot = stringValue(object?["slotId"]) else { return nil }
                bar.focusedSlot = slot
                if let root = paneRoots[slot] {
                    await followRepo(.bar, root: root, context: context)
                }
                for id in panes.keys.sorted() {
                    guard var pane = panes[id] else { continue }
                    if let workspaceID = stringValue(object?["workspaceId"]),
                       let paneWorkspace = pane.workspaceID,
                       workspaceID != paneWorkspace {
                        continue
                    }
                    pane.focusedSlot = slot
                    panes[id] = pane
                    if let root = paneRoots[slot] {
                        await followRepo(.pane(id), root: root, context: context)
                    }
                }
            case "workspace.slot-closed":
                if let slot = stringValue(objectValue(payload)?["slotId"]) {
                    paneRoots.removeValue(forKey: slot)
                }
            default:
                return nil
            }
            return contribution()
        }

        func invokeIntent(
            _ envelope: IntentEnvelope,
            providerContext: IntentProviderContext,
            context: BundledPluginContext
        ) async throws -> IntentProviderReply {
            await ensurePollTimer(context: context)
            let client = GitIntentClient.provider(
                providerContext,
                pluginContext: context
            )
            let target = await commandTarget(client: client)
            if envelope.name == GitPlugin.refreshIntent {
                await refresh(target, client: client)
                if target != .bar { await refresh(.bar, client: client) }
            } else if envelope.name == GitPlugin.switchBranchIntent {
                switch target {
                case .bar:
                    await switchBranchForBar(client: client, context: context)
                case let .pane(id):
                    await switchBranch(instanceID: id, client: client, context: context)
                }
            } else if envelope.name == GitPlugin.fetchIntent {
                await op(target: target, args: ["fetch", "--all", "--prune"], label: "Fetch", client: client)
            } else if envelope.name == GitPlugin.pullIntent {
                await op(target: target, args: ["pull", "--ff-only"], label: "Pull", client: client)
            } else if envelope.name == GitPlugin.pushIntent {
                await op(target: target, args: ["push"], label: "Push", client: client)
            } else if envelope.name == GitPlugin.stageAllIntent {
                await op(target: target, args: ["add", "-A"], label: "Stage all", client: client)
            } else {
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
            await context.publishContribution(contribution())
            return .success(.object([:]))
        }

        // MARK: - Repository reads  @domain: repository-read

        private func refreshPane(
            _ instanceID: String,
            context: BundledPluginContext
        ) async {
            await refresh(.pane(instanceID), client: .plugin(context))
        }

        private func refreshBar(context: BundledPluginContext) async {
            await refresh(.bar, client: .plugin(context))
        }

        private func refresh(
            _ target: Target,
            client: GitIntentClient
        ) async {
            guard let repo = await resolveRepo(target, client: client),
                  !repo.isEmpty
            else {
                setModel(.empty, for: target)
                return
            }
            let status = await git(
                target,
                args: [
                    "status",
                    "--porcelain=v2",
                    "--branch",
                    "-z",
                    "--untracked-files=all",
                ],
                client: client
            )
            guard status.ok, status.status == 0 else {
                setModel(.empty, for: target)
                return
            }
            var next = GitStatusParser.parseStatus(status.stdout)
            let log = await git(
                target,
                args: ["log", "-n", "5", "--pretty=%h\(GitStatusParser.logSeparator)%s"],
                client: client
            )
            if log.ok, log.status == 0 {
                next.recent = GitStatusParser.parseLog(log.stdout)
            }
            setModel(next, for: target)
        }

        private func git(
            _ target: Target,
            args: [String],
            client: GitIntentClient
        ) async -> GitProcessResult {
            guard let repo = await resolveRepo(target, client: client),
                  !repo.isEmpty
            else {
                return GitProcessResult(
                    ok: false,
                    status: 1,
                    stdout: "",
                    stderr: "no repository",
                    error: nil
                )
            }
            return await exec(
                command: "/usr/bin/git",
                arguments: args,
                workingDirectory: repo,
                client: client
            )
        }

        private func exec(
            command: String,
            arguments: [String],
            workingDirectory: String,
            client: GitIntentClient
        ) async -> GitProcessResult {
            let result = await client.send(
                GitPlugin.processExec,
                .object([
                    "command": .string(command),
                    "arguments": .array(arguments.map(IntentValue.string)),
                    "workingDirectory": .string(workingDirectory.isEmpty ? "/" : workingDirectory),
                ])
            )
            switch result {
            case let .success(success):
                let value = objectValue(success.value)
                return GitProcessResult(
                    ok: true,
                    status: integerValue(value?["exitCode"]).map(Int.init) ?? 0,
                    stdout: inlineText(value?["standardOutput"]),
                    stderr: inlineText(value?["standardError"]),
                    error: nil
                )
            case let .failure(failure):
                return GitProcessResult(
                    ok: false,
                    status: -1,
                    stdout: "",
                    stderr: "",
                    error: failure.error.code.rawValue
                )
            }
        }

        private func resolveRepo(
            _ target: Target,
            client: GitIntentClient
        ) async -> String? {
            if let explicit = settingRepo(client.context) {
                setRepo(explicit, for: target)
                return explicit
            }
            if let followed = followedRepo(for: target), !followed.isEmpty {
                setRepo(followed, for: target)
                return followed
            }
            if let existing = repoPath(for: target), !existing.isEmpty {
                return existing
            }
            let base: String
            switch target {
            case .bar:
                base = await workspacePath(client: client)
            case let .pane(id):
                base = panes[id]?.workspacePath ?? ""
            }
            let root = await exec(
                command: "/usr/bin/git",
                arguments: ["rev-parse", "--show-toplevel"],
                workingDirectory: base.isEmpty ? "/" : base,
                client: client
            )
            if let explicit = settingRepo(client.context) {
                setRepo(explicit, for: target)
                return explicit
            }
            if root.ok, root.status == 0 {
                let path = root.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                setRepo(path, for: target)
                return path
            }
            return repoPath(for: target)
        }

        private func selectedWorkspace(
            client: GitIntentClient
        ) async -> WorkspaceNode? {
            var first: WorkspaceNode?
            var cursor: String?
            for _ in 0 ..< 16 {
                var input: [String: IntentValue] = ["limit": .integer(256)]
                if let cursor { input["cursor"] = .string(cursor) }
                let result = await client.send(GitPlugin.workspaceState, .object(input))
                guard case let .success(success) = result,
                      let object = objectValue(success.value)
                else { return nil }
                let nodes = arrayValue(object["nodes"]) ?? []
                for node in nodes {
                    guard let object = objectValue(node),
                          stringValue(object["kind"]) == "workspace"
                    else { continue }
                    let workspace = WorkspaceNode(
                        id: stringValue(object["id"]),
                        path: stringValue(object["path"]) ?? "",
                        selected: boolValue(object["selected"]) ?? false
                    )
                    if workspace.selected { return workspace }
                    if first == nil { first = workspace }
                }
                cursor = stringValue(object["nextCursor"])
                if cursor == nil { break }
            }
            return first
        }

        private func workspacePath(client: GitIntentClient) async -> String {
            await selectedWorkspace(client: client)?.path ?? ""
        }

        private func owningWorkspace(
            instanceID: String,
            client: GitIntentClient
        ) async -> WorkspaceOwner {
            let result = await client.send(
                GitPlugin.paneOwner,
                .object(["paneID": .string(instanceID)])
            )
            guard case let .success(success) = result,
                  let object = objectValue(success.value)
            else { return WorkspaceOwner(id: nil, path: "") }
            return WorkspaceOwner(
                id: stringValue(object["workspaceID"]),
                path: stringValue(object["workspacePath"]) ?? ""
            )
        }

        // MARK: - Git operations  @domain: plugin-host

        private func op(
            instanceID: String,
            args: [String],
            label: String,
            context: BundledPluginContext
        ) async {
            await op(
                target: .pane(instanceID),
                args: args,
                label: label,
                client: .plugin(context)
            )
            await refreshBar(context: context)
        }

        private func op(
            target: Target,
            args: [String],
            label: String,
            client: GitIntentClient
        ) async {
            let result = await git(target, args: args, client: client)
            if !result.ok || result.status != 0 {
                let detail = firstLine(result.stderr.isEmpty ? result.error ?? "" : result.stderr)
                _ = await client.send(
                    GitPlugin.uiToast,
                    .object([
                        "message": .string("\(label) failed\(detail.isEmpty ? "" : ": \(detail)")"),
                        "kind": .string("error"),
                    ])
                )
            }
            await refresh(target, client: client)
            if target != .bar { await refresh(.bar, client: client) }
        }

        private func openDiff(
            instanceID: String,
            section: String,
            path: String,
            context: BundledPluginContext
        ) async {
            guard let pane = panes[instanceID] else { return }
            let entry = findEntry(in: pane, section: section, path: path)
            let untracked = entry.map { $0.staged == "?" || $0.unstaged == "?" } ?? false
            let result = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: GitPlugin.contentOpen,
                    input: .object([
                        "content": .object([
                            "kind": .string("diff"),
                            "source": .string("git"),
                            "repositoryPath": pane.repoPath.map(IntentValue.string) ?? .null,
                            "path": .string(path),
                            "staged": .bool(section == "staged"),
                            "untracked": .bool(untracked),
                            "originalPath": entry?.origPath.map(IntentValue.string) ?? .null,
                            "title": .string(
                                GitPluginView.shortName(path)
                                    + (section == "staged" ? " (staged)" : "")
                            ),
                        ]),
                    ])
                )
            )
            if case let .failure(failure) = result {
                await context.log("open diff failed: \(failure.error.code.rawValue)")
            }
        }

        private func discard(
            instanceID: String,
            path: String,
            context: BundledPluginContext
        ) async {
            let entry = panes[instanceID].flatMap {
                findEntry(in: $0, section: "changed", path: path)
            }
            let result = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: GitPlugin.uiConfirm,
                    input: .object([
                        "title": .string("Discard changes to \(GitPluginView.shortName(path))? This cannot be undone."),
                        "destructive": .bool(true),
                    ])
                )
            )
            guard case let .success(success) = result,
                  boolValue(objectValue(success.value)?["confirmed"]) == true
            else { return }
            if entry.map({ $0.staged == "?" || $0.unstaged == "?" }) == true {
                await op(
                    instanceID: instanceID,
                    args: ["clean", "-f", "--", path],
                    label: "Discard untracked \(GitPluginView.shortName(path))",
                    context: context
                )
            } else {
                await op(
                    instanceID: instanceID,
                    args: ["restore", "--worktree", "--", path],
                    label: "Discard \(GitPluginView.shortName(path))",
                    context: context
                )
            }
        }

        private func discardAll(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            let count = panes[instanceID]?.model.changed.count ?? 0
            let result = await context.intents.send(
                PluginIntentSendRequest(
                    intentID: GitPlugin.uiConfirm,
                    input: .object([
                        "title": .string("Discard all \(count) changed files? This cannot be undone."),
                        "destructive": .bool(true),
                    ])
                )
            )
            guard case let .success(success) = result,
                  boolValue(objectValue(success.value)?["confirmed"]) == true
            else { return }
            await op(
                instanceID: instanceID,
                args: ["restore", "--worktree", "--", "."],
                label: "Discard tracked changes",
                context: context
            )
        }

        private func commit(
            instanceID: String,
            includeAll: Bool,
            context: BundledPluginContext
        ) async {
            var message = (panes[instanceID]?.commitMessage ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                let prompt = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: GitPlugin.uiPrompt,
                        input: .object([
                            "title": .string("Commit message"),
                            "multiline": .bool(true),
                        ])
                    )
                )
                message = (stringValue(objectValue(successValue(prompt))?["value"]) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty { return }
            }
            if includeAll {
                let staged = await git(
                    .pane(instanceID),
                    args: ["add", "-A"],
                    client: .plugin(context)
                )
                guard staged.ok, staged.status == 0 else {
                    _ = await context.intents.send(
                        PluginIntentSendRequest(
                            intentID: GitPlugin.uiToast,
                            input: .object([
                                "message": .string("Stage all failed"),
                                "kind": .string("error"),
                            ])
                        )
                    )
                    return
                }
            }
            panes[instanceID]?.commitMessage = ""
            await op(
                instanceID: instanceID,
                args: ["commit", "-m", message],
                label: "Commit",
                context: context
            )
        }

        private func switchBranch(
            instanceID: String,
            client: GitIntentClient,
            context _: BundledPluginContext
        ) async {
            await switchBranch(target: .pane(instanceID), client: client)
        }

        private func switchBranchForBar(
            client: GitIntentClient,
            context _: BundledPluginContext
        ) async {
            await switchBranch(target: .bar, client: client)
        }

        private func switchBranch(target: Target, client: GitIntentClient) async {
            let result = await git(
                target,
                args: ["branch", "--format=%(refname:short)"],
                client: client
            )
            let names = result.stdout.split(separator: "\n").map(String.init)
            guard !names.isEmpty else {
                _ = await client.send(
                    GitPlugin.uiToast,
                    .object([
                        "message": .string("No branches found"),
                        "kind": .string("warning"),
                    ])
                )
                return
            }
            let current = model(for: target).branch
            let choice = await client.send(
                GitPlugin.uiPick,
                .object([
                    "items": .array(
                        names.map { name in
                            .object([
                                "id": .string(name),
                                "label": .string(name),
                                "icon": .string("arrow.triangle.branch"),
                                "detail": .string(name == current ? "current" : ""),
                            ])
                        }
                    ),
                    "placeholder": .string("Switch branch"),
                ])
            )
            guard let selected = stringValue(
                objectValue(successValue(choice))?["selectedID"]
            ),
                selected != current
            else { return }
            await op(
                target: target,
                args: ["switch", selected],
                label: "Switch to \(selected)",
                client: client
            )
        }

        // MARK: - Events, timers and watches  @domain: plugin-events

        private func ensurePollTimer(context: BundledPluginContext) async {
            guard pollTimer == nil else { return }
            do {
                pollTimer = try await context.timers.every(15_000) {
                    await self.poll(context: context)
                }
            } catch {
                await context.log("git: polling timer unavailable: \(error)")
            }
        }

        private func poll(context: BundledPluginContext) async {
            await refreshBar(context: context)
            for id in panes.keys.sorted() {
                await watchRepo(instanceID: id, context: context)
                await refreshPane(id, context: context)
            }
            await context.publishContribution(contribution())
        }

        private func followRepo(
            _ target: Target,
            root: String,
            context: BundledPluginContext
        ) async {
            guard followedRepo(for: target) != root else { return }
            setFollowedRepo(root, for: target)
            setRepo(nil, for: target)
            await refresh(target, client: .plugin(context))
            if case let .pane(id) = target {
                await watchRepo(instanceID: id, context: context)
            }
        }

        private func debouncedRefresh(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            if let debounce = panes[instanceID]?.debounce {
                await debounce.cancel()
            }
            do {
                let handle = try await context.timers.after(
                    400,
                    ownedBy: instanceID
                ) {
                    await self.debounceFired(
                        instanceID: instanceID,
                        context: context
                    )
                }
                panes[instanceID]?.debounce = handle
            } catch {
                await context.log("git: debounce timer unavailable: \(error)")
            }
        }

        private func debounceFired(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            panes[instanceID]?.debounce = nil
            await refreshPane(instanceID, context: context)
            await context.publishContribution(contribution())
        }

        private func watchRepo(
            instanceID: String,
            context: BundledPluginContext
        ) async {
            guard panes[instanceID] != nil,
                  let repo = await resolveRepo(.pane(instanceID), client: .plugin(context)),
                  !repo.isEmpty,
                  panes[instanceID]?.watchedRepo != repo
            else { return }
            if let watch = panes[instanceID]?.watch {
                await watch.cancel()
            }
            let handle = await context.fs.watch(
                repo,
                recursive: true,
                ownedBy: instanceID
            ) { _ in
                await self.debouncedRefresh(
                    instanceID: instanceID,
                    context: context
                )
            }
            panes[instanceID]?.watch = handle
            panes[instanceID]?.watchedRepo = handle == nil ? nil : repo
        }

        // MARK: - Projection and state helpers  @domain: plugin-contributions

        private func contribution() -> BundledPluginContribution {
            BundledPluginContribution(
                statusBarText: GitPluginView.statusBarText(for: bar.model),
                viewRegistrations: [
                    BundledPluginViewRegistration(
                        viewID: GitPlugin.viewID,
                        title: "Git",
                        instanced: true
                    ),
                ],
                viewBodies: panes.values.sorted { $0.id < $1.id }.map { pane in
                    BundledPluginViewBody(
                        viewID: GitPlugin.viewID,
                        instanceID: pane.id,
                        body: GitPluginView.body(for: pane),
                        header: GitPluginView.header(for: pane.model)
                    )
                }
            )
        }

        private func commandTarget(client: GitIntentClient) async -> Target {
            let workspace = await selectedWorkspace(client: client)
            let selected = workspace?.selected == true ? workspace?.id : nil
            for pane in panes.values where selected != nil && pane.workspaceID == selected {
                return .pane(pane.id)
            }
            return .bar
        }

        private func findEntry(
            in pane: Pane,
            section: String,
            path: String
        ) -> GitChangeEntry? {
            let entries: [GitChangeEntry]
            switch section {
            case "staged": entries = pane.model.staged
            case "merge": entries = pane.model.merge
            default: entries = pane.model.changed
            }
            return entries.first { $0.path == path }
        }

        private func model(for target: Target) -> GitStatusModel {
            switch target {
            case .bar: bar.model
            case let .pane(id): panes[id]?.model ?? .empty
            }
        }

        private func setModel(_ model: GitStatusModel, for target: Target) {
            switch target {
            case .bar:
                bar.model = model
            case let .pane(id):
                panes[id]?.model = model
            }
        }

        private func repoPath(for target: Target) -> String? {
            switch target {
            case .bar: bar.repoPath
            case let .pane(id): panes[id]?.repoPath
            }
        }

        private func setRepo(_ repo: String?, for target: Target) {
            switch target {
            case .bar:
                bar.repoPath = repo
            case let .pane(id):
                panes[id]?.repoPath = repo
            }
        }

        private func followedRepo(for target: Target) -> String? {
            switch target {
            case .bar: bar.followedRepo
            case let .pane(id): panes[id]?.followedRepo
            }
        }

        private func setFollowedRepo(_ repo: String, for target: Target) {
            switch target {
            case .bar:
                bar.followedRepo = repo
            case let .pane(id):
                panes[id]?.followedRepo = repo
            }
        }

        private func settingRepo(_ context: BundledPluginContext?) -> String? {
            let value = (stringValue(context?.setting("repoPath")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value == "~" ? nil : value
        }
    }
}

// MARK: - Helpers  @domain: plugin-host

private enum Target: Sendable, Equatable {
    case bar
    case pane(String)
}

private struct GitProcessResult: Sendable, Equatable {
    let ok: Bool
    let status: Int
    let stdout: String
    let stderr: String
    let error: String?
}

private struct WorkspaceNode: Sendable, Equatable {
    let id: String?
    let path: String
    let selected: Bool
}

private struct WorkspaceOwner: Sendable, Equatable {
    let id: String?
    let path: String
}

private struct GitIntentClient: Sendable {
    let context: BundledPluginContext?
    private let sendOperation: @Sendable (IntentID, IntentValue) async -> IntentResult

    static func plugin(_ context: BundledPluginContext) -> GitIntentClient {
        GitIntentClient(context: context) { intentID, input in
            await context.intents.send(
                PluginIntentSendRequest(intentID: intentID, input: input)
            )
        }
    }

    static func provider(
        _ context: IntentProviderContext,
        pluginContext: BundledPluginContext
    ) -> GitIntentClient {
        GitIntentClient(context: pluginContext) { intentID, input in
            await context.send(
                IntentProviderSendRequest(intentID: intentID, input: input)
            )
        }
    }

    private init(
        context: BundledPluginContext?,
        send: @escaping @Sendable (IntentID, IntentValue) async -> IntentResult
    ) {
        self.context = context
        sendOperation = send
    }

    func send(_ intentID: IntentID, _ input: IntentValue) async -> IntentResult {
        await sendOperation(intentID, input)
    }
}

private func inlineText(_ value: IntentValue?) -> String {
    guard stringValue(objectValue(value)?["kind"]) == "inline" else { return "" }
    return stringValue(objectValue(value)?["text"]) ?? ""
}

private func firstLine(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n", maxSplits: 1)
        .first.map(String.init) ?? ""
}

private func successValue(_ result: IntentResult) -> IntentValue? {
    guard case let .success(success) = result else { return nil }
    return success.value
}

private func objectValue(_ value: IntentValue?) -> [String: IntentValue]? {
    guard case let .object(object)? = value else { return nil }
    return object
}

private func arrayValue(_ value: IntentValue?) -> [IntentValue]? {
    guard case let .array(array)? = value else { return nil }
    return array
}

private func stringValue(_ value: IntentValue?) -> String? {
    guard case let .string(string)? = value else { return nil }
    return string
}

private func integerValue(_ value: IntentValue?) -> Int64? {
    guard case let .integer(integer)? = value else { return nil }
    return integer
}

private func boolValue(_ value: IntentValue?) -> Bool? {
    guard case let .bool(bool)? = value else { return nil }
    return bool
}
