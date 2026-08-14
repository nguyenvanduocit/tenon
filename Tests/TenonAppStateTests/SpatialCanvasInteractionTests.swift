import XCTest
import AppKit
import SwiftUI
@testable import TenonApp
import TenonCore
import TenonIntentCore

@MainActor
final class SpatialCanvasInteractionTests: XCTestCase {
    /// `withObservationTracking` hands its `onChange` a `@Sendable` closure, so the flag it
    /// raises cannot be a captured local `var`. Every use here is synchronous and on the
    /// main actor, which is what makes the unchecked conformance honest.
    private final class ObservationFlag: @unchecked Sendable {
        var didChange = false
    }

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

    func testEmptyGridLauncherAnchorExistsOnlyInAnUnoccupiedGridCell() {
        let slots = [
            slot(UUID(), x: 0, y: 0, width: 6, height: 12),
        ]

        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.emptyGridLauncherAnchor(
                at: CGPoint(x: 900, y: 600),
                canvasSize: CGSize(width: 1_200, height: 1_200),
                slots: slots
            ),
            CGPoint(x: 900, y: 600)
        )
        XCTAssertNil(
            SpatialCanvasInteractionCoordinator.emptyGridLauncherAnchor(
                at: CGPoint(x: 599, y: 600),
                canvasSize: CGSize(width: 1_200, height: 1_200),
                slots: slots
            ),
            "the visual gutter inside an occupied cell is not empty grid space"
        )
        XCTAssertNil(
            SpatialCanvasInteractionCoordinator.emptyGridLauncherAnchor(
                at: CGPoint(x: 1_200, y: 600),
                canvasSize: CGSize(width: 1_200, height: 1_200),
                slots: slots
            ),
            "a right-click outside the canvas cannot open its launcher"
        )
    }

    func testEmptyGridLauncherTargetCarriesTheClickedEmptyRegion() {
        let target = SpatialCanvasInteractionCoordinator.emptyGridLauncherTarget(
            at: CGPoint(x: 900, y: 600),
            canvasSize: CGSize(width: 1_200, height: 1_200),
            slots: [slot(UUID(), x: 0, y: 0, width: 6, height: 12)]
        )

        XCTAssertEqual(target?.anchor, CGPoint(x: 900, y: 600))
        XCTAssertEqual(target?.rect, GridRect(x: 6, y: 0, width: 6, height: 12))
    }

    func testACreationMaximumNarrowsTheClickedRegionAroundTheCellClicked() {
        // Column 11 of a hole spanning 0…12, capped to 4 columns. Left-anchoring would
        // open the pane at columns 0…4 — nowhere near the pointer.
        let target = SpatialCanvasInteractionCoordinator.emptyGridLauncherTarget(
            at: CGPoint(x: 1_150, y: 600),
            canvasSize: CGSize(width: 1_200, height: 1_200),
            slots: [],
            sizing: NewPaneSizing(maximumWidth: .oneThird)
        )

        XCTAssertEqual(target?.rect, GridRect(x: 8, y: 0, width: 4, height: 12))
    }

    func testWithNoCreationMaximumTheClickedRegionIsTheWholeHole() {
        let target = SpatialCanvasInteractionCoordinator.emptyGridLauncherTarget(
            at: CGPoint(x: 1_150, y: 600),
            canvasSize: CGSize(width: 1_200, height: 1_200),
            slots: [],
            sizing: .unlimited
        )

        XCTAssertEqual(target?.rect, GridRect(x: 0, y: 0, width: 12, height: 12))
    }

    func testAccessibilityOffersEachFillableEmptyRegion() throws {
        let barrierID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(barrierID, x: 3, y: 0, width: 3, height: 12)],
            activeSlotID: barrierID
        )
        defer { fixture.window.orderOut(nil) }
        var requestedRects: [GridRect] = []
        fixture.canvas.onPresentEmptyGridLauncher = { _, rect in requestedRects.append(rect) }

        let actions = try XCTUnwrap(fixture.canvas.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), [
            "Fill empty region, columns 1 through 3, rows 1 through 12",
            "Fill empty region, columns 7 through 12, rows 1 through 12",
        ])
        XCTAssertEqual(actions[1].handler?(), true)
        XCTAssertEqual(requestedRects, [GridRect(x: 6, y: 0, width: 6, height: 12)])
    }

    func testOptionReturnReachesCanvasThroughAChildFirstResponder() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 6, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let focusedChild = FocusProbeView(frame: .zero)
        fixture.container.addSubview(focusedChild)
        XCTAssertTrue(fixture.window.makeFirstResponder(focusedChild))
        var requestedRect: GridRect?
        fixture.canvas.onPresentEmptyGridLauncher = { _, rect in requestedRect = rect }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        NSApp.sendEvent(event)

        XCTAssertEqual(requestedRect, GridRect(x: 6, y: 0, width: 6, height: 12))
        XCTAssertTrue(fixture.window.firstResponder === focusedChild)
    }

    func testRightClickingEmptyGridRequestsLauncherAtThePointer() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 6, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        var requestedAnchor: NSRect?
        fixture.canvas.onPresentEmptyGridLauncher = { anchor, _ in requestedAnchor = anchor }
        let point = CGPoint(x: 900, y: 600)
        let event = try rightMouseEvent(
            fixture.canvas,
            local: point,
            window: fixture.window
        )

        fixture.canvas.rightMouseDown(with: event)

        XCTAssertEqual(requestedAnchor?.origin, point)
    }

    func testRightClickingAnOccupiedGridCellDoesNotRequestTheGridLauncher() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 6, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        var requestCount = 0
        fixture.canvas.onPresentEmptyGridLauncher = { _, _ in requestCount += 1 }
        let event = try rightMouseEvent(
            fixture.canvas,
            local: CGPoint(x: 599, y: 600),
            window: fixture.window
        )

        fixture.canvas.rightMouseDown(with: event)

        XCTAssertEqual(requestCount, 0)
    }

    func testPaneDropEdgeUsesTheFourTriangularTargetQuadrants() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 200)

        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.dropEdge(
                at: CGPoint(x: 120, y: 300),
                in: frame
            ),
            .left
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.dropEdge(
                at: CGPoint(x: 480, y: 300),
                in: frame
            ),
            .right
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.dropEdge(
                at: CGPoint(x: 300, y: 210),
                in: frame
            ),
            .top
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.dropEdge(
                at: CGPoint(x: 300, y: 390),
                in: frame
            ),
            .bottom
        )
    }

    func testHeaderDragKeepsTheLivePaneInPlaceAndCarriesAKeroStyleThumbnail() throws {
        let sourceID = UUID()
        let targetID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(sourceID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(targetID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: sourceID
        )
        defer { fixture.window.orderOut(nil) }
        let source = try XCTUnwrap(fixture.card(for: sourceID))
        let target = try XCTUnwrap(fixture.card(for: targetID))
        let sourceFrame = source.frame
        let pointer = CGPoint(x: 1_100, y: 600)

        fixture.canvas.begin(
            slotID: sourceID,
            region: .header,
            pointer: CGPoint(x: 300, y: 20)
        )
        fixture.canvas.drag(to: pointer)

        XCTAssertEqual(source.frame, sourceFrame, "the live surface stays mounted in its layout")
        XCTAssertEqual(source.alphaValue, 0.55, accuracy: 0.001)
        let thumbnail = try XCTUnwrap(fixture.canvas.dragThumbnailView)
        XCTAssertEqual(thumbnail.frame.midX, pointer.x, accuracy: 0.5)
        XCTAssertEqual(thumbnail.frame.midY, pointer.y, accuracy: 0.5)
        XCTAssertLessThanOrEqual(thumbnail.frame.width, 220)
        XCTAssertLessThanOrEqual(thumbnail.frame.height, 160)
        XCTAssertEqual(
            thumbnail.frame.width / thumbnail.frame.height,
            sourceFrame.width / sourceFrame.height,
            accuracy: 0.001
        )
        XCTAssertEqual(thumbnail.alphaValue, 0.9, accuracy: 0.001)

        let highlight = try XCTUnwrap(fixture.canvas.dropHighlightView)
        XCTAssertEqual(highlight.frame, CGRect(
            x: target.frame.midX,
            y: target.frame.minY,
            width: target.frame.width / 2,
            height: target.frame.height
        ))

        fixture.canvas.end()

        XCTAssertEqual(fixture.store.catalog.slot(id: sourceID)?.rect, GridRect(
            x: 6, y: 0, width: 6, height: 12
        ))
        XCTAssertEqual(fixture.store.catalog.slot(id: targetID)?.rect, GridRect(
            x: 0, y: 0, width: 6, height: 12
        ))
        XCTAssertEqual(source.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
        XCTAssertNil(fixture.canvas.dropHighlightView)
    }

    func testHeaderDragIntoEmptyGridCommitsTheSnappedMove() throws {
        let movingID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(movingID, x: 0, y: 0, width: 6, height: 12)],
            activeSlotID: movingID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: movingID))
        let originalFrame = card.frame

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 300, y: 20)
        )
        fixture.canvas.drag(to: CGPoint(x: 900, y: 20))

        XCTAssertEqual(card.frame, originalFrame, "the live surface stays mounted while carried")
        XCTAssertEqual(card.alphaValue, 0.55, accuracy: 0.001)
        XCTAssertNotNil(fixture.canvas.dragThumbnailView)
        let highlight = try XCTUnwrap(fixture.canvas.dropHighlightView)
        let inset = TenonTheme.slotGutter / 2
        XCTAssertEqual(highlight.frame, CGRect(
            x: 600 + inset,
            y: inset,
            width: 600 - TenonTheme.slotGutter,
            height: 1_200 - TenonTheme.slotGutter
        ))

        fixture.canvas.end()

        XCTAssertEqual(
            fixture.store.catalog.slot(id: movingID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
        XCTAssertNil(fixture.canvas.dropHighlightView)
    }

    func testKeroStylePickupStillReparentsToTheExistingTabBarTarget() throws {
        let leftID = UUID()
        let movingID = UUID()
        let targetSlotID = UUID()
        let targetTab = TenonCore.Tab(
            slots: [workspaceSlot(targetSlotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: targetSlotID
        )
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(leftID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(movingID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: movingID,
            additionalTabs: [targetTab]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)
        fixture.router.tabChipFrames = [
            targetTab.id: CGRect(x: 800, y: 1_200, width: 200, height: 50),
        ]

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 900, y: 20)
        )
        fixture.canvas.drag(
            to: CGPoint(x: 900, y: -20),
            window: CGPoint(x: 900, y: 1_225)
        )

        XCTAssertEqual(fixture.router.activeDropTarget, .existingTab(targetTab.id))
        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        XCTAssertNotNil(fixture.canvas.dragThumbnailView)
        XCTAssertEqual(NSCursor.current, .closedHand)

        fixture.canvas.end()

        XCTAssertEqual(fixture.store.catalog.activeWorkspace?.tabs.count, 2)
        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        XCTAssertEqual(Set(fixture.store.catalog.activeTab?.slots.map(\.id) ?? []), [
            targetSlotID,
            movingID,
        ])
        XCTAssertEqual(
            fixture.store.catalog.slot(id: leftID)?.rect,
            GridRect(x: 0, y: 0, width: 12, height: 12)
        )
        XCTAssertEqual(fixture.router.activeDropTarget, .none)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
    }

    func testHoverSelectedTabBodyChoosesAndCommitsCrossTabDropEdge() throws {
        let survivorID = UUID()
        let movingID = UUID()
        let targetID = UUID()
        let targetTab = TenonCore.Tab(
            slots: [workspaceSlot(targetID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: targetID
        )
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(survivorID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(movingID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: movingID,
            additionalTabs: [targetTab]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)
        fixture.router.tabChipFrames = [
            targetTab.id: CGRect(x: 800, y: 1_200, width: 200, height: 50),
        ]

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 900, y: 20)
        )
        fixture.canvas.drag(
            to: CGPoint(x: 900, y: -20),
            window: CGPoint(x: 900, y: 1_225)
        )

        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        fixture.reconfigure()
        let targetCard = try XCTUnwrap(fixture.card(for: targetID))
        let bodyPoint = CGPoint(x: targetCard.frame.minX + 20, y: targetCard.frame.midY)
        fixture.canvas.drag(to: bodyPoint)

        XCTAssertEqual(
            fixture.router.paneDrag?.bodyTarget,
            RoutedPaneDropTarget(
                tabID: targetTab.id,
                destination: .beside(slotID: targetID, edge: .left)
            )
        )
        XCTAssertEqual(
            fixture.canvas.dropHighlightView?.frame,
            CGRect(
                x: targetCard.frame.minX,
                y: targetCard.frame.minY,
                width: targetCard.frame.width / 2,
                height: targetCard.frame.height
            )
        )

        fixture.canvas.end()

        XCTAssertEqual(
            fixture.store.catalog.slot(id: movingID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: targetID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: survivorID)?.rect,
            GridRect(x: 0, y: 0, width: 12, height: 12)
        )
        XCTAssertNil(fixture.router.paneDrag)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
        XCTAssertNil(fixture.canvas.dropHighlightView)
    }

    func testHoverSelectedTabBodyAcceptsAnEmptyRegionAndCommitsTheMove() throws {
        let survivorID = UUID()
        let movingID = UUID()
        let targetID = UUID()
        // The revealed tab's right half is empty canvas.
        let targetTab = TenonCore.Tab(
            slots: [workspaceSlot(targetID, x: 0, y: 0, width: 6, height: 12)],
            activeSlotID: targetID
        )
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(survivorID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(movingID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: movingID,
            additionalTabs: [targetTab]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)
        fixture.router.tabChipFrames = [
            targetTab.id: CGRect(x: 800, y: 1_200, width: 200, height: 50),
        ]

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 900, y: 20)
        )
        fixture.canvas.drag(
            to: CGPoint(x: 900, y: -20),
            window: CGPoint(x: 900, y: 1_225)
        )
        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        fixture.reconfigure()

        fixture.canvas.drag(to: CGPoint(x: 900, y: 600))

        let hole = GridRect(x: 6, y: 0, width: 6, height: 12)
        XCTAssertEqual(
            fixture.router.paneDrag?.bodyTarget,
            RoutedPaneDropTarget(tabID: targetTab.id, destination: .emptyRegion(hole))
        )
        let inset = TenonTheme.slotGutter / 2
        XCTAssertEqual(
            fixture.canvas.dropHighlightView?.frame,
            CGRect(
                x: 600 + inset,
                y: inset,
                width: 600 - TenonTheme.slotGutter,
                height: 1_200 - TenonTheme.slotGutter
            ),
            "the highlight promises exactly the committed pane's inset frame"
        )

        fixture.canvas.end()

        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        XCTAssertEqual(fixture.store.catalog.slot(id: movingID)?.rect, hole)
        XCTAssertEqual(
            fixture.store.catalog.slot(id: targetID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "landing on empty canvas reshapes no existing pane"
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: survivorID)?.rect,
            GridRect(x: 0, y: 0, width: 12, height: 12)
        )
        XCTAssertNil(fixture.router.paneDrag)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
        XCTAssertNil(fixture.canvas.dropHighlightView)
    }

    func testHoverSelectedTabBodyRefusesARegionTooSmallForAPane() throws {
        let movingID = UUID()
        let targetID = UUID()
        // The free band below the pane is 12x2 cells — under the minimum pane height.
        let targetTab = TenonCore.Tab(
            slots: [workspaceSlot(targetID, x: 0, y: 0, width: 12, height: 10)],
            activeSlotID: targetID
        )
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(movingID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: movingID,
            additionalTabs: [targetTab]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)
        fixture.router.tabChipFrames = [
            targetTab.id: CGRect(x: 800, y: 1_200, width: 200, height: 50),
        ]

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 900, y: 20)
        )
        fixture.canvas.drag(
            to: CGPoint(x: 900, y: -20),
            window: CGPoint(x: 900, y: 1_225)
        )
        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        fixture.reconfigure()

        fixture.canvas.drag(to: CGPoint(x: 600, y: 1_150))

        XCTAssertNil(
            fixture.router.paneDrag?.bodyTarget,
            "a region no pane fits in is not a destination"
        )
    }

    func testRoutedDragMonitorSurvivesRemovingTheMouseDownCard() throws {
        let survivorID = UUID()
        let movingID = UUID()
        let targetID = UUID()
        let targetTab = TenonCore.Tab(
            slots: [workspaceSlot(targetID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: targetID
        )
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(survivorID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(movingID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: movingID,
            additionalTabs: [targetTab]
        )
        defer {
            fixture.canvas.prepareForRemoval()
            fixture.window.orderOut(nil)
        }
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)
        fixture.router.tabChipFrames = [
            targetTab.id: CGRect(x: 800, y: 1_200, width: 200, height: 50),
        ]
        let sourceCard = try XCTUnwrap(fixture.card(for: movingID))

        sourceCard.mouseDown(with: try leftMouseEvent(
            .leftMouseDown,
            windowPoint: sourceCard.convert(
                CGPoint(x: sourceCard.bounds.midX, y: 12),
                to: nil
            ),
            window: fixture.window,
            eventNumber: 1
        ))
        sourceCard.mouseDragged(with: try leftMouseEvent(
            .leftMouseDragged,
            windowPoint: CGPoint(x: 900, y: 1_225),
            window: fixture.window,
            eventNumber: 2
        ))
        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)

        fixture.reconfigure()
        XCTAssertNil(sourceCard.superview, "the original AppKit mouse receiver is detached")
        let targetCard = try XCTUnwrap(fixture.card(for: targetID))
        let bodyPoint = CGPoint(x: targetCard.frame.minX + 20, y: targetCard.frame.midY)
        NSApp.sendEvent(try leftMouseEvent(
            .leftMouseDragged,
            windowPoint: fixture.canvas.convert(bodyPoint, to: nil),
            window: fixture.window,
            eventNumber: 3
        ))

        XCTAssertEqual(
            fixture.router.paneDrag?.bodyTarget,
            RoutedPaneDropTarget(
                tabID: targetTab.id,
                destination: .beside(slotID: targetID, edge: .left)
            )
        )

        NSApp.sendEvent(try leftMouseEvent(
            .leftMouseUp,
            windowPoint: fixture.canvas.convert(bodyPoint, to: nil),
            window: fixture.window,
            eventNumber: 4
        ))

        XCTAssertEqual(
            fixture.store.catalog.slot(id: movingID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: targetID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        XCTAssertNil(fixture.router.paneDrag)
    }

    func testCancellingAfterHoverTabSwitchLeavesPaneInSourceTab() throws {
        let survivorID = UUID()
        let movingID = UUID()
        let targetID = UUID()
        let targetTab = TenonCore.Tab(
            slots: [workspaceSlot(targetID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: targetID
        )
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(survivorID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(movingID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: movingID,
            additionalTabs: [targetTab]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)
        fixture.router.tabChipFrames = [
            targetTab.id: CGRect(x: 800, y: 1_200, width: 200, height: 50),
        ]

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 900, y: 20)
        )
        fixture.canvas.drag(
            to: CGPoint(x: 900, y: -20),
            window: CGPoint(x: 900, y: 1_225)
        )
        fixture.reconfigure()

        XCTAssertTrue(fixture.canvas.cancelGesture())
        XCTAssertEqual(fixture.store.catalog.activeTab?.id, targetTab.id)
        XCTAssertNotNil(fixture.store.catalog.slot(id: movingID))
        XCTAssertEqual(
            fixture.store.catalog.activeTab?.slots.map(\.id),
            [targetID]
        )
        XCTAssertNil(fixture.router.paneDrag)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
    }

    func testHiddenCardsFromAnotherTabCannotInterceptAPaneDrop() throws {
        let hiddenID = UUID()
        let movingID = UUID()
        let visibleTargetID = UUID()
        let sourceTab = TenonCore.Tab(
            slots: [
                workspaceSlot(movingID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(visibleTargetID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: movingID
        )
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(hiddenID, x: 6, y: 0, width: 6, height: 12)],
            activeSlotID: hiddenID,
            additionalTabs: [sourceTab]
        )
        defer { fixture.window.orderOut(nil) }

        fixture.store.selectTab(sourceTab.id)
        fixture.reconfigure()
        XCTAssertNil(fixture.card(for: hiddenID))

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 300, y: 40)
        )
        fixture.canvas.drag(to: CGPoint(x: 1_050, y: 600))

        XCTAssertNotNil(fixture.canvas.dropHighlightView)
        fixture.canvas.end()
        XCTAssertEqual(
            fixture.store.catalog.slot(id: movingID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: visibleTargetID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
    }

    func testDetachingCanvasCancelsTheOwnedDragAndClearsPresentation() throws {
        let sourceID = UUID()
        let targetID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(sourceID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(targetID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: sourceID
        )
        defer { fixture.window.orderOut(nil) }
        let source = try XCTUnwrap(fixture.card(for: sourceID))
        fixture.router.tabBarBand = CGRect(x: 0, y: 1_200, width: 1_200, height: 50)

        fixture.canvas.begin(
            slotID: sourceID,
            region: .header,
            pointer: CGPoint(x: 300, y: 40)
        )
        fixture.canvas.drag(
            to: CGPoint(x: 300, y: -20),
            window: CGPoint(x: 600, y: 1_225)
        )
        XCTAssertEqual(source.alphaValue, 0.55, accuracy: 0.001)
        XCTAssertNotNil(fixture.canvas.dragThumbnailView)
        XCTAssertEqual(fixture.router.activeDropTarget, .newTab)

        fixture.canvas.removeFromSuperview()

        XCTAssertEqual(source.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(fixture.canvas.dragThumbnailView)
        XCTAssertNil(fixture.canvas.dropHighlightView)
        XCTAssertEqual(fixture.router.activeDropTarget, .none)
        XCTAssertEqual(NSCursor.current, .arrow)
        fixture.canvas.end()
        XCTAssertEqual(fixture.store.catalog.activeWorkspace?.tabs.count, 1)
        XCTAssertEqual(
            fixture.store.catalog.slot(id: sourceID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
    }

    func testMoveIntoEmptyGridBuildsSnappedLayoutCommit() throws {
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

        let preview = try XCTUnwrap(coordinator.update(
            pointer: CGPoint(x: 400, y: 400),
            slotFrames: [
                movingID: CGRect(x: 0, y: 0, width: 300, height: 300),
                otherID: CGRect(x: 600, y: 0, width: 300, height: 300),
            ]
        ))
        XCTAssertTrue(coordinator.isCarryingPane)
        XCTAssertNil(coordinator.moveTarget)
        guard case .move(let transaction) = preview else {
            return XCTFail("expected an empty-grid move preview, got \(preview)")
        }
        XCTAssertEqual(
            transaction.proposal.first { $0.id == movingID }?.rect,
            GridRect(x: 3, y: 3, width: 3, height: 3)
        )
        XCTAssertEqual(coordinator.finish(), .commit(preview))
    }

    func testPanePickupRequiresFourPointsOfPointerTravel() {
        let movingID = UUID()
        let targetID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 3, height: 3),
            slot(targetID, x: 6, y: 0, width: 6, height: 12),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginMove(
            slotID: movingID,
            slots: slots,
            pointer: CGPoint(x: 700, y: 600)
        )
        let frames = [
            movingID: CGRect(x: 0, y: 0, width: 300, height: 300),
            targetID: CGRect(x: 600, y: 0, width: 600, height: 1_200),
        ]

        XCTAssertNil(coordinator.update(
            pointer: CGPoint(x: 703, y: 600),
            slotFrames: frames
        ))
        XCTAssertFalse(coordinator.isCarryingPane)
        XCTAssertNotNil(coordinator.update(
            pointer: CGPoint(x: 704, y: 600),
            slotFrames: frames
        ))
        XCTAssertTrue(coordinator.isCarryingPane)
    }

    func testPointerOverAnotherSlotBuildsADirectionalMoveBesideTransaction() throws {
        let movingID = UUID()
        let targetID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 3, height: 3),
            slot(targetID, x: 6, y: 0, width: 6, height: 12),
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
            coordinator.update(
                pointer: CGPoint(x: 1_100, y: 600),
                slotFrames: [
                    movingID: CGRect(x: 0, y: 0, width: 300, height: 300),
                    targetID: CGRect(x: 600, y: 0, width: 600, height: 1_200),
                ]
            )
        )

        guard case .move(let transaction) = preview else {
            return XCTFail("expected a directional move preview, got \(preview)")
        }
        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(coordinator.moveTarget, SpatialCanvasMoveTarget(
            slotID: targetID,
            edge: .right
        ))
        XCTAssertEqual(
            transaction.proposal.first { $0.id == movingID }?.rect,
            GridRect(x: 9, y: 0, width: 3, height: 12)
        )
        XCTAssertEqual(
            transaction.proposal.first { $0.id == targetID }?.rect,
            GridRect(x: 6, y: 0, width: 3, height: 12)
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

    func testMovingFromAValidTargetIntoAGapClearsTheTargetAndRollsBack() throws {
        let movingID = UUID()
        let targetID = UUID()
        let slots = [
            slot(movingID, x: 0, y: 0, width: 3, height: 3),
            slot(targetID, x: 6, y: 0, width: 6, height: 12),
        ]
        let coordinator = SpatialCanvasInteractionCoordinator(
            canvasSize: CGSize(width: 1_200, height: 1_200)
        )
        coordinator.beginMove(
            slotID: movingID,
            slots: slots,
            pointer: CGPoint(x: 100, y: 100)
        )
        let frames = [
            movingID: CGRect(x: 0, y: 0, width: 300, height: 300),
            targetID: CGRect(x: 600, y: 0, width: 600, height: 1_200),
        ]
        XCTAssertNotNil(coordinator.update(
            pointer: CGPoint(x: 1_100, y: 600),
            slotFrames: frames
        ))
        XCTAssertNil(coordinator.update(
            pointer: CGPoint(x: 450, y: 600),
            slotFrames: frames
        ))
        XCTAssertNil(coordinator.preview)
        XCTAssertNil(coordinator.moveTarget)
        XCTAssertEqual(coordinator.finish(), .rollback(slots))
    }

    func testResizeIntoAnImpossibleShapeHoldsTheLastValidResize() throws {
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
        _ = coordinator.update(pointer: CGPoint(x: 800, y: 600))

        let held = try XCTUnwrap(
            coordinator.update(pointer: CGPoint(x: 1_100, y: 600))
        )

        guard case .resize(let transaction) = held else {
            return XCTFail("expected a resize preview, got \(held)")
        }
        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(
            transaction.proposal.first { $0.id == leftID }?.rect,
            GridRect(x: 0, y: 0, width: 8, height: 12)
        )
        XCTAssertEqual(
            transaction.proposal.first { $0.id == rightID }?.rect,
            GridRect(x: 8, y: 0, width: 4, height: 12),
            "the edge stops where the neighbour's minimum width stops it"
        )
    }

    func testUnrelatedViewRefreshKeepsTheResizePreviewOnScreen() throws {
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

        fixture.canvas.begin(
            slotID: leftID,
            region: .resize(.east),
            pointer: CGPoint(x: 600, y: 600)
        )
        fixture.canvas.drag(to: CGPoint(x: 800, y: 600))
        let previewFrames = fixture.cardFrames

        // SwiftUI may update this representable while the pointer is still down for
        // unrelated title, attention, or plugin state. The model intentionally stays
        // unchanged until mouse-up, so reconfiguration must preserve the live preview.
        fixture.reconfigure()

        XCTAssertEqual(
            fixture.cardFrames,
            previewFrames,
            "an unrelated SwiftUI update must not snap a live resize back to its baseline"
        )

        fixture.canvas.end()
        XCTAssertEqual(
            fixture.store.catalog.slot(id: leftID)?.rect,
            GridRect(x: 0, y: 0, width: 8, height: 12)
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: rightID)?.rect,
            GridRect(x: 8, y: 0, width: 4, height: 12)
        )
    }

    func testDragWithoutASplittableTargetKeepsTheLiveCardAndRollsBack() throws {
        let movingID = UUID()
        let blockingID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(movingID, x: 0, y: 0, width: 3, height: 3),
                workspaceSlot(blockingID, x: 9, y: 0, width: 3, height: 12),
            ],
            activeSlotID: movingID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(
            fixture.canvas.subviews
                .compactMap { $0 as? SpatialSlotCardView }
                .first { $0.slotID == movingID }
        )

        fixture.canvas.begin(
            slotID: movingID,
            region: .header,
            pointer: CGPoint(x: 100, y: 100)
        )
        let originalFrame = card.frame
        fixture.canvas.drag(to: CGPoint(x: 800, y: 100))

        XCTAssertEqual(card.frame, originalFrame)
        XCTAssertEqual(card.alphaValue, 0.55, accuracy: 0.001)
        XCTAssertNotNil(fixture.canvas.dragThumbnailView)
        XCTAssertNil(fixture.canvas.dropHighlightView)

        fixture.canvas.end()

        XCTAssertEqual(
            fixture.store.catalog.slot(id: movingID)?.rect,
            GridRect(x: 0, y: 0, width: 3, height: 3)
        )
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001)
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

    // MARK: - The chrome header's controls

    /// The rule the whole header vocabulary rests on: an interactive item's solved rect
    /// is a hole in the pane's drag surface, and nothing else is.
    func testAnInteractiveHeaderAccessoryReceivesItsClickInsteadOfStartingAPaneDrag() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [slotID: PaneHeader(trailing: [headerIconButton("refresh")])]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()

        XCTAssertEqual(card.headerSolution.interactiveRects.count, 1)
        let rect = try XCTUnwrap(card.headerSolution.interactiveRects.first)
        let hit = headerHit(card, x: rect.midX, y: rect.midY)

        XCTAssertFalse(
            hit === card,
            "a control's own rect must not answer as pane-drag surface"
        )
        XCTAssertTrue(
            isInsideHeaderHost(hit),
            "the click belongs to the header host that drew the control"
        )
    }

    /// Answering `hitTest` with the header host is only HALF of "a control's rect is a
    /// hole in the drag surface". AppKit hands a `mouseDown` no view consumed back up the
    /// responder chain, and the card is the header host's next responder — so unless the
    /// card declines the point itself, a click SwiftUI does not claim (a disabled button,
    /// the slack inside a menu's frame) walks straight into `onBegin` and picks the pane up.
    func testAMouseDownOnAHeaderControlNeverBeginsAPaneDrag() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [slotID: PaneHeader(trailing: [headerIconButton("refresh")])]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()
        let rect = try XCTUnwrap(card.headerSolution.interactiveRects.first)

        var begun: [SpatialCanvasHitRegion] = []
        card.onBegin = { _, region, _ in begun.append(region) }

        let control = CGPoint(x: rect.midX, y: rect.midY)
        let hit = try XCTUnwrap(card.hitTest(card.convert(control, to: card.superview)))
        XCTAssertFalse(hit === card, "the control's rect must not answer as the card")
        hit.mouseDown(with: try leftClick(at: control, in: card))

        XCTAssertTrue(
            begun.isEmpty,
            "a click on a header control must not pick the pane up: it changes that pane's "
                + "own state, and the pointer already promised a pointing hand"
        )

        // The control for the control: the bare band next to it still begins a drag
        // through the very same dispatch, so an empty `begun` means "declined" rather
        // than "this test never delivered an event".
        let bare = CGPoint(x: 20, y: rect.midY)
        let bareHit = try XCTUnwrap(card.hitTest(card.convert(bare, to: card.superview)))
        bareHit.mouseDown(with: try leftClick(at: bare, in: card))
        XCTAssertEqual(begun, [.header], "the bare header is still grab-to-move")
    }

    /// The test above cannot fail on its own, and that is the point of this one. Over a LIVE
    /// button SwiftUI claims the `mouseDown` itself, so `begun` stays empty whether or not the
    /// card declines the point — the guard is never even reached. The click SwiftUI DECLINES is
    /// the only one that reaches the card, and a disabled control is how you get one: the
    /// control still owns its rect (`isInteractive` reads the case, not `isEnabled`, so the
    /// pointer still promises a pointing hand and `hitTest` still answers with the host), but
    /// nothing consumes the event, and AppKit walks it up to the card. Delete the
    /// `interactiveRects` early return in `mouseDown` and this pane picks itself up under a
    /// pointer that promised otherwise.
    func testAMouseDownOnADeclinedHeaderControlNeverBeginsAPaneDrag() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [
                slotID: PaneHeader(
                    trailing: [headerIconButton("refresh", isEnabled: false)]
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()
        let rect = try XCTUnwrap(card.headerSolution.interactiveRects.first)

        var begun: [SpatialCanvasHitRegion] = []
        card.onBegin = { _, region, _ in begun.append(region) }

        // Deliver the event the way AppKit would: to whatever `hitTest` chose, which for a
        // disabled control is still the header host — its rect is a hole in the drag surface
        // regardless of whether the control inside it happens to be taking clicks today.
        let control = CGPoint(x: rect.midX, y: rect.midY)
        let hit = try XCTUnwrap(card.hitTest(card.convert(control, to: card.superview)))
        XCTAssertFalse(hit === card, "a disabled control still owns its rect")
        hit.mouseDown(with: try leftClick(at: control, in: card))

        XCTAssertTrue(
            begun.isEmpty,
            "a click SwiftUI declined walked the responder chain into the card and picked the "
                + "pane up — the `mouseDown` decline is the half of the exemption that `hitTest` "
                + "cannot cover"
        )

        // Same control for the control as above: the bare band next to it still moves the
        // pane, so an empty `begun` means the card declined rather than that no event arrived.
        let bare = CGPoint(x: 20, y: rect.midY)
        let bareHit = try XCTUnwrap(card.hitTest(card.convert(bare, to: card.superview)))
        bareHit.mouseDown(with: try leftClick(at: bare, in: card))
        XCTAssertEqual(begun, [.header], "the bare header is still grab-to-move")
    }

    /// A dot, a label, a badge, an image and a spinner are things a pane SAYS, not things
    /// a pane offers, so the strip they occupy stays grab-to-move.
    func testAStaticHeaderItemLeavesTheStripDraggable() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [
                slotID: PaneHeader(
                    leading: [headerLabel("status", "Running the full suite")]
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()

        XCTAssertTrue(
            card.headerSolution.placements.contains { $0.item.id == "status" },
            "the label must actually be placed, or this test proves nothing"
        )
        XCTAssertTrue(card.headerSolution.interactiveRects.isEmpty)
        // Swept rather than sampled: "still draggable" is a claim about every point in
        // the strip, including the ones the label now covers.
        for x in stride(from: 14.0, to: card.bounds.width - 31, by: 9) {
            XCTAssertTrue(
                headerHit(card, x: x) === card,
                "x=\(x) must still start a pane drag"
            )
        }
    }

    /// `x ∈ (12, 31)` is bare header at every width with any content — the guarantee the
    /// XCUITest press-drag stands on, and the reason no contribution can render its own
    /// pane immovable.
    func testTheBareBandLeftOfTheAccessoryFloorAlwaysReturnsTheCard() throws {
        let narrowID = UUID()
        let wideID = UUID()
        let crowded = PaneHeader(
            leading: [
                headerLabel("status", "Running the full suite"),
                headerBadge("count", "12"),
            ],
            trailing: [
                headerSegmented("layout"),
                headerIconButton("refresh"),
                headerIconButton("reveal", "arrow.up.forward.app"),
            ]
        )
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(narrowID, x: 0, y: 0, width: 3, height: 12),
                workspaceSlot(wideID, x: 3, y: 0, width: 9, height: 12),
            ],
            activeSlotID: wideID,
            paneHeaders: [narrowID: crowded, wideID: crowded]
        )
        defer { fixture.window.orderOut(nil) }

        for slotID in [narrowID, wideID] {
            let card = try XCTUnwrap(fixture.card(for: slotID))
            card.layout()

            XCTAssertTrue(
                headerHit(card, x: 20, y: 10) === card,
                "the bare band left of the accessory floor must always grab the pane"
            )
            for placement in card.headerSolution.placements {
                XCTAssertGreaterThanOrEqual(
                    placement.rect.minX,
                    PaneHeaderLayout.accessoryOriginFloor,
                    "\(placement.item.id) reached into the glyph column"
                )
            }
        }
    }

    /// Pane lifecycle is host authority. A header packed to its cap still cannot put a
    /// control under the ✕, and the ✕ still closes.
    func testTheCloseControlStillWinsOverEveryHeaderAccessory() throws {
        let closingID = UUID()
        let otherID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(closingID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(otherID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: closingID,
            paneHeaders: [
                closingID: PaneHeader(
                    trailing: (0..<PaneHeader.maximumTrailingItems).map {
                        headerIconButton("action-\($0)")
                    }
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: closingID))
        card.layout()

        XCTAssertFalse(
            card.headerSolution.interactiveRects.isEmpty,
            "the header must be carrying controls, or the ✕ has nothing to win against"
        )
        for placement in card.headerSolution.placements {
            XCTAssertLessThanOrEqual(
                placement.rect.maxX,
                card.bounds.width - PaneHeaderLayout.closeButtonReserve,
                "\(placement.item.id) reached into the close control's reserve"
            )
        }

        let closePoint = CGPoint(x: card.frame.maxX - 15, y: card.frame.minY + 14)
        let closeButton = try XCTUnwrap(card.hitTest(closePoint) as? NSButton)
        closeButton.performClick(nil)

        XCTAssertNil(fixture.store.catalog.slot(id: closingID))
    }

    /// Without the early return AppKit walks up from a control with no menu of its own
    /// and pops Split/Stack/Duplicate/Close over a picker.
    func testRightClickOverAnAccessoryDoesNotOpenThePaneMenuButTheBareHeaderStillDoes() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [slotID: PaneHeader(trailing: [headerSegmented("layout")])]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()
        let rect = try XCTUnwrap(card.headerSolution.interactiveRects.first)

        XCTAssertNil(
            card.menu(for: try rightClick(at: CGPoint(x: rect.midX, y: rect.midY), in: card)),
            "the picker keeps its own click; the pane menu must not cover it"
        )
        XCTAssertNotNil(
            card.menu(for: try rightClick(at: CGPoint(x: 20, y: 10), in: card)),
            "the bare header still offers the pane's actions"
        )
    }

    /// Header state is pane state, not content identity. Folding it into `contentKey`
    /// would tear down the `NSHostingView` owning this pane's live PTY on every status
    /// tick — which is why the comparison sits above the cache guard.
    func testHeaderChangesDoNotRebuildThePaneContentHost() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()
        let mountedContent = try XCTUnwrap(contentHost(of: card))
        let mountedKey = card.contentKey
        XCTAssertFalse(mountedKey.isEmpty, "the pane must have mounted content to protect")
        XCTAssertTrue(card.headerSolution.placements.isEmpty)

        fixture.paneHeaders.publish(
            PaneHeader(trailing: [headerIconButton("refresh")]),
            for: slotID
        )
        fixture.reconfigure()
        card.layout()

        XCTAssertFalse(
            card.headerSolution.placements.isEmpty,
            "the republished header must have reached the card"
        )
        // The key, not the hosting view: `configure` reuses the same `NSHostingView`
        // across a rebuild, so its identity cannot tell a rebuild from an early return.
        // A changed key means the content tree was rebuilt, which remounts the SwiftUI
        // state owning this pane's live terminal.
        XCTAssertEqual(
            card.contentKey,
            mountedKey,
            "a header tick must not change what the pane's content view tree IS"
        )
        XCTAssertTrue(
            contentHost(of: card) === mountedContent,
            "and it must not tear the mounted surface down either"
        )
    }

    func testAutomationContentMountsAndRefreshesWhenScheduledDeliverySettingChanges() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(
                slotID,
                x: 0,
                y: 0,
                width: 12,
                height: 12,
                content: .automation
            )],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))

        XCTAssertNotNil(contentHost(of: card), "Automation must mount in the Canvas card")
        XCTAssertTrue(card.contentKey.contains("automation"))
        XCTAssertTrue(card.contentKey.contains("scheduled=true"))

        fixture.reconfigure(automationSchedulesEnabled: false)

        XCTAssertTrue(
            card.contentKey.contains("scheduled=false"),
            "the value threaded from Settings must reach the separately hosted pane graph"
        )
    }

    /// The canvas's backstop sweep must not write to the store from inside the view update
    /// that asked for it. `configure` is reached only from `SpatialCanvasView.updateNSView`,
    /// so an `@Observable` write here is a "Modifying state during view update" — and the
    /// store's own guard is no defence, because the single moment the sweep IS a write is a
    /// pane closing, which is exactly the pass that runs it.
    func testClosingAPaneSweepsTheHeaderStoreAfterTheUpdatePassNotDuringIt() async throws {
        let keptID = UUID()
        let closedID = UUID()
        let kept = PaneHeader(trailing: [headerIconButton("refresh")])
        let closing = PaneHeader(leading: [headerBadge("count", "12")])
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(keptID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(closedID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: keptID,
            paneHeaders: [keptID: kept, closedID: closing]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.store.closeSlot(closedID)

        let flag = ObservationFlag()
        withObservationTracking {
            _ = fixture.paneHeaders.headers
        } onChange: {
            flag.didChange = true
        }

        fixture.reconfigure()

        XCTAssertFalse(
            flag.didChange,
            "the configure pass must perform no observable write: it runs inside SwiftUI's "
                + "view update, and this store is one of that update's own inputs"
        )
        XCTAssertEqual(
            (fixture.paneHeaders.headers[closedID] ?? .empty),
            closing,
            "…so the stale entry is still there when the pass returns"
        )

        await fixture.paneHeaders.pendingSweep?.value

        // The control: the sweep is deferred, not dropped. Without this the assertion
        // above would pass for a backstop that had quietly stopped sweeping at all.
        XCTAssertTrue(flag.didChange, "the deferred write lands once the update is over")
        XCTAssertEqual(
            (fixture.paneHeaders.headers[closedID] ?? .empty),
            .empty,
            "the closed pane's header is collected"
        )
        XCTAssertEqual(
            (fixture.paneHeaders.headers[keptID] ?? .empty),
            kept,
            "and the pane that is still open keeps its own"
        )
    }

    /// The pointer must not promise a click the card will not deliver. Hit testing is
    /// two-dimensional — an accessory occupies one 20-point band inside a 34-point strip —
    /// so a cursor pass that claimed the whole column over a control would show a pointing
    /// hand across the seven points below it and the row above it, where the click actually
    /// picks the pane up. Swept rather than sampled: "the affordance matches the surface"
    /// is a claim about every point in the strip.
    func testTheHeaderCursorAgreesWithHitTestingAtEveryPointOfTheStrip() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [
                slotID: PaneHeader(
                    leading: [headerLabel("status", "Running the full suite")],
                    trailing: [headerSegmented("layout"), headerIconButton("refresh")]
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()

        let band = try XCTUnwrap(card.headerSolution.interactiveRects.first)
        XCTAssertEqual(card.headerSolution.interactiveRects.count, 2, "two controls to cut")
        XCTAssertLessThan(
            band.maxY,
            TenonTheme.slotHeaderHeight,
            "the accessory band must be shorter than the strip, or this test proves nothing"
        )

        let cursors = card.headerCursorRects()
        var mismatches: [String] = []
        for x in stride(
            from: 14.0,
            to: card.bounds.width - PaneHeaderLayout.closeButtonReserve,
            by: 3.0
        ) {
            for y in stride(from: 7.0, to: TenonTheme.slotHeaderHeight, by: 1.0) {
                let point = CGPoint(x: x, y: y)
                let takesTheMouse = isInsideHeaderHost(
                    card.hitTest(card.convert(point, to: card.superview))
                )
                let expected: NSCursor = takesTheMouse ? .pointingHand : .openHand
                let drawn = cursors.first { $0.rect.contains(point) }?.cursor
                if drawn !== expected {
                    mismatches.append(
                        "(\(Int(x)), \(Int(y))): hit test says "
                            + (takesTheMouse ? "control" : "pane drag")
                    )
                }
            }
        }

        XCTAssertEqual(
            mismatches.count,
            0,
            "the pointer lied at \(mismatches.count) points, first: \(mismatches.first ?? "")"
        )
    }

    /// The solver RESERVES a contiguous, control-free band before it places anything —
    /// that reservation is what makes a pane you can always grab a layout constraint
    /// instead of a residual. The cursor pass draws the open hand from that band, so the
    /// guarantee is one that ships rather than one only a solver test can see.
    func testThePanesGrabSurfaceIsCutFromTheReservedDragBand() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [
                slotID: PaneHeader(
                    // The leading run ends in something that is NOT a control, so the
                    // reserved band starts to the right of the last interactive rect: a
                    // pass that walked the gaps between controls would hand back a wider
                    // rect than the band and call it the grab surface.
                    leading: [headerLabel("status", "Running"), headerBadge("count", "12")],
                    trailing: [headerSegmented("layout"), headerIconButton("refresh")]
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()

        let band = card.headerSolution.dragBandRect
        XCTAssertGreaterThanOrEqual(
            band.width,
            PaneHeaderLayout.minimumDragBand,
            "the solver must have reserved a real band for this test to be about one"
        )
        XCTAssertTrue(
            card.headerSolution.placements.contains { !$0.item.isInteractive },
            "…with a non-control between the band and the last interactive rect"
        )

        let cursors = card.headerCursorRects()
        let grab = try XCTUnwrap(
            cursors.first { $0.rect.contains(CGPoint(x: band.midX, y: band.midY)) },
            "the reserved band must be covered by a cursor rect"
        )

        XCTAssertTrue(grab.cursor === NSCursor.openHand, "and it means grab-to-move")
        XCTAssertEqual(grab.rect.minX, band.minX, accuracy: 0.5)
        XCTAssertEqual(grab.rect.maxX, band.maxX, accuracy: 0.5)
        // Full strip height, clipped only where the north resize edge claims the top:
        // the band is the one region provably free of controls at EVERY y, which is what
        // lets it be drawn as one rect instead of a row sandwich.
        XCTAssertEqual(grab.rect.minY, 6, accuracy: 0.5)
        XCTAssertEqual(grab.rect.maxY, TenonTheme.slotHeaderHeight, accuracy: 0.5)
        XCTAssertEqual(
            cursors.filter { $0.rect.intersects(band.insetBy(dx: 1, dy: 0)) }.count,
            1,
            "one rect, not a stack of rows: the band has nothing in it to cut around"
        )
    }

    /// The card is the only place that can attribute a pick in the host-composed `…` menu
    /// back to the item that folded, because it is the only place that holds the solution.
    /// Those entries speak the FOLDED item's value space — a folded `segmented` yields
    /// "tree"/"flat", never "changes.layout" — so reporting a pick under the overflow's own
    /// id would name a control no owner ever published, and the pane's layout would never
    /// change however many times the user picked.
    ///
    /// Driven through the renderer's own `perform` closure rather than by calling the
    /// substitution directly, so what is asserted is the wiring a click actually travels:
    /// menu entry → `PaneHeaderBar.perform` → the card's attribution → the canvas route →
    /// the owning pane's handler.
    func testAPickInTheOverflowMenuIsReportedUnderTheItemThatFolded() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 3, height: 12)],
            activeSlotID: slotID,
            paneHeaders: [
                slotID: PaneHeader(
                    trailing: [
                        headerSegmented(PaneHeaderCommand.changesLayout.rawValue),
                        headerIconButton("one"),
                        headerIconButton("two"),
                        headerIconButton("three"),
                    ]
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        var routed: [(command: PaneHeaderCommand, value: String?)] = []
        fixture.paneHeaders.onCommand(for: slotID) { command, value in
            routed.append((command, value))
        }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        card.layout()

        // The premise, asserted rather than assumed: this pane is narrow enough that the
        // picker really did fold, so the rest of the test is about the fold and not about
        // a picker that is still sitting in the strip.
        XCTAssertEqual(
            card.headerSolution.overflow?.id,
            PaneHeaderLayout.overflowItemID,
            "the pane must be narrow enough to have produced an overflow menu"
        )
        XCTAssertTrue(
            card.headerSolution.folded.contains {
                $0.item.id == PaneHeaderCommand.changesLayout.rawValue
            },
            "…and the picker must be what folded into it"
        )

        let overflowHost = try XCTUnwrap(
            card.subviews
                .compactMap { $0 as? PaneHeaderHostView }
                .first { host in
                    host.rootView.placements.contains {
                        $0.item.id == PaneHeaderLayout.overflowItemID
                    }
                },
            "the overflow control must be mounted in a run, or nothing can click it"
        )

        overflowHost.rootView.perform(
            PaneHeaderAction(itemID: PaneHeaderLayout.overflowItemID, value: "flat")
        )

        XCTAssertEqual(routed.count, 1, "the pick must reach the pane that owns the state")
        XCTAssertEqual(
            routed.first?.command,
            .changesLayout,
            "under the folded picker's id — the overflow's own id routes nowhere"
        )
        XCTAssertEqual(
            routed.first?.value,
            "flat",
            "carrying the segment's value, not the menu's"
        )

        // An entry no folded item claims resolves to nothing rather than to the overflow
        // itself: a stale menu outliving a re-solve must not fire a neighbour's command.
        overflowHost.rootView.perform(
            PaneHeaderAction(itemID: PaneHeaderLayout.overflowItemID, value: "no-such-value")
        )
        XCTAssertEqual(routed.count, 1, "an unclaimed entry value reports nothing at all")
    }

    /// `refreshCardActivity()` restates every card's focus after every gesture and every
    /// reconfigure — that is what it is FOR, and it is written to do it without a full
    /// rebuild. A `setState` that invalidated layout unconditionally would turn each of
    /// those cheap restatements into a re-solve and a re-mount of every header run on
    /// every card, which is the cost this whole path was shaped to avoid.
    func testRestatingAPanesFocusDoesNotInvalidateItsLayout() throws {
        let activeID = UUID()
        let bareID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 6, height: 12),
                workspaceSlot(bareID, x: 6, y: 0, width: 6, height: 12),
            ],
            activeSlotID: activeID,
            paneHeaders: [activeID: PaneHeader(trailing: [headerIconButton("refresh")])]
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: activeID))
        let bare = try XCTUnwrap(fixture.card(for: bareID))
        card.layoutSubtreeIfNeeded()
        bare.layoutSubtreeIfNeeded()
        XCTAssertFalse(card.needsLayout, "the fixture must start settled")
        XCTAssertFalse(card.headerSolution.placements.isEmpty, "…carrying a control")

        card.setState(isActive: true)

        XCTAssertFalse(
            card.needsLayout,
            "restating the focus a pane already has must invalidate nothing"
        )

        // A pane with nothing in its chrome has nothing whose appearance depends on
        // focus: the glyph and title recolour themselves, which needs no layout pass.
        bare.setState(isActive: true)
        XCTAssertFalse(
            bare.needsLayout,
            "a bare header changes no geometry and mounts no run, at either focus"
        )

        // The control: accessories DO dim with their pane, so a header that has any must
        // still be re-applied when the focus genuinely changes.
        card.setState(isActive: false)
        XCTAssertTrue(
            card.needsLayout,
            "a real focus change must still re-apply the runs, or the accessories keep "
                + "the brightness of the pane that just lost focus"
        )
    }

    /// D2: a header control focuses its pane before it acts, because it changes that
    /// pane's own state and AppKit focus must not disagree with `activeSlotID`. The ✕ is
    /// the documented exception, and stays one.
    func testAHeaderActionFocusesItsPaneWhileTheCloseControlStillDoesNot() throws {
        let activeID = UUID()
        let closingID = UUID()
        let actingID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(activeID, x: 0, y: 0, width: 4, height: 12),
                workspaceSlot(closingID, x: 4, y: 0, width: 4, height: 12),
                workspaceSlot(actingID, x: 8, y: 0, width: 4, height: 12),
            ],
            activeSlotID: activeID,
            paneHeaders: [
                actingID: PaneHeader(
                    trailing: [headerIconButton(PaneHeaderCommand.changesRefresh.rawValue)]
                ),
            ]
        )
        defer { fixture.window.orderOut(nil) }
        var routed: [(command: PaneHeaderCommand, value: String?)] = []
        fixture.paneHeaders.onCommand(for: actingID) { command, value in
            routed.append((command, value))
        }

        let closingCard = try XCTUnwrap(fixture.card(for: closingID))
        closingCard.layout()
        let closePoint = CGPoint(
            x: closingCard.frame.maxX - 15,
            y: closingCard.frame.minY + 14
        )
        fixture.canvas.handleLocalLeftMouseDown(at: closePoint)
        let closeButton = try XCTUnwrap(closingCard.hitTest(closePoint) as? NSButton)
        closeButton.performClick(nil)

        XCTAssertEqual(
            fixture.store.catalog.activeSlotID,
            activeID,
            "closing an inactive pane still must not focus it first"
        )

        let actingCard = try XCTUnwrap(fixture.card(for: actingID))
        actingCard.layout()
        let action = try XCTUnwrap(
            actingCard.headerSolution.placements.first?.item.id
        )
        actingCard.onHeaderAction?(actingID, PaneHeaderAction(itemID: action))

        XCTAssertEqual(fixture.store.catalog.activeSlotID, actingID)
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed.first?.command, .changesRefresh)
        XCTAssertNil(routed.first?.value)
    }

    // MARK: - Header fixtures

    /// `isEnabled` is a parameter rather than a constant because a DISABLED control is the
    /// only case that can prove the card's own `mouseDown` decline. SwiftUI consumes the
    /// click on a live button, so an enabled control's rect never exercises the guard —
    /// see `testAMouseDownOnADeclinedHeaderControlNeverBeginsAPaneDrag`.
    private func headerIconButton(
        _ id: String,
        _ systemName: String = "arrow.clockwise",
        isEnabled: Bool = true
    ) -> PaneHeaderItem {
        .iconButton(
            id: id,
            systemName: systemName,
            tint: .muted,
            isEnabled: isEnabled,
            tooltip: nil,
            accessibilityID: nil
        )
    }

    private func headerLabel(_ id: String, _ text: String) -> PaneHeaderItem {
        .label(
            id: id,
            text: text,
            weight: .regular,
            color: .muted,
            truncation: .tail,
            tooltip: nil
        )
    }

    private func headerBadge(_ id: String, _ text: String) -> PaneHeaderItem {
        .badge(id: id, text: text, tint: .muted, tooltip: nil)
    }

    private func headerSegmented(_ id: String) -> PaneHeaderItem {
        .segmented(
            id: id,
            segments: [
                PaneHeaderSegment(value: "tree", label: "Tree"),
                PaneHeaderSegment(value: "flat", label: "Flat"),
            ].compactMap { $0 },
            selection: "tree",
            isEnabled: true,
            accessibilityID: nil
        )
    }

    /// Card-local coordinates in, hit-test answer out. `hitTest` takes the card's
    /// SUPERVIEW space, which is exactly the conversion a real click goes through.
    private func headerHit(
        _ card: SpatialSlotCardView,
        x: CGFloat,
        y: CGFloat = 14
    ) -> NSView? {
        card.hitTest(card.convert(CGPoint(x: x, y: y), to: card.superview))
    }

    private func isInsideHeaderHost(_ view: NSView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is PaneHeaderHostView { return true }
            candidate = current.superview
        }
        return false
    }

    private func contentHost(of card: SpatialSlotCardView) -> NSView? {
        card.subviews.first { $0 is NSHostingView<AnyView> }
    }

    private func leftClick(
        at local: CGPoint,
        in card: SpatialSlotCardView
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: card.convert(local, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: card.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func rightClick(
        at local: CGPoint,
        in card: SpatialSlotCardView
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: card.convert(local, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: card.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
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

        fixture.reconfigure()
        let authoritativeFrame = card.frame
        fixture.canvas.drag(to: CGPoint(x: 700, y: 100))

        XCTAssertEqual(
            card.frame,
            authoritativeFrame,
            "a cancelled stale gesture must not reintroduce its old preview"
        )
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

    func testHeaderContextMenuOffersSplitStackRenameCopyIDAndClose() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        _ = fixture.pool.surface(for: slotID, workspacePath: fixture.workspacePath)

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "Split", "Stack", "Duplicate", "",
                "Rename…", "AI Rename…", "",
                "Copy Pane ID", "", "Close",
            ]
        )
        XCTAssertTrue(try menuItem(menu, "Split").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Stack").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Duplicate").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Rename…").isEnabled)
        XCTAssertTrue(try menuItem(menu, "AI Rename…").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Copy Pane ID").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Close").isEnabled)
        XCTAssertTrue(
            menu.items.allSatisfy { $0.submenu == nil },
            "the pane menu is flat — no submenu to walk into"
        )
    }

    func testHeaderContextMenuCopiesTheClickedPaneIDThroughTheSharedRoute() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        var copiedIDs: [UUID] = []
        fixture.canvas.copyWorkspaceIdentifier = { copiedIDs.append($0) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))
        try menuItem(menu, "Copy Pane ID").invoke()

        XCTAssertEqual(copiedIDs, [slotID])
    }

    // MARK: - Agent session continuations (SP-FR-029)

    /// Only a pane carrying an agent session offers the continuations, and each joins the
    /// group whose meaning it shares: Fork Session beside Duplicate (both make a pane),
    /// Copy Resume Command beside Copy Pane ID (both put a line on the clipboard). The
    /// offer is computed before the click and travels with the item.
    func testAnAgentPaneMenuOffersForkSessionAndCopyResumeCommand() throws {
        let slotID = UUID()
        let ref = try agentRef()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            agentSuggestions: [claudeInstall()]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.canvas.agentSessionReading = { _ in ref }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "Split", "Stack", "Duplicate", "Fork Session", "",
                "Rename…", "AI Rename…", "",
                "Copy Pane ID", "Copy Resume Command", "", "Close",
            ]
        )
        XCTAssertTrue(try menuItem(menu, "Fork Session").isEnabled)
        XCTAssertTrue(try menuItem(menu, "Copy Resume Command").isEnabled)
        XCTAssertTrue(
            try XCTUnwrap(menuItem(menu, "Fork Session").toolTip)
                .contains("--fork-session"),
            "the composed fork travels with the item, stated before any click"
        )
    }

    func testCopyResumeCommandCopiesTheComposedResumeNotAFork() throws {
        let slotID = UUID()
        let ref = try agentRef()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            agentSuggestions: [claudeInstall()]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.canvas.agentSessionReading = { _ in ref }
        var copied: [String] = []
        fixture.canvas.copyResumeCommand = { copied.append($0) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))
        try menuItem(menu, "Copy Resume Command").invoke()

        XCTAssertEqual(copied.count, 1)
        let commandLine = try XCTUnwrap(copied.first)
        XCTAssertTrue(commandLine.contains("--resume"), commandLine)
        XCTAssertTrue(commandLine.contains(ref.sessionID), commandLine)
        XCTAssertFalse(
            commandLine.contains("--fork-session"),
            "copying a resume must not mint a new session"
        )
    }

    /// The fork lands beside the pane it forks — `duplicateSlot`'s placement — and the
    /// provider's own fork is queued for the shell that fresh pane is about to build.
    func testForkOpensAFreshTerminalBesideRunningTheProvidersFork() throws {
        let slotID = UUID()
        let ref = try agentRef()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 6, height: 12)],
            activeSlotID: slotID,
            agentSuggestions: [claudeInstall()]
        )
        defer { fixture.window.orderOut(nil) }
        fixture.canvas.agentSessionReading = { _ in ref }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))
        try menuItem(menu, "Fork Session").invoke()

        let slots = try XCTUnwrap(fixture.store.catalog.activeTab).slots
        XCTAssertEqual(slots.count, 2)
        let forked = try XCTUnwrap(slots.first { $0.id != slotID })
        XCTAssertEqual(forked.content, .terminal)
        let surface = try XCTUnwrap(
            fixture.pool.surface(
                for: forked.id,
                workspacePath: fixture.workspacePath
            ) as? StubTerminalSurface
        )
        XCTAssertEqual(surface.sentText.count, 1)
        let line = try XCTUnwrap(surface.sentText.first)
        XCTAssertTrue(line.contains("--resume"), line)
        XCTAssertTrue(line.contains("--fork-session"), line)
        XCTAssertTrue(line.hasSuffix("\n"), "the fork runs; it is not left half-typed")
    }

    /// A recorded pane forks the same way, with no seam: the ref is read straight off the
    /// pane's content, and the duplicate that would have read the recording twice becomes
    /// the fresh shell the fork runs in.
    func testARecordedPaneForksIntoAFreshTerminalBesideItsReading() throws {
        let slotID = UUID()
        let ref = try agentRef()
        let fixture = try makeCanvasFixture(
            slots: [
                workspaceSlot(slotID, x: 0, y: 0, width: 6, height: 12, content: .agentSession(ref)),
            ],
            activeSlotID: slotID,
            agentSuggestions: [claudeInstall()]
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))
        try menuItem(menu, "Fork Session").invoke()

        let slots = try XCTUnwrap(fixture.store.catalog.activeTab).slots
        XCTAssertEqual(slots.count, 2)
        let forked = try XCTUnwrap(slots.first { $0.id != slotID })
        XCTAssertEqual(forked.content, .terminal, "the fork runs in a shell, not in a second reading")
        XCTAssertEqual(
            fixture.store.catalog.slot(id: slotID)?.content,
            .agentSession(ref),
            "the reading the person was looking at stays exactly where it was"
        )
        let surface = try XCTUnwrap(
            fixture.pool.surface(
                for: forked.id,
                workspacePath: fixture.workspacePath
            ) as? StubTerminalSurface
        )
        XCTAssertTrue(try XCTUnwrap(surface.sentText.first).contains("--fork-session"))
    }

    /// The refusal is stated where the button is, before it is pressed: an agent this
    /// machine lacks greys both items and the tooltip carries the reason.
    func testMissingAgentGreysTheContinuationsAndStatesWhy() throws {
        let slotID = UUID()
        let ref = try agentRef()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        fixture.canvas.agentSessionReading = { _ in ref }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))

        XCTAssertFalse(try menuItem(menu, "Fork Session").isEnabled)
        XCTAssertFalse(try menuItem(menu, "Copy Resume Command").isEnabled)
        XCTAssertTrue(
            try XCTUnwrap(menuItem(menu, "Fork Session").toolTip).contains("not installed")
        )
    }

    private func agentRef(
        sessionID: String = "0199f0c1-2b7a-4d51-9d16-5b6f4a5c33d0"
    ) throws -> AgentSessionRef {
        try XCTUnwrap(AgentSessionRef(
            provider: .claude,
            sessionID: sessionID,
            transcriptPath: "/Users/x/.claude/projects/-Users-x-p/\(sessionID).jsonl"
        ))
    }

    private func claudeInstall() -> AgentLaunchSuggestion {
        AgentLaunchSuggestion(
            agent: .claude,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            arguments: ["--model", "opus"]
        )
    }

    func testHeaderMenuAndVoiceOverRenameEnterTheSameCoordinator() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }

        let menu = try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID))
        try menuItem(menu, "Rename…").invoke()
        XCTAssertEqual(fixture.paneRenamer.phase(for: slotID)?.isEditing, true)
        fixture.paneRenamer.cancel(slotID: slotID)

        let card = try XCTUnwrap(fixture.card(for: slotID))
        let renameAction = try XCTUnwrap(
            card.accessibilityCustomActions()?.first { $0.name == "Rename Pane" }
        )
        XCTAssertEqual(renameAction.handler?(), true)
        XCTAssertEqual(fixture.paneRenamer.phase(for: slotID)?.isEditing, true)
    }

    /// The rename happens where the name is. Nothing is presented over the shell, the pane's
    /// own title becomes the field, and Return enters the one typed mutation.
    func testManualRenameIsTypedOnThePaneTitleItself() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        XCTAssertFalse(card.isRenamingInline)

        try menuItem(
            try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID)),
            "Rename…"
        ).invoke()
        fixture.reconfigure()
        XCTAssertTrue(card.isRenamingInline)
        // The field owns the band between the glyph and the close control, so a rename is
        // never typed into a rect the solver folded away to zero.
        let field = card.editingTitleRect(headerHeight: TenonTheme.slotHeaderHeight)
        XCTAssertGreaterThan(field.width, 0)
        XCTAssertLessThanOrEqual(field.maxX, card.bounds.width - 27)

        card.setRenameText("API failures")
        // The canvas reconfigures on every catalog mutation, and a pane being renamed is
        // still a pane other work happens around. What is half-typed must survive that.
        fixture.reconfigure()
        XCTAssertEqual(card.displayedTitle, "API failures")
        // The open field is a control, not pane-drag surface: clicking it places a caret.
        let hit = card.hitTest(
            card.convert(CGPoint(x: field.midX, y: field.midY), to: card.superview)
        )
        XCTAssertFalse(hit === card, "clicking the rename field must not pick the pane up")

        card.commitRename()
        fixture.reconfigure()

        XCTAssertEqual(fixture.store.catalog.slot(id: slotID)?.customTitle, "API failures")
        XCTAssertNil(fixture.paneRenamer.phase(for: slotID))
        XCTAssertFalse(card.isRenamingInline)
        XCTAssertEqual(card.displayedTitle, "API failures")
    }

    func testAIRenameSaysSoOnThePaneTitleAndPresentsNothingOverTheShell() throws {
        let slotID = UUID()
        let fixture = try makeCanvasFixture(
            slots: [workspaceSlot(slotID, x: 0, y: 0, width: 12, height: 12)],
            activeSlotID: slotID,
            renameGenerator: StalledPaneTitleGenerator()
        )
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: slotID))
        let namedBefore = card.displayedTitle

        try menuItem(
            try XCTUnwrap(fixture.canvas.slotContextMenu(for: slotID)),
            "AI Rename…"
        ).invoke()
        fixture.reconfigure()

        XCTAssertEqual(fixture.paneRenamer.phase(for: slotID), .generating)
        XCTAssertEqual(card.displayedTitle, PaneRenameChrome.generatingTitle)
        XCTAssertFalse(card.isRenamingInline, "generating is reported, not edited")
        // The pane keeps its own name underneath, so a second rename starts from the real
        // one rather than from the state the header is reporting.
        XCTAssertEqual(card.presentedTitle, namedBefore)

        fixture.paneRenamer.cancel(slotID: slotID)
        fixture.reconfigure()
        XCTAssertEqual(card.displayedTitle, namedBefore)
    }

    func testWorkspaceIdentifierClipboardWritesOnlyTheRawUUID() {
        let id = UUID()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.tenon.tests.identifier.\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }

        XCTAssertTrue(WorkspaceIdentifierClipboard.copy(id, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), id.uuidString)
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
        _ card: NSView,
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

    private func leftMouseEvent(
        _ type: NSEvent.EventType,
        windowPoint: CGPoint,
        window: NSWindow,
        eventNumber: Int
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: TimeInterval(eventNumber),
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
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
        activeSlotID: UUID,
        additionalTabs: [TenonCore.Tab] = [],
        paneHeaders: [UUID: PaneHeader] = [:],
        renameGenerator: (any PaneTitleGenerating)? = nil,
        agentSuggestions: [AgentLaunchSuggestion] = []
    ) throws -> CanvasFixture {
        // A slot whose header THIS fixture injects must be a pane with no producer of its
        // own, and `.empty` is the one pane kind that contributes nothing. A terminal pane
        // is not: Agent Lens publishes into the same store from its `.task`, so an injected
        // header on one is replaced the moment the run loop turns and the test would be
        // asserting against the pane's own answer instead of the value it set up.
        let tab = TenonCore.Tab(
            slots: slots.map { slot in
                guard paneHeaders[slot.id] != nil else { return slot }
                return WorkspaceSlot(id: slot.id, rect: slot.rect, content: .empty)
            },
            activeSlotID: activeSlotID
        )
        let workspacePath = FileManager.default.temporaryDirectory
        let workspace = Workspace(
            name: "Test",
            path: workspacePath,
            tabs: [tab] + additionalTabs,
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
        let webPool = PluginWebSurfacePool()
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
        let userInterface = PluginUIState()
        let intentRuntime = try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: webPool,
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: pluginsRoot,
            stateRoot: stateRoot,
            kernel: intentRuntime.kernel
        )
        let palette = CommandPaletteState(
            storeURL: stateRoot.appendingPathComponent("frecency.json")
        )
        let editorStates = EditorPaneStateStore()
        let agentLens = AgentLensPool()
        let automation = AutomationScheduler()
        let automationActions = AutomationPaneActions(
            runNow: { _, _ in },
            setPaused: { _, _, _ in },
            createWithAI: {},
            openRunDetail: { _, _ in }
        )
        // Published through the real store rather than handed straight to `configure`,
        // so these tests exercise the whole chain a running app uses: publish → the
        // dictionary the stage reads → the projection → the card.
        let headerStore = PaneHeaderStore()
        for (slotID, header) in paneHeaders {
            headerStore.publish(header, for: slotID)
        }
        let router = DragRouter()
        let paneRenamer = PaneRenameCoordinator(
            store: store,
            pool: pool,
            generator: renameGenerator
        )
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
            workspaceID: workspace.id,
            workspacePath: workspacePath,
            allLiveSlotIDs: Set(([tab] + additionalTabs).flatMap { $0.slots.map(\.id) }),
            activeSlotID: activeSlotID,
            store: store,
            pool: pool,
            agentLens: agentLens,
            webPool: webPool,
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
            agentSuggestions: agentSuggestions,
            editorStates: editorStates,
            pluginSnapshots: [],
            pluginViewSections: [],
            webSurfaceTitles: [:],
            paneAttention: [:],
            paneHeaders: headerStore.headers,
            paneHeaderStore: headerStore,
            paneRenames: paneRenamer.phases,
            paneRenamer: paneRenamer,
            router: router,
            automation: automation,
            automationSchedulesEnabled: true,
            automationActions: automationActions
        )
        canvas.layout()
        return CanvasFixture(
            window: window,
            container: container,
            canvas: canvas,
            store: store,
            pool: pool,
            webPool: webPool,
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
            editorStates: editorStates,
            agentLens: agentLens,
            paneHeaders: headerStore,
            paneRenamer: paneRenamer,
            router: router,
            automation: automation,
            automationActions: automationActions,
            workspacePath: workspacePath
        )
    }
}

