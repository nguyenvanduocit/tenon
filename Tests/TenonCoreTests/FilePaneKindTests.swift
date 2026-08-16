@testable import TenonCore
import XCTest

/// T-038: which renderer a file pane gets, asserted without a window.
final class FilePaneKindTests: XCTestCase {
    /// The extension decides the renderer, case-insensitively, and anything unclaimed keeps
    /// the editor. One rule, so one table — the parsing rules that decide *what the
    /// extension is* get their own tests below.
    func testTheExtensionDecidesTheRendererAndTheEditorTakesTheRest() {
        for (path, expected) in [
            ("/repo/logo.png", FilePaneKind.image),
            ("/repo/shot.JPG", .image),
            ("/repo/anim.gif", .image),
            ("/repo/hero.webp", .image),
            ("/repo/mark.svg", .image),
            ("/repo/photo.HEIC", .image),
            ("/repo/scan.tiff", .image),
            ("/repo/index.html", .web),
            ("/repo/page.HTM", .web),
            ("/repo/doc.xhtml", .web),
            ("/repo/main.swift", .text),
            ("/repo/README.md", .text),
            ("/repo/data.json", .text),
            ("/repo/Makefile", .text),
            ("/repo/archive.tar.gz", .text),
        ] {
            XCTAssertEqual(
                FilePaneKind.kind(forPath: path),
                expected,
                "\(path) should render as \(expected)"
            )
        }
    }

    /// A leading dot is part of the name, so a file *named* `.png` is not a picture — and
    /// a dotfile that does carry a real extension still is one.
    ///
    /// Measured, not assumed: `NSString.pathExtension` returns "" for ".gitignore" and
    /// ".png", and "png" for ".hidden.png". An earlier version of this rule hand-guarded
    /// leading dots on the belief that Foundation reported "gitignore" — it does not, so
    /// the guard was dead where it agreed and wrong where it did not, forcing a real
    /// `.hidden.png` to the editor. Mutation testing is what surfaced that: deleting the
    /// guard reddened nothing.
    func testALeadingDotIsPartOfTheNameNotAnExtension() {
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/.gitignore"), .text)
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/.png"), .text)
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/.env.local"), .text)
        XCTAssertEqual(
            FilePaneKind.kind(forPath: "/repo/.hidden.png"),
            .image,
            "a dotfile with a real extension is still that kind of file"
        )
    }

    /// Only the last extension counts, because that is what the name says the file is.
    func testTheLastExtensionWins() {
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/notes.png.txt"), .text)
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/page.txt.html"), .web)
    }

    func testNamesWithNoExtensionKeepTheEditor() {
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/LICENSE"), .text)
        XCTAssertEqual(FilePaneKind.kind(forPath: "/repo/trailing."), .text)
        XCTAssertEqual(FilePaneKind.kind(forPath: ""), .text)
    }

    /// A directory component must never decide the renderer — only the file's own name.
    func testOnlyTheFileNameDecides() {
        XCTAssertEqual(
            FilePaneKind.kind(forPath: "/repo/images.png/main.swift"),
            .text
        )
        XCTAssertEqual(
            FilePaneKind.kind(forPath: "/repo/src.swift/logo.png"),
            .image
        )
    }
}
