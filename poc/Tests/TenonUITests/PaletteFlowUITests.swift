import XCTest

/// Black-box proof that the command palette actually works in the running app — the
/// part `TenonCoreTests` can't reach (`docs/tdd.md`: "can this rule be asserted without
/// a window?" — no). These three assertions close the GUI risks the headless suite
/// leaves open: that ⌘⇧P opens the palette *despite the terminal grabbing keys first*,
/// that keyboard focus lands in the search field, and that a typed query filters to a
/// real command row. It drives Tenon.app through the Accessibility tree, so it needs no
/// osascript/Accessibility grant.
final class PaletteFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The source plugins dir, so the bundled `core-commands` is guaranteed loaded even
    /// if a prior run left a stale seeded copy in Application Support.
    private static var sourcePluginsDir: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TenonUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // poc
            .appendingPathComponent("plugins")
            .path
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TENON_STUB_TERMINAL"] = "1"
        app.launchEnvironment["TENON_PLUGINS_DIR"] = Self.sourcePluginsDir
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    private var canvas: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tenon.canvas").firstMatch
    }

    private var search: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tenon.palette.search").firstMatch
    }

    /// ⌘⇧P opens the palette even though a terminal surface has first responder — the
    /// whole reason the chord is ⌘⇧P and not ⌘K.
    func testCommandShiftPOpensThePalette() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "app never launched")
        XCTAssertFalse(search.exists, "palette should start closed")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(search.waitForExistence(timeout: 5),
                      "⌘⇧P did not open the palette — the search field never appeared")
    }

    /// The search field is focused on open, so a typed query reaches it and filters the
    /// list down to a real bundled command (core-commands' Split Right).
    func testTypingFiltersToABundledCommandRow() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        app.typeText("split")

        let splitRight = app.descendants(matching: .any)
            .matching(identifier: "tenon.palette.row.core-commands.split-right").firstMatch
        XCTAssertTrue(splitRight.waitForExistence(timeout: 5),
                      "typing 'split' did not surface the Split Right row — focus or ranking is broken")
    }

    /// Esc dismisses the palette.
    func testEscapeClosesThePalette() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(waitForDisappearance(of: search, timeout: 5),
                      "Esc did not close the palette")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return !element.exists
    }
}
