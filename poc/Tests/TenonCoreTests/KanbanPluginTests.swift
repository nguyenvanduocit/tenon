import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-041: the shipped `kanban` plugin, driven as real JavaScript in a real runtime.
///
/// The plugin touches no host Swift — files arrive through the filesystem intent, the tree
/// is a CONTRIBUTION, the watch is a RESOURCE it owns, and Start is `terminal.open.v1`.
/// These tests are therefore also the claim that the public boundary is wide enough to
/// build a real feature on: if any of them needed a new host seam, it would not be here.
final class KanbanPluginTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    private enum Fixture {
        static let workspaceA = "AAAAAAAA-0000-0000-0000-000000000041"
        static let workspaceB = "BBBBBBBB-0000-0000-0000-000000000041"
        static let tabA = "AAAAAAAA-1111-0000-0000-000000000041"
        static let tabB = "BBBBBBBB-1111-0000-0000-000000000041"
        static let paneA = "AAAAAAAA-2222-0000-0000-000000000041"
        static let paneB = "BBBBBBBB-2222-0000-0000-000000000041"

        static let board = """
        # Kanban Board
        <!-- Updated: 2026-07-31 -->

        ## Todo
        - [T-101](tasks/T-101-first.md) First thing — high/M
        - this line is not a task and must not break the board
        - [T-102](tasks/T-102-second.md) Second thing — medium/S — claimed by someone

        ## Doing
        - [T-103](tasks/T-103-third.md) Third thing — low/L

        ## Done
        """

        static let taskFile = """
        # T-101: First thing
        > One line of description.
        - **priority**: high
        - **effort**: M

        ## Criteria
        - [x] Something already done
        - [ ] Something still open
        """