/// A Companion that never answers, so a pane stays in its generating state for the length
/// of a test rather than for the length of a subprocess.
private struct StalledPaneTitleGenerator: PaneTitleGenerating {
    func generateTitle(from brief: PaneRenameBrief) async throws -> String {
        try await Task.sleep(for: .seconds(600))
        return ""
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
    let webPool: PluginWebSurfacePool
    let host: PluginHost
    let intentRuntime: AppIntentRuntime
    let palette: CommandPaletteState
    let editorStates: EditorPaneStateStore
    let agentLens: AgentLensPool
    let paneHeaders: PaneHeaderStore
    let paneRenamer: PaneRenameCoordinator
    let router: DragRouter
    let automation: AutomationScheduler
    let automationActions: AutomationPaneActions
    let workspacePath: URL

    @MainActor
    var cardFrames: [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: canvas.subviews.compactMap { view in
            guard let card = view as? SpatialSlotCardView else { return nil }
            return (card.slotID, card.frame)
        })
    }

    @MainActor
    func card(for id: UUID) -> SpatialSlotCardView? {
        canvas.subviews
            .compactMap { $0 as? SpatialSlotCardView }
            .first { $0.slotID == id }
    }

    @MainActor
    func reconfigure(automationSchedulesEnabled: Bool = true) {
        guard let tab = store.catalog.activeTab else { return }
        canvas.configure(
            tab: tab,
            workspaceID: store.catalog.activeWorkspaceID,
            workspacePath: workspacePath,
            allLiveSlotIDs: Set(store.catalog.workspaces.flatMap { workspace in
                workspace.tabs.flatMap { $0.slots.map(\.id) }
            }),
            activeSlotID: tab.activeSlotID,
            store: store,
            pool: pool,
            agentLens: agentLens,
            webPool: webPool,
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
            agentSuggestions: [],
            editorStates: editorStates,
            pluginSnapshots: [],
            pluginViewSections: [],
            webSurfaceTitles: [:],
            paneAttention: [:],
            paneHeaders: paneHeaders.headers,
            paneHeaderStore: paneHeaders,
            paneRenames: paneRenamer.phases,
            paneRenamer: paneRenamer,
            router: router,
            automation: automation,
            automationSchedulesEnabled: automationSchedulesEnabled,
            automationActions: automationActions
        )
    }
}
