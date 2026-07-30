import XCTest
@testable import TenonCore

final class KeyChordTests: XCTestCase {
    func testTextAndGlyphAliasesNormalizeToOneChord() throws {
        let expected = KeyChord(
            modifiers: [.command, .shift],
            key: .character("p")
        )

        XCTAssertEqual(try KeyChord(parsing: "cmd+shift+p"), expected)
        XCTAssertEqual(try KeyChord(parsing: "shift+command+P"), expected)
        XCTAssertEqual(try KeyChord(parsing: "⌘⇧P"), expected)
        XCTAssertEqual(expected.display, "⇧⌘P")
    }

    func testSupportedPrintableAndFunctionKeysHaveCanonicalDisplay() throws {
        XCTAssertEqual(
            try KeyChord(parsing: "ctrl+alt+k").display,
            "⌃⌥K"
        )
        XCTAssertEqual(try KeyChord(parsing: "cmd+1").display, "⌘1")
        XCTAssertEqual(try KeyChord(parsing: "cmd+]").display, "⌘]")
        XCTAssertEqual(try KeyChord(parsing: "f5").display, "F5")
        XCTAssertEqual(try KeyChord(parsing: "cmd+f12").display, "⌘F12")
    }

    func testRejectsModifierOnlyMultipleUnknownAndBarePrintableKeys() {
        assertParseError("cmd+shift", equals: .modifierOnly)
        assertParseError("cmd+k+p", equals: .multipleKeys(["k", "p"]))
        assertParseError("cmd+hyper+k", equals: .unknownToken("hyper"))
        assertParseError("k", equals: .barePrintable("k"))
        assertParseError("]", equals: .barePrintable("]"))
        assertParseError(
            "cmd+command+k",
            equals: .duplicateModifier(.command)
        )
        assertParseError("f0", equals: .invalidFunctionKey("f0"))
        assertParseError("f36", equals: .invalidFunctionKey("f36"))
    }

    private func assertParseError(
        _ source: String,
        equals expected: KeyChord.ParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try KeyChord(parsing: source),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? KeyChord.ParseError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
