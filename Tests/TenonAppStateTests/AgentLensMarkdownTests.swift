import AppKit
import Foundation
import Observation
import SwiftUI
@testable import TenonApp
import XCTest

final class AgentLensMarkdownTests: XCTestCase {
    @MainActor
    func testMarkdownReportsProseHeightOnItsFirstLayoutPass() {
        let host = NSHostingView(
            rootView: AgentMarkdownText(
                source: """
                This answer is still being parsed for markdown.
                Its work row can arrive during the same update.
                The answer must reserve these lines before that row is placed.
                """
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            host.fittingSize.height,
            40,
            """
            AgentMarkdownText reported no prose height before its detached parser returned, so \
            the lazy timeline could place a Running work row inside the answer's later text.
            """
        )
    }

    @MainActor
    func testStreamingGrowthReservesSpaceAheadOfTheRunningRow() {
        let model = MarkdownStreamingFixtureModel(source: "Short answer.")
        let host = NSHostingView(rootView: MarkdownStreamingFixture(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()
        let shortHeight = host.fittingSize.height

        model.source = (1 ... 10)
            .map { "Streaming line \($0) must sit above the running work row." }
            .joined(separator: "\n")
        host.rootView = MarkdownStreamingFixture(model: model)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            host.fittingSize.height,
            shortHeight + 100,
            """
            A new streaming source kept the old parsed row height, so the following Running \
            row could be placed inside the prose until the detached reparse completed.
            """
        )
    }

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

    /// Two ways a paragraph is nearly mistaken for structure: a single newline is a soft
    /// wrap and not a block break, and a line opening with `**` is emphasis and not a
    /// bullet. Both must come back as one paragraph carrying its own text verbatim.
    func testTextThatOnlyLooksLikeStructureStaysOneParagraph() {
        for source in ["first line\nsecond line", "**fast and terse** wins"] {
            XCTAssertEqual(
                AgentMarkdown.parse(source),
                [.paragraph(source)],
                source
            )
        }
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

@MainActor
@Observable
private final class MarkdownStreamingFixtureModel {
    var source: String

    init(source: String) {
        self.source = source
    }
}

private struct MarkdownStreamingFixture: View {
    let model: MarkdownStreamingFixtureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentMarkdownText(source: model.source)
            Text("RUNNING")
                .frame(height: 20)
        }
    }
}
