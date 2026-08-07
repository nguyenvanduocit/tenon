import Foundation
@testable import TenonApp
@testable import TenonCore
import XCTest

/// The Changes pane's whole remaining drawing decision, asserted without a window.
///
/// Indent, hover, chevron, context menu and the status column belong to `TreeRowsView` now —
/// what stays here is which rows exist, in which order, carrying which fields. That is
/// arithmetic over the model, the layout and the collapsed set, so it is testable in the
/// headless target, which is the fitness test `docs/tdd.md` asks any pane design to pass.
final class ChangesRowPlanTests: XCTestCase {
    private let root = "/repo"

    private func entry(_ path: String, _ badge: String, staged: Bool = false) -> ChangeEntry {
        ChangeEntry(path: path, badge: badge, staged: staged, untracked: badge == "?")
    }

    private func plan(
        staged: [ChangeEntry] = [],
        changed: [ChangeEntry] = [],
        layout: ChangesLayout = .tree,
        collapsed: Set<String> = [],
        selected: String? = nil,
        repoRoot: String? = nil
    ) -> ChangesRowPlan {
        ChangesRowPlan.build(
            staged: staged,
            changed: changed,
            layout: layout,
            collapsed: collapsed,
            selected: selected,
            repoRoot: repoRoot ?? root
        )
    }

    // MARK: the status column

    /// The letter git reported and the colour it is drawn in are ONE fact. `tint` is derived
    /// from `badge` precisely so no construction site can set them to disagree.
    func testTheStatusLetterCarriesItsOwnTint() {
        XCTAssertEqual(entry("a", "A").tint, .green)
        XCTAssertEqual(entry("a", "D").tint, .red)
        XCTAssertEqual(entry("a", "U").tint, .red)
        XCTAssertEqual(entry("a", "?").tint, .muted)
        XCTAssertEqual(entry("a", "M").tint, .amber)
        XCTAssertEqual(entry("a", "R").tint, .amber, "an unlisted status is a modification")
    }

    func testAFileRowPutsItsStatusInTheAccessory() throws {
        let rows = plan(changed: [entry("a.swift", "M")]).items
        let file = try XCTUnwrap(rows.first { $0.kind == .row })
        XCTAssertEqual(file.accessory?.text, "M")
        XCTAssertEqual(file.accessory?.tint, .amber)
    }

    // MARK: sections

    func testEachSectionIsAHeadingRowCarryingItsOwnCount() throws {
        let rows = plan(
            staged: [entry("a.swift", "M", staged: true)],
            changed: [entry("b.swift", "M"), entry("c.swift", "?")]
        ).items

        let headings = rows.filter { $0.kind == .sectionHeader }
        XCTAssertEqual(headings.map(\.label), ["Staged", "Changes"])
        XCTAssertEqual(headings.map { $0.accessory?.text }, ["1", "2"])
    }

    /// A heading is a member of the row vocabulary so it can INTERLEAVE — `Staged` and its
    /// files, then `Changes` and its files, in one scroll of one list.
    func testHeadingsPrecedeTheFilesTheyName() throws {
        let rows = plan(
            staged: [entry("a.swift", "M", staged: true)],
            changed: [entry("b.swift", "M")]
        ).items

        let labels = rows.map { $0.kind == .sectionHeader ? "#" + $0.label : $0.label }
        XCTAssertEqual(labels, ["#Staged", "a.swift", "#Changes", "b.swift"])
    }

    func testAnEmptySectionPublishesNoHeading() {
        let rows = plan(changed: [entry("b.swift", "M")]).items
        XCTAssertEqual(rows.filter { $0.kind == .sectionHeader }.map(\.label), ["Changes"])
    }

    // MARK: tree layout

    func testTheTreeLayoutIndentsFilesUnderDirectoryRows() throws {
        let rows = plan(changed: [entry("src/app/a.swift", "M")]).items

        let directory = try XCTUnwrap(rows.first { $0.expanded != nil })
        XCTAssertEqual(directory.label, "src/app", "a single-child chain collapses to one row")
        XCTAssertEqual(directory.depth, 0)
        XCTAssertEqual(directory.icon, "folder.fill")

        let file = try XCTUnwrap(rows.first { $0.label == "a.swift" })
        XCTAssertEqual(file.depth, 1)
        XCTAssertNil(file.detail, "the tree already says which directory this is in")
    }

    func testACollapsedDirectoryHidesItsFilesAndSaysSo() throws {
        let directoryID = "Changes:src"
        let rows = plan(
            changed: [entry("src/a.swift", "M")],
            collapsed: [directoryID]
        ).items

        let directory = try XCTUnwrap(rows.first { $0.id == directoryID })
        XCTAssertEqual(directory.expanded, false)
        XCTAssertFalse(rows.contains { $0.label == "a.swift" })
    }

