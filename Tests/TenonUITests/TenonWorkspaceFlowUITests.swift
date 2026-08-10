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
@MainActor
final class TenonWorkspaceFlowUITests: XCTestCase {

    /// Stable identifiers the shell must publish. Mirrors Tests/TenonUITests/README.md —
    /// keep the two in sync; this struct is the machine-readable half of that contract.
    private enum A11y {
        static let tab = "tenon.tab"          // one per tab chip in the tab bar
        static let newTab = "tenon.newTab"    // the "+" launcher button in the tab bar
        static let launcher = "tenon.launcher"
        static let launcherSearch = "tenon.launcher.search"
        static let launcherCopyTabID = "tenon.launcher.copyTabID"
        static let launcherRow = "tenon.launcher.row."  // + one command ID, per launcher entry
        static let canvas = "tenon.canvas"    // the active tab's spatial canvas
        static let slot = "tenon.slot"        // one per slot rendered on the canvas
    }

    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Stub terminal: no PTY / libghostty process, so the plugin+workspace loop is the
        // only thing under test and launches are deterministic on any machine and in CI.
        app.launchEnvironment["TENON_STUB_TERMINAL"] = "1"
        // A prior test terminates the one-window scene. Ignore that saved closure so each
        // black-box test starts with the workspace window the same way a fresh launch does.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
        try await super.tearDown()
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

