import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// The two fields that let ONE row list serve every indented list in the product: a muted
/// `detail` beside the label, and a tinted `accessory` at the trailing edge.
///
/// They are decoded from a plugin's `views.set` items, so they carry the same fail-soft rule
/// every other token field in that decoder carries: a mistake about a decoration costs the
/// decoration, never the row it was decorating. A dropped row is a file that vanished from a
/// list a human is using to decide what to look at — the one outcome this decoder may not have.
final class TreeRowItemTests: XCTestCase {
    private func row(_ fields: [String: IntentValue]) -> TreeRowItem? {
        var object: [String: IntentValue] = ["id": .string("a.swift"), "label": .string("a.swift")]
        object.merge(fields) { _, new in new }
        return PluginRuntimeValueParsing.rows(from: .array([.object(object)])).first
    }

    func testDetailAndAccessoryAreDecodedFromARow() throws {
        let decoded = try XCTUnwrap(row([
            "detail": .string("Sources/TenonApp"),
            "accessory": .object(["text": .string("M"), "tint": .string("amber")]),
        ]))

        XCTAssertEqual(decoded.detail, "Sources/TenonApp")
        XCTAssertEqual(decoded.accessory?.text, "M")
        XCTAssertEqual(decoded.accessory?.tint, .amber)
        XCTAssertEqual(decoded.kind, .row, "a row that says nothing about its kind IS a row")
    }

    func testSectionHeaderKindIsDecoded() throws {
        let decoded = try XCTUnwrap(row(["kind": .string("sectionHeader")]))
        XCTAssertEqual(decoded.kind, .sectionHeader)
    }

    /// A typo in an adjective costs the adjective. Dropping the row instead would take a file
    /// off the list because its author misspelled a heading.
    func testUnknownKindDegradesToARowRatherThanDroppingIt() throws {
        let decoded = try XCTUnwrap(row(["kind": .string("sectionheader")]))
        XCTAssertEqual(decoded.kind, .row)
        XCTAssertEqual(decoded.label, "a.swift")
    }

    func testUnknownAccessoryTintDegradesToTheDefault() throws {
        let decoded = try XCTUnwrap(row([
            "accessory": .object(["text": .string("M"), "tint": .string("chartreuse")]),
        ]))
        XCTAssertEqual(decoded.accessory?.tint, .default)
        XCTAssertEqual(decoded.accessory?.text, "M")
    }

    /// The accessory column is fixed-width by construction, so an accessory long enough to
    /// squeeze the file name is refused — and refused ALONE.
    func testOverlongAccessoryIsDroppedAndTheRowSurvives() throws {
        let tooLong = String(repeating: "X", count: RowAccessory.maximumTextLength + 1)
        let decoded = try XCTUnwrap(row([
            "accessory": .object(["text": .string(tooLong)]),
        ]))
        XCTAssertNil(decoded.accessory)
        XCTAssertEqual(decoded.label, "a.swift")
    }

    func testWhitespaceOnlyAccessoryIsDropped() throws {
        let decoded = try XCTUnwrap(row(["accessory": .object(["text": .string("   ")])]))
        XCTAssertNil(decoded.accessory)
    }

    func testAccessoryTextIsTrimmedRatherThanPaddingTheColumn() throws {
        let decoded = try XCTUnwrap(row(["accessory": .object(["text": .string("  M ")])]))
        XCTAssertEqual(decoded.accessory?.text, "M")
    }

    func testAnAccessoryWithNoTextIsAbsentRatherThanEmpty() throws {
        let decoded = try XCTUnwrap(row(["accessory": .object(["tint": .string("red")])]))
        XCTAssertNil(decoded.accessory)
    }

    /// The fields are additive: every row published before they existed decodes unchanged.
    func testARowThatUsesNeitherNewFieldIsUnchanged() throws {
        let decoded = try XCTUnwrap(row([
            "depth": .integer(2),
            "icon": .string("doc.text"),
            "path": .string("/tmp/a.swift"),
        ]))
        XCTAssertNil(decoded.detail)
        XCTAssertNil(decoded.accessory)
        XCTAssertEqual(decoded.kind, .row)
        XCTAssertEqual(decoded.depth, 2)
        XCTAssertEqual(decoded.icon, "doc.text")
        XCTAssertEqual(decoded.path, "/tmp/a.swift")
    }
}
