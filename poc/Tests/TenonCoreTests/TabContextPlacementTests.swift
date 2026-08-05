@testable import TenonCore
import XCTest

/// T-039: which tab a command chosen from a tab's context menu is talking about.
///
/// An unanchored launcher answers "the focused pane", which is wrong for a menu attached
/// to one specific tab — most obviously when that tab is not selected.
final class TabContextPlacementTests: XCTestCase {
    /// The distinguishing case, and the reason this rule exists: the focused pane is in
    /// another tab entirely, so anything reading focus would place the result there.
    func testTheScopedPaneIsTheClickedTabsOwnActivePaneNotTheFocusedOne() {
        let fixture = makeCatalog()

        XCTAssertEqual(
            TabContextPlacement.scopedPane(in: fixture.catalog, tabID: fixture.secondTabID),
            fixture.secondTabActiveSlotID
        )
        XCTAssertNotEqual(
            fixture.secondTabActiveSlotID,
            fixture.catalog.activeSlotID,
            "the fixture must actually have focus elsewhere, or this proves nothing"
        )
    }

    func testAnUnknownTabResolvesToNothingRatherThanToTheFocusedPane() {
        let fixture = makeCatalog()

        XCTAssertNil(
            TabContextPlacement.scopedPane(in: fixture.catalog, tabID: UUID()),
            "an unknown tab must refuse, not silently fall back to whatever has focus"
        )
    }

    func testATabInAnUnselectedWorkspaceStillResolvesToItsOwnWorkspace() {
        let fixture = makeCatalog()

        XCTAssertEqual(
            TabContextPlacement.owningWorkspace(
                in: fixture.catalog,
                tabID: fixture.otherWorkspaceTabID
            ),
            fixture.otherWorkspaceID
        )
        XCTAssertNotEqual(
            fixture.otherWorkspaceID,
            fixture.catalog.activeWorkspaceID,
            "the fixture must have a second, unselected workspace"
        )
    }

    /// Criterion 4: a right-click on a background tab must not move the human unless the
    /// action puts something there they need to see.
    func testOnlyAPlacingCommandBringsABackgroundTabForward() {
        let fixture = makeCatalog()
        let background = fixture.secondTabID
        let foreground = try! XCTUnwrap(fixture.catalog.activeWorkspace?.activeTabID)

        XCTAssertTrue(
            TabContextPlacement.requiresRevealing(
                in: fixture.catalog,
                tabID: background,
                placesContent: true
            )
        )
        XCTAssertFalse(
            TabContextPlacement.requiresRevealing(
                in: fixture.catalog,
                tabID: background,
                placesContent: false
            ),
            "a command that places nothing must leave the selection alone"
        )
        XCTAssertFalse(
            TabContextPlacement.requiresRevealing(
                in: fixture.catalog,
                tabID: foreground,
                placesContent: true
            ),
            "the tab is already in front — there is nothing to reveal"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let catalog: WorkspaceCatalog
        let secondTabID: UUID
        let secondTabActiveSlotID: UUID
        let otherWorkspaceID: UUID
        let otherWorkspaceTabID: UUID
    }

    /// Two workspaces; the selected one has two tabs and focus sits in the first, so a
    /// menu opened on the second tab is genuinely talking about a different pane.
    private func makeCatalog() -> Fixture {
        var catalog = WorkspaceCatalog(
            path: FileManager.default.temporaryDirectory,
            content: .terminal
        )
        catalog.newTab(content: .terminal)
        let secondTab = catalog.activeWorkspace!.tabs[1]
        catalog.addWorkspace(
            name: "Other",
            path: FileManager.default.temporaryDirectory,
            content: .terminal
        )
        let otherWorkspace = catalog.workspaces[1]
        let otherTab = otherWorkspace.tabs[0]

        // Put focus back on the first workspace's FIRST tab, so the second tab is a
        // background tab whose active pane differs from the focused one.
        catalog.selectWorkspace(catalog.workspaces[0].id)
        catalog.selectTab(catalog.workspaces[0].tabs[0].id)

        return Fixture(
            catalog: catalog,
            secondTabID: secondTab.id,
            secondTabActiveSlotID: secondTab.activeSlotID ?? secondTab.slots[0].id,
            otherWorkspaceID: otherWorkspace.id,
            otherWorkspaceTabID: otherTab.id
        )
    }
}
