import TenonCore
import XCTest
@testable import TenonApp

/// The launcher popover regroups its ranked list by category, so "row N" only means one
/// thing if the regrouped order is also the order the arrow keys move through. These
/// assert that equality without a window: the Nth displayed row is the Nth selectable row.
final class LauncherSectionsTests: XCTestCase {
    /// Frecency interleaves categories as soon as the launcher is actually used, which is
    /// exactly when a flat-vs-displayed mismatch starts skipping rows.
    private func interleavedRanking() -> [CommandMatch] {
        [
            match("browser.open", "Open Browser", category: "Open"),
            match("core.new-tab", "New Tab", category: "New"),
            match("core.new-terminal", "New Terminal", category: "New"),
            match("core.open-changes", "Open Changes", category: "Open"),
        ]
    }

    private func match(_ id: String, _ title: String, category: String) -> CommandMatch {
        CommandMatch(
            command: Command(id: id, title: title, category: category, isLauncher: true),
            score: 0,
            titleMatch: []
        )
    }

    func testTheNthDisplayedRowIsTheNthSelectableRow() {
        let order = LauncherSections(ranked: interleavedRanking(), query: "")

        // `displayed` is the render sequence, section by section, in section order.
        XCTAssertEqual(
            order.sections.flatMap(\.matches).map(\.id),
            order.displayed.map(\.id)
        )
        // And every row's own index into `displayed` is where the section says it renders.
        for section in order.sections {
            for (rowIndex, match) in section.matches.enumerated() {
                XCTAssertEqual(order.displayed[section.startIndex + rowIndex].id, match.id)
            }
        }
    }

    func testAnEmptyQueryGroupsByCategoryInFirstAppearanceOrder() {
        let order = LauncherSections(ranked: interleavedRanking(), query: "")

        XCTAssertEqual(order.sections.map(\.category), ["Open", "New"])
        XCTAssertEqual(order.sections.map(\.startIndex), [0, 2])
        XCTAssertEqual(
            order.displayed.map(\.id),
            ["browser.open", "core.open-changes", "core.new-tab", "core.new-terminal"]
        )
    }

    /// The regression: one ↓ from the top row must land on the row drawn directly beneath
    /// it. Against the flat ranking index 1 is `core.new-tab`, which renders third.
    func testArrowingDownOnceSelectsTheRowDrawnDirectlyBeneathTheFirst() {
        let order = LauncherSections(ranked: interleavedRanking(), query: "")

        XCTAssertEqual(order.displayed[0].id, "browser.open")
        XCTAssertEqual(order.displayed[1].id, "core.open-changes")
    }

    func testATypedQueryKeepsRelevanceOrderAndDoesNotGroup() {
        let ranked = interleavedRanking()
        let order = LauncherSections(ranked: ranked, query: "new")

        XCTAssertEqual(order.displayed.map(\.id), ranked.map(\.id))
        XCTAssertEqual(order.sections.count, 1)
        XCTAssertEqual(order.sections.map(\.startIndex), [0])
    }

    func testNoMatchesProducesNoSectionsAndNothingSelectable() {
        let order = LauncherSections(ranked: [], query: "")

        XCTAssertTrue(order.sections.isEmpty)
        XCTAssertTrue(order.displayed.isEmpty)
    }

}