    /// Right-clicking a tab opens the same searchable LauncherMenu popover as the `+`
    /// button, without first showing an "Open Something New…" native-menu item.
    func testTabRightClickOpensTheLauncherPopoverDirectly() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let firstTab = app.descendants(matching: .any)
            .matching(identifier: A11y.tab)
            .firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: 5), "tab chip missing")

        firstTab.rightClick()

        let launcher = app.descendants(matching: .any)
            .matching(identifier: A11y.launcher)
            .firstMatch
        XCTAssertTrue(
            launcher.waitForExistence(timeout: 5),
            "tab right-click did not open LauncherMenu directly"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: A11y.launcherSearch)
                .firstMatch
                .exists,
            "tab right-click opened a native menu instead of the searchable launcher popover"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: A11y.launcherCopyTabID)
                .firstMatch
                .exists,
            "tab launcher dropped the tab-scoped Copy Tab ID action"
        )

        let newTabRow = app.descendants(matching: .any)
            .matching(identifier: A11y.launcherRow + "dev.tenon.core-commands.tab.new.v1")
            .firstMatch
        XCTAssertTrue(newTabRow.waitForExistence(timeout: 5), "launcher New Tab row missing")
        newTabRow.click()
        XCTAssertTrue(
            waitFor { self.tabCount == 2 },
            "the tab-scoped launcher choice did not run"
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

    /// The hidden-titlebar window must not treat the tab chip as draggable background.
    /// Releasing over the last chip moves the first tab there while the window stays put.
    ///
    /// Read its green with care. This test passed against a mechanism a person's hands then
    /// falsified twice (T-101), so it does not discriminate the failure it appears to cover:
    /// the window server takes a title-bar press from a drag region AppKit uploads in advance,
    /// and nothing here observes that region. What does: `TabStripReorderTests` pins the
    /// `NSControl` superclass that keeps the chips out of it, and
    /// `swift scripts/drag-region-probe.swift` re-measures the rule itself.
    func testDraggingATabReordersItWithoutMovingTheWindow() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertTrue(openNewTabFromLauncher(), "launcher did not create the second tab")
        XCTAssertTrue(openNewTabFromLauncher(), "launcher did not create the third tab")
        XCTAssertTrue(
            waitForTabFramesToSettle(),
            "tab frames did not settle before the reorder gesture"
        )

        let tabs = tabElements
        let expectedCount = tabs.count
        let source = tabs.element(boundBy: 0)
        let target = tabs.element(boundBy: expectedCount - 1)
        XCTAssertTrue(source.exists && target.exists)

        // Stub fallback labels are positional ("Terminal 1", "Terminal 2", …), so give
        // the source tab a title that follows its identity before asserting where it lands.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let titleButton = app.buttons["Simulate title change"].firstMatch
        XCTAssertTrue(titleButton.waitForExistence(timeout: 5), "source tab never became active")
        titleButton.click()
        XCTAssertTrue(
            waitFor { self.tabElements.element(boundBy: 0).label == "stub-title-1" },
            "stub did not publish the source tab's stable title"
        )
        let sourceLabel = tabElements.element(boundBy: 0).label
        let windowFrame = app.windows.firstMatch.frame
        let grab = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let drop = target.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        grab.press(forDuration: 0.2, thenDragTo: drop)

        XCTAssertTrue(
            waitFor {
                let reordered = self.tabElements.allElementsBoundByIndex
                return reordered.count == expectedCount && reordered.last?.label == sourceLabel
            },
            "dragging the first tab over the last one did not reorder the strip"
        )
        XCTAssertEqual(
            app.windows.firstMatch.frame,
            windowFrame,
            "dragging a tab moved the whole window instead of reordering the strip"
        )
    }

    /// Taking the chips out of the window's drag region must not take the rest of the bar with
    /// them. A drag past the tab strip still moves the window like system chrome — which is
    /// exactly what `window.isMovable = false` would have cost, measured to empty the region
    /// including this zone.
    func testDraggingTheEmptyTitleBarStillMovesTheWindow() {
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        let frameBefore = window.frame
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frameBefore.width * 0.65, dy: 18))
        let end = start.withOffset(CGVector(dx: 80, dy: 40))

        start.press(forDuration: 0.2, thenDragTo: end)

        XCTAssertTrue(
            waitFor { window.frame.origin != frameBefore.origin },
            "the explicit empty-titlebar WindowDragArea no longer moves the window"
        )
    }

    // MARK: - Queries

    private var canvas: XCUIElement {
        app.descendants(matching: .any).matching(identifier: A11y.canvas).firstMatch
    }

    private var tabCount: Int {
        tabElements.count
    }

    private var tabElements: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: A11y.tab)
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

    /// Wait for the manifest-backed New Tab contribution before invoking it. The canvas can
    /// appear a moment before plugin loading completes, so typing Command-T immediately would
    /// make this gesture test depend on startup timing instead of tab drag behavior.
    private func openNewTabFromLauncher() -> Bool {
        let countBefore = tabCount
        let plus = app.descendants(matching: .any)
            .matching(identifier: A11y.newTab)
            .firstMatch
        guard plus.waitForExistence(timeout: 5) else { return false }
        plus.click()

        let row = app.descendants(matching: .any)
            .matching(identifier: A11y.launcherRow + "dev.tenon.core-commands.tab.new.v1")
            .firstMatch
        guard row.waitForExistence(timeout: 8) else { return false }
        row.click()
        return waitFor { self.tabCount == countBefore + 1 }
    }

    /// Accessibility can publish a newly inserted tab one render pass before the strip's
    /// geometry reporters finish laying out every chip. Wait for identical non-empty frames
    /// across consecutive polls so this test starts at the same settled state as a person's
    /// pointer drag instead of racing the two launcher dismissals above it.
    private func waitForTabFramesToSettle(timeout: TimeInterval = 3) -> Bool {
        let expectedCount = tabCount
        var previous: [CGRect]?
        var consecutiveMatches = 0
        return waitFor(timeout: timeout) {
            let frames = self.tabElements.allElementsBoundByIndex.map(\.frame)
            guard frames.count == expectedCount,
                  frames.allSatisfy({ $0.width > 0 && $0.height > 0 })
            else {
                previous = nil
                consecutiveMatches = 0
                return false
            }
            if frames == previous {
                consecutiveMatches += 1
            } else {
                previous = frames
                consecutiveMatches = 0
            }
            return consecutiveMatches >= 2
        }
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