        /// A board with the shape the T-052 bug reported: larger than one inline page, so
        /// the host serves it as several cursor-linked pages. The Done column sits on the
        /// last page — it renders only when every cursor is followed to the end.
        static func largeBoard() -> (text: String, todoCount: Int) {
            var lines = ["# Kanban Board", "", "## Todo"]
            var todoCount = 0
            var size = 0
            let target = CoreIntentPayloadPolicy.maximumInlineTextCharacters * 2 + 4096
            while size < target {
                todoCount += 1
                let id = 10_000 + todoCount
                let line =
                    "- [T-\(id)](tasks/T-\(id)-filler.md) Filler task number \(todoCount) — low/S"
                lines.append(line)
                size += line.utf8.count + 1
            }
            lines.append("")
            lines.append("## Done")
            lines.append("- [T-999](tasks/T-999-last.md) Landed on the last page — high/S")
            return (lines.joined(separator: "\n"), todoCount)
        }
    }

    // MARK: - The format

    /// Fail-soft is the rule that matters most here: this board is written by several
    /// agents at once, so a half-written line is the normal case. A parser that threw, or
    /// that dropped the whole column, would blank the pane exactly when a human is trying
    /// to see what is going on.
    func testBoardParserReadsTheFormatAndSkipsMalformedLinesWithoutLosingTheRest() async throws {
        let runtime = try makeRuntime(bridge: makeBridge())
        _ = try await runtime.start()

        let json = try await evaluateJSON(
            runtime,
            "JSON.stringify(parseBoard(\(jsString(Fixture.board))))"
        )
        let columns = try XCTUnwrap(json as? [[String: Any]])

        XCTAssertEqual(columns.map { $0["name"] as? String }, ["Todo", "Doing", "Done"])
        let todo = try XCTUnwrap(columns.first?["tasks"] as? [[String: Any]])
        XCTAssertEqual(
            todo.map { $0["id"] as? String },
            ["T-101", "T-102"],
            "the malformed line must be skipped, and only it"
        )
        XCTAssertEqual(todo.first?["title"] as? String, "First thing")
        XCTAssertEqual(todo.first?["meta"] as? String, "high/M")
        XCTAssertEqual(todo.first?["path"] as? String, "tasks/T-101-first.md")
        // A line carrying extra ` — ` segments keeps its title and its meta, and drops
        // the rest rather than smuggling a status note into the title.
        XCTAssertEqual(todo.last?["title"] as? String, "Second thing")
        XCTAssertEqual(todo.last?["meta"] as? String, "medium/S")

        let done = try XCTUnwrap(columns.last?["tasks"] as? [[String: Any]])
        XCTAssertTrue(done.isEmpty)
        _ = await runtime.shutdown()
    }

    func testTaskParserReadsDescriptionFieldsAndCriteriaState() async throws {
        let runtime = try makeRuntime(bridge: makeBridge())
        _ = try await runtime.start()

        let json = try await evaluateJSON(
            runtime,
            "JSON.stringify(parseTask(\(jsString(Fixture.taskFile))))"
        )
        let detail = try XCTUnwrap(json as? [String: Any])

        XCTAssertEqual(detail["title"] as? String, "First thing")
        XCTAssertEqual(detail["description"] as? String, "One line of description.")
        XCTAssertEqual(detail["priority"] as? String, "high")
        XCTAssertEqual(detail["effort"] as? String, "M")
        let criteria = try XCTUnwrap(detail["criteria"] as? [[String: Any]])
        XCTAssertEqual(criteria.count, 2)
        XCTAssertEqual(criteria.first?["done"] as? Bool, true)
        XCTAssertEqual(criteria.last?["done"] as? Bool, false)
        _ = await runtime.shutdown()
    }

    // MARK: - The pane

    func testBoardRendersColumnsWithTheirTasks() async throws {
        let bridge = makeBridge()
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }
        XCTAssertTrue(rendered)

        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertTrue(labels.contains { $0.hasPrefix("Todo") && $0.contains("(2)") })
        XCTAssertTrue(labels.contains { $0.hasPrefix("Doing") && $0.contains("(1)") })
        XCTAssertTrue(labels.contains { $0.contains("First thing") && $0.contains("high/M") })
        _ = await runtime.shutdown()
    }

    // MARK: - The read

    /// T-052 regression: this repo's real board is 113 KB, and the pane showed
    /// "No board" although the file was right there. The read arrives one bounded page
    /// at a time; only a reader that follows every cursor sees the whole board.
    func testABoardLargerThanOneInlinePageRendersItsColumnsWithoutAnErrorRow() async throws {
        let board = Fixture.largeBoard()
        let bridge = makeBridge(
            files: [Self.rootA + "/.kanban/board.md": board.text]
        )
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-999") }
        }
        XCTAssertTrue(rendered, "the Done column lives on the last page; it must render")

        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertTrue(
            labels.contains { $0.hasPrefix("Todo") && $0.contains("(\(board.todoCount))") },
            "every Todo row on every page must be counted"
        )
        XCTAssertFalse(
            labels.contains {
                $0.hasPrefix("No board at") || $0.hasPrefix("Board read failed")
            },
            "a large board is not an error"
        )
        _ = await runtime.shutdown()
    }

    /// The one failure that really means "No board": the file does not exist.
    func testAMissingBoardFileStillRendersNoBoard() async throws {
        let bridge = makeBridge(files: [:])
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains("No board at " + Self.rootA + "/.kanban/board.md")
        }
        XCTAssertTrue(rendered, "path-not-found is the one failure that means no board")
        _ = await runtime.shutdown()
    }

    /// Honest errors: any other failure names its reason. "No board" for a read that
    /// failed some other way sends a human hunting for a file that was there all along.
    func testAFailedBoardReadNamesTheReasonInsteadOfClaimingNoBoard() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge(
            readFailureReasons: [boardPath: "path-is-directory"]
        )
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains("Board read failed: path-is-directory")
        }
        XCTAssertTrue(rendered, "a failed read must say why")
        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertFalse(
            labels.contains { $0.hasPrefix("No board at") },
            "the board exists; the pane must not claim it does not"
        )
        _ = await runtime.shutdown()
    }

    /// Another agent rewriting the board mid-read invalidates the cursor. The pane
    /// restarts the read from the first byte instead of rendering shifted bytes or an
    /// error — on this board, concurrent writers are the normal case.
    func testAReadInvalidatedMidPageRestartsAndStillRendersTheBoard() async throws {
        let board = Fixture.largeBoard()
        let bridge = makeBridge(
            files: [Self.rootA + "/.kanban/board.md": board.text],
            invalidatedCursorReads: 1
        )
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-999") }
        }
        XCTAssertTrue(rendered, "an invalidated page restarts the read; it does not fail it")
        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertFalse(
            labels.contains {
                $0.hasPrefix("No board at") || $0.hasPrefix("Board read failed")
            }
        )
        _ = await runtime.shutdown()
    }

    func testSelectingATaskRevealsItsDescriptionAndCriteria() async throws {
        let bridge = makeBridge()
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "task:T-101"
        )

        let revealed = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains("Something still open")
        }
        XCTAssertTrue(revealed, "selecting a task must show what it still owes")
        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertTrue(labels.contains("One line of description."))
        XCTAssertTrue(labels.contains { $0.contains("priority high") })
        _ = await runtime.shutdown()
    }

    /// The product point of the whole plugin: a click puts an agent on a task in a real
    /// PTY. The payload has to name the task file, or the agent starts without the brief.
    func testStartHandsTheTaskToAnAgentInANewTerminal() async throws {
        let bridge = makeBridge()
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "start",
            value: .string("task:T-101")
        )

        let sent = await eventually {
            await bridge.requests().contains {
                $0.intentID.rawValue == "terminal.open.v1"
            }
        }
        XCTAssertTrue(sent, "Start must reach terminal.open.v1")

        let opens = await bridge.requests().filter {
            $0.intentID.rawValue == "terminal.open.v1"
        }
        let request = try XCTUnwrap(opens.last)
        let input = try XCTUnwrap(request.input.objectValue)
        let command = try XCTUnwrap(input["command"]?.stringValue)
        XCTAssertTrue(command.hasPrefix("claude "), command)
        XCTAssertTrue(command.contains("T-101"), command)
        XCTAssertTrue(
            command.contains(".kanban/tasks/T-101-first.md"),
            "the prompt must point the agent at the task file: \(command)"
        )
        XCTAssertTrue(
            command.contains("CLAUDE.md"),
            "the prompt must send the agent to the workflow protocol: \(command)"
        )
        XCTAssertEqual(input["workingDirectory"]?.stringValue, Self.rootA)
        _ = await runtime.shutdown()
    }

    /// T-036's rule, for this plugin: the board belongs to the workspace that owns the
    /// pane, never to whichever workspace happens to be selected.
    func testTwoPanesEachFollowTheBoardOfTheirOwningWorkspace() async throws {
        let bridge = makeBridge()
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("board")
        XCTAssertTrue(instanced, "a singleton board cannot hold two workspaces at once")

        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneB)

        let bothRooted = await eventually {
            let views = await runtime.snapshot().views
            let a = views.first { $0.instanceID == Fixture.paneA }
            let b = views.first { $0.instanceID == Fixture.paneB }
            return a?.subtitle == Self.rootA + "/.kanban/board.md"
                && b?.subtitle == Self.rootB + "/.kanban/board.md"
        }
        XCTAssertTrue(bothRooted)

        // B's board has a task A's does not; neither pane may show the other's.
        let aLabels = await labels(of: runtime, instance: Fixture.paneA)
        let bLabels = await labels(of: runtime, instance: Fixture.paneB)
        XCTAssertTrue(aLabels.contains { $0.hasPrefix("T-101") })
        XCTAssertFalse(aLabels.contains { $0.hasPrefix("T-900") })
        XCTAssertTrue(bLabels.contains { $0.hasPrefix("T-900") })
        XCTAssertFalse(bLabels.contains { $0.hasPrefix("T-101") })
        _ = await runtime.shutdown()
    }

    // MARK: - The watcher

    /// A real edit on a real disk through real FSEvents — the same bar `ShippedPluginsTests`
    /// sets for hot reload. A mocked watcher would prove the plugin calls a function, not
    /// that a human editing the board sees it.
    func testEditingTheBoardOnDiskReachesThePane() async throws {
        let workspace = try makeTemporaryWorkspace()
        let boardPath = workspace + "/.kanban/board.md"
        try Fixture.board.write(
            toFile: boardPath,
            atomically: true,
            encoding: .utf8
        )

        let bridge = OnDiskBridge(workspacePath: workspace)
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        let initial = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }
        XCTAssertTrue(initial, "the pane must render the board that is on disk")

        try (Fixture.board + "\n- [T-777](tasks/T-777-late.md) Landed later — high/S\n")
            .write(toFile: boardPath, atomically: true, encoding: .utf8)

        let propagated = await eventually(attempts: 400) {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-777") }
        }
        XCTAssertTrue(
            propagated,
            "an on-disk board edit must reach the pane through fs.watch"
        )
        _ = await runtime.shutdown()
    }

    /// Several agents write this directory in bursts. Without coalescing, one board edit
    /// becomes a re-parse per filesystem event, which is how a supervision surface starts
    /// costing more than the work it supervises.
    func testABurstOfWritesCoalescesIntoOneReparse() async throws {
        let workspace = try makeTemporaryWorkspace()
        let boardPath = workspace + "/.kanban/board.md"
        try Fixture.board.write(toFile: boardPath, atomically: true, encoding: .utf8)

        let bridge = OnDiskBridge(workspacePath: workspace)
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }
        await bridge.resetReadCount()

        // Driven at the plugin's own debounce entry point rather than through the file
        // system. Writing eight files and counting reads measured FSEvents' coalescing,
        // not the plugin's: with the debounce deleted outright that version still passed,
        // because macOS had already merged the events before the plugin ever saw them.
        _ = try await runtime.evaluateForTesting(
            """
            (function () {
              var st = panes["\(Fixture.paneA)"];
              for (var i = 0; i < 8; i++) debouncedRefresh(st);
              return true;
            })()
            """
        )
        try? await Task.sleep(for: .milliseconds(600))

        let reads = await bridge.readCount()
        XCTAssertEqual(
            reads,
            1,
            "eight watch events produced \(reads) board reads — they must collapse into one"
        )
        _ = await runtime.shutdown()
    }

    /// Invariant 10: a retired generation owns nothing. A watcher that outlived its pane
    /// would keep firing into a context that no longer exists.
    func testClosingThePaneReleasesItsWatcherAndTimer() async throws {
        let workspace = try makeTemporaryWorkspace()
        try Fixture.board.write(
            toFile: workspace + "/.kanban/board.md",
            atomically: true,
            encoding: .utf8
        )
        let bridge = OnDiskBridge(workspacePath: workspace)
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }

        let watchingBefore = await paneField(
            runtime,
            instance: Fixture.paneA,
            expression: "!!(panes[\"\(Fixture.paneA)\"] || {}).watch"
        )
        XCTAssertEqual(watchingBefore, true, "the open pane must hold a watcher")

        try await runtime.closeViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let stateGone = await paneField(
            runtime,
            instance: Fixture.paneA,
            expression: "!panes[\"\(Fixture.paneA)\"]"
        )
        XCTAssertEqual(stateGone, true, "closing the pane must drop its state")

        await bridge.resetReadCount()
        try (Fixture.board + "\n- [T-999](tasks/x.md) After close — low/S\n")
            .write(
                toFile: workspace + "/.kanban/board.md",
                atomically: true,
                encoding: .utf8
            )
        try? await Task.sleep(for: .milliseconds(600))
        let reads = await bridge.readCount()
        XCTAssertEqual(
            reads,
            0,
            "a closed pane's watcher fired \(reads) reads — it was not cancelled"
        )
        _ = await runtime.shutdown()
    }

    // MARK: - Helpers

    private static let rootA = "/tmp/tenon-t041-ws-a"
    private static let rootB = "/tmp/tenon-t041-ws-b"

    private func makeBridge(
        files: [String: String]? = nil,
        readFailureReasons: [String: String] = [:],
        invalidatedCursorReads: Int = 0
    ) -> KanbanBridge {
        KanbanBridge(
            workspaces: [
                .init(id: Fixture.workspaceA, path: Self.rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: Self.rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            files: files ?? [
                Self.rootA + "/.kanban/board.md": Fixture.board,
                Self.rootA + "/.kanban/tasks/T-101-first.md": Fixture.taskFile,
                Self.rootB + "/.kanban/board.md": """
                ## Todo
                - [T-900](tasks/T-900-other.md) Other workspace — high/M
                """,
            ],
            readFailureReasons: readFailureReasons,
            invalidatedCursorReads: invalidatedCursorReads
        )
    }

    private func makeRuntime(bridge: any KanbanIntentBridge) throws -> PluginRuntime {
        let directory = Self.pluginsRoot.appendingPathComponent("kanban", isDirectory: true)
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginLoader.loadManifest(at: directory),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { request in await bridge.send(request) },
                    list: { .array([]) }
                )
            )
        )
    }

    private func labels(
        of runtime: PluginRuntime,
        instance: String
    ) async -> [String] {
        await runtime.snapshot().views
            .first { $0.instanceID == instance }?.items.map(\.label) ?? []
    }

    private func evaluateJSON(
        _ runtime: PluginRuntime,
        _ script: String
    ) async throws -> Any {
        let value = try await runtime.evaluateForTesting(script)
        let text = try XCTUnwrap(value.stringValue)
        return try JSONSerialization.jsonObject(
            with: Data(text.utf8),
            options: [.fragmentsAllowed]
        )
    }

    private func paneField(
        _ runtime: PluginRuntime,
        instance: String,
        expression: String
    ) async -> Bool? {
        guard let value = try? await runtime.evaluateForTesting(expression) else {
            return nil
        }
        return value.boolValue
    }

    private func jsString(_ text: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: text,
            options: [.fragmentsAllowed]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func makeTemporaryWorkspace() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t041-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".kanban/tasks"),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func eventually(
        attempts: Int = 200,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

// MARK: - Bridges

private protocol KanbanIntentBridge: Sendable {
    func send(_ request: PluginIntentSendRequest) async -> IntentResult
}

/// Answers `workspace.state.v1` for a fixed two-workspace catalog and serves board/task
/// files from memory, speaking `filesystem.file.read.v1`'s real contract: one bounded
/// page per reply, a cursor while bytes remain, a typed path-not-found failure for a
/// missing file. Used where the test is about parsing and rendering rather than about
/// the filesystem.
private actor KanbanBridge: KanbanIntentBridge {
    struct Workspace {
        let id: String
        let path: String
        let tabID: String
        let paneID: String
    }

    private let workspaces: [Workspace]
    private var selectedID: String
    private let files: [String: String]
    private let readFailureReasons: [String: String]
    private var invalidatedCursorReads: Int
    private var recorded: [PluginIntentSendRequest] = []

    init(
        workspaces: [Workspace],
        selectedID: String,
        files: [String: String],
        readFailureReasons: [String: String] = [:],
        invalidatedCursorReads: Int = 0
    ) {
        self.workspaces = workspaces
        self.selectedID = selectedID
        self.files = files
        self.readFailureReasons = readFailureReasons
        self.invalidatedCursorReads = invalidatedCursorReads
    }

    func requests() -> [PluginIntentSendRequest] { recorded }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        recorded.append(request)
        let value: IntentValue
        switch request.intentID.rawValue {
        case "workspace.state.v1":
            value = KanbanStateSnapshot.value(
                workspaces: workspaces.map {
                    (id: $0.id, path: $0.path, tabID: $0.tabID, paneID: $0.paneID)
                },
                selectedID: selectedID
            )
        case "filesystem.file.read.v1":
            let input = request.input.objectValue
            guard let path = input?["path"]?.stringValue else {
                return KanbanFileRead.pathNotFound()
            }
            if let reason = readFailureReasons[path] {
                return KanbanFileRead.failure(
                    code: "dev.tenon.core.filesystem-failed",
                    reason: reason
                )
            }
            guard let text = files[path] else {
                return KanbanFileRead.pathNotFound()
            }
            let cursor = input?["cursor"]?.stringValue
            if cursor != nil, invalidatedCursorReads > 0 {
                invalidatedCursorReads -= 1
                value = KanbanFileRead.invalidatedPage()
            } else {
                value = KanbanFileRead.page(of: text, cursor: cursor)
            }
        default:
            value = .object([:])
        }
        return .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }
}

