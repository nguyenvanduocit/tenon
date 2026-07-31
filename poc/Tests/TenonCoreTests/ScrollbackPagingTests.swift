@testable import TenonCore
import XCTest

/// The paging rule for `terminal.scrollback.read.v1`, asserted without a terminal.
final class ScrollbackPagingTests: XCTestCase {
    func testAFirstPageStartsAtTheOldestRetainedRow() {
        let page = ScrollbackPaging.page(
            totalRows: 10,
            maxLines: 4,
            cursor: nil
        )

        XCTAssertEqual(
            page,
            .rows(
                0 ..< 4,
                next: ScrollbackPaging.Cursor(nextRow: 4, totalRows: 10)
            )
        )
    }

    func testPagesWalkTheWholeScrollbackExactlyOnceAndThenStop() {
        var collected: [Int] = []
        var cursor: ScrollbackPaging.Cursor?
        var pages = 0

        while pages < 10 {
            pages += 1
            guard case let .rows(range, next) = ScrollbackPaging.page(
                totalRows: 10,
                maxLines: 4,
                cursor: cursor
            ) else {
                return XCTFail("unexpected invalidation")
            }
            collected.append(contentsOf: range)
            guard let next else { break }
            cursor = next
        }

        // Every row once, in order, and the walk ended on its own rather than by the
        // loop guard — a cursor that never returns nil would page forever.
        XCTAssertEqual(collected, Array(0 ..< 10))
        XCTAssertEqual(pages, 3)
    }

    func testTheLastPageReportsNoFurtherCursor() {
        let page = ScrollbackPaging.page(
            totalRows: 8,
            maxLines: 8,
            cursor: nil
        )

        XCTAssertEqual(page, .rows(0 ..< 8, next: nil))
    }

    func testAPaneRetainingNothingAnswersAnEmptyPageRatherThanFailing() {
        let page = ScrollbackPaging.page(
            totalRows: 0,
            maxLines: 100,
            cursor: nil
        )

        XCTAssertEqual(page, .rows(0 ..< 0, next: nil))
    }

    /// The whole reason the cursor carries a row count. Positions are relative to the
    /// oldest retained row, so once the buffer changes size they address different rows;
    /// answering with them would hand the caller a silent gap or a silent repeat.
    func testACursorIssuedAgainstADifferentScrollbackSizeIsRefused() {
        let stale = ScrollbackPaging.Cursor(nextRow: 4, totalRows: 10)

        XCTAssertEqual(
            ScrollbackPaging.page(totalRows: 12, maxLines: 4, cursor: stale),
            .invalidated
        )
        XCTAssertEqual(
            ScrollbackPaging.page(totalRows: 9, maxLines: 4, cursor: stale),
            .invalidated
        )
        XCTAssertEqual(
            ScrollbackPaging.page(totalRows: 10, maxLines: 4, cursor: stale),
            .rows(4 ..< 8, next: ScrollbackPaging.Cursor(
                nextRow: 8,
                totalRows: 10
            ))
        )
    }

    func testAPageSizeBelowOneStillMakesProgress() {
        // A zero-row page would return the same cursor forever, so the caller would loop
        // without ever advancing. Clamping is what makes the walk terminate.
        XCTAssertEqual(
            ScrollbackPaging.page(totalRows: 3, maxLines: 0, cursor: nil),
            .rows(
                0 ..< 1,
                next: ScrollbackPaging.Cursor(nextRow: 1, totalRows: 3)
            )
        )
    }

    func testCursorsRoundTripThroughTheirEncodedForm() {
        let cursor = ScrollbackPaging.Cursor(nextRow: 128, totalRows: 4_096)

        XCTAssertEqual(cursor.encoded, "128:4096")
        XCTAssertEqual(ScrollbackPaging.Cursor.decode("128:4096"), cursor)
    }

    /// A cursor arrives from outside the host, so decoding is a boundary. Each rejection
    /// below is a way a caller could otherwise name rows the pane never offered.
    func testDecodeRejectsAnythingItDidNotWrite() {
        for raw in [
            "",
            "128",
            "128:4096:7",
            "abc:4096",
            "128:abc",
            "-1:4096",
            "128:-1",
            "4097:4096",
        ] {
            XCTAssertNil(
                ScrollbackPaging.Cursor.decode(raw),
                "decoded a cursor from \(raw.debugDescription)"
            )
        }
    }
}
