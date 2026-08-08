import XCTest
@testable import TenonApp
import TenonIntentCore

/// T-063. The render itself needs a real host and writes a file, so it is exercised by hand
/// (`docs/design-plugin-views.md` carries the command and its output). What a test can hold is
/// the parsing: a snapshot request is a string a person types, and every way of getting it
/// wrong should say so instead of booting a plugin host and failing halfway through.
final class PluginViewSnapshotTests: XCTestCase {
    func testARequestNamesAPluginAViewAndAFile() throws {
        let request = try XCTUnwrap(
            PluginViewSnapshot.Request("dev.tenon.kanban/board:/tmp/board.png")
        )
        XCTAssertEqual(request.pluginID, PluginID("dev.tenon.kanban"))
        XCTAssertEqual(request.viewID, "board")
        XCTAssertEqual(request.outputPath, "/tmp/board.png")
    }

    func testTheOutputPathMayContainAColon() throws {
        // Split on the LAST colon, so a path is not truncated at the first one it contains.
        let request = try XCTUnwrap(
            PluginViewSnapshot.Request("dev.tenon.kanban/board:/tmp/run:1/board.png")
        )
        XCTAssertEqual(request.outputPath, "/tmp/run:1/board.png")
        XCTAssertEqual(request.viewID, "board")
    }

    func testAnInvalidPluginIDIsRefusedAtParseTimeRatherThanAtRender() {
        // Not a dotted DNS name, so `PluginID` refuses it. Catching it here is what turns a
        // typo into a usage message instead of a half-booted host.
        XCTAssertNil(PluginViewSnapshot.Request("kanban/board:/tmp/board.png"))
    }

    func testAMalformedRequestIsRefused() {
        for raw in [
            "dev.tenon.kanban/board",            // no output path
            "dev.tenon.kanban:/tmp/board.png",   // no view id
            "/board:/tmp/board.png",             // no plugin id
            "dev.tenon.kanban/board:",           // empty output path
            "",
        ] {
            XCTAssertNil(PluginViewSnapshot.Request(raw), "accepted \(raw)")
        }
    }

    func testTheSizeOverrideTakesTwoPositiveNumbersAndNothingElse() {
        XCTAssertEqual(
            PluginViewSnapshot.size(from: "1400x900"),
            CGSize(width: 1_400, height: 900)
        )
        XCTAssertEqual(
            PluginViewSnapshot.size(from: "1400X900"),
            CGSize(width: 1_400, height: 900)
        )
        // A bad size falls back to the default rather than rendering a zero-sized pane.
        for raw in ["1400", "0x900", "-10x20", "widexhigh", "1400x900x2", ""] {
            XCTAssertNil(PluginViewSnapshot.size(from: raw), "accepted \(raw)")
        }
        XCTAssertNil(PluginViewSnapshot.size(from: nil))
    }
}
