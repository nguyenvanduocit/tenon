import XCTest
@testable import TenonCore

/// T-176 (`CMD-FR-020`, `CMD-FR-021`): what an empty pane's search field turns a query into.
///
/// The whole rule lives here rather than in the card, so the thing that decides which row a
/// person lands on can be read without a window — `docs/tdd.md`'s fitness question answered
/// yes. The card below it only draws this order.
final class EmptyPaneLauncherTests: XCTestCase {
    /// The offerings an empty pane hands the ranker, in the order the card lists them.
    private var offerings: [Command] {
        [
            Command(
                id: "add-terminal",
                title: "Add terminal",
                icon: ">_",
                keywords: ["shell", "console"]
            ),
            Command(id: "agent.codex", title: "Codex", subtitle: "Bypass approvals", icon: "✦"),
            Command(id: "agent.claude", title: "Claude Code", subtitle: "Skip permissions", icon: "◉"),
            Command(id: "view.files", title: "Files", icon: "◇", keywords: ["explorer", "tree"]),
            Command(id: "view.changes", title: "Changes", icon: "±", keywords: ["git", "diff"]),
            Command(id: "view.automation", title: "Automation", icon: "↻", keywords: ["schedule"]),
            Command(id: "view.browser", title: "Browser", icon: "◇", keywords: ["web"]),
            Command(id: "recent.0", title: "judge.go", subtitle: "Recently opened", icon: "F"),
        ]
    }

    private func rows(_ query: String) -> [EmptyPaneLauncherRow] {
        EmptyPaneLauncher.rows(query: query, items: offerings)
    }

    private func ids(_ query: String) -> [String] {
        rows(query).map(\.id)
    }

    // MARK: - Nothing typed

    func testNothingTypedRanksNothing() {
        XCTAssertEqual(rows("").count, 0)
        XCTAssertEqual(rows("   ").count, 0, "whitespace alone is still an empty query")
        XCTAssertEqual(RunCommandOffer.placement(for: ""), .none)
        XCTAssertEqual(RunCommandOffer.placement(for: "  \n "), .none)
    }

    // MARK: - A word is a name

    func testASingleWordFindsWhatIsNamedThatBeforeOfferingToRunIt() {
        XCTAssertEqual(
            ids("ch"),
            // Automation follows on its "schedule" keyword, below the title that opens with
            // the query — a keyword reaches a row, it does not outrank a name.
            ["item:view.changes", "item:view.automation", "run"],
            "the word names a view, the view leads, and the offer to run it follows"
        )
    }

    func testTheHighlightPointsAtTheCharactersTheQueryMatched() throws {
        let changes = try XCTUnwrap(rows("ch").first { $0.kind == .item("view.changes") })
        XCTAssertEqual(changes.titleMatch, [0, 1], "\"Ch\" opens \"Changes\"")
        XCTAssertEqual(changes.glyph, "±", "the row keeps the offering's own glyph")
        let run = try XCTUnwrap(rows("ch").first { $0.id == "run" })
        XCTAssertEqual(run.titleMatch, [], "the run offer matched nothing; it highlights nothing")
    }

    func testAKeywordFindsAnOfferingWhoseTitleDoesNotCarryTheQuery() {
        XCTAssertTrue(ids("git").contains("item:view.changes"), "\"git\" is a Changes keyword")
    }

    // MARK: - A command line is a command line

    func testACommandLineIsOfferedBeforeAnythingItAccidentallyMatched() {
        XCTAssertEqual(RunCommandOffer.placement(for: "npm run dev"), .leading)
        let rows = rows("npm run dev")
        XCTAssertEqual(rows.first?.kind, .runCommand("npm run dev"))
    }

    func testAShellShapedWordIsACommandLineEvenWithoutASpace() {
        for query in ["./scripts/build.sh", "~/bin/tool", "$EDITOR", "a|b", "a>b", "a&b", "a;b", "*.go"] {
            XCTAssertEqual(
                RunCommandOffer.placement(for: query),
                .leading,
                "\(query) reads as a command line"
            )
        }
    }

    func testAFileNameAndAHyphenatedNameStayNames() {
        // The commonest pick in the list is a recently opened file. `judge.go` leading with
        // `Run "judge.go"` would break it to serve the rarer case.
        XCTAssertEqual(RunCommandOffer.placement(for: "judge.go"), .trailing)
        XCTAssertEqual(RunCommandOffer.placement(for: "agent-lens"), .trailing)
        XCTAssertEqual(ids("judge.go").first, "item:recent.0")
    }

    func testAQueryNothingMatchesIsStillSomethingToRun() {
        let rows = rows("./scripts/internal/prune-build-cache.sh")
        XCTAssertEqual(rows.count, 1, "nothing offered carries that query")
        XCTAssertEqual(
            rows.first?.kind,
            .runCommand("./scripts/internal/prune-build-cache.sh"),
            "so the pane never draws a dead end — it offers to run what was typed"
        )
    }

    func testTheOfferedCommandIsTheQueryWithoutItsSurroundingWhitespace() throws {
        let row = try XCTUnwrap(rows("   ls -la   ").first { $0.id == "run" })
        XCTAssertEqual(row.kind, .runCommand("ls -la"))
        XCTAssertEqual(row.title, "ls -la", "the row shows exactly what will run")
    }

    // MARK: - The order is one order

    func testEveryRowIsUniquelyAddressableSoSelectionCannotLandOnTwo() {
        let ids = ids("a")
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids would make ↓/↑ ambiguous")
        XCTAssertGreaterThan(ids.count, 1)
    }

    func testATieIsBrokenByNameSoTheOrderIsTheSameEveryTimeItIsTyped() {
        // Add terminal (through its "console" keyword), Changes, Claude Code and Codex all
        // open on the queried letter, so the matcher scores them identically.
        XCTAssertEqual(
            ids("c"),
            [
                "item:add-terminal", "item:view.changes", "item:agent.claude", "item:agent.codex",
                // Automation reaches the list through "schedule", where the query lands mid-word
                // and scores far below the four titles that open on it.
                "item:view.automation",
                "run",
            ]
        )
        XCTAssertEqual(ids("c"), ids("c"), "the same query twice is the same list twice")
    }
}
