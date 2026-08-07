import AppKit
import XCTest
@testable import TenonApp

@MainActor
final class ScrollbarStyleTests: XCTestCase {
    func testStyleUsesSmallNativeScrollersWithoutChangingTheSystemStyle() throws {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .legacy

        XCTAssertTrue(TenonScrollbarStyle.apply(to: scrollView))
        XCTAssertEqual(try XCTUnwrap(scrollView.verticalScroller).controlSize, .small)
        XCTAssertEqual(try XCTUnwrap(scrollView.horizontalScroller).controlSize, .small)
        XCTAssertEqual(scrollView.scrollerStyle, .legacy)
    }

    func testStyleIsIdempotent() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true

        XCTAssertTrue(TenonScrollbarStyle.apply(to: scrollView))
        XCTAssertFalse(TenonScrollbarStyle.apply(to: scrollView))
    }

}
