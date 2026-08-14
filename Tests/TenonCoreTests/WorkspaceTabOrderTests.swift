import XCTest

@testable import TenonCore

/// T-096: a tab takes a different place in its own workspace, and nothing else about it —
/// or about any other workspace — changes. Asserted over the catalog value, with no window.
final class WorkspaceTabOrderTests: XCTestCase {
    private let projectPath = URL(fileURLWithPath: "/tmp/tenon-tab-order", isDirectory: true)
    private let otherPath = URL(fileURLWithPath: "/tmp/tenon-tab-order-2", isDirectory: true)

    private let anyDirectory: (String) -> Bool = { _ in true }
    private let anyFile: (String) -> Bool = { _ in true }
    private let anyPluginView: (String, String) -> Bool = { _, _ in true }

    /// One workspace holding `count` tabs, each with its own pane, first tab selected.
    private func catalog(tabs count: Int) -> WorkspaceCatalog {
        var catalog = WorkspaceCatalog(name: "Order", path: projectPath)
        for _ in 1 ..< count {
            catalog.newTab()
        }
        catalog.selectTab(catalog.activeWorkspace!.tabs[0].id)
        return catalog
    }

    private func order(_ catalog: WorkspaceCatalog) -> [UUID] {
        catalog.activeWorkspace?.tabs.map(\.id) ?? []
    }

    // MARK: - The move itself

    func testMovingATabForwardPutsItAtTheNamedIndex() throws {
        var catalog = self.catalog(tabs: 4)
        let before = order(catalog)

        let events = catalog.moveTab(before[0], to: 2)

        XCTAssertEqual(order(catalog), [before[1], before[2], before[0], before[3]])
        XCTAssertEqual(events, [
            .tabMoved(
                tab: before[0],
                from: 0,
                to: 2,
                workspace: catalog.activeWorkspaceID
            ),
        ])
    }

    func testMovingATabBackwardPutsItAtTheNamedIndex() throws {
        var catalog = self.catalog(tabs: 4)
        let before = order(catalog)

        catalog.moveTab(before[3], to: 1)

        XCTAssertEqual(order(catalog), [before[0], before[3], before[1], before[2]])
    }

    func testATabCanReachEitherEndOfTheStrip() throws {
        var catalog = self.catalog(tabs: 4)
        let before = order(catalog)

        catalog.moveTab(before[2], to: 0)
        XCTAssertEqual(order(catalog), [before[2], before[0], before[1], before[3]])

        catalog.moveTab(before[2], to: 3)
        XCTAssertEqual(order(catalog), [before[0], before[1], before[3], before[2]])
    }

    // MARK: - What refuses to move

    func testMovingATabToWhereItAlreadyIsChangesNothing() throws {
        var catalog = self.catalog(tabs: 3)
        let before = order(catalog)

        let events = catalog.moveTab(before[1], to: 1)

        XCTAssertEqual(events, [])
        XCTAssertEqual(order(catalog), before)
    }

    func testAnIndexOutsideTheStripChangesNothing() throws {
        var catalog = self.catalog(tabs: 3)
        let before = order(catalog)

        XCTAssertEqual(catalog.moveTab(before[0], to: -1), [])
        XCTAssertEqual(catalog.moveTab(before[0], to: 3), [])
        XCTAssertEqual(catalog.moveTab(before[0], to: 99), [])
        XCTAssertEqual(order(catalog), before)
    }

    func testAnUnknownTabChangesNothing() throws {
        var catalog = self.catalog(tabs: 3)
        let before = order(catalog)

        XCTAssertEqual(catalog.moveTab(UUID(), to: 0), [])
        XCTAssertEqual(order(catalog), before)
    }

