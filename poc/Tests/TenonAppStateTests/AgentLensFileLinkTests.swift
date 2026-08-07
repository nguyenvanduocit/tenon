import Foundation
import SwiftUI
@testable import TenonApp
import XCTest

final class AgentLensFileLinkTests: XCTestCase {
    // MARK: - What counts as a file an agent named

    func testAPathInProseIsAFileReference() {
        XCTAssertEqual(
            AgentFileReferenceRule.reference(in: "poc/Sources/TenonApp/AgentLensView.swift"),
            AgentFileReference(path: "poc/Sources/TenonApp/AgentLensView.swift", line: nil)
        )
    }

    func testALineSuffixPointsIntoTheFileTheReferenceNames() {
        XCTAssertEqual(
            AgentFileReferenceRule.reference(in: "AgentLensView.swift:1023"),
            AgentFileReference(path: "AgentLensView.swift", line: 1_023)
        )
    }

    func testALineAndColumnSuffixKeepsTheLine() {
        XCTAssertEqual(
            AgentFileReferenceRule.reference(in: "Sources/App/View.swift:42:9"),
            AgentFileReference(path: "Sources/App/View.swift", line: 42)
        )
    }

    func testRelativeAndHomePathsAreReferences() {
        XCTAssertEqual(
            AgentFileReferenceRule.reference(in: "./scripts/setup-ghosttykit.sh")?.path,
            "./scripts/setup-ghosttykit.sh"
        )
        XCTAssertEqual(
            AgentFileReferenceRule.reference(in: "~/.claude/CLAUDE.md")?.path,
            "~/.claude/CLAUDE.md"
        )
    }

    func testADotfileIsAFileEvenWithoutADirectory() {
        XCTAssertEqual(AgentFileReferenceRule.reference(in: ".gitignore")?.path, ".gitignore")
    }

    func testCommandsFlagsURLsAndProseAreNotFiles() {
        for span in [
            "swift test --filter testFoo",
            "--filter",
            "https://example.com/a.swift",
            "https://tenon.dev",
            "nguyenvanduocit@gmail.com",
            "main",
            "poc/",
            "AgentLensView.swift:notaline",
            "",
        ] {
            XCTAssertNil(
                AgentFileReferenceRule.reference(in: span),
                "\(span) should not read as a file"
            )
        }
    }

    // MARK: - Only a file that is really there earns a link

    func testARelativePathResolvesAgainstTheWorkspaceRoot() {
        let root = URL(fileURLWithPath: "/workspace")
        let links = AgentFileLinks(root: root) { $0 == "/workspace/Sources/App.swift" }

        XCTAssertEqual(links.path(for: "Sources/App.swift"), "/workspace/Sources/App.swift")
        XCTAssertEqual(links.path(for: "./Sources/App.swift"), "/workspace/Sources/App.swift")
    }

