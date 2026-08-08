import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-041/T-055: the shipped `kanban` plugin, driven as real JavaScript in a real runtime.
///
/// The plugin touches no host Swift — files arrive through the filesystem intent, the tree
/// is a CONTRIBUTION, the watch is a RESOURCE it owns, Start is `terminal.open.v1`, and a
/// card move rewrites the board through the paged `filesystem.file.write.v1`. These tests
/// are therefore also the claim that the public boundary is wide enough to build a real
/// feature on: if any of them needed a new host seam, it would not be here.
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
        let runtime = try await makeStartedRuntime(bridge: makeBridge())

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
    }

    func testTaskParserReadsDescriptionFieldsAndCriteriaState() async throws {
        let runtime = try await makeStartedRuntime(bridge: makeBridge())

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
    }

    // MARK: - The board tree (T-055)

    /// The pane is a real column/card board now: one `hstack` of column `vstack`s, each
    /// with a header (name + count badge) and one `card` per task carrying the id, the
    /// title, and the meta badge.
    func testBoardRendersColumnsSideBySideWithCountBadgesAndCards() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }
        XCTAssertTrue(rendered, "three column boxes must sit under the root hstack")

        let columns = await renderedColumns(of: runtime, instance: Fixture.paneA)
        XCTAssertEqual(columns.map(\.name), ["Todo", "Doing", "Done"])
        XCTAssertEqual(
            columns.map(\.count),
            ["2", "1", "0"],
            "every task line counts toward its column badge"
        )
        XCTAssertEqual(columns.map(\.cardIDs), [["T-101", "T-102"], ["T-103"], []])

        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertTrue(labels.contains("First thing"), "a card carries its task title")
        XCTAssertTrue(labels.contains("high/M"), "a card carries its meta badge")
    }

    /// The nodes that make the board read as a board rather than as scattered cards.
    /// Found by rendering the real tree offscreen, not by reading it: a bare `vstack`
    /// column collapses to the width of its own heading when it holds no cards, and a row
    /// of columns without the trailing `spacer` centres them against each other, so a
    /// short column floats in the middle of the pane beside a tall one. A card's title is
    /// its own node under the id line for the same reason — beside the id and the badge it
    /// wraps into a column of single words.
    ///
    /// T-066 adds the rule the pane could not express before: a column is a **fixed**
    /// width, identical for every column, and the row of them lives inside a horizontal
    /// `scroll`. Sharing the pane equally meant five columns on a narrow pane were five
    /// unreadable slivers; a fixed width instead lets the board run off the edge and be
    /// scrolled to, which is what a board does.
    func testEveryColumnIsAFixedWidthBoxInsideAHorizontalScroll() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        let rendered = await body(of: runtime, instance: Fixture.paneA)
        let body = try XCTUnwrap(rendered)
        let scroll = try XCTUnwrap(
            Self.firstScroll(in: body),
            "the board is wrapped in a scroll, or fixed columns fall off an unreachable edge"
        )
        guard case let .scroll(axis, _) = scroll else { return }
        XCTAssertEqual(axis, .horizontal, "the overflow a fixed-width board creates is sideways")

        let row = try XCTUnwrap(Self.columnRow(in: scroll), "the columns sit inside the scroll")
        let columns = Self.children(of: row)
        XCTAssertEqual(columns.count, 3)
        var widths: [Double?] = []
        for column in columns {
            guard case let .box(_, _, _, width, parts) = column else {
                XCTFail("a column must be a box — a vstack claims only its content's width")
                continue
            }
            widths.append(width)
            guard case .spacer = try XCTUnwrap(parts.last) else {
                XCTFail("a column must end in a spacer, or its cards centre in the row")
                continue
            }
        }
        XCTAssertEqual(
            widths.compactMap { $0 }.count,
            3,
            "every column declares a width; one that does not would stretch over the rest"
        )
        XCTAssertEqual(
            Set(widths.compactMap { $0 }).count,
            1,
            "all columns are the same width whatever they hold"
        )

        // The Todo column's first card: id line, then the title on its own line.
        guard case let .box(_, _, _, _, todo) = columns[0] else { return }
        let card = try XCTUnwrap(todo.first {
            if case .card = $0 { return true }
            return false
        })
        let cardParts = Self.children(of: card)
        guard case .hstack = cardParts.first else {
            return XCTFail("a card opens with its id line")
        }
        guard case let .text(title, _, _, _) = cardParts[1] else {
            return XCTFail("the title is the card's own line, not a neighbour of the id")
        }
        XCTAssertEqual(title, "First thing")
    }

    /// ◀ appears only when a column exists to the left, ▶ only when one exists to the
    /// right; every card offers Start. A single-column board moves nothing anywhere.
    func testMoveButtonsFollowTheColumnPosition() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneB)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneB).count == 1
        }

        let bodyA = await body(of: runtime, instance: Fixture.paneA)
        let first = Self.buttons(in: Self.card(withID: "T-101", in: bodyA)).map(\.action)
        XCTAssertFalse(
            first.contains("move-left:T-101"),
            "the first column has nothing to its left"
        )
        XCTAssertTrue(first.contains("move-right:T-101"))
        XCTAssertTrue(first.contains("start:T-101"), "every card offers Start")

        let middle = Self.buttons(in: Self.card(withID: "T-103", in: bodyA)).map(\.action)
        XCTAssertTrue(middle.contains("move-left:T-103"))
        XCTAssertTrue(middle.contains("move-right:T-103"))

        let bodyB = await body(of: runtime, instance: Fixture.paneB)
        let only = Self.buttons(in: Self.card(withID: "T-900", in: bodyB)).map(\.action)
        XCTAssertFalse(only.contains("move-left:T-900"))
        XCTAssertFalse(
            only.contains("move-right:T-900"),
            "a single-column board has no adjacent column in either direction"
        )
    }

    /// Bounds survive the new tree (invariant 10): a column renders at most twelve cards
    /// and names how many it clipped, instead of however long the file got.
    func testAColumnCapsAtTwelveCardsAndNamesTheOverflow() async throws {
        let board = Fixture.largeBoard()
        let bridge = makeBridge(
            files: [Self.rootA + "/.kanban/board.md": board.text]
        )
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 2
        }
        XCTAssertTrue(rendered)

        let columns = await renderedColumns(of: runtime, instance: Fixture.paneA)
        let todo = try XCTUnwrap(columns.first)
        XCTAssertEqual(todo.cardIDs.count, 12, "a column renders at most twelve cards")
        XCTAssertEqual(
            todo.more,
            "… \(board.todoCount - 12) more",
            "the clip must say how much it hid"
        )
        XCTAssertEqual(todo.count, "\(board.todoCount)", "the badge counts every task")
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
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-999") }
        }
        XCTAssertTrue(rendered, "the Done column lives on the last page; it must render")

        let columns = await renderedColumns(of: runtime, instance: Fixture.paneA)
        XCTAssertEqual(
            columns.first?.count,
            "\(board.todoCount)",
            "every Todo row on every page must be counted"
        )
        let labels = await labels(of: runtime, instance: Fixture.paneA)
        XCTAssertFalse(
            labels.contains {
                $0.hasPrefix("No board at") || $0.hasPrefix("Board read failed")
            },
            "a large board is not an error"
        )
    }

    /// The one failure that really means "No board": the file does not exist.
    func testAMissingBoardFileStillRendersNoBoard() async throws {
        let bridge = makeBridge(files: [:])
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)

        let rendered = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains("No board at " + Self.rootA + "/.kanban/board.md")
        }
        XCTAssertTrue(rendered, "path-not-found is the one failure that means no board")
    }

    /// Honest errors: any other failure names its reason. "No board" for a read that
    /// failed some other way sends a human hunting for a file that was there all along.
    func testAFailedBoardReadNamesTheReasonInsteadOfClaimingNoBoard() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge(
            readFailureReasons: [boardPath: "path-is-directory"]
        )
        let runtime = try await makeStartedRuntime(bridge: bridge)
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
        let runtime = try await makeStartedRuntime(bridge: bridge)
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
    }

    /// T-066: More opens the task in the modal rather than growing the card.
    ///
    /// A card is one column wide. Expanding the detail inside it pushed every card below
    /// it down the column and still had to wrap the criteria into single words, so the
    /// detail now gets a sheet the size of the window. The card keeps its own size no
    /// matter which task is open — asserted here, because the inline expansion is gone
    /// rather than merely unused.
    func testMoreOpensTheTaskInAModalAndLeavesTheCardUnchanged() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }
        let cardBefore = await Self.card(
            withID: "T-101",
            in: body(of: runtime, instance: Fixture.paneA)
        )

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "more:T-101"
        )

        let opened = await eventually {
            await Self.texts(in: self.modal(of: runtime, instance: Fixture.paneA)?.body)
                .contains("Something still open")
        }
        XCTAssertTrue(opened, "More must show what the task still owes, in the modal")

        let published = await self.modal(of: runtime, instance: Fixture.paneA)
        let modal = try XCTUnwrap(published)
        XCTAssertTrue(modal.title.contains("T-101"), "the sheet names the task it is showing")
        let inModal = Self.texts(in: modal.body)
        XCTAssertTrue(inModal.contains("One line of description."))
        XCTAssertTrue(inModal.contains { $0.contains("priority high") })

        let cardAfter = await Self.card(
            withID: "T-101",
            in: body(of: runtime, instance: Fixture.paneA)
        )
        XCTAssertEqual(
            cardAfter,
            cardBefore,
            "opening the detail must not change the card — that was the inline expansion"
        )
    }

    /// Dismissal is the plugin's decision, not the host's: Escape, the backdrop, and the
    /// close control all deliver the modal's action id here, and only this handler takes
    /// the modal away. A host that cleared it itself would leave the plugin believing a
    /// task is still open.
    func testDismissingTheModalClosesItThroughThePluginsOwnAction() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }
        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "more:T-101"
        )
        _ = await eventually { await self.modal(of: runtime, instance: Fixture.paneA) != nil }

        let opened = await self.modal(of: runtime, instance: Fixture.paneA)
        let dismiss = try XCTUnwrap(opened).dismissAction
        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: dismiss
        )

        let closed = await eventually {
            await self.modal(of: runtime, instance: Fixture.paneA) == nil
        }
        XCTAssertTrue(closed, "the dismiss action the modal published must close it")
    }

    /// T-066: the modal is where a started agent is watched.
    ///
    /// Start opens the agent's pane and the modal then follows *that* pane —
    /// `terminal.viewport.read.v1` under the pane's own invocation scope — showing whether
    /// it is still running and the tail of what it printed. Reading the viewport rather
    /// than paging the whole scrollback is deliberate: the question a supervisor asks a
    /// running agent is "what is it doing now", and the answer is one bounded read
    /// however long the run gets (VISION: evidence-linked compression).
    func testStartTracksTheAgentPaneInTheModal() async throws {
        let bridge = makeBridge()
        await bridge.setViewport(text: "> claude 'Do task T-101'\nReading the task file\n")
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "start:T-101"
        )

        let tracking = await eventually(attempts: 400) {
            await Self.texts(in: self.modal(of: runtime, instance: Fixture.paneA)?.body)
                .contains { $0.contains("Reading the task file") }
        }
        XCTAssertTrue(
            tracking,
            "Start must open the modal on the pane it started and show its output"
        )

        let running = Self.texts(in: await modal(of: runtime, instance: Fixture.paneA)?.body)
        XCTAssertTrue(
            running.contains { $0.lowercased().contains("running") },
            "a live pane reads as running: \(running)"
        )

        // The scope is the started pane, not the kanban pane: a read without it would
        // report whatever terminal happens to be focused.
        let reads = await bridge.requests().filter {
            $0.intentID.rawValue == "terminal.viewport.read.v1"
        }
        let scoped = try XCTUnwrap(reads.last)
        XCTAssertEqual(
            scoped.scopeOverride?.paneID?.uuidString.lowercased(),
            KanbanBridge.agentPaneID.lowercased(),
            "the viewport read is scoped to the pane Start opened"
        )

        await bridge.setViewport(text: "Done.\n", exited: true)
        let ended = await eventually(attempts: 400) {
            let texts = await Self.texts(in: self.modal(of: runtime, instance: Fixture.paneA)?.body)
            return texts.contains { $0.lowercased().contains("exited") }
        }
        XCTAssertTrue(ended, "a pane that exited must stop reading as running")
    }

    /// The product point of the whole plugin: a click puts an agent on a task in a real
    /// PTY. The payload has to name the task file, or the agent starts without the brief.
    func testStartHandsTheTaskToAnAgentInANewTerminal() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "start:T-101"
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
    }

    /// T-036's rule, for this plugin: the board belongs to the workspace that owns the
    /// pane, never to whichever workspace happens to be selected.
    func testTwoPanesEachFollowTheBoardOfTheirOwningWorkspace() async throws {
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)

        let instanced = await runtime.isViewInstanced("board")
        XCTAssertTrue(instanced, "a singleton board cannot hold two workspaces at once")

        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneB)

        let bothRooted = await eventually {
            let views = await runtime.snapshot().views
            let a = views.first { $0.instanceID == Fixture.paneA }
            let b = views.first { $0.instanceID == Fixture.paneB }
            return Self.publishedBoardPath(of: a) == Self.rootA + "/.kanban/board.md"
                && Self.publishedBoardPath(of: b) == Self.rootB + "/.kanban/board.md"
        }
        XCTAssertTrue(bothRooted)

        // B's board has a task A's does not; neither pane may show the other's.
        let aLabels = await labels(of: runtime, instance: Fixture.paneA)
        let bLabels = await labels(of: runtime, instance: Fixture.paneB)
        XCTAssertTrue(aLabels.contains { $0.hasPrefix("T-101") })
        XCTAssertFalse(aLabels.contains { $0.hasPrefix("T-900") })
        XCTAssertTrue(bLabels.contains { $0.hasPrefix("T-900") })
        XCTAssertFalse(bLabels.contains { $0.hasPrefix("T-101") })
    }

    // MARK: - The move (T-055)

    /// ▶ re-reads the board first, then rewrites it: another agent's edit that landed
    /// after this pane last rendered must survive the move byte-for-byte. A board that
    /// fits one page goes through today's single-page call — exactly `path` + `content`.
    func testMoveReReadsTheBoardFreshAndRewritesOnlyTheMovedLine() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        // Lands on disk after the pane rendered; no watcher fires in this bridge, so
        // only a fresh read before the rewrite can see it.
        let t101 = "- [T-101](tasks/T-101-first.md) First thing — high/M"
        let t103 = "- [T-103](tasks/T-103-third.md) Third thing — low/L"
        let changed = Fixture.board
            + "\n- [T-104](tasks/T-104-fourth.md) Fourth thing — low/S"
        await bridge.setFile(boardPath, to: changed)
        let expected = changed
            .replacingOccurrences(of: "\n" + t101, with: "")
            .replacingOccurrences(of: t103, with: t103 + "\n" + t101)

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-right:T-101"
        )

        let written = await eventually {
            await bridge.fileContents(boardPath) == expected
        }
        let contents = await bridge.fileContents(boardPath)
        XCTAssertTrue(
            written,
            "the moved line changes column and every other byte survives; got:\n"
                + (contents ?? "nil")
        )

        let writes = await bridge.requests().filter {
            $0.intentID.rawValue == "filesystem.file.write.v1"
        }
        XCTAssertEqual(writes.count, 1, "a one-page board needs exactly one write")
        let input = try XCTUnwrap(writes.first?.input.objectValue)
        XCTAssertEqual(
            input.keys.sorted(),
            ["content", "path"],
            "a single-page write keeps today's call shape — no cursor, no commit field"
        )

        let refreshed = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA)
                .map(\.count) == ["1", "2", "1"]
        }
        XCTAssertTrue(refreshed, "after the move the pane re-renders from the new board")
    }

    /// Moving into a column with no tasks appends the line directly under its heading.
    func testMoveIntoAnEmptyColumnAppendsUnderItsHeading() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        let t103 = "- [T-103](tasks/T-103-third.md) Third thing — low/L"
        let expected = Fixture.board
            .replacingOccurrences(of: "\n" + t103, with: "")
            .replacingOccurrences(of: "## Done", with: "## Done\n" + t103)

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-right:T-103"
        )

        let written = await eventually {
            await bridge.fileContents(boardPath) == expected
        }
        let contents = await bridge.fileContents(boardPath)
        XCTAssertTrue(
            written,
            "the line lands under the empty column's heading; got:\n" + (contents ?? "nil")
        )
    }

    /// The move and the parser share one heading predicate: a bare "## " stub line —
    /// a board half-written by another agent, the normal case here — is not a column
    /// for either. A move that counted it would compute its target against columns the
    /// pane never drew and land the line under a phantom heading.
    func testMoveSkipsABareHeadingStubExactlyAsTheParserDoes() async throws {
        let runtime = try await makeStartedRuntime(bridge: makeBridge())
        // Built line by line: the stub is "## " with a trailing space, which a string
        // literal would invite an editor to strip.
        let stub = [
            "# Board",
            "",
            "## Todo",
            "- [T-1](tasks/T-1-alpha.md) Alpha — high/S",
            "",
            "## ",
            "",
            "## Done",
            "",
        ].joined(separator: "\n")

        let json = try await evaluateJSON(
            runtime,
            "JSON.stringify(parseBoard(relocateTaskLine(\(jsString(stub)), \"T-1\", 1).text))"
        )
        let columns = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertEqual(columns.map { $0["name"] as? String }, ["Todo", "Done"])
        let todo = try XCTUnwrap(columns.first?["tasks"] as? [[String: Any]])
        XCTAssertTrue(todo.isEmpty, "the moved line must leave Todo")
        let done = try XCTUnwrap(columns.last?["tasks"] as? [[String: Any]])
        XCTAssertEqual(
            done.map { $0["id"] as? String },
            ["T-1"],
            "▶ from Todo lands in Done, the column the pane actually drew next"
        )
    }

    /// One id in two columns is a real board state here — the workflow doc's stale
    /// copy that "reads as free work". Every button resolves an id to its first
    /// occurrence (findTask, render, Start), so the move must relocate that same line,
    /// never the later duplicate.
    func testMoveRelocatesTheFirstOccurrenceWhenAnIDIsDuplicated() async throws {
        let runtime = try await makeStartedRuntime(bridge: makeBridge())
        let duplicated = [
            "## Todo",
            "- [T-200](tasks/T-200-x.md) Stale copy — high/S",
            "",
            "## Doing",
            "- [T-200](tasks/T-200-x.md) Live claim — high/S",
            "",
            "## Done",
            "",
        ].joined(separator: "\n")

        let json = try await evaluateJSON(
            runtime,
            "JSON.stringify(parseBoard(relocateTaskLine(\(jsString(duplicated)), \"T-200\", 1).text))"
        )
        let columns = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertEqual(columns.map { $0["name"] as? String }, ["Todo", "Doing", "Done"])
        let todo = try XCTUnwrap(columns.first?["tasks"] as? [[String: Any]])
        XCTAssertTrue(todo.isEmpty, "the clicked card is the first occurrence; it moves")
        let doing = try XCTUnwrap(columns[1]["tasks"] as? [[String: Any]])
        XCTAssertEqual(
            doing.map { $0["title"] as? String },
            ["Live claim", "Stale copy"],
            "the duplicate already in Doing stays exactly where it was"
        )
        let done = try XCTUnwrap(columns.last?["tasks"] as? [[String: Any]])
        XCTAssertTrue(done.isEmpty, "the live claim must not be pushed on to Done")
    }

    /// A workspace switch can rebind `st.boardPath` while a move is between its read
    /// and its write — a 113 KB board is several paged reads (T-036 moves the pane,
    /// `workspace.changed` rebinds it). The move belongs to the board that rendered
    /// the click: one path, captured once, read and written at the same place — never
    /// workspace A's board renamed over workspace B's.
    func testMoveWritesTheBoardItReadEvenWhenThePaneIsReboundMidMove() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let boardPathB = Self.rootB + "/.kanban/board.md"
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }
        let boardB = await bridge.fileContents(boardPathB)

        // Rebinds the pane to workspace B's board on every access after the first —
        // exactly what the workspace.changed handler does when it lands mid-move.
        _ = try await runtime.evaluateForTesting(
            """
            (function () {
              var st = panes["\(Fixture.paneA)"];
              var first = st.boardPath;
              var accesses = 0;
              Object.defineProperty(st, "boardPath", {
                configurable: true,
                get: function () {
                  accesses += 1;
                  return accesses === 1 ? first : "\(Self.rootB)/.kanban/board.md";
                }
              });
              return true;
            })()
            """
        )

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-right:T-101"
        )

        let t101 = "- [T-101](tasks/T-101-first.md) First thing — high/M"
        let t103 = "- [T-103](tasks/T-103-third.md) Third thing — low/L"
        let expected = Fixture.board
            .replacingOccurrences(of: "\n" + t101, with: "")
            .replacingOccurrences(of: t103, with: t103 + "\n" + t101)
        let written = await eventually {
            await bridge.fileContents(boardPath) == expected
        }
        XCTAssertTrue(written, "the move lands on the board the click was read from")

        let writes = await bridge.requests().filter {
            $0.intentID.rawValue == "filesystem.file.write.v1"
        }
        XCTAssertEqual(
            writes.compactMap { $0.input.objectValue?["path"]?.stringValue },
            [boardPath],
            "a mid-move rebind must not redirect the write to the new workspace's board"
        )
        let untouchedB = await bridge.fileContents(boardPathB)
        XCTAssertEqual(untouchedB, boardB, "workspace B's board survives byte-for-byte")
    }

    /// Two clicks a beat apart are two moves, not a coin flip: moves on one pane run
    /// strictly one after another, each computed against the board the previous one
    /// committed. Neither `invokeViewSelect` awaits the async handler, so without
    /// serialization both moves read the same original board and the second commit
    /// silently swallows the first.
    func testTwoRapidMovesOnOnePaneBothApplyInOrder() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge()
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-right:T-101"
        )
        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-right:T-101"
        )

        let t101 = "- [T-101](tasks/T-101-first.md) First thing — high/M"
        let expected = Fixture.board
            .replacingOccurrences(of: "\n" + t101, with: "")
            .replacingOccurrences(of: "## Done", with: "## Done\n" + t101)
        let settled = await eventually {
            await bridge.fileContents(boardPath) == expected
        }
        let contents = await bridge.fileContents(boardPath)
        XCTAssertTrue(
            settled,
            "▶▶ is Todo → Doing → Done, both moves applied; got:\n" + (contents ?? "nil")
        )

        let refreshed = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA)
                .map(\.count) == ["1", "1", "1"]
        }
        XCTAssertTrue(refreshed, "the pane re-renders the doubly moved board")
    }

    /// The reason T-055 needed a host change at all: the real board is 113 KB and one
    /// write page holds 48 KB. The move must stream staged pages — first page opens the
    /// staging, middle pages carry the cursor, the last page commits — and the committed
    /// bytes must be the whole board with exactly one line repositioned.
    func testMoveRewritesALargeBoardThroughStagedPagesAndACommit() async throws {
        let board = Fixture.largeBoard()
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge(files: [boardPath: board.text])
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 2
        }

        let t999 = "- [T-999](tasks/T-999-last.md) Landed on the last page — high/S"
        let lastID = 10_000 + board.todoCount
        let lastFiller =
            "- [T-\(lastID)](tasks/T-\(lastID)-filler.md) Filler task number \(board.todoCount) — low/S"
        let expected = board.text
            .replacingOccurrences(of: "\n" + t999, with: "")
            .replacingOccurrences(of: lastFiller, with: lastFiller + "\n" + t999)

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-left:T-999"
        )

        let committed = await eventually {
            await bridge.fileContents(boardPath) == expected
        }
        XCTAssertTrue(committed, "the committed board must be byte-identical to expected")

        let writes = await bridge.requests().filter {
            $0.intentID.rawValue == "filesystem.file.write.v1"
        }
        XCTAssertGreaterThanOrEqual(
            writes.count,
            3,
            "a >96 KB board cannot land in fewer than three bounded pages"
        )
        var streamed = ""
        for (index, write) in writes.enumerated() {
            let input = try XCTUnwrap(write.input.objectValue)
            let content = try XCTUnwrap(input["content"]?.objectValue)
            let text = try XCTUnwrap(content["text"]?.stringValue)
            XCTAssertLessThanOrEqual(
                text.utf8.count,
                CoreIntentPayloadPolicy.maximumInlineTextCharacters,
                "every page stays inside the inline bound"
            )
            streamed += text
            let isFirst = index == 0
            let isLast = index == writes.count - 1
            if isFirst {
                XCTAssertNil(input["cursor"], "the first page opens the staging")
            } else {
                XCTAssertNotNil(input["cursor"], "every later page continues the staging")
            }
            if isLast {
                XCTAssertNotEqual(
                    input["commit"],
                    .bool(false),
                    "the last page commits"
                )
            } else {
                XCTAssertEqual(
                    input["commit"],
                    .bool(false),
                    "no page before the last may publish"
                )
            }
        }
        XCTAssertEqual(streamed, expected, "the pages concatenate to the whole board")

        let refreshed = await eventually {
            let columns = await self.renderedColumns(of: runtime, instance: Fixture.paneA)
            return columns.map(\.count) == ["\(board.todoCount + 1)", "0"]
        }
        XCTAssertTrue(refreshed, "after the commit the pane re-renders the moved board")
    }

    /// A write that fails must never lose the move silently: the pane names the reason
    /// and re-reads the board from disk, which still holds the untouched bytes.
    func testAFailedBoardWriteRendersItsReasonAndRefreshesFromDisk() async throws {
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge(writeFailureReason: "disk-full")
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 3
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-right:T-101"
        )

        let reported = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains("Board write failed: disk-full")
        }
        XCTAssertTrue(reported, "a failed write must say why, in the pane")

        let untouched = await bridge.fileContents(boardPath)
        XCTAssertEqual(untouched, Fixture.board, "a failed write changes nothing")

        let requests = await bridge.requests()
        let lastWrite = try XCTUnwrap(
            requests.lastIndex { $0.intentID.rawValue == "filesystem.file.write.v1" }
        )
        XCTAssertTrue(
            requests.indices.contains { index in
                index > lastWrite
                    && requests[index].intentID.rawValue == "filesystem.file.read.v1"
                    && requests[index].input.objectValue?["path"]?.stringValue == boardPath
            },
            "after the failure the board is re-read from disk"
        )
        let columns = await renderedColumns(of: runtime, instance: Fixture.paneA)
        XCTAssertEqual(
            columns.map(\.count),
            ["2", "1", "0"],
            "the pane still shows the board that is actually on disk"
        )
    }

    /// A staging invalidated mid-sequence (expired, swept, or raced) fails closed on the
    /// host. The plugin's job is the honest half: report it, leave no partial state, and
    /// show the board the disk still holds.
    func testAnInvalidatedWriteCursorLeavesNoPartialStateAndReportsHonestly() async throws {
        let board = Fixture.largeBoard()
        let boardPath = Self.rootA + "/.kanban/board.md"
        let bridge = makeBridge(
            files: [boardPath: board.text],
            invalidatedWriteCursors: 1
        )
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.renderedColumns(of: runtime, instance: Fixture.paneA).count == 2
        }

        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: Fixture.paneA,
            itemID: "move-left:T-999"
        )

        let reported = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains("Board write failed: tenon.invalid-input")
        }
        XCTAssertTrue(reported, "an invalidated staging must be reported, not swallowed")

        let untouched = await bridge.fileContents(boardPath)
        XCTAssertEqual(untouched, board.text, "no page of the abandoned staging landed")

        let requests = await bridge.requests()
        let lastWrite = try XCTUnwrap(
            requests.lastIndex { $0.intentID.rawValue == "filesystem.file.write.v1" }
        )
        XCTAssertTrue(
            requests.indices.contains { index in
                index > lastWrite
                    && requests[index].intentID.rawValue == "filesystem.file.read.v1"
                    && requests[index].input.objectValue?["path"]?.stringValue == boardPath
            },
            "after the invalidation the board is re-read from disk"
        )
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
        let runtime = try await makeStartedRuntime(bridge: bridge)
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
    }

    /// Several agents write this directory in bursts. Without coalescing, one board edit
    /// becomes a re-parse per filesystem event, which is how a supervision surface starts
    /// costing more than the work it supervises.
    func testABurstOfWritesCoalescesIntoOneReparse() async throws {
        let workspace = try makeTemporaryWorkspace()
        let boardPath = workspace + "/.kanban/board.md"
        try Fixture.board.write(toFile: boardPath, atomically: true, encoding: .utf8)

        let bridge = OnDiskBridge(workspacePath: workspace)
        let runtime = try await makeStartedRuntime(bridge: bridge)
        try await runtime.openViewInstance(viewID: "board", instanceID: Fixture.paneA)
        _ = await eventually {
            await self.labels(of: runtime, instance: Fixture.paneA)
                .contains { $0.hasPrefix("T-101") }
        }
        await bridge.resetReadCount()
        let armedBefore = await runtime.resourceCounts.timers

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

        // T-074: the rule is "a burst arms one refresh", and the generation's live timer
        // count says so outright. The burst is a single synchronous evaluation, so no timer
        // can fire inside it — the reading below is a fact about the plugin's bookkeeping,
        // not a race against a debounce window. The earlier version slept 600 ms and counted
        // reads, which measured how busy the machine was: a late FSEvent from the fixture's
        // own board write lands as a second read, and a slow turn leaves the first one
        // unfired. It failed about one full-suite run in three for those reasons.
        //
        // Counted as a delta because the pane also holds a repeating tracking timer, which
        // is not this rule's business.
        let armedAfter = await runtime.resourceCounts.timers
        XCTAssertEqual(
            armedAfter - armedBefore,
            1,
            "eight refresh requests armed \(armedAfter - armedBefore) timers — they must "
                + "collapse into one"
        )

        // And the one that survives does refresh the board. Waiting on the fact rather than
        // on a duration: `>=` because a stray filesystem event may legitimately add another.
        let refreshed = await eventually { await bridge.readCount() >= 1 }
        XCTAssertTrue(refreshed, "the surviving debounce timer never re-read the board")
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
        let runtime = try await makeStartedRuntime(bridge: bridge)
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
    }

    // MARK: - Helpers

    private static let rootA = "/tmp/tenon-t041-ws-a"
    private static let rootB = "/tmp/tenon-t041-ws-b"

    private func makeBridge(
        files: [String: String]? = nil,
        readFailureReasons: [String: String] = [:],
        invalidatedCursorReads: Int = 0,
        writeFailureReason: String? = nil,
        invalidatedWriteCursors: Int = 0
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
            invalidatedCursorReads: invalidatedCursorReads,
            writeFailureReason: writeFailureReason,
            invalidatedWriteCursors: invalidatedWriteCursors
        )
    }

    /// Starts the runtime and owns its teardown: a test that throws mid-body (a failed
    /// `XCTUnwrap`, say) must still shut the runtime down, or its release preconditions
    /// and takes the rest of the suite with it.
    private func makeStartedRuntime(
        bridge: any KanbanIntentBridge
    ) async throws -> PluginRuntime {
        let runtime = try makeRuntime(bridge: bridge)
        _ = try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        return runtime
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

    private func body(
        of runtime: PluginRuntime,
        instance: String
    ) async -> PluginViewNode? {
        await runtime.snapshot().views
            .first { $0.instanceID == instance }?.body
    }

    private func modal(
        of runtime: PluginRuntime,
        instance: String
    ) async -> PluginViewModal? {
        await runtime.snapshot().views
            .first { $0.instanceID == instance }?.modal
    }

    /// The board this pane says it is showing, read off the `board` label the view publishes
    /// into its pane's chrome header — the one thing two panes of this view display
    /// differently, and so the observable this file's per-workspace rooting proof stands on.
    private static func publishedBoardPath(of view: PluginViewInfo?) -> String? {
        guard case let .label(_, text, _, _, _, _) = view?.header.leading.first else {
            return nil
        }
        return text
    }

    private static func firstScroll(in node: PluginViewNode) -> PluginViewNode? {
        if case .scroll = node { return node }
        for child in children(of: node) {
            if let found = firstScroll(in: child) { return found }
        }
        return nil
    }

    /// Every human-visible string in the pane, row items and body tree alike, so the
    /// honest-error assertions read the same whichever way the pane rendered.
    private func labels(
        of runtime: PluginRuntime,
        instance: String
    ) async -> [String] {
        guard let view = await runtime.snapshot().views
            .first(where: { $0.instanceID == instance })
        else {
            return []
        }
        return view.items.map(\.label) + Self.texts(in: view.body)
    }

    /// The board tree, structurally: the first `hstack` under the root holds one
    /// `vstack` per column — header text + count badge, cards, an optional clip row.
    private struct RenderedColumn: Equatable {
        let name: String
        let count: String
        let cardIDs: [String]
        let more: String?
    }

    private func renderedColumns(
        of runtime: PluginRuntime,
        instance: String
    ) async -> [RenderedColumn] {
        guard let body = await body(of: runtime, instance: instance),
              let columnsNode = Self.columnRow(in: body),
              case let .hstack(_, columnNodes) = columnsNode
        else {
            return []
        }
        return columnNodes.compactMap { columnNode in
            // A column is a `box`: the node that claims the full width offered to it, so
            // every column takes an equal share of the pane and an empty one still holds
            // its place instead of collapsing to the width of its heading.
            guard case let .box(_, _, _, _, parts) = columnNode,
                  let headerNode = parts.first,
                  case let .hstack(_, header) = headerNode
            else {
                return nil
            }
            var name = ""
            var count = ""
            for node in header {
                if case let .text(value, _, _, _) = node, name.isEmpty { name = value }
                if case let .badge(value, _) = node { count = value }
            }
            var cardIDs: [String] = []
            var more: String?
            for part in parts.dropFirst() {
                switch part {
                case let .card(children):
                    if let id = Self.cardID(children) { cardIDs.append(id) }
                case let .text(value, _, _, _):
                    more = value
                default:
                    break
                }
            }
            return RenderedColumn(name: name, count: count, cardIDs: cardIDs, more: more)
        }
    }

    /// The row of columns, wherever the tree puts it: it sits inside the horizontal
    /// `scroll` now, so finding it by walking rather than by position keeps every
    /// board assertion independent of how the board is wrapped.
    private static func columnRow(in node: PluginViewNode) -> PluginViewNode? {
        if case .hstack = node, !children(of: node).isEmpty,
           children(of: node).allSatisfy({
               if case .box = $0 { return true }
               return false
           })
        {
            return node
        }
        for child in children(of: node) {
            if let found = columnRow(in: child) { return found }
        }
        return nil
    }

    private static func cardID(_ children: [PluginViewNode]) -> String? {
        for child in children {
            if case let .hstack(_, header) = child {
                for node in header {
                    if case let .text(value, _, _, _) = node { return value }
                }
            }
        }
        return nil
    }

    private static func children(of node: PluginViewNode) -> [PluginViewNode] {
        switch node {
        case let .vstack(_, children), let .hstack(_, children), let .card(children),
             let .grid(_, _, children), let .field(_, children),
             let .scroll(_, children):
            return children
        case let .box(_, _, _, _, children):
            return children
        default:
            return []
        }
    }

    private static func texts(in node: PluginViewNode?) -> [String] {
        guard let node else { return [] }
        var out: [String] = []
        switch node {
        case let .text(value, _, _, _):
            out.append(value)
        case let .badge(value, _):
            out.append(value)
        case let .button(label, _, _):
            out.append(label)
        case let .stat(label, value), let .keyValue(label, value, _):
            out.append(label)
            out.append(value)
        default:
            break
        }
        for child in children(of: node) {
            out.append(contentsOf: texts(in: child))
        }
        return out
    }

    private static func card(
        withID id: String,
        in node: PluginViewNode?
    ) -> PluginViewNode? {
        guard let node else { return nil }
        if case let .card(children) = node, cardID(children) == id { return node }
        for child in children(of: node) {
            if let found = card(withID: id, in: child) { return found }
        }
        return nil
    }

    private static func buttons(
        in node: PluginViewNode?
    ) -> [(label: String, action: String)] {
        guard let node else { return [] }
        var out: [(label: String, action: String)] = []
        if case let .button(label, action, _) = node {
            out.append((label: label, action: action))
        }
        for child in children(of: node) {
            out.append(contentsOf: buttons(in: child))
        }
        return out
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
/// files from memory, speaking `filesystem.file.read.v1`'s real paged contract and
/// `filesystem.file.write.v1`'s real staged contract: one bounded page per call, a
/// `v1:<bytes>:<token>` cursor while a staging is open, commit as the only step that
/// publishes, and every malformed/foreign/out-of-sequence cursor failing closed as
/// `tenon.invalid-input`. Used where the test is about parsing, rendering, and moving
/// rather than about the filesystem.
private actor KanbanBridge: KanbanIntentBridge {
    struct Workspace {
        let id: String
        let path: String
        let tabID: String
        let paneID: String
    }

    private struct WriteStaging {
        let target: String
        var text: String
    }

    private let workspaces: [Workspace]
    private var selectedID: String
    private var files: [String: String]
    private let readFailureReasons: [String: String]
    private var invalidatedCursorReads: Int
    private let writeFailureReason: String?
    private var invalidatedWriteCursors: Int
    private var writeStagings: [String: WriteStaging] = [:]
    private var recorded: [PluginIntentSendRequest] = []
    /// The pane `terminal.open.v1` hands back, and what a read of it currently shows —
    /// enough of the terminal contract for the modal's run tracking (T-066).
    static let agentPaneID = "CCCCCCCC-3333-0000-0000-000000000041"
    private var viewportText = ""
    private var viewportExited = false

    init(
        workspaces: [Workspace],
        selectedID: String,
        files: [String: String],
        readFailureReasons: [String: String] = [:],
        invalidatedCursorReads: Int = 0,
        writeFailureReason: String? = nil,
        invalidatedWriteCursors: Int = 0
    ) {
        self.workspaces = workspaces
        self.selectedID = selectedID
        self.files = files
        self.readFailureReasons = readFailureReasons
        self.invalidatedCursorReads = invalidatedCursorReads
        self.writeFailureReason = writeFailureReason
        self.invalidatedWriteCursors = invalidatedWriteCursors
    }

    func requests() -> [PluginIntentSendRequest] { recorded }

    func fileContents(_ path: String) -> String? { files[path] }

    func setViewport(text: String, exited: Bool = false) {
        viewportText = text
        viewportExited = exited
    }

    func setFile(_ path: String, to text: String) { files[path] = text }

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
        case "workspace.pane.owner.v1":
            guard let owner = KanbanStateSnapshot.owner(
                workspaces: workspaces.map {
                    (id: $0.id, path: $0.path, tabID: $0.tabID, paneID: $0.paneID)
                },
                paneID: request.input.objectValue?["paneID"]?.stringValue
            ) else {
                return KanbanFileRead.failure(
                    code: "dev.tenon.core.workspace-unavailable",
                    reason: "pane-unknown"
                )
            }
            value = owner
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
        case "filesystem.file.write.v1":
            return write(request)
        case "terminal.open.v1":
            value = .object(["paneID": .string(Self.agentPaneID)])
        case "terminal.viewport.read.v1":
            value = .object([
                "paneID": .string(Self.agentPaneID),
                "text": .string(viewportText),
                "exited": .bool(viewportExited),
                "columns": .integer(80),
                "rows": .integer(24),
            ])
        default:
            value = .object([:])
        }
        return .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    private func write(_ request: PluginIntentSendRequest) -> IntentResult {
        guard let input = request.input.objectValue,
              let path = input["path"]?.stringValue,
              let content = input["content"]?.objectValue,
              content["kind"]?.stringValue == "inline",
              let text = content["text"]?.stringValue
        else {
            return KanbanFileWrite.invalidInput(field: "content")
        }
        if let reason = writeFailureReason {
            return KanbanFileRead.failure(
                code: "dev.tenon.core.filesystem-failed",
                reason: reason
            )
        }
        guard text.utf8.count <= CoreIntentPayloadPolicy.maximumInlineTextCharacters else {
            return KanbanFileRead.failure(
                code: "dev.tenon.core.filesystem-failed",
                reason: "content-too-large"
            )
        }
        let commit = input["commit"]?.boolValue ?? true
        guard let rawCursor = input["cursor"]?.stringValue else {
            guard files[path] != nil else { return KanbanFileRead.pathNotFound() }
            if commit {
                files[path] = text
                return KanbanFileWrite.success(.object([:]))
            }
            let token = UUID().uuidString
            writeStagings[token] = WriteStaging(target: path, text: text)
            return KanbanFileWrite.success(
                .object(["cursor": .string("v1:\(text.utf8.count):\(token)")])
            )
        }
        if invalidatedWriteCursors > 0 {
            invalidatedWriteCursors -= 1
            return KanbanFileWrite.invalidInput(field: "cursor")
        }
        let parts = rawCursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "v1",
              let offset = Int(parts[1]),
              var staging = writeStagings[String(parts[2])],
              staging.target == path,
              offset == staging.text.utf8.count
        else {
            return KanbanFileWrite.invalidInput(field: "cursor")
        }
        let token = String(parts[2])
        writeStagings[token] = nil
        staging.text += text
        guard staging.text.utf8.count
            <= CoreIntentPayloadPolicy.maximumStagedFileWriteBytes
        else {
            return KanbanFileRead.failure(
                code: "dev.tenon.core.filesystem-failed",
                reason: "staged-write-limit-exceeded"
            )
        }
        if commit {
            files[path] = staging.text
            return KanbanFileWrite.success(.object([:]))
        }
        writeStagings[token] = staging
        return KanbanFileWrite.success(
            .object(["cursor": .string("v1:\(staging.text.utf8.count):\(token)")])
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
        let workspaces = [(
            id: "AAAAAAAA-0000-0000-0000-000000000041",
            path: workspacePath,
            tabID: "AAAAAAAA-1111-0000-0000-000000000041",
            paneID: "AAAAAAAA-2222-0000-0000-000000000041"
        )]
        let value: IntentValue
        switch request.intentID.rawValue {
        case "workspace.state.v1":
            value = KanbanStateSnapshot.value(
                workspaces: workspaces,
                selectedID: "AAAAAAAA-0000-0000-0000-000000000041"
            )
        case "workspace.pane.owner.v1":
            guard let owner = KanbanStateSnapshot.owner(
                workspaces: workspaces,
                paneID: request.input.objectValue?["paneID"]?.stringValue
            ) else {
                return KanbanFileRead.failure(
                    code: "dev.tenon.core.workspace-unavailable",
                    reason: "pane-unknown"
                )
            }
            value = owner
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

/// The write half of the fake bridge's success/failure vocabulary. Invalid cursors fail
/// exactly as the shipped provider fails them: `tenon.invalid-input` naming the field.
private enum KanbanFileWrite {
    static func success(_ value: IntentValue) -> IntentResult {
        .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    static func invalidInput(field: String) -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(.invalidInput),
                details: .object(["field": .string(field)]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }
}

private enum KanbanStateSnapshot {
    /// Sourced from the same fixture tuples `value(workspaces:selectedID:)` consumes, so
    /// the snapshot and the pane→workspace edge can never disagree about who owns what.
    static func owner(
        workspaces: [(id: String, path: String, tabID: String, paneID: String)],
        paneID: String?
    ) -> IntentValue? {
        guard let paneID,
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
