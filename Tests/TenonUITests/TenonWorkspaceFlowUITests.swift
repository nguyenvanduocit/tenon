import XCTest

/// Black-box end-to-end tests: they launch the real Tenon.app and drive it the way a
/// person would — keyboard shortcuts to create/split/close slots, and a pointer drag on
/// the spatial canvas to rearrange them — then assert against the Accessibility tree.
///
/// These are the *only* tests that exercise the gesture → core wiring that a headless
/// `TenonCoreTests` cannot reach (see docs/tdd.md: "can this rule be asserted without a
/// window?" — these are the ones where the answer is no). Everything about *what* a split
/// or a move does stays unit-tested in the core; these prove the shell is actually plugged
/// into it.
///
/// The shell publishes the identifier/value contract documented in
/// `Tests/TenonUITests/README.md`; these tests are part of the default Tenon scheme.
final class TenonWorkspaceFlowUITests: XCTestCase {

    /// Stable identifiers the shell must publish. Mirrors Tests/TenonUITests/README.md —
    /// keep the two in sync; this struct is the machine-readable half of that contract.
    private enum A11y {
        static let tab = "tenon.tab"          // one per tab chip in the tab bar
        static let newTab = "tenon.newTab"    // the "+" launcher button in the tab bar
        static let launcherRow = "tenon.launcher.row."  // + one command ID, per launcher entry
        static let canvas = "tenon.canvas"    // the active tab's spatial canvas
        static let slot = "tenon.slot"        // one per slot rendered on the canvas
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Stub terminal: no PTY / libghostty process, so the plugin+workspace loop is the
        // only thing under test and launches are deterministic on any machine and in CI.
        app.launchEnvironment["TENON_STUB_TERMINAL"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Smoke

    /// The window comes up on a canvas holding exactly the one seeded slot
    /// (WorkspaceCatalog() → 1 workspace → 1 tab → 1 slot).
    func testAppLaunchesShowingASingleSlotCanvas() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "canvas never appeared — app failed to launch or identifier missing")
        XCTAssertEqual(tabCount, 1)
        XCTAssertEqual(slotCount, 1)
    }

    // MARK: - Create

    /// ⌘T opens a second tab.
    func testNewTabShortcutOpensAnAdditionalTab() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertEqual(tabCount, 1)

        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(waitFor { self.tabCount == 2 }, "⌘T did not open a second tab (was \(tabCount))")
    }

    /// The "+" button opens the launcher, and picking "New Tab" from it is the
    /// mouse-driven path to a new tab. This proves the whole projection is live: the
    /// popover's rows come from `core-commands`' manifest, and clicking one invokes that
    /// plugin's intent — not a hardcoded shell action.
    func testPlusButtonLauncherOpensAnAdditionalTab() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let plus = app.descendants(matching: .any).matching(identifier: A11y.newTab).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "launcher button missing")

        plus.click()

        let newTabRow = app.descendants(matching: .any)
            .matching(identifier: A11y.launcherRow + "dev.tenon.core-commands.tab.new.v1")
            .firstMatch
        XCTAssertTrue(
            newTabRow.waitForExistence(timeout: 5),
            "launcher did not offer the plugin-declared New Tab entry"
        )
        newTabRow.click()

        XCTAssertTrue(
            waitFor { self.tabCount == 2 },
            "the launcher's New Tab did not open a second tab"
        )
    }

    // MARK: - Split

    /// ⌘D splits the active slot, so the active tab now holds two slots.
    func testSplitShortcutAddsASlotToTheActiveTab() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertEqual(slotCount, 1)

        app.typeKey("d", modifierFlags: .command)

        XCTAssertTrue(waitFor { self.slotCount == 2 }, "⌘D did not add a slot (was \(slotCount))")
    }

    /// ⌘D to split, then ⌘W to close the active slot — back to one.
    func testCloseSlotShortcutRemovesASlot() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.slotCount == 2 })

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(waitFor { self.slotCount == 1 }, "⌘W did not close the split slot")
    }

    // MARK: - Drag (the interaction the whole exercise is really about)

    /// Split into two slots, then drag one onto the other's region to rearrange the canvas.
    ///
    /// The spatial canvas uses a *custom pointer drag* (SpatialCanvasInteractionCoordinator:
    /// beginMove → update → finish), not SwiftUI's `.draggable`/`.dropDestination`. That is the
    /// lucky part: a plain mouse-down/move/up is far more reliably driven from XCUITest than a
    /// native drag session. We grab the moving slot near its top edge (hitRegion == .header, the
    /// only region that starts a move — corners/edges resize, body is inert) and press-drag it
    /// onto the target slot's centre.
    ///
    /// This is the flakiest test by nature; if it misbehaves, the usual fixes are (1) a longer
    /// press duration so the coordinator registers a move rather than a click, and (2) a couple
    /// of intermediate `.press(forDuration:thenDragTo:)` hops so the pointer path crosses the
    /// coordinator's move threshold.
    func testDraggingASlotOntoAnotherRearrangesTheCanvas() throws {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.slotCount == 2 }, "need two slots to drag one onto the other")

        let slots = slotElements
        let source = slots.element(boundBy: 0)
        let target = slots.element(boundBy: 1)
        XCTAssertTrue(source.exists && target.exists)

        // Record identity and geometry so we can assert the arrangement actually changed. Each
        // slot identifier carries its stable UUID and current grid rect; a move/swap changes the
        // rect encoded by the element at index 0. Identity rides the identifier because the
        // spoken value belongs to the person using VoiceOver.
        let identifierBefore = source.identifier

        let grab = source
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: source.frame.width / 2, dy: 10))
        let drop = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.6, thenDragTo: drop)

        XCTAssertTrue(
            waitFor { self.slotElements.element(boundBy: 0).identifier != identifierBefore },
            "dragging a slot onto another did not change the canvas arrangement"
        )
    }

    // MARK: - Queries

    private var canvas: XCUIElement {
        app.descendants(matching: .any).matching(identifier: A11y.canvas).firstMatch
    }

    private var tabCount: Int {
        app.descendants(matching: .any).matching(identifier: A11y.tab).count
    }

    private var slotCount: Int {
        slotElements.count
    }

    /// Slots carry their identity and grid rect in the identifier, so the query matches its
    /// prefix rather than the whole string.
    private var slotElements: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", A11y.slot)
        )
    }

    /// Poll a UI condition without a fixed sleep — XCUITest state settles asynchronously.
    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }
}
