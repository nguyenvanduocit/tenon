import XCTest
@testable import TenonCore

/// `DiffRequest` / `DiffSource` / `SlotPlacement` are the pure values a plugin
/// builds through `tenon.diff.open`. No window needed to pin their shape.
final class DiffRequestTests: XCTestCase {
    func testGitSourceCarriesEveryField() {
        let req = DiffRequest(
            source: .git(repoPath: "/repo", path: "a/b.swift", staged: true, untracked: false, origPath: "a/old.swift"),
            fileName: "b.swift",
            title: "b.swift (Staged)"
        )
        XCTAssertEqual(
            req.source,
            .git(repoPath: "/repo", path: "a/b.swift", staged: true, untracked: false, origPath: "a/old.swift")
        )
        XCTAssertEqual(req.fileName, "b.swift")
        XCTAssertEqual(req.title, "b.swift (Staged)")
    }

    func testInlineSourceHoldsBothTexts() {
        let req = DiffRequest(source: .inline(oldText: "x", newText: "y"), fileName: "note", title: "note")
        XCTAssertEqual(req.source, .inline(oldText: "x", newText: "y"))
    }

    func testSourcesWithDifferentFlagsAreNotEqual() {
        let a = DiffSource.git(repoPath: "/r", path: "p", staged: false, untracked: false, origPath: nil)
        let b = DiffSource.git(repoPath: "/r", path: "p", staged: true, untracked: false, origPath: nil)
        XCTAssertNotEqual(a, b)
    }
}