/// Serves one workspace whose files are really on disk, so `fs.watch` has something real
/// to observe, and counts board reads so coalescing is measurable.
private actor OnDiskBridge: KanbanIntentBridge {
    private let workspacePath: String
    private var reads = 0

    init(workspacePath: String) {
        self.workspacePath = workspacePath
    }

    func readCount() -> Int { reads }
    func resetReadCount() { reads = 0 }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        let value: IntentValue
        switch request.intentID.rawValue {
        case "workspace.state.v1":
            value = KanbanStateSnapshot.value(
                workspaces: [(
                    id: "AAAAAAAA-0000-0000-0000-000000000041",
                    path: workspacePath,
                    tabID: "AAAAAAAA-1111-0000-0000-000000000041",
                    paneID: "AAAAAAAA-2222-0000-0000-000000000041"
                )],
                selectedID: "AAAAAAAA-0000-0000-0000-000000000041"
            )
        case "filesystem.file.read.v1":
            let input = request.input.objectValue
            guard let path = input?["path"]?.stringValue,
                  let text = try? String(contentsOfFile: path, encoding: .utf8)
            else {
                return KanbanFileRead.pathNotFound()
            }
            let cursor = input?["cursor"]?.stringValue
            // One refresh starts exactly one cursor-less read, so counting those keeps
            // the coalescing metric meaning "board refreshes", not "pages served".
            if path.hasSuffix("board.md"), cursor == nil { reads += 1 }
            value = KanbanFileRead.page(of: text, cursor: cursor)
        default:
            value = .object([:])
        }
        return .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }
}

