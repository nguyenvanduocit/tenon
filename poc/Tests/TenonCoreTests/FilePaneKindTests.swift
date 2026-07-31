@testable import TenonCore
import XCTest

/// T-038: which renderer a file pane gets, asserted without a window.
final class FilePaneKindTests: XCTestCase {
    func testImagesRenderAsPictures() {
        for path in [
            "/repo/logo.png",
            "/repo/shot.JPG",
            "/repo/anim.gif",
            "/repo/hero.webp",
            "/repo/mark.svg",
            "/repo/photo.HEIC",
            "/repo/scan.tiff",
        ] {
            XCTAssertEqual(
                FilePaneKind.kind(forPath: path),
                .image,
                "\(path) should render as a picture"
            )
        }
    }

    func testHTMLRendersAsAPage() {
        for path in ["/repo/index.html", "/repo/page.HTM", "/repo/doc.xhtml"] {
            XCTAssertEqual(FilePaneKind.kind(forPath: path), .web, path)
        }
    }

    func testEverythingElseKeepsTheEditor() {
        for path in [
            "/repo/main.swift",
            "/repo/README.md",
            "/repo/data.json",
            "/repo/Makefile",
            "/repo/archive.tar.gz",
        ] {
            XCTAssertEqual(FilePaneKind.kind(forPath: path), .text, path)
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
