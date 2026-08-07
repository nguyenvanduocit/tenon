import XCTest
@testable import TenonCore

final class PaneTargetTests: XCTestCase {
    func testExplicitTerminalResolves() {
        let store = WorkspaceStore()
        let active = store.catalog.activeSlotID!
        XCTAssertEqual(PaneTarget.resolve(explicit: active, in: store.catalog, requireTerminal: true), .resolved(active))
    }

    func testUnknownExplicitPaneNotFound() {
        let store = WorkspaceStore()
        let bogus = UUID()
        XCTAssertEqual(PaneTarget.resolve(explicit: bogus, in: store.catalog, requireTerminal: true), .paneNotFound(bogus))
    }

    func testNonTerminalRejectedWhenTerminalRequired() {
        let store = WorkspaceStore()
        let active = store.catalog.activeSlotID!
        store.setSlotContent(
            active,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        XCTAssertEqual(PaneTarget.resolve(explicit: active, in: store.catalog, requireTerminal: true), .notATerminal(active))
    }

    func testNonTerminalAllowedWhenTerminalNotRequired() {
        let store = WorkspaceStore()
        let active = store.catalog.activeSlotID!
        store.setSlotContent(
            active,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        XCTAssertEqual(PaneTarget.resolve(explicit: active, in: store.catalog, requireTerminal: false), .resolved(active))
    }

    func testNilExplicitFallsBackToActiveSlot() {
        let store = WorkspaceStore()
        let active = store.catalog.activeSlotID!
        XCTAssertEqual(PaneTarget.resolve(explicit: nil, in: store.catalog, requireTerminal: true), .resolved(active))
    }

    // MARK: - preferredTerminal (where `terminal.run.v1` lands)

    func testPreferredTerminalIsTheActiveSlotWhenItIsATerminal() {
        let store = WorkspaceStore()
        let active = store.catalog.activeSlotID!
        XCTAssertEqual(PaneTarget.preferredTerminal(in: store.catalog), active)
    }

    /// The case that matters: a plugin's button is clicked, so the plugin's own panel is the
    /// active pane. Its command still belongs in the terminal sitting next to it.
    func testPreferredTerminalFallsBackToTheTabsTerminalWhenAPanelIsActive() {
        let store = WorkspaceStore()
        let terminal = store.catalog.activeSlotID!
        store.splitActiveSlot(.horizontal)
        let panel = store.catalog.activeSlotID!
        XCTAssertNotEqual(panel, terminal)
        store.setSlotContent(
            panel,
            .pluginView(pluginID: "dev.tenon.claude-sessions", viewID: "sessions")
        )

        XCTAssertEqual(PaneTarget.preferredTerminal(in: store.catalog), terminal)
    }

    func testPreferredTerminalIsNilWhenTheWorkspaceHasNoTerminalAtAll() {
        let store = WorkspaceStore()
        let only = store.catalog.activeSlotID!
        store.setSlotContent(
            only,
            .pluginView(pluginID: "dev.tenon.claude-sessions", viewID: "sessions")
        )

        XCTAssertNil(PaneTarget.preferredTerminal(in: store.catalog),
                     "with no terminal anywhere the shell has to open one")
    }

    /// Opening the panel from the palette puts it in its OWN tab, so the terminal the user is
    /// working in lives one tab over. Reuse it — focusing it switches tabs, so the command
    /// still runs in front of them — instead of spawning a second shell next to an idle one.
    func testPreferredTerminalReusesATerminalInAnotherTabOfTheWorkspace() {
        let store = WorkspaceStore()
        let terminal = store.catalog.activeSlotID!
        store.newTab(
            content: .pluginView(
                pluginID: "dev.tenon.claude-sessions",
                viewID: "sessions"
            )
        )
        XCTAssertNotEqual(store.catalog.activeSlotID, terminal, "the panel opened in its own tab")

        XCTAssertEqual(PaneTarget.preferredTerminal(in: store.catalog), terminal)
    }

    /// …but only after the active tab's own terminal, which is nearer.
    func testPreferredTerminalPrefersTheActiveTabOverOtherTabs() {
        let store = WorkspaceStore()
        let farTerminal = store.catalog.activeSlotID!
        store.newTab(
            content: .pluginView(
                pluginID: "dev.tenon.claude-sessions",
                viewID: "sessions"
            )
        )
        let panel = store.catalog.activeSlotID!
        store.splitActiveSlot(.horizontal)
        let nearTerminal = store.catalog.activeSlotID!
        store.setSlotContent(nearTerminal, .terminal)
        store.focusSlot(panel)

        XCTAssertNotEqual(nearTerminal, farTerminal)
        XCTAssertEqual(PaneTarget.preferredTerminal(in: store.catalog), nearTerminal)
    }
}
