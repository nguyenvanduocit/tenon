import XCTest
@testable import TenonApp

final class SidebarResizeTests: XCTestCase {
    func testCollapsedSidebarKeepsANonzeroIconRail() {
        XCTAssertEqual(
            SidebarResize.renderedWidth(isExpanded: false, expandedWidth: 300),
            SidebarResize.collapsedWidth
        )
        XCTAssertEqual(SidebarResize.collapsedWidth, 48)
        XCTAssertGreaterThan(SidebarResize.collapsedWidth, 0)
        XCTAssertLessThan(SidebarResize.collapsedWidth, SidebarResize.minWidth)
    }

    /// A collapsed workspace is a mark and nothing else, so the shape its fill draws is the
    /// row itself. The rail leaves it `collapsedRowWidth` of width; giving it any other
    /// height makes a selected or hovered workspace read as a stripe rather than a tile.
    /// Derived rather than agreed by literal: widen the rail or its inset and the mark stays
    /// square.
    func testACollapsedWorkspaceRowIsSquare() {
        XCTAssertEqual(
            WorkspaceSidebarLayout.rowHeight,
            WorkspaceSidebarLayout.collapsedRowWidth
        )
    }

    /// The same height serves the expanded row, which is `designs.md`'s two-line utility row
    /// — a name over a tab count — and is contracted there at 36–40 pt. This is what stops
    /// the rail's geometry from silently dragging the expanded list out of the design band.
    func testTheWorkspaceRowKeepsTheTwoLineUtilityRowBand() {
        XCTAssertGreaterThanOrEqual(WorkspaceSidebarLayout.rowHeight, 36)
        XCTAssertLessThanOrEqual(WorkspaceSidebarLayout.rowHeight, 40)
    }

    func testExpandedSidebarKeepsItsStoredWidth() {
        XCTAssertEqual(
            SidebarResize.renderedWidth(isExpanded: true, expandedWidth: 300),
            300
        )
    }

    func testWidthWithinBoundsIsKeptAsIs() {
        XCTAssertEqual(SidebarResize.resolve(proposedWidth: 300), .resize(300))
        XCTAssertEqual(
            SidebarResize.resolve(proposedWidth: SidebarResize.defaultWidth),
            .resize(SidebarResize.defaultWidth)
        )
    }

    func testWidthPastTheMaximumIsClampedNotCollapsed() {
        XCTAssertEqual(
            SidebarResize.resolve(proposedWidth: 999),
            .resize(SidebarResize.maxWidth)
        )
    }

    func testMinimumWidthStaysOpenButAnythingNarrowerCollapses() {
        XCTAssertEqual(
            SidebarResize.resolve(proposedWidth: SidebarResize.minWidth),
            .resize(SidebarResize.minWidth)
        )
        XCTAssertEqual(
            SidebarResize.resolve(proposedWidth: SidebarResize.minWidth - 1),
            .collapse
        )
    }

    func testDraggingWellBelowTheIconsCollapses() {
        XCTAssertEqual(SidebarResize.resolve(proposedWidth: 40), .collapse)
        XCTAssertEqual(SidebarResize.resolve(proposedWidth: 0), .collapse)
        XCTAssertEqual(SidebarResize.resolve(proposedWidth: -120), .collapse)
    }
}
