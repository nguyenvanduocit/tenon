@testable import TenonBundledPlugins
import XCTest

final class GitPluginParseTests: XCTestCase {
    func testBranchRecordsBecomeTheHeaderModel() {
        let model = GitStatusParser.parseStatus(
            [
                "# branch.oid abc123",
                "# branch.head main",
                "# branch.upstream origin/main",
                "# branch.ab +2 -3",
            ].joined(separator: "\0")
        )

        XCTAssertEqual(model.branch, "main")
        XCTAssertEqual(model.upstream, "origin/main")
        XCTAssertEqual(model.ahead, 2)
        XCTAssertEqual(model.behind, 3)
        XCTAssertTrue(model.hasHead)
        XCTAssertTrue(model.isRepo)
    }

    func testAnUnbornBranchHasNoHeadAndDetachedOneSaysSo() {
        let unborn = GitStatusParser.parseStatus(
            ["# branch.oid (initial)", "# branch.head main"].joined(separator: "\0")
        )
        XCTAssertFalse(unborn.hasHead)

        let detached = GitStatusParser.parseStatus(
            ["# branch.oid abc123", "# branch.head (detached)"].joined(separator: "\0")
        )
        XCTAssertEqual(detached.branch, "detached HEAD")
    }

    func testOrdinaryEntriesSplitIntoStagedAndChanged() {
        let model = GitStatusParser.parseStatus(
            [
                "# branch.head main",
                "1 M. N... 100644 100644 100644 aaa bbb staged-only.txt",
                "1 .M N... 100644 100644 100644 aaa bbb worktree-only.txt",
                "1 MM N... 100644 100644 100644 aaa bbb both.txt",
                "? untracked.txt",
            ].joined(separator: "\0")
        )

        XCTAssertEqual(model.staged.map(\.path), ["staged-only.txt", "both.txt"])
        XCTAssertEqual(model.changed.map(\.path), ["worktree-only.txt", "both.txt", "untracked.txt"])
        XCTAssertEqual(model.merge.map(\.path), [])
    }

    func testRenameConsumesItsOriginalPathRecordAndKeepsSpaces() {
        let model = GitStatusParser.parseStatus(
            [
                "# branch.head main",
                "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt",
                "old name.txt",
                "1 M. N... 100644 100644 100644 aaa bbb after.txt",
            ].joined(separator: "\0")
        )

        XCTAssertEqual(model.staged.map(\.path), ["new name.txt", "after.txt"])
        XCTAssertEqual(model.staged.first?.origPath, "old name.txt")
    }

    func testConflictsAreTheirOwnListAndNeverStagedOrChanged() {
        let model = GitStatusParser.parseStatus(
            [
                "# branch.head main",
                "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.txt",
            ].joined(separator: "\0")
        )

        XCTAssertEqual(model.merge.map(\.path), ["conflicted.txt"])
        XCTAssertEqual(model.staged.map(\.path), [])
        XCTAssertEqual(model.changed.map(\.path), [])
    }

    func testLogRecordsPreserveHashAndSubject() {
        XCTAssertEqual(
            GitStatusParser.parseLog("abc123\u{1f}Keep the status panel\ndef456\u{1f}Fix spacing\n"),
            [
                GitRecentCommit(hash: "abc123", subject: "Keep the status panel"),
                GitRecentCommit(hash: "def456", subject: "Fix spacing"),
            ]
        )
    }

    func testUnknownAndEmptyRecordsAreIgnored() {
        let model = GitStatusParser.parseStatus(
            ["", "# branch.head main", "x nonsense", ""].joined(separator: "\0")
        )
        XCTAssertEqual(model.branch, "main")
        XCTAssertTrue(model.staged.isEmpty)
        XCTAssertTrue(model.changed.isEmpty)
    }
}