/// `filesystem.file.read.v1` replies with the shape the shipped provider gives, over an
/// in-memory string: at most `maximumInlineTextCharacters` bytes per page, a
/// `"v1:<offset>:<identity>"` cursor while bytes remain, `invalidated` when the cursor's
/// identity no longer matches the text. Fixtures are ASCII, so pages split on byte
/// offsets without the provider's UTF-8 boundary back-off.
private enum KanbanFileRead {
    static func page(of text: String, cursor: String?) -> IntentValue {
        let bytes = Array(text.utf8)
        let identity = String(bytes.count)
        var offset = 0
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0] == "v1",
                  let parsed = Int(parts[1]),
                  parts[2] == identity
            else {
                return invalidatedPage()
            }
            offset = parsed
        }
        let end = min(
            offset + CoreIntentPayloadPolicy.maximumInlineTextCharacters,
            bytes.count
        )
        let page = Array(bytes[offset ..< end])
        return .object([
            "content": inline(String(decoding: page, as: UTF8.self)),
            "cursor": end < bytes.count ? .string("v1:\(end):\(identity)") : .null,
            "invalidated": .bool(false),
        ])
    }

    static func invalidatedPage() -> IntentValue {
        .object([
            "content": inline(""),
            "cursor": .null,
            "invalidated": .bool(true),
        ])
    }

    static func pathNotFound() -> IntentResult {
        failure(code: "dev.tenon.core.path-not-found", reason: "path-not-found")
    }

    static func failure(code: String, reason: String) -> IntentResult {
        .failure(
            error: IntentError(
                code: .domain(try! IntentDomainErrorCode(code)),
                details: .object(["reason": .string(reason)]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    private static func inline(_ text: String) -> IntentValue {
        .object([
            "kind": .string("inline"),
            "text": .string(text),
            "byteCount": .integer(Int64(text.utf8.count)),
        ])
    }
}

private enum KanbanStateSnapshot {
    static func value(
        workspaces: [(id: String, path: String, tabID: String, paneID: String)],
        selectedID: String
    ) -> IntentValue {
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
                    "pluginID": .string("dev.tenon.kanban"),
                    "viewID": .string("board"),
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