    /// The operation names no workspace but the active one, so a tab belonging to another
    /// workspace is not a tab it can find — and the other workspace is untouched.
    func testATabFromAnotherWorkspaceCannotBeMovedIntoThisOne() throws {
        var catalog = self.catalog(tabs: 3)
        let firstWorkspace = catalog.activeWorkspaceID
        let firstOrder = order(catalog)

        catalog.addWorkspace(name: "Other", path: otherPath)
        catalog.newTab()
        let secondOrder = order(catalog)

        XCTAssertEqual(catalog.moveTab(firstOrder[0], to: 0), [])
        XCTAssertEqual(order(catalog), secondOrder)
        XCTAssertEqual(
            catalog.workspaces.first(where: { $0.id == firstWorkspace })?.tabs.map(\.id),
            firstOrder
        )
    }

    // MARK: - What the move must not disturb

    func testReorderingPreservesSelectionPanesAndContent() throws {
        var catalog = WorkspaceCatalog(name: "Order", path: projectPath)
        catalog.newTab(content: .file(path: "/tmp/tenon-tab-order/a.md"))
        catalog.newTab()
        catalog.splitActiveSlot(.horizontal)
        catalog.newTab()

        let workspace = try XCTUnwrap(catalog.activeWorkspace)
        let selected = workspace.activeTabID
        let moved = workspace.tabs[2]
        let movedSlots = moved.slots
        let movedActiveSlot = moved.activeSlotID
        let slotsBefore = catalog.allSlotIDs.sorted()

        catalog.moveTab(moved.id, to: 0)

        let after = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(after.activeTabID, selected, "reordering changed which tab is active")
        XCTAssertEqual(after.tabs[0].id, moved.id)
        XCTAssertEqual(after.tabs[0].slots, movedSlots, "the tab lost or reshaped its panes")
        XCTAssertEqual(after.tabs[0].activeSlotID, movedActiveSlot)
        XCTAssertEqual(catalog.allSlotIDs.sorted(), slotsBefore, "a pane appeared or vanished")
        XCTAssertEqual(after.tabs.count, 4)
    }

    /// Moving the selected tab moves the selection with it, because selection is by
    /// identity: the tab a person was looking at is still the tab they are looking at.
    func testMovingTheActiveTabKeepsItActive() throws {
        var catalog = self.catalog(tabs: 4)
        let before = order(catalog)
        catalog.selectTab(before[1])

        catalog.moveTab(before[1], to: 3)

        XCTAssertEqual(catalog.activeWorkspace?.activeTabID, before[1])
        XCTAssertEqual(catalog.activeWorkspace?.tabs[3].id, before[1])
    }

    func testMovingAnInactiveTabLeavesTheSelectionWhereItWas() throws {
        var catalog = self.catalog(tabs: 4)
        let before = order(catalog)
        catalog.selectTab(before[2])

        catalog.moveTab(before[0], to: 3)

        XCTAssertEqual(catalog.activeWorkspace?.activeTabID, before[2])
    }

    // MARK: - The order a person chose comes back

    func testTheReorderedSequenceSurvivesSaveAndRestore() throws {
        var catalog = self.catalog(tabs: 4)
        let before = order(catalog)
        catalog.selectTab(before[2])
        catalog.moveTab(before[3], to: 0)
        let expected = order(catalog)
        XCTAssertNotEqual(expected, before, "the fixture must actually have been reordered")

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: encoded
        )
        let restored = try XCTUnwrap(
            WorkspaceCatalogSnapshot.restore(
                decoded,
                isDirectory: anyDirectory,
                isFileReadable: anyFile,
                isKnownPluginView: anyPluginView
            )
        )