    func testDirectoryRowsAreReportedSoAClickCanTellThemFromFiles() {
        let built = plan(changed: [entry("src/a.swift", "M")])
        XCTAssertEqual(built.directories, ["Changes:src"])
        XCTAssertEqual(Set(built.entries.keys), ["w/src/a.swift"])
    }

    /// Two sections holding the same directory must collapse independently — the id is
    /// section-qualified for exactly that reason.
    func testTheSameDirectoryInTwoSectionsCollapsesIndependently() {
        let built = plan(
            staged: [entry("src/a.swift", "M", staged: true)],
            changed: [entry("src/b.swift", "M")],
            collapsed: ["Staged:src"]
        )
        XCTAssertFalse(built.items.contains { $0.label == "a.swift" })
        XCTAssertTrue(built.items.contains { $0.label == "b.swift" })
    }

    // MARK: flat layout

    func testTheFlatLayoutDropsDirectoryRowsAndNamesTheDirectoryInline() throws {
        let built = plan(changed: [entry("src/app/a.swift", "M")], layout: .flat)

        XCTAssertTrue(built.directories.isEmpty)
        let file = try XCTUnwrap(built.items.first { $0.kind == .row })
        XCTAssertEqual(file.label, "a.swift")
        XCTAssertEqual(file.detail, "src/app")
        XCTAssertEqual(file.depth, 0)
    }

    func testAFileAtTheRepositoryRootHasNoDirectoryToName() throws {
        let built = plan(changed: [entry("README.md", "M")], layout: .flat)
        let file = try XCTUnwrap(built.items.first { $0.kind == .row })
        XCTAssertNil(file.detail)
    }

    // MARK: what a row lets a human do

    func testEveryFileRowCarriesAnAbsolutePathSoItCanBeDraggedOut() throws {
        let built = plan(changed: [entry("src/a.swift", "M")])
        let file = try XCTUnwrap(built.items.first { $0.label == "a.swift" })
        XCTAssertEqual(file.path, "/repo/src/a.swift")

        let directory = try XCTUnwrap(built.items.first { $0.expanded != nil })
        XCTAssertEqual(directory.path, "/repo/src")
    }

    /// The seeded snapshot pane knows no repository root, and its paths name no file on this
    /// disk — so it offers no drag-out and no Finder verb rather than pointing at "/src".
    func testASeededPaneOffersNoPathAtAll() throws {
        let built = plan(changed: [entry("src/a.swift", "M")], repoRoot: "")
        let file = try XCTUnwrap(built.items.first { $0.label == "a.swift" })
        XCTAssertNil(file.path)
    }

    /// No row of this pane publishes a menu, and that is load-bearing rather than unfinished:
    /// every verb one would hold — reveal, copy path — is an existing canonical intent, so
    /// spelling it here would be new same-owner DIRECT behaviour in an inventory the boundary
    /// law records as having grown 3.21× ambiently. Reusing a renderer does not earn that
    /// edit. If this assertion is ever inverted, the law and its pin move in the same change.
    func testNoRowPublishesAMenuBecauseItsVerbsWouldBeNewDirectSurface() {
        let built = plan(
            staged: [entry("src/a.swift", "M", staged: true)],
            changed: [entry("b.swift", "?")]
        )
        XCTAssertTrue(built.items.allSatisfy { $0.menu.isEmpty })
    }

    func testHeadingsAreNotClickableTargets() throws {
        let built = plan(changed: [entry("a.swift", "M")])
        let heading = try XCTUnwrap(built.items.first { $0.kind == .sectionHeader })
        XCTAssertNil(heading.path)
        XCTAssertNil(heading.expanded)
        XCTAssertFalse(built.directories.contains(heading.id))
        XCTAssertNil(built.entries[heading.id])
    }

    func testTheOpenedRowIsTheSelectedRow() throws {
        let built = plan(changed: [entry("a.swift", "M"), entry("b.swift", "M")], selected: "w/a.swift")
        let selected = built.items.filter(\.selected).map(\.label)
        XCTAssertEqual(selected, ["a.swift"])
    }

    /// Row ids are unique across the whole list, including across sections — `LazyVStack`
    /// silently drops duplicates, so a staged and an unstaged edit of one file must not
    /// collide into a single row.
    func testAFileStagedAndEditedAppearsOnceInEachSection() {
        let built = plan(
            staged: [entry("a.swift", "M", staged: true)],
            changed: [entry("a.swift", "M")]
        )
        let ids = built.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate row ids: \(ids)")
        XCTAssertEqual(built.items.filter { $0.label == "a.swift" }.count, 2)
    }
}
