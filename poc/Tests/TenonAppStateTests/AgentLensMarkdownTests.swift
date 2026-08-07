import Foundation
import SwiftUI
@testable import TenonApp
import XCTest

final class AgentLensMarkdownTests: XCTestCase {
    func testProseSplitsIntoParagraphsOnBlankLines() {
        let blocks = AgentMarkdown.parse(
            """
            The questionnaire tool is unavailable in Default mode.

            Which topics interest you?
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .paragraph("The questionnaire tool is unavailable in Default mode."),
                .paragraph("Which topics interest you?"),
            ]
        )
    }

    func testSoftWrappedLinesStayInOneParagraph() {
        let blocks = AgentMarkdown.parse("first line\nsecond line")

        XCTAssertEqual(blocks, [.paragraph("first line\nsecond line")])
    }

    func testHeadingsCarryTheirLevelWithoutTheirPunctuation() {
        let blocks = AgentMarkdown.parse("## What changed ##\n\n### Why")

        XCTAssertEqual(
            blocks,
            [
                .heading(level: 2, text: "What changed"),
                .heading(level: 3, text: "Why"),
            ]
        )
    }

    func testTaskListItemsCarryTheirCheckboxSeparatelyFromTheirText() {
        let blocks = AgentMarkdown.parse(
            """
            - [ ] SwiftUI
            - [x] Plugin development
            - Architecture
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .list([
                    AgentMarkdownListItem(depth: 0, marker: .bullet, task: .unchecked, text: "SwiftUI"),
                    AgentMarkdownListItem(
                        depth: 0,
                        marker: .bullet,
                        task: .checked,
                        text: "Plugin development"
                    ),
                    AgentMarkdownListItem(depth: 0, marker: .bullet, task: nil, text: "Architecture"),
                ]),
            ]
        )
    }

    func testNestedListsCarryDepthAndOrderedMarkersKeepTheirOrdinal() {
        let blocks = AgentMarkdown.parse(
            """
            1. Open the lens
               - inspect evidence
                 - deeper
            2) Close it
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .list([
                    AgentMarkdownListItem(depth: 0, marker: .ordered("1."), task: nil, text: "Open the lens"),
                    AgentMarkdownListItem(depth: 1, marker: .bullet, task: nil, text: "inspect evidence"),
                    AgentMarkdownListItem(depth: 2, marker: .bullet, task: nil, text: "deeper"),
                    AgentMarkdownListItem(depth: 0, marker: .ordered("2)"), task: nil, text: "Close it"),
                ]),
            ]
        )
    }

    func testEmphasisAtTheStartOfALineIsNotABulletMarker() {
        let blocks = AgentMarkdown.parse("**fast and terse** wins")

        XCTAssertEqual(blocks, [.paragraph("**fast and terse** wins")])
    }

    func testFencedCodeKeepsItsLanguageAndItsOwnBlankLines() {
        let blocks = AgentMarkdown.parse(
            """
            Run it:

            ```swift
            let lens = AgentLens()

            lens.open()
            ```

            Done.
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .paragraph("Run it:"),
                .code(language: "swift", source: "let lens = AgentLens()\n\nlens.open()"),
                .paragraph("Done."),
            ]
        )
    }

    func testAnUnterminatedFenceStillRendersAsCodeWhileStreaming() {
        let blocks = AgentMarkdown.parse("```sh\nswift test")

        XCTAssertEqual(blocks, [.code(language: "sh", source: "swift test")])
    }

    func testBlockquotesParseTheirOwnInnerBlocks() {
        let blocks = AgentMarkdown.parse(
            """
            > ## Note
            > - one
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .quote([
                    .heading(level: 2, text: "Note"),
                    .list([AgentMarkdownListItem(depth: 0, marker: .bullet, task: nil, text: "one")]),
                ]),
            ]
        )
    }

    func testThematicBreaksAreTheirOwnBlock() {
        let blocks = AgentMarkdown.parse("above\n\n---\n\nbelow")

        XCTAssertEqual(blocks, [.paragraph("above"), .rule, .paragraph("below")])
    }

    func testPipeTablesCarryHeaderAlignmentAndRows() {
        let blocks = AgentMarkdown.parse(
            """
            | Test | Result |
            |:-----|-------:|
            | lens | green  |
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .table(
                    AgentMarkdownTable(
                        header: ["Test", "Result"],
                        columns: [.leading, .trailing],
                        rows: [["lens", "green"]]
                    )
                ),
            ]
        )
    }

    func testATableRightAfterProseIsNotSwallowedByTheParagraph() {
        let blocks = AgentMarkdown.parse(
            """
            Results:
            | a | b |
            | - | - |
            | 1 | 2 |
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .paragraph("Results:"),
                .table(
                    AgentMarkdownTable(
                        header: ["a", "b"],
                        columns: [.leading, .leading],
                        rows: [["1", "2"]]
                    )
                ),
            ]
        )
    }

    func testInlineEmphasisBecomesAttributesInsteadOfLiteralPunctuation() {
        let attributed = AgentMarkdownInline.attributed(
            "What coding style do you prefer: **fast and terse**, or `detailed`?"
        )

        XCTAssertEqual(
            String(attributed.characters),
            "What coding style do you prefer: fast and terse, or detailed?"
        )

        let bolded = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(bolded, "strong emphasis must survive as an attribute")

        let monospaced = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true && run.font != nil
        }
        XCTAssertTrue(monospaced, "inline code must carry a monospaced font")
    }

    func testUnparseableInlineSourceFallsBackToItsOwnCharacters() {
        let source = "unterminated [link( and a stray * star"
        let attributed = AgentMarkdownInline.attributed(source)

        XCTAssertTrue(String(attributed.characters).contains("stray"))
    }

    func testTheScreenshotTranscriptRendersAsStructureNotPunctuation() {
        let blocks = AgentMarkdown.parse(
            """
            The questionnaire tool only supports single-select choices, not multi-select. We can
            simulate it here:

            Which topics interest you? Select any:

            - [ ] SwiftUI
            - [ ] Plugin development
            - [ ] Architecture
            """
        )

        guard case .list(let items) = blocks.last else {
            return XCTFail("expected the trailing task list, got \(String(describing: blocks.last))")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.task), [.unchecked, .unchecked, .unchecked])
        XCTAssertEqual(items.map(\.text), ["SwiftUI", "Plugin development", "Architecture"])
    }
}
