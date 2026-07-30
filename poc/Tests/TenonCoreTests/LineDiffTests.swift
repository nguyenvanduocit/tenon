import XCTest
@testable import TenonCore

/// `LineDiff` — a pure Myers line-diff engine, the content model behind the host's
/// native default diff view. It carries no AppKit/SwiftUI, so the whole diff *rule*
/// is asserted here without a window (`docs/tdd.md` fitness test). The shell only
/// paints the `DiffLine`/`DiffHunk` values this produces.
final class LineDiffTests: XCTestCase {
    // MARK: lines()

    func testIdenticalTextIsAllContext() {
        let text = "alpha\nbeta\ngamma\n"
        let lines = LineDiff.lines(old: text, new: text)
        XCTAssertEqual(lines.map(\.kind), [.context, .context, .context])
        XCTAssertEqual(lines.map(\.text), ["alpha", "beta", "gamma"])
        // Context lines carry both sides' 1-based numbers.
        XCTAssertEqual(lines.map(\.oldNumber), [1, 2, 3])
        XCTAssertEqual(lines.map(\.newNumber), [1, 2, 3])
    }

    func testAppendedLinesAreAdded() {
        let lines = LineDiff.lines(old: "a\nb\n", new: "a\nb\nc\nd\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .context, .added, .added])
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c", "d"])
        // Added lines have no old-side number; new numbers stay sequential.
        XCTAssertEqual(lines[2].oldNumber, nil)
        XCTAssertEqual(lines[2].newNumber, 3)
        XCTAssertEqual(lines[3].newNumber, 4)
    }

    func testRemovedLines() {
        let lines = LineDiff.lines(old: "a\nb\nc\n", new: "a\nc\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .context])
        XCTAssertEqual(lines[1].text, "b")
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertEqual(lines[1].newNumber, nil)
        // The surviving "c" renumbers to 2 on the new side.
        XCTAssertEqual(lines[2].oldNumber, 3)
        XCTAssertEqual(lines[2].newNumber, 2)
    }

    func testChangedLineIsRemovePlusAdd() {
        let lines = LineDiff.lines(old: "a\nB\nc\n", new: "a\nX\nc\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines[1].text, "B")
        XCTAssertEqual(lines[2].text, "X")
    }

    func testEmptyOldIsAllAdded() {
        let lines = LineDiff.lines(old: "", new: "x\ny\n")
        XCTAssertEqual(lines.map(\.kind), [.added, .added])
        XCTAssertEqual(lines.map(\.text), ["x", "y"])
    }

    func testEmptyNewIsAllRemoved() {
        let lines = LineDiff.lines(old: "x\ny\n", new: "")
        XCTAssertEqual(lines.map(\.kind), [.removed, .removed])
    }

    func testBothEmptyIsNoLines() {
        XCTAssertEqual(LineDiff.lines(old: "", new: ""), [])
    }

    func testTrailingNewlineIsNotASpuriousEmptyLine() {
        // "a\nb\n" and "a\nb" describe the same two lines for display purposes.
        XCTAssertEqual(LineDiff.lines(old: "a\nb\n", new: "a\nb\n").count, 2)
        XCTAssertEqual(LineDiff.lines(old: "a\nb", new: "a\nb").count, 2)
    }

    func testGenuineBlankLineIsPreserved() {
        // "a\n\n" is line "a" then an empty line — the blank must survive.
        let lines = LineDiff.lines(old: "a\n\n", new: "a\n\n")
        XCTAssertEqual(lines.map(\.text), ["a", ""])
    }

    // MARK: stat()

    func testStatCountsAddedAndRemoved() {
        let s = LineDiff.stat(old: "a\nb\nc\n", new: "a\nX\nc\nd\n")
        XCTAssertEqual(s.added, 2)   // X, d
        XCTAssertEqual(s.removed, 1) // b
    }

    // MARK: hunks()

    func testNoChangesYieldNoHunks() {
        XCTAssertEqual(LineDiff.hunks(old: "a\nb\n", new: "a\nb\n"), [])
    }

    func testSingleChangeIsOneHunkWithContext() {
        let old = "1\n2\n3\n4\n5\n6\n7\n"
        let new = "1\n2\n3\nX\n5\n6\n7\n"
        let hunks = LineDiff.hunks(old: old, new: new, context: 2)
        XCTAssertEqual(hunks.count, 1)
        // 2 lines of context each side around the changed line 4.
        let kinds = hunks[0].lines.map(\.kind)
        XCTAssertTrue(kinds.contains(.removed))
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertEqual(kinds.first, .context)
        XCTAssertEqual(kinds.last, .context)
    }

    func testDistantChangesSplitIntoTwoHunks() {
        let old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
        let new = "X\n2\n3\n4\n5\n6\n7\n8\n9\nY\n"
        let hunks = LineDiff.hunks(old: old, new: new, context: 1)
        XCTAssertEqual(hunks.count, 2)
    }

    func testHunkHeaderReflectsRanges() {
        let old = "a\nb\nc\n"
        let new = "a\nX\nc\n"
        let hunks = LineDiff.hunks(old: old, new: new, context: 3)
        XCTAssertEqual(hunks.count, 1)
        // Full-file context here: old 1..3, new 1..3.
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].header, "@@ -1,3 +1,3 @@")
    }
}
