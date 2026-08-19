import Foundation
@testable import TenonBundledPlugins
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-036 regression: a plugin view opened in one workspace keeps state owned by that
/// workspace. Switching the global selection must neither rebind an inactive workspace's
/// view nor wipe its per-instance UI state.
///
/// The real shipped runtimes run against a bridge that emulates `workspace.state.v1` for two
/// workspaces, each owning one pane of the view under test.
/// Sharing one runtime per plugin is by design and is not what these tests reject; what
/// they reject is view-instance state riding on that runtime without workspace identity.
final class WorkspaceScopedViewStateTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    private enum Fixture {
        static let workspaceA = "AAAAAAAA-0000-0000-0000-000000000001"
        static let workspaceB = "BBBBBBBB-0000-0000-0000-000000000002"
        static let tabA = "AAAAAAAA-1111-0000-0000-000000000001"
        static let tabB = "BBBBBBBB-1111-0000-0000-000000000002"
        static let paneA = "AAAAAAAA-2222-0000-0000-000000000001"
        static let paneB = "BBBBBBBB-2222-0000-0000-000000000002"
    }

    /// The root a File Browser pane says it is showing, read off the `root` label the view
    /// publishes into its pane's chrome header.
    ///
    /// This is the observable these tests hang the whole per-workspace rooting proof on, so
    /// it is worth saying what it is: the ONE thing each pane displays that differs by
    /// owning workspace. It moved out of the view body and into the header along with every
    /// other second header bar; what it proves did not change.
    private static func publishedRoot(of view: PluginViewInfo?) -> String? {
        guard case let .label(_, text, _, _, _, _) = view?.header.leading.first else {
            return nil
        }
        return text
    }

    // MARK: - File Browser (the reported defect)

    func testFileBrowserStateStaysWithItsWorkspaceWhenSelectionChanges() async throws {
        let rootA = "/tmp/tenon-t036-ws-a"
        let rootB = "/tmp/tenon-t036-ws-b"
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.file-explorer", viewID: "tree"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "filesystem.directory.list.v2" else {
                    return nil
                }
                let path = request.input.objectValue?["path"]?.stringValue
                func entry(_ name: String, directory: Bool) -> IntentValue {
                    .object(["name": .string(name), "isDirectory": .bool(directory)])
                }
                let entries: [IntentValue]
                switch path {
                case rootA:
                    entries = [entry("src-a", directory: true), entry("a.txt", directory: false)]
                case rootA + "/src-a":
                    entries = [entry("main-a.swift", directory: false)]
                case rootB:
                    entries = [entry("b.txt", directory: false)]
                default:
                    entries = []
                }
                return .object(["entries": .array(entries), "nextCursor": .null])
            }
        )
        let runtime = try await makeBundledRuntime(plugin: "file-explorer", bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("tree")
        XCTAssertTrue(
            instanced,
            "file-explorer must opt into per-pane instances — a singleton view cannot keep independent per-workspace state"
        )
        try await runtime.openViewInstance(viewID: "tree", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "tree", instanceID: Fixture.paneB)

        // Each pane is rooted at the workspace that OWNS it, even though A is selected.
        let bothRooted = await eventually {
            let views = await runtime.snapshot().views
            let a = views.first { $0.instanceID == Fixture.paneA }
            let b = views.first { $0.instanceID == Fixture.paneB }
            return Self.publishedRoot(of: a) == rootA && Self.publishedRoot(of: b) == rootB
        }
        XCTAssertTrue(
            bothRooted,
            "each File Browser pane must root at its owning workspace, not the selected one"
        )

        // Give A's tree per-instance UI state: expand a directory.
        _ = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Fixture.paneA,
            itemID: rootA + "/src-a",
            value: nil
        )
        let expanded = await eventually {
            await self.items(of: runtime, instance: Fixture.paneA)
                .contains { $0.label == "main-a.swift" }
        }
        XCTAssertTrue(expanded)

        // Switch the global selection to B, then back — the repro from the task file.
        for selected in [Fixture.workspaceB, Fixture.workspaceA] {
            await bridge.select(selected)
            try await runtime.deliverEvent(
                event: "workspace.selected",
                payload: .object(["workspaceId": .string(selected)])
            )
            try? await Task.sleep(for: .milliseconds(150))

            let views = await runtime.snapshot().views
            let a = views.first { $0.instanceID == Fixture.paneA }
            let b = views.first { $0.instanceID == Fixture.paneB }
            XCTAssertEqual(
                Self.publishedRoot(of: a),
                rootA,
                "A's browser must not follow the selection (selected: \(selected))"
            )
            XCTAssertEqual(
                Self.publishedRoot(of: b),
                rootB,
                "B's browser must not follow the selection (selected: \(selected))"
            )
            XCTAssertTrue(
                a?.items.contains { $0.label == "main-a.swift" } == true,
                "A's expansion state must survive the selection change (selected: \(selected))"
            )
        }
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - Git panel

    func testGitPanelBindsEachPaneToItsOwnWorkspaceRepository() async throws {
        let rootA = try makeTemporaryDirectory(suffix: "repo-a")
        let rootB = try makeTemporaryDirectory(suffix: "repo-b")
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.git", viewID: "git"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                let input = request.input.objectValue
                let arguments = input?["arguments"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
                let workingDirectory = input?["workingDirectory"]?.stringValue ?? "/"
                func inline(_ text: String) -> IntentValue {
                    .object(["kind": .string("inline"), "text": .string(text)])
                }
                func exec(_ stdout: String) -> IntentValue {
                    .object([
                        "exitCode": .integer(0),
                        "standardOutput": inline(stdout),
                        "standardError": inline(""),
                    ])
                }
                switch arguments.first {
                case "rev-parse":
                    return exec(workingDirectory + "\n")
                case "status":
                    let branch = "branch-" + (workingDirectory as NSString).lastPathComponent
                    return exec("# branch.oid 1234567\u{0}# branch.head \(branch)\u{0}")
                default:
                    return exec("")
                }
            }
        )
        let runtime = try await makeBundledRuntime(plugin: "git", bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("git")
        XCTAssertTrue(
            instanced,
            "git must opt into per-pane instances — a singleton panel cannot show two workspaces' repos"
        )
        try await runtime.openViewInstance(viewID: "git", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "git", instanceID: Fixture.paneB)

        let branchA = "branch-" + (rootA as NSString).lastPathComponent
        let branchB = "branch-" + (rootB as NSString).lastPathComponent
        let bothBound = await eventually {
            let currentA = await self.branchName(of: runtime, instance: Fixture.paneA)
            let currentB = await self.branchName(of: runtime, instance: Fixture.paneB)
            return currentA == branchA && currentB == branchB
        }
        XCTAssertTrue(
            bothBound,
            "each git pane must read the repository of its owning workspace"
        )

        await bridge.select(Fixture.workspaceB)
        try await runtime.deliverEvent(
            event: "workspace.selected",
            payload: .object(["workspaceId": .string(Fixture.workspaceB)])
        )
        try? await Task.sleep(for: .milliseconds(150))
        let settledA = await branchName(of: runtime, instance: Fixture.paneA)
        let settledB = await branchName(of: runtime, instance: Fixture.paneB)
        XCTAssertEqual(settledA, branchA, "A's git panel must not follow the selection to B")
        XCTAssertEqual(settledB, branchB)
        _ = await runtime.shutdown(timeout: 2)
    }

    /// One conflicted, one staged and one changed file on a branch two commits ahead of its
    /// upstream and one behind — the smallest `--porcelain=v2` status that makes every badge
    /// the git header can draw non-zero at once.
    private static let porcelainStatus = [
        "# branch.oid 1234567",
        "# branch.head feature/pane-header",
        "# branch.upstream origin/feature/pane-header",
        "# branch.ab +2 -1",
        "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb staged.txt",
        "1 .M N... 100644 100644 100644 ccccccc ddddddd changed.txt",
        "u UU N... 100644 100644 100644 100644 eeeeeee fffffff ggggggg conflict.txt",
    ].joined(separator: "\u{0}") + "\u{0}"

    /// The chrome header is where a supervisor reads a git panel WITHOUT reading it: which
    /// branch, how much is uncommitted, how far the branch has drifted, and one verb to
    /// re-read it. Every fact up there left the body when it arrived, which is the half of
    /// this the second block asserts — a header restating the body is the two-row duplication
    /// the one-header rule exists to delete.
    func testGitHeaderCarriesBranchCountsAndSyncAndRefreshesFromItsTrailingEdge() async throws {
        let root = try makeTemporaryDirectory(suffix: "repo-header")
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.git", viewID: "git"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: root, tabID: Fixture.tabA, paneID: Fixture.paneA),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                let input = request.input.objectValue
                let arguments = input?["arguments"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
                let workingDirectory = input?["workingDirectory"]?.stringValue ?? "/"
                func inline(_ text: String) -> IntentValue {
                    .object(["kind": .string("inline"), "text": .string(text)])
                }
                func exec(_ stdout: String) -> IntentValue {
                    .object([
                        "exitCode": .integer(0),
                        "standardOutput": inline(stdout),
                        "standardError": inline(""),
                    ])
                }
                switch arguments.first {
                case "rev-parse":
                    return exec(workingDirectory + "\n")
                case "status":
                    return exec(Self.porcelainStatus)
                default:
                    return exec("")
                }
            }
        )
        let runtime = try await makeBundledRuntime(plugin: "git", bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "git", instanceID: Fixture.paneA)

        let drawn = await eventually {
            await self.paneAView(of: runtime)?.header.leading.map(\.id)
                == ["branch-icon", "branch", "conflicts", "staged", "changed"]
        }
        XCTAssertTrue(
            drawn,
            "the git pane's identity and its measurement belong in the one chrome header"
        )
        let published = await paneAView(of: runtime)
        let view = try XCTUnwrap(published)
        guard case let .label(_, branch, _, _, _, _) = view.header.item(id: "branch") else {
            _ = await runtime.shutdown(timeout: 2)
            return XCTFail("the branch is the pane's identity — it must be a header label")
        }
        XCTAssertEqual(branch, "feature/pane-header")
        XCTAssertEqual(Self.badgeText(view.header.item(id: "conflicts")), "1 conflicted")
        XCTAssertEqual(Self.badgeText(view.header.item(id: "staged")), "1 staged")
        XCTAssertEqual(Self.badgeText(view.header.item(id: "changed")), "1 changed")
        XCTAssertEqual(
            view.header.trailing.map(\.id),
            ["sync", "refresh"],
            "status reads first in the trailing run, the verb sits at the edge"
        )
        XCTAssertEqual(Self.badgeText(view.header.item(id: "sync")), "↑2 ↓1")

        // The de-duplication half. `String(describing:)` walks the whole published node tree,
        // so these three assertions fail the moment a body row starts restating the strip.
        let body = String(describing: view.body)
        XCTAssertFalse(
            body.contains("feature/pane-header"),
            "the branch name is header identity; a body button repeating it is the second row"
        )
        XCTAssertFalse(
            body.contains("Staged (") || body.contains("Changes (") || body.contains("Conflicts ("),
            "the counts are header badges now; a section heading may name its files, not count them"
        )
        XCTAssertFalse(
            body.contains("↑2"),
            "upstream drift is a header badge; the branch row must not carry it too"
        )

        // The refresh verb has to actually re-read the repository, not merely be drawn.
        let before = Self.statusCalls(in: await bridge.requests())
        let clicked = try await runtime.invokeViewSelect(
            viewID: "git",
            instanceID: Fixture.paneA,
            itemID: "refresh"
        )
        XCTAssertTrue(clicked)
        let reread = await eventually {
            Self.statusCalls(in: await bridge.requests()) > before
        }
        XCTAssertTrue(reread, "the header's refresh verb must re-run `git status`")

        // A panel with no repository has no branch to name and nothing to count. Publishing
        // NO header is how a plugin takes one away, so this is the state that must produce
        // one — a strip saying "?" and nothing else would be worse than the bare chrome.
        XCTAssertTrue(
            GitPluginView.header(for: .empty).isEmpty,
            "a git panel with no repository must publish no header"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - Claude sessions panel

    func testClaudeSessionsListsEachPanesOwnWorkspaceProject() async throws {
        let rootA = "/tmp/tenon-t036-project-a"
        let rootB = "/tmp/tenon-t036-project-b"
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.claude-sessions", viewID: "sessions"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                // The sessions directory does not exist; the scan reports that and keeps
                // the per-instance project binding, which is what this test asserts.
                return .object([
                    "exitCode": .integer(3),
                    "standardOutput": .object([
                        "kind": .string("inline"), "text": .string(""),
                    ]),
                    "standardError": .object([
                        "kind": .string("inline"), "text": .string(""),
                    ]),
                ])
            }
        )
        let runtime = try await makeBundledRuntime(plugin: "claude-sessions", bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("sessions")
        XCTAssertTrue(
            instanced,
            "claude-sessions must opt into per-pane instances — one shared list cannot serve two workspaces"
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.paneB)

        let bothBound = await eventually {
            let projectA = await self.projectPath(of: runtime, instance: Fixture.paneA)
            let projectB = await self.projectPath(of: runtime, instance: Fixture.paneB)
            return projectA == rootA && projectB == rootB
        }
        XCTAssertTrue(
            bothBound,
            "each sessions pane must list the project of its owning workspace"
        )

        await bridge.select(Fixture.workspaceB)
        try await runtime.deliverEvent(
            event: "workspace.selected",
            payload: .object(["workspaceId": .string(Fixture.workspaceB)])
        )
        try await runtime.deliverEvent(event: "workspace.changed", payload: .object([:]))
        try? await Task.sleep(for: .milliseconds(150))
        let projectA = await projectPath(of: runtime, instance: Fixture.paneA)
        let projectB = await projectPath(of: runtime, instance: Fixture.paneB)
        XCTAssertEqual(projectA, rootA, "A's sessions panel must not follow the selection to B")
        XCTAssertEqual(projectB, rootB)
        _ = await runtime.shutdown(timeout: 2)
    }

    func testAgentSessionsIncludeTitledCodexThreadsAndResumeWithCodex() async throws {
        let root = "/tmp/tenon-agent-sessions-codex"
        let sessionID = "019f0000-1111-7222-8333-444455556666"
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.claude-sessions", viewID: "sessions"),
            workspaces: [
                .init(
                    id: Fixture.workspaceA,
                    path: root,
                    tabID: Fixture.tabA,
                    paneID: Fixture.paneA
                ),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                if request.intentID.rawValue == "agent.inventory.v1" {
                    return .object([
                        "agents": .array([
                            .object([
                                "id": .string("codex"),
                                "label": .string("Codex"),
                                "arguments": .array([]),
                                "habit": .null,
                            ])
                        ])
                    ])
                }
                // The host is what knows that Codex spells a resume as a subcommand. The
                // plugin's part is naming the session and passing the answer through.
                if request.intentID.rawValue == "agent.command.v1" {
                    let session = request.input.objectValue?["session"]?.objectValue
                    let id = session?["sessionID"]?.stringValue ?? ""
                    return .object([
                        "agent": .string("codex"),
                        "commandLine": .string("/opt/bin/codex resume \(id)"),
                        "arguments": .array([.string("resume"), .string(id)]),
                        "handoff": .bool(false),
                    ])
                }
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                let input = request.input.objectValue
                let arguments = input?["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let isCodexIndexRead = arguments.contains { $0.contains("sqlite3") }
                let trustsPopulatedTitleRows = !arguments.contains {
                    $0.contains("has_user_event")
                }
                let standardOutput: String
                let exitCode: Int64
                if isCodexIndexRead && trustsPopulatedTitleRows {
                    standardOutput = """
                    [{"id":"\(sessionID)","mtime":1786000000,"title":"Make session history readable","tokens":12345,"branch":"main"}]
                    """
                    exitCode = 0
                } else {
                    standardOutput = ""
                    exitCode = 3
                }
                func inline(_ text: String) -> IntentValue {
                    .object(["kind": .string("inline"), "text": .string(text)])
                }
                return .object([
                    "exitCode": .integer(exitCode),
                    "standardOutput": inline(standardOutput),
                    "standardError": inline(""),
                ])
            }
        )
        let runtime = try await makeBundledRuntime(plugin: "claude-sessions", bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.paneA)

        let loaded = await eventually {
            await self.texts(of: runtime, instance: Fixture.paneA)
                .contains("Make session history readable")
        }
        XCTAssertTrue(loaded, "Codex's stored thread title must be the visible session name")
        let visibleTexts = await texts(of: runtime, instance: Fixture.paneA)
        XCTAssertTrue(visibleTexts.contains("Codex"))
        XCTAssertTrue(visibleTexts.contains("Make session history readable"))
        XCTAssertFalse(
            visibleTexts.contains(sessionID),
            "session IDs are internal actions, not UI copy"
        )

        _ = try await runtime.invokeViewSelect(
            viewID: "sessions",
            instanceID: Fixture.paneA,
            itemID: "open:codex:\(sessionID)",
            value: nil
        )
        let resumed = await eventually {
            await bridge.requests().contains { request in
                guard request.intentID.rawValue == "terminal.open.v1" else { return false }
                let command = request.input.objectValue?["command"]?.stringValue ?? ""
                return command.contains("codex resume") && command.contains(sessionID)
            }
        }
        XCTAssertTrue(resumed, "a Codex row must resume through the Codex CLI")
        // The session it named is the row's own session, and it asked for a resume by that
        // session's own agent — which is what makes the answer a resume and not a handoff.
        let asked = await bridge.requests().first {
            $0.intentID.rawValue == "agent.command.v1"
        }
        let session = try XCTUnwrap(asked?.input.objectValue?["session"]?.objectValue)
        XCTAssertEqual(session["agent"]?.stringValue, "codex")
        XCTAssertEqual(session["sessionID"]?.stringValue, sessionID)
        _ = await runtime.shutdown(timeout: 2)
    }

    /// What a supervisor scans on a sessions pane: whose project it is, how much agent
    /// history is here and from which tool, and two verbs — start one, re-read the list.
    ///
    /// Codex-only on purpose. The Codex half reads a bounded SQLite index and is the one scan
    /// path this test can drive without pinning itself to how Claude transcripts are
    /// enumerated, which is being reworked under T-081. The zero-Claude case is an assertion
    /// in its own right: a count badge nobody can read as "none" has no business being drawn.
    func testAgentSessionsHeaderCountsItsSessionsAndStartsOneFromItsTrailingMenu() async throws {
        let root = "/tmp/tenon-agent-sessions-header"
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.claude-sessions", viewID: "sessions"),
            workspaces: [
                .init(
                    id: Fixture.workspaceA,
                    path: root,
                    tabID: Fixture.tabA,
                    paneID: Fixture.paneA
                ),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                // The pane never spells an agent's command line; it asks the host which
                // agents exist and then for the line that starts one.
                if request.intentID.rawValue == "agent.inventory.v1" {
                    return .object([
                        "agents": .array([
                            .object([
                                "id": .string("claude"),
                                "label": .string("Claude Code"),
                                "arguments": .array([]),
                                "habit": .null,
                            ]),
                            .object([
                                "id": .string("codex"),
                                "label": .string("Codex"),
                                "arguments": .array([.string("--full-auto")]),
                                "habit": .string("Full auto"),
                            ]),
                        ])
                    ])
                }
                if request.intentID.rawValue == "agent.command.v1" {
                    let agent = request.input.objectValue?["agent"]?
                        .stringValue ?? ""
                    return .object([
                        "agent": .string(agent),
                        "commandLine": .string("/opt/bin/\(agent) --model opus"),
                        "arguments": .array([
                            .string("--model"),
                            .string("opus"),
                        ]),
                        "handoff": .bool(false),
                    ])
                }
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                let arguments = request.input.objectValue?["arguments"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
                let isCodexIndexRead = arguments.contains { $0.contains("FROM threads") }
                func inline(_ text: String) -> IntentValue {
                    .object(["kind": .string("inline"), "text": .string(text)])
                }
                return .object([
                    "exitCode": .integer(isCodexIndexRead ? 0 : 3),
                    "standardOutput": inline(
                        isCodexIndexRead
                            ? #"[{"id":"thread-1","mtime":1786000000,"title":"Land the pane header","tokens":900,"branch":"main"}]"#
                            : ""
                    ),
                    "standardError": inline(""),
                ])
            }
        )
        let runtime = try await makeBundledRuntime(plugin: "claude-sessions", bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.paneA)

        let drawn = await eventually {
            await self.paneAView(of: runtime)?.header.leading.map(\.id) == ["project", "codex"]
        }
        XCTAssertTrue(
            drawn,
            "the project and the per-tool session count are the pane's scannable facts"
        )
        let published = await paneAView(of: runtime)
        let view = try XCTUnwrap(published)
        guard case let .label(_, project, _, _, truncation, _) = view.header.item(id: "project")
        else {
            _ = await runtime.shutdown(timeout: 2)
            return XCTFail("the project is the pane's identity — it must be a header label")
        }
        XCTAssertEqual(project, root)
        XCTAssertEqual(
            truncation,
            .head,
            "a path gives up its front; the directory you are in is its meaningful tail"
        )
        XCTAssertEqual(Self.badgeText(view.header.item(id: "codex")), "1 Codex")
        XCTAssertEqual(
            view.header.trailing.map(\.id),
            ["new", "refresh"],
            "both pane-wide verbs sit in the strip; neither may keep a copy in the body"
        )
        guard case let .menu(_, _, entries, _, _, _) = view.header.item(id: "new") else {
            _ = await runtime.shutdown(timeout: 2)
            return XCTFail("two labelled ways to start a session is a menu, not two glyphs")
        }
        XCTAssertEqual(
            entries.map(\.value),
            ["start:claude", "start:codex"],
            "the entries are the agents the host reports, not a list this plugin keeps"
        )
        XCTAssertEqual(
            entries.map(\.label),
            ["New Claude Code session", "New Codex session"]
        )

        let body = String(describing: view.body)
        XCTAssertFalse(
            body.contains("Agent sessions"),
            "the pane's name is host chrome; a body title restating it is the second row"
        )
        XCTAssertFalse(
            body.contains(root),
            "the project path is a header label now"
        )
        XCTAssertFalse(
            body.contains("New Codex") || body.contains("\"Refresh\"") || body.contains("label: \"Refresh\""),
            "the toolbar row moved into the strip; a body copy of it is the duplication"
        )

        // A menu reports its OWN id plus the picked entry's value, so the pick has to survive
        // that indirection all the way to the terminal it opens.
        let picked = try await runtime.invokeViewSelect(
            viewID: "sessions",
            instanceID: Fixture.paneA,
            itemID: "new",
            value: .string("start:claude")
        )
        XCTAssertTrue(picked)
        let started = await eventually {
            await bridge.requests().contains { request in
                request.intentID.rawValue == "terminal.open.v1"
                    && request.input.objectValue?["command"]?.stringValue
                        == "/opt/bin/claude --model opus"
            }
        }
        XCTAssertTrue(
            started,
            "the pane opens the line the host composed, unedited — that is the whole point "
                + "of asking for one"
        )

        // The count badges are pure functions of the scanned list, so they are checked
        // against a list this test states outright rather than one it has to arrange.
        let countedPane = ClaudeSessionsPaneState(
            id: Fixture.paneA,
            project: "/p",
            sessions: [
                ClaudeSessionRecord(provider: .claude, id: "a", path: "", mtime: 0, size: 0, prompts: 0, replies: 0, tokens: 0, branch: "", title: ""),
                ClaudeSessionRecord(provider: .claude, id: "b", path: "", mtime: 0, size: 0, prompts: 0, replies: 0, tokens: 0, branch: "", title: ""),
                ClaudeSessionRecord(provider: .codex, id: "c", path: "", mtime: 0, size: 0, prompts: 0, replies: 0, tokens: 0, branch: "", title: ""),
            ]
        )
        let counted = ClaudeSessionsView.contribution(
            panes: [countedPane],
            favourites: []
        ).viewBodies[0].header
        XCTAssertEqual(
            counted.leading.map { item in
                switch item {
                case let .label(id, text, _, _, _, _): return "\(id)=\(text)"
                case let .badge(id, text, _, _): return "\(id)=\(text)"
                default: return item.id
                }
            },
            ["project=/p", "claude=2 Claude", "codex=1 Codex"]
        )

        let scanningPane = ClaudeSessionsPaneState(
            id: Fixture.paneA,
            project: "/p",
            notice: "Scanning…"
        )
        let scanning = ClaudeSessionsView.contribution(
            panes: [scanningPane],
            favourites: []
        ).viewBodies[0].header
        XCTAssertEqual(
            scanning.trailing.map(\.id),
            ["scanning", "refresh"],
            "a scan in flight is the pane's own state and belongs in its strip"
        )

        // A machine with no agent installed offers no way to start one, rather than a menu
        // whose every entry fails.
        let bare = ClaudeSessionsView.contribution(
            panes: [ClaudeSessionsPaneState(id: Fixture.paneA, project: "/p", notice: "")],
            favourites: []
        ).viewBodies[0].header
        XCTAssertEqual(bare.trailing.map(\.id), ["refresh"])
        _ = await runtime.shutdown(timeout: 2)
    }

    func testClaudeEnrichmentOutputFitsTheFiniteProcessIntentBody() async throws {
        let awk = ClaudeSessionsScan.awk
        let root = URL(fileURLWithPath: try makeTemporaryDirectory(suffix: "sessions"))
        let padding = String(repeating: "x", count: 19_000)
        var transcripts: [String] = []
        for index in 0 ..< 25 {
            let transcript = root.appendingPathComponent("session-\(index).jsonl")
            let body = """
            {"type":"user","message":{"role":"user","content":"Readable prompt \(index) \(padding)"},"gitBranch":"main"}
            {"type":"ai-title","aiTitle":"Readable title \(index)"}

            """
            try Data(body.utf8).write(to: transcript)
            transcripts.append(transcript.path)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["LC_ALL=C", "/usr/bin/awk", awk] + transcripts
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThanOrEqual(
            data.count,
            CoreIntentPayloadPolicy.maximumInlineTextCharacters,
            "session enrichment must remain a finite process.exec.v1 body"
        )
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self).contains("Readable title 0"),
            "bounding the enrich body must preserve the human-readable title"
        )
    }

    // MARK: - The sweep the task file demands

    /// Workspace-dependent shipped views are instanced; the gallery deliberately shares
    /// one body across panes because its demo content depends on no workspace.
    func testEveryWorkspaceDependentShippedViewOptsIntoInstances() async throws {
        for (plugin, viewID) in [
            ("file-explorer", "tree"),
            ("git", "git"),
            ("claude-sessions", "sessions"),
        ] {
            if plugin == "file-explorer" || plugin == "git" || plugin == "claude-sessions" {
                let runtime = try await makeBundledRuntime(
                    plugin: plugin,
                    bridge: WorkspaceBridge(
                        plugin: (id: "dev.tenon.\(plugin)", viewID: viewID),
                        workspaces: [],
                        selectedID: "",
                        respond: { _ in nil }
                    )
                )
                _ = try await runtime.start()
                let instanced = await runtime.isViewInstanced(viewID)
                XCTAssertTrue(instanced, "\(plugin)/\(viewID) leaks state across workspaces without instances")
                _ = await runtime.shutdown(timeout: 2)
                continue
            }
        }

        let galleryDirectory = Self.pluginsRoot.appendingPathComponent(
            "view-gallery",
            isDirectory: true
        )
        let galleryManifest = try PluginLoader.loadManifest(at: galleryDirectory)
        let gallery = try await BundledPluginRuntime.factory.make(
            PluginRuntimeConfiguration(
                manifest: galleryManifest,
                directory: galleryDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in
                        .success(
                            value: .object([:]),
                            requestID: UUID(),
                            providerID: try! ProviderID("dev.tenon.view-gallery.tests")
                        )
                    },
                    list: { .array([]) }
                )
            )
        )
        _ = try await gallery.start()
        let galleryInstanced = await gallery.isViewInstanced("gallery")
        XCTAssertFalse(
            galleryInstanced,
            "the gallery's shared body is deliberate — per-pane sharing must survive this fix"
        )
        _ = await gallery.shutdown(timeout: 2)
    }

    /// The pane→workspace edge is host structure, so exactly one implementation of it may
    /// exist and it lives in the host. A plugin that rebuilds a `tabWorkspace` map from
    /// `workspace.state.v1` has copied the host's model into JavaScript, where it silently
    /// answers "no owner" for any pane past the snapshot's first page.
    func testNoShippedPluginReimplementsThePaneToWorkspaceJoin() throws {
        let plugins = ["git", "kanban", "claude-sessions", "file-explorer"]
        var rebuiltJoin: [String] = []
        var missingOwnerIntent: [String] = []
        var staleSnapshotUse: [String] = []

        for plugin in plugins {
            let manifest = try PluginLoader.loadManifest(
                at: Self.pluginsRoot.appendingPathComponent(plugin, isDirectory: true)
            )
            guard manifest.runtime == .javaScript else { continue }
            let source = try String(
                contentsOf: Self.pluginsRoot
                    .appendingPathComponent(plugin, isDirectory: true)
                    .appendingPathComponent("main.js"),
                encoding: .utf8
            )
            if source.contains("tabWorkspace") { rebuiltJoin.append(plugin) }
            if !source.contains("workspace.pane.owner.v1") {
                missingOwnerIntent.append(plugin)
            }
            // These two ask only about a pane's owner, so the whole-catalog snapshot has
            // no remaining caller in them. git and file-explorer keep it for their genuine
            // selected-workspace questions.
            if ["kanban", "claude-sessions"].contains(plugin),
               source.contains("workspace.state.v1") {
                staleSnapshotUse.append(plugin)
            }
        }

        XCTAssertEqual(
            rebuiltJoin,
            [],
            "these plugins rebuild the host's pane→tab→workspace join by hand"
        )
        XCTAssertEqual(
            missingOwnerIntent,
            [],
            "these plugins resolve a pane's owner without asking the host for it"
        )
        XCTAssertEqual(
            staleSnapshotUse,
            [],
            "these plugins pay for a paginated catalog snapshot they no longer read"
        )
    }

    // MARK: - Helpers

    private func makeBundledRuntime(
        plugin: String,
        bridge: WorkspaceBridge
    ) async throws -> any PluginHostRuntime {
        let directory = Self.pluginsRoot.appendingPathComponent(plugin, isDirectory: true)
        let configuration = PluginRuntimeConfiguration(
            manifest: try PluginLoader.loadManifest(at: directory),
            directory: directory,
            intents: PluginRuntimeIntentBridge(
                send: { request in await bridge.send(request) },
                list: { .array([]) }
            )
        )
        if plugin == "git" {
            return BundledPluginRuntimeActor(
                configuration: configuration,
                program: GitPlugin.makeProgram(),
                watcherStart: { _ in false }
            )
        }
        return try await BundledPluginRuntime.factory.make(
            configuration
        )
    }

    private func paneAView(of runtime: any PluginHostRuntime) async -> PluginViewInfo? {
        await runtime.snapshot().views.first { $0.instanceID == Fixture.paneA }
    }

    private func branchName(
        of runtime: any PluginHostRuntime,
        instance: String
    ) async -> String? {
        let view = await runtime.snapshot().views.first { $0.instanceID == instance }
        guard case let .label(_, branch, _, _, _, _) = view?.header.item(id: "branch") else {
            return nil
        }
        return branch
    }

    private func projectPath(
        of runtime: any PluginHostRuntime,
        instance: String
    ) async -> String? {
        let view = await runtime.snapshot().views.first { $0.instanceID == instance }
        guard case let .label(_, project, _, _, _, _) = view?.header.item(id: "project") else {
            return nil
        }
        return project
    }

    private func texts(
        of runtime: any PluginHostRuntime,
        instance: String
    ) async -> [String] {
        guard let body = await runtime.snapshot().views
            .first(where: { $0.instanceID == instance })?.body
        else {
            return []
        }
        return Self.texts(in: body)
    }

    private static func texts(in node: PluginViewNode) -> [String] {
        var values: [String] = []
        switch node {
        case let .text(value, _, _, _):
            values.append(value)
        case let .badge(value, _):
            values.append(value)
        default:
            break
        }
        for child in node.children {
            values.append(contentsOf: texts(in: child))
        }
        return values
    }

    /// A badge is the one item whose whole meaning is its text, so reading it back is how
    /// these tests say what a pane measured.
    private static func badgeText(_ item: PaneHeaderItem?) -> String? {
        guard case let .badge(_, text, _, _) = item else { return nil }
        return text
    }

    private static func statusCalls(in requests: [PluginIntentSendRequest]) -> Int {
        requests.filter { request in
            request.intentID.rawValue == "process.exec.v1"
                && request.input.objectValue?["arguments"]?.arrayValue?
                .first?.stringValue == "status"
        }.count
    }

    private func items(
        of runtime: any PluginHostRuntime,
        instance: String
    ) async -> [TreeRowItem] {
        await runtime.snapshot().views
            .first { $0.instanceID == instance }?.items ?? []
    }

    private func makeTemporaryDirectory(suffix: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t036-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url.path
    }

    private func eventually(
        attempts: Int = 200,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// Emulates the host's `workspace.state.v1` for a fixed catalog of workspaces, each with
/// one tab and one pane showing the plugin view under test. Every other intent is answered
/// by the test's `respond` closure, or by an empty success so start-up work fails soft.
private actor WorkspaceBridge {
    struct Workspace {
        let id: String
        let path: String
        let tabID: String
        let paneID: String
    }

    private let plugin: (id: String, viewID: String)
    private let workspaces: [Workspace]
    private var selectedID: String
    private let respond: @Sendable (PluginIntentSendRequest) -> IntentValue?
    private var recorded: [PluginIntentSendRequest] = []

    init(
        plugin: (id: String, viewID: String),
        workspaces: [Workspace],
        selectedID: String,
        respond: @escaping @Sendable (PluginIntentSendRequest) -> IntentValue?
    ) {
        self.plugin = plugin
        self.workspaces = workspaces
        self.selectedID = selectedID
        self.respond = respond
    }

    func select(_ workspaceID: String) {
        selectedID = workspaceID
    }

    func requests() -> [PluginIntentSendRequest] {
        recorded
    }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        recorded.append(request)
        let value: IntentValue
        switch request.intentID.rawValue {
        case "workspace.state.v1":
            value = stateValue()
        case "workspace.pane.owner.v1":
            guard let owner = ownerValue(request.input) else {
                return .failure(
                    error: IntentError(
                        code: .domain(
                            try! IntentDomainErrorCode(
                                "dev.tenon.core.workspace-unavailable"
                            )
                        ),
                        details: .object(["reason": .string("pane-unknown")]),
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: UUID(),
                    providerID: try! ProviderID("dev.tenon.tests")
                )
            }
            value = owner
        default:
            value = respond(request) ?? .object([:])
        }
        return .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    /// Answered from the same `workspaces` array `stateValue()` walks, so the snapshot and
    /// the edge can never disagree about who owns what.
    private func ownerValue(_ input: IntentValue) -> IntentValue? {
        guard let paneID = input.objectValue?["paneID"]?.stringValue,
              let workspace = workspaces.first(where: { $0.paneID == paneID })
        else {
            return nil
        }
        return .object([
            "workspaceID": .string(workspace.id),
            "workspacePath": .string(workspace.path),
            "tabID": .string(workspace.tabID),
        ])
    }

    private func stateValue() -> IntentValue {
        var nodes: [IntentValue] = []
        for workspace in workspaces {
            nodes.append(.object([
                "kind": .string("workspace"),
                "id": .string(workspace.id),
                "name": .string((workspace.path as NSString).lastPathComponent),
                "path": .string(workspace.path),
                "selected": .bool(workspace.id == selectedID),
                "activeTabID": .string(workspace.tabID),
            ]))
            nodes.append(.object([
                "kind": .string("tab"),
                "id": .string(workspace.tabID),
                "workspaceID": .string(workspace.id),
                "selected": .bool(true),
                "activePaneID": .string(workspace.paneID),
            ]))
            nodes.append(.object([
                "kind": .string("pane"),
                "id": .string(workspace.paneID),
                "tabID": .string(workspace.tabID),
                "content": .object([
                    "kind": .string("plugin"),
                    "pluginID": .string(plugin.id),
                    "viewID": .string(plugin.viewID),
                ]),
                "frame": .object([
                    "x": .integer(0),
                    "y": .integer(0),
                    "width": .integer(1),
                    "height": .integer(1),
                ]),
            ]))
        }
        return .object([
            "snapshotID": .string(UUID().uuidString),
            "activeWorkspaceID": .string(selectedID),
            "activePaneID": .null,
            "nodes": .array(nodes),
            "nextCursor": .null,
        ])
    }
}
