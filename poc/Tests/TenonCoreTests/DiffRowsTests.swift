import XCTest
@testable import TenonCore

/// `DiffRows` — the pure projection from `LineDiff`'s hunks to the flat, indexed row
/// list a lazy container scrolls. It carries no AppKit/SwiftUI, so the whole
/// flattening *rule* — unified order, side-by-side pairing, pairing gaps, and row
/// identity — is asserted here without a window (`docs/tdd.md` fitness test). The
/// shell only paints the `DiffRow` values this produces, one screen at a time.
final class DiffRowsTests: XCTestCase {
    // MARK: - Unified

    func testUnifiedEmitsTheHunkHeaderThenEveryLineInOrder() {
        let hunks = LineDiff.hunks(old: "a\nB\nc\n", new: "a\nX\nc\n", context: 3)
        XCTAssertEqual(hunks.count, 1)

        let rows = DiffRows.unified(hunks)

        // header, a, -B, +X, c
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.first?.content, .header(hunks[0].header))
        XCTAssertEqual(
            rows.dropFirst().map(\.content),
            hunks[0].lines.map(DiffRow.Content.line)
        )
    }

    func testUnifiedConcatenatesEveryHunkAndTagsEachRowWithItsHunk() {
        // Two edits 200 lines apart collapse to two hunks, never one.
        var old = (1...400).map { "line \($0)" }
        var new = old
        new[10] = "edited near the top"
        new[300] = "edited near the bottom"
        old.append("")  // trailing newline
        new.append("")

        let hunks = LineDiff.hunks(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        XCTAssertEqual(hunks.count, 2)

        let rows = DiffRows.unified(hunks)
        XCTAssertEqual(rows.filter { $0.isHeader }.count, 2)
        XCTAssertEqual(rows.count, 2 + hunks[0].lines.count + hunks[1].lines.count)
        XCTAssertEqual(Set(rows.map(\.hunkIndex)), [0, 1])
        // Rows stay in hunk order — the list is scrolled top to bottom.
        XCTAssertEqual(rows.map(\.hunkIndex), rows.map(\.hunkIndex).sorted())
    }

    func testNoHunksProduceNoRows() {
        XCTAssertEqual(DiffRows.unified([]).count, 0)
        XCTAssertEqual(DiffRows.split([]).count, 0)
    }

    // MARK: - Split / side-by-side

    func testSplitPutsAContextLineOnBothSides() {
        let hunks = LineDiff.hunks(old: "a\nB\n", new: "a\nX\n")
        let rows = DiffRows.split(hunks)

        guard case .pair(let left, let right) = rows[1].content else {
            return XCTFail("expected a pair row, got \(rows[1].content)")
        }
        XCTAssertEqual(left?.text, "a")
        XCTAssertEqual(right?.text, "a")
        XCTAssertEqual(left?.oldNumber, 1)
        XCTAssertEqual(right?.newNumber, 1)
    }

    func testSplitAlignsARunOfRemovalsWithTheAdditionsThatFollowIt() {
        let hunks = LineDiff.hunks(old: "A\nB\n", new: "X\nY\n")
        let pairs = DiffRows.split(hunks).compactMap(\.pairContent)

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].left?.text, "A")
        XCTAssertEqual(pairs[0].right?.text, "X")
        XCTAssertEqual(pairs[1].left?.text, "B")
        XCTAssertEqual(pairs[1].right?.text, "Y")
    }

    func testSplitLeavesAGapWhenTheRemovedSideIsLonger() {
        // Three lines out, one line in: two rows have nothing on the right.
        let hunks = LineDiff.hunks(old: "A\nB\nC\n", new: "X\n")
        let pairs = DiffRows.split(hunks).compactMap(\.pairContent)

        XCTAssertEqual(pairs.map { $0.left?.text }, ["A", "B", "C"])
        XCTAssertEqual(pairs.map { $0.right?.text }, ["X", nil, nil])
    }

    func testSplitLeavesAGapWhenTheAddedSideIsLonger() {
        let hunks = LineDiff.hunks(old: "A\n", new: "X\nY\nZ\n")
        let pairs = DiffRows.split(hunks).compactMap(\.pairContent)

        XCTAssertEqual(pairs.map { $0.left?.text }, ["A", nil, nil])
        XCTAssertEqual(pairs.map { $0.right?.text }, ["X", "Y", "Z"])
    }

    func testSplitPutsAPureAdditionOnTheRightOnly() {
        let hunks = LineDiff.hunks(old: "a\n", new: "a\nb\n")
        let pairs = DiffRows.split(hunks).compactMap(\.pairContent)

        XCTAssertEqual(pairs.map { $0.left?.text }, ["a", nil])
        XCTAssertEqual(pairs.map { $0.right?.text }, ["a", "b"])
    }

    func testSplitKeepsTheHunkHeader() {
        let hunks = LineDiff.hunks(old: "a\nB\n", new: "a\nX\n")
        let rows = DiffRows.split(hunks)

        XCTAssertTrue(rows[0].isHeader)
        XCTAssertEqual(rows[0].content, .header(hunks[0].header))
        XCTAssertEqual(rows.filter(\.isHeader).count, 1)
    }

    // MARK: - Row identity
    //
    // Identity is the whole point of flattening: a lazy container recycles rows, and
    // `enumerated().offset` makes every row's identity change when anything above it
    // changes, which forces a full rebuild. Ids here come from the line numbers the
    // row shows, so they survive that.

    func testUnifiedRowIDsAreUniqueAcrossAWholeDiff() {
        let old = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...500).map { "line \($0)" }
        for index in stride(from: 0, to: 500, by: 7) { lines[index] = "edited \(index)" }
        let new = lines.joined(separator: "\n") + "\n"

        let hunks = LineDiff.hunks(old: old, new: new)
        let unified = DiffRows.unified(hunks)
        let split = DiffRows.split(hunks)

        XCTAssertGreaterThan(unified.count, 100)
        XCTAssertEqual(Set(unified.map(\.id)).count, unified.count)
        XCTAssertEqual(Set(split.map(\.id)).count, split.count)
    }

    func testRowIDsComeFromLineNumbersNotFromPositionInTheList() {
        // The same edit, once alone and once with an unrelated edit inserted far
        // above it. Every row below the insertion shifts position; none of their ids
        // may change, or a lazy container rebuilds the whole list on every reload.
        let base = (1...400).map { "line \($0)" }

        var onlyLate = base
        onlyLate[300] = "edited late"
        var alsoEarly = onlyLate
        alsoEarly[10] = "edited early"

        let text: ([String]) -> String = { $0.joined(separator: "\n") + "\n" }
        let lateOnlyRows = DiffRows.unified(LineDiff.hunks(old: text(base), new: text(onlyLate)))
        let bothRows = DiffRows.unified(LineDiff.hunks(old: text(base), new: text(alsoEarly)))

        // The second diff has strictly more rows, and they sit at different offsets…
        XCTAssertGreaterThan(bothRows.count, lateOnlyRows.count)
        XCTAssertNotEqual(bothRows.prefix(lateOnlyRows.count).map(\.id), lateOnlyRows.map(\.id))
        // …yet the late hunk's rows keep exactly the ids they had.
        let lateIDs = Set(lateOnlyRows.map(\.id))
        XCTAssertTrue(lateIDs.isSubset(of: Set(bothRows.map(\.id))))
    }

    func testAHeaderRowNeverCollidesWithALineRow() {
        let hunks = LineDiff.hunks(old: "a\nB\nc\n", new: "a\nX\nc\n")
        let rows = DiffRows.unified(hunks)
        let headerIDs = Set(rows.filter(\.isHeader).map(\.id))
        let lineIDs = Set(rows.filter { !$0.isHeader }.map(\.id))

        XCTAssertFalse(headerIDs.isEmpty)
        XCTAssertTrue(headerIDs.isDisjoint(with: lineIDs))
    }

    func testAddedAndRemovedRowsWithTheSameNumberGetDifferentIDs() {
        // A one-line replacement produces `-2` and `+2`: same number, different sides.
        let hunks = LineDiff.hunks(old: "a\nB\nc\n", new: "a\nX\nc\n")
        let rows = DiffRows.unified(hunks)
        let removed = rows.first { $0.lineContent?.kind == .removed }
        let added = rows.first { $0.lineContent?.kind == .added }

        XCTAssertEqual(removed?.lineContent?.oldNumber, 2)
        XCTAssertEqual(added?.lineContent?.newNumber, 2)
        XCTAssertNotEqual(removed?.id, added?.id)
    }

    // MARK: - Column sizing
    //
    // A lazy container only measures the rows it builds, so the scrollable content
    // width has to be decided from the content instead. Core picks the widest
    // candidates per column; the shell measures just those few with the real font.

    func testWidestTextsPicksTheLongestLinesForTheUnifiedColumn() {
        let hunks = LineDiff.hunks(old: "short\n", new: "a considerably longer line of code\n")
        let widest = DiffRows.widestTexts(DiffRows.unified(hunks), column: .unified, limit: 1)

        XCTAssertEqual(widest, ["a considerably longer line of code"])
    }

    func testWidestTextsKeepsTheTwoSidesIndependent() {
        // The long line is on the new side only: the left column must not inherit it.
        let hunks = LineDiff.hunks(old: "x\n", new: "an extremely long replacement line\n")
        let rows = DiffRows.split(hunks)

        XCTAssertEqual(DiffRows.widestTexts(rows, column: .left, limit: 1), ["x"])
        XCTAssertEqual(
            DiffRows.widestTexts(rows, column: .right, limit: 1),
            ["an extremely long replacement line"]
        )
    }

    func testWidestTextsReturnsAtMostTheLimitLongestFirst() {
        let old = "aaa\nbbbbbb\nc\ndddddddddd\n"
        let rows = DiffRows.unified(LineDiff.hunks(old: old, new: ""))
        let widest = DiffRows.widestTexts(rows, column: .unified, limit: 2)

        XCTAssertEqual(widest, ["dddddddddd", "bbbbbb"])
    }

    func testWidestTextsIgnoresHeaderRows() {
        let hunks = LineDiff.hunks(old: "a\n", new: "b\n")
        let widest = DiffRows.widestTexts(DiffRows.unified(hunks), column: .unified, limit: 10)

        XCTAssertEqual(Set(widest), ["a", "b"])
    }

    func testDisplayWidthCountsAWideCharacterAsTwoCells() {
        // A monospaced font draws CJK at double advance, so eight ASCII characters
        // are narrower than five han characters — picking candidates by `count`
        // alone would hand the shell the wrong line to measure.
        XCTAssertEqual(DiffRows.displayWidth("abcdefgh"), 8)
        XCTAssertEqual(DiffRows.displayWidth("日本語です"), 10)
        XCTAssertEqual(DiffRows.displayWidth("héllo"), 5)
        XCTAssertEqual(DiffRows.displayWidth(""), 0)
    }

    func testWidestTextsRanksByDisplayWidthSoNonASCIIWins() {
        let rows = DiffRows.unified(LineDiff.hunks(old: "abcdefgh\n日本語です\n", new: ""))
        XCTAssertEqual(DiffRows.widestTexts(rows, column: .unified, limit: 1), ["日本語です"])
    }

    // MARK: - Gutter

    func testMaxLineNumberIsTheLargestNumberAnyRowShows() {
        let old = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...50).map { "line \($0)" }
        lines[48] = "edited"
        let new = lines.joined(separator: "\n") + "\n"

        XCTAssertEqual(DiffRows.maxLineNumber(LineDiff.hunks(old: old, new: new)), 50)
        // Never zero: the gutter is at least one digit wide even for an empty diff.
        XCTAssertEqual(DiffRows.maxLineNumber([]), 1)
    }
}

// MARK: - Reading helpers

private extension DiffRow {
    var pairContent: (left: DiffLine?, right: DiffLine?)? {
        if case .pair(let left, let right) = content { return (left, right) }
        return nil
    }

    var lineContent: DiffLine? {
        if case .line(let line) = content { return line }
        return nil
    }
}
