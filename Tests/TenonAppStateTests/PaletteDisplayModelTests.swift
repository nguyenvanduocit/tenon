import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// The palette overlay's one flattened order (T-006 phase 4 + 5b): static ranked rows
/// first, provider sections appended below, selection indexing that skips the
/// non-selectable header/pending rows, and the ⌘K submenu sourced from the selected
/// dynamic result's declared actions.
final class PaletteDisplayModelTests: XCTestCase {
    func testStaticRowsComeFirstAndProviderSectionsAppendBelow() throws {
        let display = PaletteDisplay(
            matches: [match("a.one.v1", "One"), match("a.two.v1", "Two")],
            sections: [
                try section(
                    providerID: "files",
                    title: "Files",
                    results: [try result("r1", "Result 1")]
                ),
            ]
        )
        XCTAssertEqual(
            display.rows.map(\.id),
            [
                "command.a.one.v1",
                "command.a.two.v1",
                "header.dev.test.palette#files",
                "result.dev.test.palette.r1",
            ]
        )
    }

    func testAQuietSectionContributesNothingAndAPendingOneShowsOneMarker() throws {
        let display = PaletteDisplay(
            matches: [match("a.one.v1", "One")],
            sections: [
                try section(providerID: "quiet", title: "Quiet", results: []),
                try section(
                    providerID: "busy",
                    title: "Busy",
                    isPending: true,
                    results: []
                ),
            ]
        )
        XCTAssertEqual(
            display.rows.map(\.id),
            [
                "command.a.one.v1",
                "header.dev.test.palette#busy",
                "pending.dev.test.palette#busy",
            ]
        )
    }

    func testSelectionSkipsHeadersAndPendingRows() throws {
        let display = PaletteDisplay(
            matches: [match("a.one.v1", "One")],
            sections: [
                try section(
                    providerID: "busy",
                    title: "Busy",
                    isPending: true,
                    results: []
                ),
                try section(
                    providerID: "files",
                    title: "Files",
                    results: [try result("r1", "Result 1")]
                ),
            ]
        )
        XCTAssertEqual(display.selectableCount, 2)
        XCTAssertEqual(display.selectableRow(at: 0)?.id, "command.a.one.v1")
        XCTAssertEqual(
            display.selectableRow(at: 1)?.id,
            "result.dev.test.palette.r1"
        )
        XCTAssertNil(display.selectableRow(at: 2))
    }

    func testCommandKActionsComeFromTheSelectedDynamicResultOnly() throws {
        let armed = try result(
            "r1",
            "Result 1",
            actions: [
                PaletteResultAction(
                    title: "Reveal",
                    intentID: try IntentID("dev.test.palette.reveal.v1"),
                    input: .object([:])
                ),
            ]
        )
        let display = PaletteDisplay(
            matches: [match("a.one.v1", "One")],
            sections: [
                try section(
                    providerID: "files",
                    title: "Files",
                    results: [armed]
                ),
            ]
        )
        XCTAssertEqual(display.actions(forSelection: 0), [])
        XCTAssertEqual(
            display.actions(forSelection: 1).map(\.title),
            ["Reveal"]
        )
        XCTAssertEqual(display.actions(forSelection: 9), [])
    }

    private func match(_ id: String, _ title: String) -> CommandMatch {
        CommandMatch(
            command: Command(id: id, title: title),
            score: 0,
            titleMatch: []
        )
    }

    private func result(
        _ id: String,
        _ title: String,
        actions: [PaletteResultAction] = []
    ) throws -> PaletteResultItem {
        PaletteResultItem(
            id: id,
            title: title,
            intentID: try IntentID("dev.test.palette.open.v1"),
            actions: actions
        )
    }

    private func section(
        providerID: String,
        title: String,
        isPending: Bool = false,
        results: [PaletteResultItem]
    ) throws -> PaletteProviderSection {
        PaletteProviderSection(
            pluginID: "dev.test.palette",
            providerID: providerID,
            title: title,
            isPending: isPending,
            results: results
        )
    }
}
