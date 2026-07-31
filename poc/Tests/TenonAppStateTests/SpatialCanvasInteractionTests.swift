import XCTest
import AppKit
@testable import TenonApp
import TenonCore
import TenonIntentCore

@MainActor
final class SpatialCanvasInteractionTests: XCTestCase {
    func testHitTestingPrioritizesInvisibleCornersEdgesThenHeader() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)

        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: 4, y: 4),
                in: bounds
            ),
            .resize(.northWest)
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: 100, y: 2),
                in: bounds
            ),
            .resize(.north)
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: 199, y: 60),
                in: bounds
            ),
            .resize(.east)
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: 100, y: 20),
                in: bounds
            ),
            .header
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: 100, y: 60),
                in: bounds
            ),
            .body
        )
    }

    func testGridDeltaSnapsPointerTranslationToTwelveByTwelveCanvas() {
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 600)
        )

        XCTAssertEqual(
            coordinator.snappedDelta(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 301, y: 249)
            ),
            GridDelta(columns: 2, rows: 3)
        )
    }

    func testMovePreviewUsesSpatialMoveTransactionAwayFromTargets() throws {
        let movingID = UUID()
        let otherID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 3, height: 3),
            slot(otherID, x: 6, y: 0, width: 3, height: 3),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginMove(
            slotID: movingID,
            slots: slots,
            pointer: CGPoint(x: 100, y: 100)
        )

        let preview = try XCTUnwrap(
            coordinator.update(pointer: CGPoint(x: 400, y: 400))
        )

        guard case .move(let transaction) = preview else {
            return XCTFail("expected a move preview, got \(preview)")
        }
        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(
            transaction.proposal.first { $0.id == movingID }?.rect,
            GridRect(x: 3, y: 3, width: 3, height: 3)
        )
    }

    func testPointerOverAnotherSlotSelectsCompleteRectSwap() throws {
        let movingID = UUID()
        let targetID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 3, height: 6),
            slot(targetID, x: 6, y: 6, width: 6, height: 3),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginMove(
            slotID: movingID,
            slots: slots,
            pointer: CGPoint(x: 100, y: 100)
        )

        let preview = try XCTUnwrap(
            coordinator.update(pointer: CGPoint(x: 900, y: 750))
        )

        guard case .swap(let transaction) = preview else {
            return XCTFail("expected a swap preview, got \(preview)")
        }
        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(
            transaction.proposal.first { $0.id == movingID }?.rect,
            GridRect(x: 6, y: 6, width: 6, height: 3)
        )
        XCTAssertEqual(
            transaction.proposal.first { $0.id == targetID }?.rect,
            GridRect(x: 0, y: 0, width: 3, height: 6)
        )
    }

    func testResizePreviewUsesCoupledSpatialTransaction() throws {
        let leftID = UUID()
        let rightID = UUID()
        let slots = [
            slot(leftID, x: 0, y: 0, width: 6, height: 12),
            slot(rightID, x: 6, y: 0, width: 6, height: 12),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginResize(
            slotID: leftID,
            direction: .east,
            slots: slots,
            pointer: CGPoint(x: 600, y: 600)
        )

        let preview = try XCTUnwrap(
            coordinator.update(pointer: CGPoint(x: 800, y: 600))
        )

        guard case .resize(let transaction) = preview else {
            return XCTFail("expected a resize preview, got \(preview)")
        }
        XCTAssertTrue(transaction.isValid)
        XCTAssertFalse(transaction.isDetached)
        XCTAssertEqual(Set(transaction.affectedSlotIDs), Set([leftID, rightID]))
        XCTAssertEqual(
            transaction.proposal.first { $0.id == leftID }?.rect,
            GridRect(x: 0, y: 0, width: 8, height: 12)
        )
        XCTAssertEqual(
            transaction.proposal.first { $0.id == rightID }?.rect,
            GridRect(x: 8, y: 0, width: 4, height: 12)
        )
    }

    func testEscapeReturnsExactPointerSnapshotAndClearsPreview() throws {
        let movingID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 3, height: 3),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginMove(
            slotID: movingID,
            slots: slots,
            pointer: CGPoint(x: 100, y: 100)
        )
        _ = coordinator.update(pointer: CGPoint(x: 700, y: 700))

        XCTAssertEqual(try XCTUnwrap(coordinator.cancel()), slots)
        XCTAssertNil(coordinator.preview)
        XCTAssertNil(coordinator.finish())
    }

    func testInvalidMouseUpRollsBackInsteadOfReturningCommit() throws {
        let movingID = UUID()
        let blockingID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 6, height: 6),
            slot(blockingID, x: 6, y: 0, width: 6, height: 6),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginMove(
            slotID: movingID,
            slots: slots,
            pointer: CGPoint(x: 100, y: 100)
        )
        _ = coordinator.update(pointer: CGPoint(x: 400, y: 100))

        let result = try XCTUnwrap(coordinator.finish())

        XCTAssertEqual(result, .rollback(slots))
    }

    func testNonOriginCardConvertsParentCoordinatesForHeaderEdgeAndCloseHitTesting() {
        let parent = FlippedTestView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 400)
        )
        let card = SpatialSlotCardView(slotID: UUID())
        card.frame = CGRect(x: 120, y: 90, width: 220, height: 180)
        parent.addSubview(card)
        card.layout()

        XCTAssertTrue(
            card.hitTest(CGPoint(x: 122, y: 92)) === card,
            "the invisible north-west resize zone must receive the hit"
        )
        XCTAssertTrue(
            card.hitTest(CGPoint(x: 210, y: 108)) === card,
            "the draggable header must receive the hit"
        )
        XCTAssertTrue(
            card.hitTest(CGPoint(x: 327, y: 104)) is NSButton,
            "the close control must win over the header"
        )
    }

    func testCloseButtonDispatchesItsActionThroughNSButtonTargetAction() throws {
        let parent = FlippedTestView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 400)
        )
        let slotID = UUID()
        let card = SpatialSlotCardView(slotID: slotID)
        card.frame = CGRect(x: 120, y: 90, width: 220, height: 180)
        parent.addSubview(card)
        card.layout()
        var closedSlotID: UUID?
        card.onClose = { closedSlotID = $0 }

        let closeButton = try XCTUnwrap(
            card.hitTest(CGPoint(x: 327, y: 104)) as? NSButton
        )
        closeButton.performClick(nil)

        XCTAssertEqual(closedSlotID, slotID)
    }

    /// The canvas itself is undecorated — it is the background the gutters show through.
    /// The card carries the chrome, inset by half a gutter on every side
    /// (`SpatialCanvasView.applyFrames`). Expectations are derived from `TenonTheme` so
    /// retuning the theme moves this test with it instead of freezing today's numbers.
    func testCanvasIsUndecoratedAndTheCardCarriesTheChromeInsideAHalfGutter() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12),
            ],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(
            fixture.canvas.subviews
                .compactMap { $0 as? SpatialSlotCardView }
                .first { $0.slotID == slotID }
        )
        let bounds = fixture.canvas.bounds
        let inset = TenonTheme.slotGutter / 2

        XCTAssertEqual(fixture.canvas.layer?.borderWidth, 0)
        XCTAssertEqual(fixture.canvas.layer?.cornerRadius, 0)
        // Stated independently of the theme, so retuning `slotGutter` to zero fails here
        // instead of quietly moving the expectation along with the code.
        XCTAssertGreaterThan(card.frame.minX, bounds.minX)
        XCTAssertGreaterThan(card.frame.minY, bounds.minY)
        XCTAssertLessThan(card.frame.maxX, bounds.maxX)
        XCTAssertLessThan(card.frame.maxY, bounds.maxY)
        XCTAssertGreaterThan(
            card.layer?.cornerRadius ?? 0,
            0,
            "a pane reads as a card, not as a rectangle of background"
        )
        // And the exact geometry today, which is what makes a layout regression legible.
        XCTAssertEqual(
            card.frame,
            bounds.insetBy(dx: inset, dy: inset),
            "a single full-width slot still leaves a half-gutter margin"
        )
    }

    /// The functional half of the gutter, and the reason it is not merely decorative:
    /// two neighbours are separated by a full gutter, so their resize edges can never
    /// land on the same pixel and a drag is always unambiguous about which pane it grabs.
    func testNeighbouringCardsAreSeparatedByAFullGutterSoResizeEdgesNeverOverlap() throws {
        let leftID = UUID()
        let rightID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(leftID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(rightID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: leftID
        )
        defer { fixture.window.orderOut(nil) }
        let cards = fixture.canvas.subviews
            .compactMap { $0 as? SpatialSlotCardView }
        let left = try XCTUnwrap(cards.first { $0.slotID == leftID })
        let right = try XCTUnwrap(cards.first { $0.slotID == rightID })

        // The rule, stated without reference to the theme: there is a gap at all. Remove
        // the gutter and two resize edges land on the same pixel, which is the ambiguity
        // the inset exists to prevent.
        XCTAssertGreaterThan(
            right.frame.minX - left.frame.maxX,
            0,
            "neighbours must not share an edge, or a resize drag cannot say which pane it grabbed"
        )
        // And its size today.
        XCTAssertEqual(
            right.frame.minX - left.frame.maxX,
            TenonTheme.slotGutter
        )
    }

    func testInvalidLayoutPreviewKeepsItsErrorBorder() {
        let card = SpatialSlotCardView(slotID: UUID())

        card.setState(isActive: true, previewIsValid: nil)
        let resting = try? XCTUnwrap(card.layer?.borderWidth)
        XCTAssertEqual(resting, 1)

        card.setState(isActive: true, previewIsValid: false)
        XCTAssertEqual(card.layer?.borderWidth, 1.5)
        XCTAssertGreaterThan(
            card.layer?.borderWidth ?? 0,
            resting ?? 0,
            "an invalid preview must read as heavier than a resting card, not merely different"
        )
    }

    func testCloseInactiveSlotDoesNotFocusItBeforeTheCloseAction() throws {
        let activeID = UUID()
        let inactiveID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(inactiveID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }
        let inactiveCard = try XCTUnwrap(
            fixture.canvas.subviews
                .compactMap { $0 as? SpatialSlotCardView }
                .first { $0.slotID == inactiveID }
        )
        inactiveCard.layout()
        let closePoint = CGPoint(
            x: inactiveCard.frame.maxX - 15,
            y: inactiveCard.frame.minY + 14
        )

        fixture.canvas.handleLocalLeftMouseDown(at: closePoint)
        let closeButton = try XCTUnwrap(
            inactiveCard.hitTest(closePoint) as? NSButton
        )
        closeButton.performClick(nil)

        XCTAssertEqual(fixture.store.catalog.activeSlotID, activeID)
        XCTAssertNil(fixture.store.catalog.slot(id: inactiveID))
    }

    func testActiveDragKeepsCanvasFocusUntilMouseUpThenRestoresResponder() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(slotID, x: 0, y: 0, width: 3, height: 3),
            ],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let previousResponder = FocusProbeView(frame: .zero)
        fixture.container.addSubview(previousResponder)
        XCTAssertTrue(fixture.window.makeFirstResponder(previousResponder))

        fixture.canvas.begin(
            slotID: slotID,
            region: .header,
            pointer: CGPoint(x: 100, y: 100)
        )
        fixture.canvas.drag(to: CGPoint(x: 400, y: 100))

        XCTAssertTrue(fixture.window.firstResponder === fixture.canvas)

        fixture.canvas.end()

        XCTAssertTrue(fixture.window.firstResponder === previousResponder)
        XCTAssertEqual(
            fixture.store.catalog.slot(id: slotID)?.rect,
            GridRect(x: 3, y: 0, width: 3, height: 3)
        )
    }

    func testInactiveDragDoesNotChangeFocusBeforeEscapeAndRestoresResponder() throws {
        let activeID = UUID()
        let inactiveID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 3, height: 3),
                workspaceSlot(inactiveID, x: 6, y: 0, width: 3, height: 3),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }
        let previousResponder = FocusProbeView(frame: .zero)
        fixture.container.addSubview(previousResponder)
        XCTAssertTrue(fixture.window.makeFirstResponder(previousResponder))

        fixture.canvas.begin(
            slotID: inactiveID,
            region: .header,
            pointer: CGPoint(x: 700, y: 100)
        )
        fixture.canvas.drag(to: CGPoint(x: 700, y: 400))

        XCTAssertEqual(fixture.store.catalog.activeSlotID, activeID)
        XCTAssertTrue(fixture.window.firstResponder === fixture.canvas)

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        fixture.canvas.keyDown(with: escape)

        XCTAssertEqual(fixture.store.catalog.activeSlotID, activeID)
        XCTAssertTrue(fixture.window.firstResponder === previousResponder)
        XCTAssertEqual(
            fixture.store.catalog.slot(id: inactiveID)?.rect,
            GridRect(x: 6, y: 0, width: 3, height: 3)
        )
    }

    func testInactiveFileDragRestoresPreviousResponderAfterCommit() throws {
        let activeID = UUID()
        let inactiveFileID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 3, height: 3),
                workspaceSlot(
                    inactiveFileID,
                    x: 6,
                    y: 0,
                    width: 3,
                    height: 3,
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }
        let previousResponder = FocusProbeView(frame: .zero)
        fixture.container.addSubview(previousResponder)
        XCTAssertTrue(fixture.window.makeFirstResponder(previousResponder))

        fixture.canvas.begin(
            slotID: inactiveFileID,
            region: .header,
            pointer: CGPoint(x: 700, y: 100)
        )
        fixture.canvas.drag(to: CGPoint(x: 700, y: 400))
        fixture.canvas.end()

        XCTAssertEqual(fixture.store.catalog.activeSlotID, inactiveFileID)
        XCTAssertTrue(fixture.window.firstResponder === previousResponder)
    }

    func testInactiveTerminalDragRestoresThenRequestsFocusForNewTerminal() throws {
        let activeID = UUID()
        let inactiveTerminalID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 3, height: 3),
                workspaceSlot(inactiveTerminalID, x: 6, y: 0, width: 3, height: 3),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }
        let previousResponder = FocusProbeView(frame: .zero)
        fixture.container.addSubview(previousResponder)
        XCTAssertTrue(fixture.window.makeFirstResponder(previousResponder))
        let surface = fixture.pool.surface(
            for: inactiveTerminalID,
            workspacePath: fixture.workspacePath
        ) as! StubTerminalSurface
        let focusCountBefore = surface.focusCount

        fixture.canvas.begin(
            slotID: inactiveTerminalID,
            region: .header,
            pointer: CGPoint(x: 700, y: 100)
        )
        fixture.canvas.drag(to: CGPoint(x: 700, y: 400))
        fixture.canvas.end()

        XCTAssertTrue(fixture.window.firstResponder === previousResponder)
        let focused = expectation(description: "new terminal focus requested")
        DispatchQueue.main.async {
            XCTAssertGreaterThan(surface.focusCount, focusCountBefore)
            focused.fulfill()
        }
        wait(for: [focused], timeout: 1)
    }

    func testRejectedStaleGestureRendersTheAuthoritativeStoreGeometry() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(slotID, x: 0, y: 0, width: 3, height: 3),
            ],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(
            fixture.canvas.subviews
                .compactMap { $0 as? SpatialSlotCardView }
                .first { $0.slotID == slotID }
        )

        fixture.canvas.begin(
            slotID: slotID,
            region: .header,
            pointer: CGPoint(x: 100, y: 100)
        )
        fixture.canvas.drag(to: CGPoint(x: 400, y: 100))

        let intervening = SpatialLayout.move(
            fixture.store.catalog.activeTab!.spatialSlots,
            slotID: slotID,
            toColumn: 0,
            row: 3
        )
        fixture.store.applyMove(intervening)
        fixture.canvas.end()

        XCTAssertEqual(
            fixture.store.catalog.slot(id: slotID)?.rect,
            GridRect(x: 0, y: 3, width: 3, height: 3)
        )
        // Row 3 of a 12-row canvas, plus the half-gutter inset every card carries.
        let inset = TenonTheme.slotGutter / 2
        XCTAssertEqual(
            card.frame.origin,
            CGPoint(x: inset, y: 300 + inset)
        )
    }

    func testHeaderContextMenuOffersSplitStackDuplicateAndClose() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Split", "Stack", "Duplicate", "", "Close"]
        )
        XCTAssertTrue(try menuItem(menu, "Split").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Stack").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Duplicate").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Close").isEnabled)
        XCTAssertTrue(
            menu.items.allSatisfy { $0.submenu == nil },
            "the pane menu is flat — no submenu to walk into"
        )
    }

    func testHeaderContextMenuSplitTargetsTheClickedSlotNotTheActiveOne() throws {
        let activeID = UUID()
        let clickedID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(clickedID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: clickedID))
        try menuItem(menu, "Split").invoke()

        let tab = try XCTUnwrap(fixture.store.catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 3)
        let clicked = try XCTUnwrap(tab.slots.first { $0.id == clickedID })
        XCTAssertEqual(clicked.rect, GridRect(x: 6, y: 0, width: 3, height: 12))
        XCTAssertNotEqual(tab.activeSlotID, activeID)
        XCTAssertNotEqual(tab.activeSlotID, clickedID)
    }

    func testHeaderContextMenuStackSplitsTheClickedSlotDownward() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))
        try menuItem(menu, "Stack").invoke()

        let tab = try XCTUnwrap(fixture.store.catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 2)
        let top = try XCTUnwrap(tab.slots.first { $0.id == slotID })
        XCTAssertEqual(top.rect, GridRect(x: 0, y: 0, width: 12, height: 6))
        let bottom = try XCTUnwrap(tab.slots.first { $0.id != slotID })
        XCTAssertEqual(bottom.rect, GridRect(x: 0, y: 6, width: 12, height: 6))
    }

    func testHeaderContextMenuDisablesSplitWhenNarrowAndStackWhenShort() throws {
        let narrowID = UUID()
        let shortID = UUID()
        let fillID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(narrowID, x: 0, y: 0, width: 3, height: 12),
                workspaceSlot(shortID, x: 3, y: 0, width: 9, height: 3),
                workspaceSlot(fillID, x: 3, y: 3, width: 9, height: 9),
            ],
            activeSlotID: fillID
        )
        defer { fixture.window.orderOut(nil) }

        let narrowMenu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: narrowID))
        XCTAssertFalse(try menuItem(narrowMenu, "Split").isEnabled)
        XCTAssertTrue(try menuItem(narrowMenu, "Stack").isEnabled)

        let shortMenu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: shortID))
        XCTAssertTrue(try menuItem(shortMenu, "Split").isEnabled)
        XCTAssertFalse(try menuItem(shortMenu, "Stack").isEnabled)
    }

    func testHeaderContextMenuCloseRemovesTheClickedSlot() throws {
        let activeID = UUID()
        let clickedID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(clickedID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: clickedID))
        try menuItem(menu, "Close").invoke()

        XCTAssertNil(fixture.store.catalog.slot(id: clickedID))
        XCTAssertNotNil(fixture.store.catalog.slot(id: activeID))
    }

    func testHeaderContextMenuDuplicateOpensASecondPaneWithTheSameContent() throws {
        let activeID = UUID()
        let clickedID = UUID()
        let tree = SlotContent.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(clickedID, x: 6, y: 0, width: 6, height: 12, content: tree),
            ],
            activeSlotID: activeID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: clickedID))
        try menuItem(menu, "Duplicate").invoke()

        let tab = try XCTUnwrap(fixture.store.catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 3)
        let copy = try XCTUnwrap(tab.slots.first { $0.id != activeID && $0.id != clickedID })
        XCTAssertEqual(copy.content, tree, "the copy shows what the clicked pane showed")
        XCTAssertEqual(tab.activeSlotID, copy.id)
        XCTAssertEqual(
            fixture.store.catalog.slot(id: activeID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "duplicating the clicked pane left the other one alone"
        )
    }

    func testHeaderContextMenuDisablesDuplicateWhenThePaneCanNeitherFitNorSplit() throws {
        let crampedID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(crampedID, x: 0, y: 0, width: 3, height: 3),
                workspaceSlot(UUID(), x: 3, y: 0, width: 9, height: 12),
                workspaceSlot(UUID(), x: 0, y: 3, width: 3, height: 9),
            ],
            activeSlotID: crampedID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: crampedID))
        XCTAssertFalse(try menuItem(menu, "Duplicate").isEnabled)
    }

    func testHeaderMenuAppearsForHeaderRegionAndNotTheBody() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(
            fixture.canvas.subviews
                .compactMap { $0 as? SpatialSlotCardView }
                .first { $0.slotID == slotID }
        )

        let headerEvent = try rightMouseEvent(
            card,
            local: CGPoint(x: card.bounds.midX, y: 15),
            window: fixture.window
        )
        let bodyEvent = try rightMouseEvent(
            card,
            local: CGPoint(x: card.bounds.midX, y: card.bounds.midY),
            window: fixture.window
        )

        XCTAssertNotNil(card.menu(for: headerEvent))
        XCTAssertNil(card.menu(for: bodyEvent))
    }

    private func menuItem(_ menu: NSMenu, _ title: String) throws -> SlotMenuItem {
        try XCTUnwrap(menu.item(withTitle: title) as? SlotMenuItem)
    }

    private func rightMouseEvent(
        _ card: SpatialSlotCardView,
        local: CGPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: card.convert(local, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func slot(
        _ id: UUID,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> SpatialSlot {
        SpatialSlot(
            id: id,
            rect: GridRect(x: x, y: y, width: width, height: height)
        )
    }

    private func workspaceSlot(
        _ id: UUID,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        content: SlotContent = .terminal
    ) -> WorkspaceSlot {
        WorkspaceSlot(
            id: id,
            rect: GridRect(
                x: x,
                y: y,
                width: width,
                height: height
            ),
            content: content
        )
    }

    private func makeCanvasFixture(
        slots: [WorkspaceSlot],
        activeSlotID: UUID
    ) throws -> CanvasFixture {
        let tab = TenonCore.Tab(
            slots: slots,
            activeSlotID: activeSlotID
        )
        let workspacePath = FileManager.default.temporaryDirectory
        let workspace = Workspace(
            name: "Test",
            path: workspacePath,
            tabs: [tab],
            activeTabID: tab.id
        )
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )
        )
        let pool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }
        let pluginsRoot = workspacePath
            .appendingPathComponent("tenon-empty-plugins-\(UUID())")
        let stateRoot = workspacePath
            .appendingPathComponent("tenon-empty-plugins-state-\(UUID())")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: stateRoot)
        }
        // An empty plugin root on purpose: these tests are about pointer geometry on the
        // canvas, so the host is present only to satisfy `configure` and must contribute
        // no panes of its own.
        let host = try PluginHost(
            pluginsRoot: pluginsRoot,
            stateRoot: stateRoot,
            kernel: IntentKernelComponents(
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            )
        )
        let router = DragRouter()
        let container = FlippedTestView(
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 1_200)
        )
        let canvas = SpatialCanvasNSView(frame: container.bounds)
        container.addSubview(canvas)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        canvas.configure(
            tab: tab,
            workspacePath: workspacePath,
            allLiveSlotIDs: Set(slots.map(\.id)),
            activeSlotID: activeSlotID,
            store: store,
            pool: pool,
            webPool: PluginWebSurfacePool(),
            host: host,
            editorStates: EditorPaneStateStore(),
            pluginSnapshots: [],
            pluginViewSections: [],
            webSurfaceTitles: [:],
            paneAttention: [:],
            router: router
        )
        canvas.layout()
        return CanvasFixture(
            window: window,
            container: container,
            canvas: canvas,
            store: store,
            pool: pool,
            router: router,
            workspacePath: workspacePath
        )
    }
}

private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}

private final class FocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct CanvasFixture {
    let window: NSWindow
    let container: FlippedTestView
    let canvas: SpatialCanvasNSView
    let store: WorkspaceStore
    let pool: SurfacePool
    let router: DragRouter
    let workspacePath: URL
}
