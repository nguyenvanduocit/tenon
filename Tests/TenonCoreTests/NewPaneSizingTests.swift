import XCTest
@testable import TenonCore

/// The automatic-layout maximum: a cap applied when a pane is born or when close reflow
/// offers a neighbor released width. Every assertion runs on the pure workspace value.
final class NewPaneSizingTests: XCTestCase {
    private let third = NewPaneSizing(maximumWidth: .oneThird)   // 4 of 12 columns
    private let half = NewPaneSizing(maximumWidth: .oneHalf)     // 6 of 12 columns

    private func catalog(occupying rect: GridRect? = nil) -> WorkspaceCatalog {
        guard let rect else { return WorkspaceCatalog(name: "w", path: Self.path) }
        let slot = WorkspaceSlot(rect: rect, content: .terminal)
        let tab = Tab(slots: [slot], activeSlotID: slot.id)
        let workspace = Workspace(
            name: "w",
            path: Self.path,
            tabs: [tab],
            activeTabID: tab.id
        )
        return WorkspaceCatalog(workspaces: [workspace], activeWorkspaceID: workspace.id)
    }

    private func rects(_ catalog: WorkspaceCatalog) -> [GridRect] {
        catalog.activeTab?.slots.map(\.rect) ?? []
    }

    private func store(
        slots: [WorkspaceSlot],
        activeSlotID: UUID,
        maximumWidth: SpatialExtentFraction
    ) -> WorkspaceStore {
        let tab = Tab(slots: slots, activeSlotID: activeSlotID)
        let workspace = Workspace(
            name: "w",
            path: Self.path,
            tabs: [tab],
            activeTabID: tab.id
        )
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        ))
        store.newPaneSizingProvider = { NewPaneSizing(maximumWidth: maximumWidth) }
        return store
    }

    private static let path = URL(fileURLWithPath: "/tmp", isDirectory: true)

    // MARK: - Unset: today's behaviour, unchanged

    func testAnUnsetMaximumLeavesEveryCreationPathExactlyAsItIsToday() {
        var capped = catalog()
        var plain = catalog()

        for step in 0..<4 {
            capped.addSlot(content: .terminal, sizing: .unlimited)
            plain.addSlot(content: .terminal)
            XCTAssertEqual(
                rects(capped), rects(plain),
                "step \(step): .unlimited must be the code path with no policy at all"
            )
        }

        capped.splitActiveSlot(.horizontal, content: .terminal, sizing: .unlimited)
        plain.splitActiveSlot(.horizontal, content: .terminal)
        XCTAssertEqual(rects(capped), rects(plain))

        XCTAssertNil(
            NewPaneSizing.unlimited.maximumColumns,
            "an unset maximum names no column budget for the layout to honour"
        )
    }

    func testAnUnsetMaximumStillFillsTheCanvasWithATabsFirstPane() {
        let tab = Tab(content: .terminal, sizing: .unlimited)

        XCTAssertEqual(tab.slots[0].rect.width, SpatialLayout.columns)
        XCTAssertEqual(tab.slots[0].rect.height, SpatialLayout.rows)
    }

    // MARK: - Wide space: the maximum is what binds

    func testATabsFirstPaneStopsAtTheConfiguredMaximum() {
        let tab = Tab(content: .terminal, sizing: third)

        XCTAssertEqual(tab.slots[0].rect.width, 4, "1/3 of a 12-column canvas")
        XCTAssertEqual(tab.slots[0].rect.x, 0)
        XCTAssertEqual(
            tab.slots[0].rect.height, SpatialLayout.rows,
            "the maximum is a width; it must not touch the pane's height"
        )
    }

    func testANewWorkspaceAndANewTabBothRespectTheMaximum() {
        var catalog = self.catalog()

        catalog.addWorkspace(
            name: "second",
            path: Self.path,
            content: .terminal,
            sizing: half
        )
        XCTAssertEqual(rects(catalog).map(\.width), [6])

        catalog.newTab(content: .terminal, sizing: third)
        XCTAssertEqual(rects(catalog).map(\.width), [4])
    }

    func testTheSecondPaneTakesFreeCanvasBoundedByTheMaximum() {
        var catalog = self.catalog(occupying: GridRect(x: 0, y: 0, width: 4, height: 12))

        catalog.addSlot(content: .terminal, sizing: third)

        XCTAssertEqual(
            rects(catalog),
            [
                GridRect(x: 0, y: 0, width: 4, height: 12),
                GridRect(x: 4, y: 0, width: 4, height: 12),
            ],
            "the free hole was 8 wide; the new pane took 4 of it and left the rest empty"
        )
    }

    // MARK: - Narrow space: available room is what binds

    func testTheMaximumNeverWidensAPaneTheLayoutOffersLessThan() {
        // The only free room is a 3-column strip, narrower than the 6-column maximum.
        var catalog = self.catalog(occupying: GridRect(x: 0, y: 0, width: 9, height: 12))

        catalog.addSlot(content: .terminal, sizing: half)

        XCTAssertEqual(
            rects(catalog).map(\.width), [9, 3],
            "3 columns were on offer; a 6-column cap adds nothing"
        )
    }

    func testAMaximumWiderThanTheCanvasIsSimplyTheCanvas() {
        let tab = Tab(content: .terminal, sizing: NewPaneSizing(maximumWidth: .full))

        XCTAssertEqual(tab.slots[0].rect.width, SpatialLayout.columns)
    }

    // MARK: - Boundary values

    func testAMaximumEqualToTheOfferedWidthChangesNothing() {
        var withCap = catalog()
        var without = catalog()

        withCap.splitActiveSlot(.horizontal, content: .terminal, sizing: half)
        without.splitActiveSlot(.horizontal, content: .terminal)

        // A 12-wide pane splits into 6 + 6; a 6-column maximum is exactly that half.
        XCTAssertEqual(rects(withCap).map(\.width), [6, 6])
        XCTAssertEqual(rects(withCap), rects(without))
    }

    func testTheCapCanNeverProduceAPaneNarrowerThanTheLayoutAllows() throws {
        let slots = [SpatialSlot(id: UUID(), rect: GridRect(x: 0, y: 0, width: 12, height: 12))]
        let newID = UUID()

        // A caller naming an impossible maximum gets the narrowest legal pane, not an
        // invalid layout and not a refusal.
        let transaction = try XCTUnwrap(SpatialLayout.split(
            slots,
            slotID: slots[0].id,
            newSlotID: newID,
            axis: .horizontal,
            newSlotMaximumWidth: 1
        ))

        XCTAssertEqual(
            transaction.proposal.first(where: { $0.id == newID })?.rect.width,
            SpatialLayout.minimumWidth
        )
        XCTAssertTrue(SpatialLayout.isValid(transaction.proposal))
    }

    func testEveryFractionOfTheCanvasIsAtLeastAUsablePaneWide() {
        // The reason the preference names fractions instead of counting columns: no stored
        // value can ask for a pane too narrow to exist. Read off the fraction itself, not
        // off `maximumColumns` — its floor would answer this question for it, and a
        // fraction whose Settings label promised a width the layout refuses would ship.
        for fraction in SpatialExtentFraction.allCases {
            XCTAssertGreaterThanOrEqual(
                fraction.extent(of: SpatialLayout.columns),
                SpatialLayout.minimumWidth,
                "\(fraction) must name a width the layout accepts"
            )
        }
    }

    // MARK: - Where the width goes

    func testSplittingHandsTheUnusedWidthBackToThePaneBeingSplit() throws {
        var catalog = self.catalog()
        let original = try XCTUnwrap(catalog.activeTab?.slots[0].id)

        catalog.splitSlot(original, .horizontal, content: .terminal, sizing: third)

        let slots = try XCTUnwrap(catalog.activeTab?.slots)
        XCTAssertEqual(
            slots.first { $0.id != original }?.rect,
            GridRect(x: 8, y: 0, width: 4, height: 12)
        )
        XCTAssertEqual(
            slots.first { $0.id == original }?.rect,
            GridRect(x: 0, y: 0, width: 8, height: 12),
            "a horizontal split has a neighbour to give the width to, so it leaves no gap"
        )
    }

    func testAVerticalSplitReturnsTheUnusedWidthToTheCanvas() throws {
        var catalog = self.catalog()
        let original = try XCTUnwrap(catalog.activeTab?.slots[0].id)

        catalog.splitSlot(original, .vertical, content: .terminal, sizing: third)

        let slots = try XCTUnwrap(catalog.activeTab?.slots)
        XCTAssertEqual(
            slots.first { $0.id != original }?.rect,
            GridRect(x: 0, y: 6, width: 4, height: 6),
            "stacked beneath its sibling there is no neighbour to widen, so the width the "
                + "maximum declines stays free canvas"
        )
        XCTAssertEqual(slots.first { $0.id == original }?.rect.width, 12)
    }

    // MARK: - The clicked cell survives the cap

    func testANarrowedRegionStillCoversTheCellThatWasPointedAt() {
        let hole = GridRect(x: 0, y: 0, width: 12, height: 12)

        let fitted = third.fitting(hole, keeping: 10)

        XCTAssertEqual(fitted, GridRect(x: 8, y: 0, width: 4, height: 12))
        XCTAssertTrue((fitted.x..<(fitted.x + fitted.width)).contains(10))
    }

    func testWithNoCellNamedTheNarrowedRegionKeepsItsLeadingEdge() {
        let fitted = third.fitting(GridRect(x: 3, y: 2, width: 9, height: 5))

        XCTAssertEqual(fitted, GridRect(x: 3, y: 2, width: 4, height: 5))
    }

    func testANarrowedRegionBeginsAtTheCellThatWasPointedAt() {
        // Room to the right, so the pane starts exactly where the pointer was.
        XCTAssertEqual(
            third.fitting(GridRect(x: 0, y: 0, width: 12, height: 12), keeping: 5),
            GridRect(x: 5, y: 0, width: 4, height: 12)
        )
    }

    func testTheNarrowedRegionNeverLeavesTheRegionItCameFrom() {
        let hole = GridRect(x: 5, y: 0, width: 7, height: 12)

        for column in 5..<12 {
            let fitted = third.fitting(hole, keeping: column)
            XCTAssertGreaterThanOrEqual(fitted.x, hole.x, "column \(column)")
            XCTAssertLessThanOrEqual(
                fitted.x + fitted.width, hole.x + hole.width, "column \(column)"
            )
            XCTAssertTrue(
                (fitted.x..<(fitted.x + fitted.width)).contains(column), "column \(column)"
            )
        }
    }

    func testFittingIsIdempotent() {
        let once = third.fitting(GridRect(x: 0, y: 0, width: 12, height: 12), keeping: 10)

        XCTAssertEqual(third.fitting(once, keeping: 10), once)
    }

    // MARK: - Panes that already exist

    func testLoweringTheMaximumLeavesEveryOpenPaneWhereItIs() {
        // A pane opened while there was no maximum, twice as wide as the one about to be set.
        var catalog = self.catalog(occupying: GridRect(x: 0, y: 0, width: 8, height: 12))
        let before = rects(catalog)

        catalog.addSlot(content: .terminal, sizing: third)

        XCTAssertEqual(
            Array(rects(catalog).prefix(1)), before,
            "a creation maximum is not a resize: the open pane keeps its 8 columns"
        )
        XCTAssertEqual(rects(catalog).last?.width, 4, "only the new pane obeys the maximum")
    }

    func testClosingAPaneOnlyAutoExpandsItsNeighborToTheConfiguredMaximum() throws {
        let survivingID = UUID()
        let closingID = UUID()
        let store = store(
            slots: [
                WorkspaceSlot(
                    id: survivingID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: closingID,
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: closingID,
            maximumWidth: .oneThird
        )

        store.closeSlot(closingID)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: survivingID)).rect,
            GridRect(x: 0, y: 0, width: 4, height: 12),
            "automatic close reflow may grow a pane up to the live maximum, not past it"
        )
    }

    func testCloseReflowNeverShrinksAPaneAlreadyWiderThanTheConfiguredMaximum() throws {
        let survivingID = UUID()
        let closingID = UUID()
        let store = store(
            slots: [
                WorkspaceSlot(
                    id: survivingID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: closingID,
                    rect: GridRect(x: 6, y: 0, width: 6, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: closingID,
            maximumWidth: .oneThird
        )
        var events: [WorkspaceEvent] = []
        store.onEvents = { published, _ in events = published }

        store.closeSlot(closingID)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: survivingID)).rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "the setting limits automatic growth; it never retroactively shrinks a pane"
        )
        XCTAssertFalse(events.contains { event in
            if case .slotsResized = event { return true }
            return false
        })
    }

    func testRightNeighborKeepsItsRightEdgeWhenCloseReflowIsCapped() throws {
        let closingID = UUID()
        let survivingID = UUID()
        let store = store(
            slots: [
                WorkspaceSlot(
                    id: closingID,
                    rect: GridRect(x: 0, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: survivingID,
                    rect: GridRect(x: 9, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: closingID,
            maximumWidth: .oneThird
        )

        store.closeSlot(closingID)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: survivingID)).rect,
            GridRect(x: 8, y: 0, width: 4, height: 12),
            "a right neighbor grows left into the released region without jumping right"
        )
    }

    func testSplittingStillResizesThePaneBeingSplit() {
        // The exception that proves the rule above: a split has always changed its
        // target's width, maximum or no maximum. What the maximum changes is only how
        // the two shares are divided.
        var catalog = self.catalog()

        catalog.splitActiveSlot(.horizontal, content: .terminal, sizing: third)

        XCTAssertEqual(rects(catalog).map(\.width), [8, 4])
    }

    func testAMaximumNeverStopsThePersonResizingPastIt() throws {
        var catalog = self.catalog()
        catalog.newTab(content: .terminal, sizing: third)
        let paneID = try XCTUnwrap(catalog.activeTab?.slots[0].id)

        catalog.resizeSlot(paneID, direction: .east, fraction: .full)

        XCTAssertEqual(
            catalog.activeTab?.slots[0].rect.width, 12,
            "the maximum bounds automatic layout only; the border is the person's"
        )
    }

    // MARK: - A pane that moves to another tab

    func testDraggingAPaneOutLeavesTheNeighborExactlyWhereClosingItWould() throws {
        let stayingID = UUID()
        let movingID = UUID()
        let store = store(
            slots: [
                WorkspaceSlot(
                    id: stayingID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: movingID,
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: movingID,
            maximumWidth: .oneThird
        )

        store.moveSlotToNewTab(movingID)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: stayingID)).rect,
            GridRect(x: 0, y: 0, width: 4, height: 12),
            "the tab the pane left reflows on the same rule as a close, not a wider one"
        )
    }

    func testAPaneDroppedOnTheTabBarOpensAtTheConfiguredMaximum() throws {
        let stayingID = UUID()
        let movingID = UUID()
        let store = store(
            slots: [
                WorkspaceSlot(
                    id: stayingID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: movingID,
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: movingID,
            maximumWidth: .oneThird
        )

        store.moveSlotToNewTab(movingID)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: movingID)).rect,
            GridRect(x: 0, y: 0, width: 4, height: 12),
            "nobody named a frame for the new tab, so automatic layout obeys the maximum"
        )
    }

    func testAPaneDroppedOnATabChipTakesFreeCanvasBoundedByTheMaximum() throws {
        let movingID = UUID()
        let store = twoTabStore(movingSlotID: movingID, maximumWidth: .oneThird)
        let targetTabID = try XCTUnwrap(store.catalog.activeWorkspace?.tabs[1].id)

        store.moveSlot(movingID, toTab: targetTabID)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: movingID)).rect,
            GridRect(x: 6, y: 0, width: 4, height: 12),
            "a chip drop names a tab, not a frame: placement is automatic and capped"
        )
    }

    func testAPaneDroppedOnAHighlightedRegionStillAdoptsThatRegionExactly() throws {
        let movingID = UUID()
        let store = twoTabStore(movingSlotID: movingID, maximumWidth: .oneThird)
        let targetTabID = try XCTUnwrap(store.catalog.activeWorkspace?.tabs[1].id)
        let chosen = GridRect(x: 6, y: 0, width: 6, height: 12)

        store.moveSlot(movingID, toTab: targetTabID, at: chosen)

        XCTAssertEqual(
            try XCTUnwrap(store.catalog.slot(id: movingID)).rect, chosen,
            "the drop highlight promised this frame; the maximum bounds automatic layout only"
        )
    }

    /// Two tabs in one workspace: the source holds the pane about to move beside a 3-column
    /// neighbor, and the target holds one 6-column pane, leaving columns 6…11 free.
    private func twoTabStore(
        movingSlotID: UUID,
        maximumWidth: SpatialExtentFraction
    ) -> WorkspaceStore {
        let source = Tab(
            slots: [
                WorkspaceSlot(
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: movingSlotID,
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: movingSlotID
        )
        let occupant = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 6, height: 12),
            content: .terminal
        )
        let target = Tab(slots: [occupant], activeSlotID: occupant.id)
        let workspace = Workspace(
            name: "w",
            path: Self.path,
            tabs: [source, target],
            activeTabID: source.id
        )
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        ))
        store.newPaneSizingProvider = { NewPaneSizing(maximumWidth: maximumWidth) }
        return store
    }
}