    func testAPathThatDoesNotExistNeverBecomesALink() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) { _ in false }

        XCTAssertNil(links.path(for: "Sources/Missing.swift"))
        XCTAssertNil(links.url(for: "Sources/Missing.swift"))
    }

    func testADirectoryIsNotAFilePane() {
        let root = URL(fileURLWithPath: "/workspace")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let links = AgentFileLinks(root: root) { _ in true }

        XCTAssertNil(links.path(for: "Sources/"))
    }

    func testARelativePathCannotWalkOutOfTheWorkspace() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) { _ in true }

        XCTAssertNil(links.path(for: "../../etc/passwd"))
        XCTAssertTrue(
            AgentFileLinks.candidates(for: "../secret.txt", root: URL(fileURLWithPath: "/workspace"))
                .isEmpty
        )
    }

    func testAnAbsolutePathResolvesAsWritten() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) {
            $0 == "/etc/hosts"
        }

        XCTAssertEqual(links.path(for: "/etc/hosts"), "/etc/hosts")
    }

    func testResolutionAgainstARealDirectoryFindsTheFileAndSkipsTheFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-lens-file-links-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "let a = 1".write(
            to: nested.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let links = AgentFileLinks(root: root)

        XCTAssertEqual(
            links.path(for: "Sources/App.swift"),
            nested.appendingPathComponent("App.swift").standardizedFileURL.path
        )
        XCTAssertNil(links.path(for: "Sources/Nothing.swift"))
        XCTAssertNil(links.path(for: "Sources"))
    }

    // MARK: - How a resolved file renders

    func testACitedPathInBackticksBecomesAFileLink() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) {
            $0 == "/workspace/Sources/App.swift"
        }

        let attributed = AgentMarkdownInline.attributed(
            "I changed `Sources/App.swift` today.",
            fileLinks: links
        )

        XCTAssertEqual(
            Self.links(in: attributed),
            [URL(fileURLWithPath: "/workspace/Sources/App.swift")]
        )
    }

    func testACitedPathWithALineStillLinksTheFile() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) {
            $0 == "/workspace/Sources/App.swift"
        }

        let attributed = AgentMarkdownInline.attributed(
            "See `Sources/App.swift:42`.",
            fileLinks: links
        )

        XCTAssertEqual(
            Self.links(in: attributed),
            [URL(fileURLWithPath: "/workspace/Sources/App.swift")]
        )
    }

    func testACommandInBackticksStaysPlainText() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) { _ in true }

        let attributed = AgentMarkdownInline.attributed("Run `swift test` now.", fileLinks: links)

        XCTAssertTrue(Self.links(in: attributed).isEmpty)
    }

    func testAWrittenLinkToAMissingPathRendersAsPlainText() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) { _ in false }

        let attributed = AgentMarkdownInline.attributed(
            "See [the view](Sources/Gone.swift).",
            fileLinks: links
        )

        XCTAssertTrue(Self.links(in: attributed).isEmpty)
        XCTAssertTrue(String(attributed.characters).contains("the view"))
    }

    func testAWrittenLinkToAResolvingPathBecomesAFileLink() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) {
            $0 == "/workspace/Sources/App.swift"
        }

        let attributed = AgentMarkdownInline.attributed(
            "See [the view](Sources/App.swift).",
            fileLinks: links
        )

        XCTAssertEqual(
            Self.links(in: attributed),
            [URL(fileURLWithPath: "/workspace/Sources/App.swift")]
        )
    }

    func testARemoteLinkKeepsItsOwnDestination() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) { _ in true }

        let attributed = AgentMarkdownInline.attributed(
            "See [the docs](https://tenon.dev/docs).",
            fileLinks: links
        )

        XCTAssertEqual(Self.links(in: attributed), [URL(string: "https://tenon.dev/docs")])
    }

    // MARK: - Backticks are punctuation, not a reason for an address to go dead

    func testAnAddressInBackticksLinksLikeABareOne() {
        let inBackticks = AgentMarkdownInline.attributed("Open `https://tenon.dev/docs`.")
        let bare = AgentMarkdownInline.attributed("Open https://tenon.dev/docs")

        XCTAssertEqual(Self.links(in: inBackticks), [URL(string: "https://tenon.dev/docs")])
        XCTAssertEqual(Self.links(in: bare), Self.links(in: inBackticks))
    }

    func testOnlyAnAbsoluteWebAddressLinksFromACodeSpan() {
        for span in ["swift test", "--filter", "ftp://files.example.com", "tenon.dev", "https://"] {
            XCTAssertTrue(
                Self.links(in: AgentMarkdownInline.attributed("Run `\(span)`.")).isEmpty,
                "`\(span)` should not read as a web address"
            )
        }
    }

    func testAFilePathStillWinsOverAnAddressInTheSameSpan() {
        let links = AgentFileLinks(root: URL(fileURLWithPath: "/workspace")) {
            $0 == "/workspace/Sources/App.swift"
        }

        let attributed = AgentMarkdownInline.attributed(
            "I changed `Sources/App.swift`.",
            fileLinks: links
        )

        XCTAssertEqual(
            Self.links(in: attributed),
            [URL(fileURLWithPath: "/workspace/Sources/App.swift")]
        )
    }

    func testProseRendersWithoutLinksWhenNoWorkspaceResolvesPaths() {
        let attributed = AgentMarkdownInline.attributed("I changed `Sources/App.swift`.")

        XCTAssertTrue(Self.links(in: attributed).isEmpty)
    }

    private static func links(in attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap(\.link)
    }
}
