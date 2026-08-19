import XCTest

@testable import TenonApp
@testable import TenonCore

/// What the shell's two chrome rows measure, and the source-level rules that keep the swap
/// honest. No window is mounted here — these are the parts of the change a headless assertion
/// can genuinely settle.
final class ShellChromeLayoutTests: XCTestCase {
    // MARK: - The foot row's height

    func testTheFootIsAsTallAsTheStripItHolds() {
        XCTAssertEqual(TenonTheme.footHeight(for: .status), 24, "the status strip's own row")
        XCTAssertEqual(
            TenonTheme.footHeight(for: .tabs),
            34,
            "a 26-pt chip needs a taller row than 8-pt status text does"
        )
    }

    /// The foot row and the sidebar footer sit side by side across the bottom of the window,
    /// each under its own 1-pt rule. Different heights would draw those two rules as a kink.
    func testTheFootTabRowRuleLinesUpWithTheSidebarFooterRule() {
        XCTAssertEqual(
            TenonTheme.footHeight(for: .tabs),
            SidebarFooterLayout.height,
            "the content column's rule and the sidebar footer's rule must be collinear"
        )
    }

    /// Stated so the cost is a number somebody chose rather than one that turned up: putting
    /// the tabs at the foot spends ten more points of window on chrome, because the title bar
    /// stays 36 pt for the traffic lights while the foot grows from 24 to 34.
    func testTabsOnBottomSpendsTenMorePointsOnChromeThanTabsOnTop() {
        func chrome(_ order: ShellChromeOrder) -> CGFloat {
            TenonTheme.titleBarHeight + 1 + 1 + TenonTheme.footHeight(for: order.footStrip)
        }

        XCTAssertEqual(chrome(.tabsOnBottom) - chrome(.tabsOnTop), 10)
    }

    /// A chip drawn flush to the window's bottom loses its lowest rows of pixels to the
    /// resize gutter, which hit-tests to `NSThemeFrame` rather than to any app view. The
    /// margin is small enough to be worth an assertion that says so out loud.
    func testAChipCentredInTheFootRowClearsTheWindowsResizeGutter() {
        let chipHeight: CGFloat = 26
        let clearance = (TenonTheme.footHeight(for: .tabs) - chipHeight) / 2

        XCTAssertGreaterThan(
            clearance,
            3,
            "the measured gutter is about 3 pt; scripts/internal/foot-strip-edge-probe.swift "
                + "is what confirms it on a real window"
        )
    }

    // MARK: - One implementation, wherever the strip is drawn

    /// Criterion 8 of T-177, and the only assertion that can enforce it: the strip is one
    /// view mounted in two rows, never two views that happen to agree today.
    func testExactlyOneSourceFileDrawsTheTabStrip() throws {
        let drawers = try Self.appSources()
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("TabStripSurface(") }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            drawers,
            ["ShellTabStrip.swift"],
            "a second file drawing the strip is a second thing to keep in step; the strip "
                + "takes its row's edge as a parameter instead"
        )
    }

    /// …and exactly one file decides which of the two strips a row is holding. Both chrome
    /// rows and every offscreen renderer go through it, so a renderer cannot photograph a
    /// row the shell would not actually draw.
    func testExactlyOneSourceFileChoosesBetweenTheTwoStrips() throws {
        let choosers = try Self.appSources()
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("ShellTabStrip(") }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(choosers, ["ShellChromeOccupant.swift"])
    }

    /// The window-server drag belongs to the title bar and to nothing else. A foot row that
    /// asked for it would move the window from the bottom edge and would run a double-click
    /// handler that reads a System Settings key about title bars.
    func testOnlyTheTitleBarRowAsksForAWindowDrag() throws {
        let source = try Self.appSource("ShellFootBar.swift")

        XCTAssertFalse(
            source.contains("WindowDragArea("),
            "the foot row is not the title-bar band and must not behave as if it were"
        )
    }

    /// The status strip is a closed plugin-contribution surface. Moving it into the title bar
    /// puts it beside host controls, and the promise is that it never contains one.
    func testTheContributedStatusStripHoldsNoHostControl() throws {
        let source = try Self.appSource("WorkspaceStatusBar.swift")

        XCTAssertFalse(source.contains("ResourceMonitorButton"))
        XCTAssertFalse(source.contains("QuickCommandControl"))
    }

    // MARK: - Reading the tree

    private static func appSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TenonAppStateTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/TenonApp")
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (all?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func appSource(_ name: String) throws -> String {
        let match = try XCTUnwrap(
            try appSources().first { $0.lastPathComponent == name },
            "Sources/TenonApp/\(name) is missing"
        )
        return try String(contentsOf: match, encoding: .utf8)
    }
}