        XCTAssertEqual(restored.catalog.activeWorkspace?.tabs.map(\.id), expected)
        XCTAssertEqual(restored.catalog.activeWorkspace?.activeTabID, before[2])
    }

    // MARK: - Through the store

    func testTheStorePublishesTheMoveAndRefusesTheNoOp() throws {
        let store = WorkspaceStore(catalog: catalog(tabs: 3))
        var published: [WorkspaceEvent] = []
        store.onEvents = { events, _ in published.append(contentsOf: events) }
        let before = store.catalog.activeWorkspace!.tabs.map(\.id)
        let snapshot = store.snapshotID

        store.moveTab(before[2], to: 0)

        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.map(\.id), [
            before[2], before[0], before[1],
        ])
        XCTAssertEqual(published, [
            .tabMoved(
                tab: before[2],
                from: 2,
                to: 0,
                workspace: store.catalog.activeWorkspaceID
            ),
        ])
        XCTAssertNotEqual(store.snapshotID, snapshot)

        published.removeAll()
        let settled = store.snapshotID
        store.moveTab(before[2], to: 0)

        XCTAssertEqual(published, [], "a no-op reorder published a fact that did not happen")
        XCTAssertEqual(store.snapshotID, settled)
    }

    // MARK: - A tab's own number (T-105)

    /// The defect this file's reorder tests could not see: the strip moved and the names
    /// moved back, so a working reorder read as no reorder at all.
    func testATabKeepsItsNumberWhenItMoves() {
        let store = WorkspaceStore()
        while (store.catalog.activeWorkspace?.tabs.count ?? 0) < 3 { store.newTab() }
        let ids = store.catalog.activeWorkspace!.tabs.map(\.id)
        let numbers = Dictionary(
            uniqueKeysWithValues: store.catalog.activeWorkspace!.tabs.map { ($0.id, $0.number) }
        )

        store.moveTab(ids[0], to: 2)

        for tab in store.catalog.activeWorkspace!.tabs {
            XCTAssertEqual(
                tab.number,
                numbers[tab.id],
                "tab \(tab.id) was renamed by a move that only changed where it stands"
            )
        }
        XCTAssertEqual(
            store.catalog.activeWorkspace!.tabs.map(\.number),
            [numbers[ids[1]], numbers[ids[2]], numbers[ids[0]]],
            "the numbers must travel with their tabs, in the tabs' new order"
        )
    }

    /// Numbers come from creation, so closing one leaves a gap rather than renaming a
    /// survivor — the trade the alternative (dense renumbering) refuses to make.
    func testClosingATabLeavesAGapInsteadOfRenamingTheSurvivors() {
        let store = WorkspaceStore()
        while (store.catalog.activeWorkspace?.tabs.count ?? 0) < 3 { store.newTab() }
        let ids = store.catalog.activeWorkspace!.tabs.map(\.id)
        XCTAssertEqual(store.catalog.activeWorkspace!.tabs.map(\.number), [1, 2, 3])

        store.closeTab(ids[1], in: store.catalog.activeWorkspaceID)

        XCTAssertEqual(
            store.catalog.activeWorkspace!.tabs.map(\.number),
            [1, 3],
            "closing the middle tab renamed a tab that never moved"
        )

        store.newTab()
        XCTAssertEqual(
            store.catalog.activeWorkspace!.tabs.map(\.number),
            [1, 3, 4],
            "the new tab must not take a number a living tab already answers to"
        )
    }

    /// Every route that makes a tab has to number it, or one route quietly ships tabs that
    /// all call themselves the same thing.
    func testEveryRouteThatMakesATabNumbersIt() {
        let store = WorkspaceStore()
        XCTAssertEqual(
            store.catalog.activeWorkspace!.tabs.map(\.number),
            [1],
            "a workspace's first tab is the first tab"
        )

        store.newTab()
        store.newTab()
        XCTAssertEqual(store.catalog.activeWorkspace!.tabs.map(\.number), [1, 2, 3])

        // A pane pulled out of its tab into one of its own is the third route. Because it
        // was the source tab's final pane, that source closes and leaves its number as a
        // gap; the newly created tab keeps the number it received at creation.
        let crowded = store.catalog.activeWorkspace!.tabs[2]
        store.selectTab(crowded.id)
        let slot = crowded.slots[0].id
        store.moveSlotToNewTab(slot)

        XCTAssertEqual(
            store.catalog.activeWorkspace!.tabs.map(\.number).sorted(),
            [1, 2, 4],
            "a pane dragged out into its own tab arrived unnumbered"
        )
        XCTAssertEqual(
            Set(store.catalog.activeWorkspace!.tabs.map(\.number)).count,
            store.catalog.activeWorkspace!.tabs.count,
            "two tabs in one workspace answer to the same number"
        )
    }
}
