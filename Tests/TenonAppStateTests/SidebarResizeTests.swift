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
