import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// The `+` launcher menu is a projection, not a list. What it offers is declared by
/// plugins in `manifest.json` (`palette.launcher`) and reaches the shell through the
/// same `CommandIndex` the palette ranks — so adding an entry is a manifest change,
/// never a Swift change. These tests hold that boundary headlessly.
final class LauncherCommandsTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    // MARK: - Manifest

    func testPaletteDeclarationCarriesTheLauncherFlag() throws {
        let declared = try JSONDecoder().decode(
            PluginPalettePresentation.self,
            from: Data(#"{"category": "New", "icon": "terminal", "launcher": true, "fillsPane": true}"#.utf8)
        )
        XCTAssertTrue(declared.launcher)
        XCTAssertTrue(declared.fillsPane)
    }

    /// Omitting the flag must keep an intent out of the launcher: a palette command is
    /// not a creation verb by default, or "Close Pane" would offer itself under a `+`.
    func testPaletteDeclarationWithoutTheFlagIsNotALauncherEntry() throws {
        let declared = try JSONDecoder().decode(
            PluginPalettePresentation.self,
            from: Data(#"{"category": "Git"}"#.utf8)
        )
        XCTAssertFalse(declared.launcher)
        XCTAssertFalse(declared.fillsPane)
    }

    // MARK: - Projection

    func testLauncherOnlyKeepsTheDeclaredCreationVerbsAndRanksThemUnchanged() {
        let index = CommandIndex([
            Command(id: "new-terminal", title: "New Terminal", isLauncher: true),
            Command(id: "close-pane", title: "Close Pane"),
            Command(id: "open-browser", title: "Open Browser", isLauncher: true),
        ])

        let launcher = index.launcherOnly
        XCTAssertEqual(launcher.commands.map(\.id).sorted(), ["new-terminal", "open-browser"])

        // Ranking is the palette's, unchanged — the filter is the only difference.
        let ranked = launcher.rank(query: "term", frecency: Frecency(), now: Date())
        XCTAssertEqual(ranked.map(\.command.id), ["new-terminal"])
    }

    func testPaneFillersKeepOnlyLauncherCommandsThatCanOccupyATargetSlot() {
        let index = CommandIndex([
            Command(
                id: "new-terminal",
                title: "New Terminal",
                isLauncher: true,
                fillsPane: true
            ),
            Command(id: "new-tab", title: "New Tab", isLauncher: true),
            Command(id: "split-right", title: "Split Right", isLauncher: true),
            Command(id: "close-pane", title: "Close Pane", fillsPane: true),
        ])

        XCTAssertEqual(index.paneFillersOnly.commands.map(\.id), ["new-terminal"])
    }

    // MARK: - Shipped plugins

    /// The regression that matters for the title bar: the launcher must still offer
    /// everything the removed "Add slot" menu did — Terminal, Files, Diff,
    /// Automation, Browser — plus the split verbs that menu never had.
    func testShippedLauncherOffersEverythingTheAddSlotMenuDid() throws {
        let launchers = try shippedLauncherIntentIDs()

        for expected in [
            "dev.tenon.core-commands.terminal.new.v1",   // Terminal
            "dev.tenon.file-explorer.open.v1",           // Files
            "dev.tenon.core-commands.changes.open.v1",   // Diff
            "dev.tenon.core-commands.automation.open.v1", // Automation
            "dev.tenon.browser.open.v1",                 // Browser
            "dev.tenon.core-commands.tab.new.v1",
            "dev.tenon.core-commands.pane.split-right.v1",
            "dev.tenon.core-commands.pane.split-down.v1",
        ] {
            XCTAssertTrue(
                launchers.contains(expected),
                "\(expected) must be declared as a launcher entry"
            )
        }
    }

    /// A `+` menu is for opening things. Destructive and navigational verbs stay in the
    /// palette where they belong.
    func testShippedLauncherExcludesDestructiveAndNavigationVerbs() throws {
        let launchers = try shippedLauncherIntentIDs()

        for excluded in [
            "dev.tenon.core-commands.pane.close.v2",
            "dev.tenon.core-commands.tab.next.v1",
            "dev.tenon.core-commands.tab.previous.v1",
            "dev.tenon.core-commands.pane.focus-next.v1",
            "dev.tenon.core-commands.workspace.switch.v1",
            "dev.tenon.git.push.v1",
        ] {
            XCTAssertFalse(
                launchers.contains(excluded),
                "\(excluded) must not appear under the + button"
            )
        }
    }

    func testShippedPaneFillersExcludeTabAndSplitStructureCommands() throws {
        let fillers = try shippedPaneFillerIntentIDs()

        for expected in [
            "dev.tenon.core-commands.terminal.new.v1",
            "dev.tenon.core-commands.changes.open.v1",
            "dev.tenon.core-commands.automation.open.v1",
            "dev.tenon.file-explorer.open.v1",
            "dev.tenon.browser.open.v1",
            "dev.tenon.kanban.open.v1",
            "dev.tenon.claude-sessions.open.v1",
        ] {
            XCTAssertTrue(fillers.contains(expected), "\(expected) must fill an empty grid target")
        }

        for excluded in [
            "dev.tenon.core-commands.tab.new.v1",
            "dev.tenon.core-commands.pane.split-right.v1",
            "dev.tenon.core-commands.pane.split-down.v1",
        ] {
            XCTAssertFalse(fillers.contains(excluded), "\(excluded) cannot fill an empty grid target")
        }
    }

    private func shippedLauncherIntentIDs() throws -> Set<String> {
        var ids: Set<String> = []
        for directory in PluginLoader.discover(in: Self.pluginsRoot) {
            let manifest = try PluginLoader.loadManifest(at: directory)
            for provision in manifest.intents.provides where provision.palette?.launcher == true {
                ids.insert(provision.name.rawValue)
            }
        }
        return ids
    }

    private func shippedPaneFillerIntentIDs() throws -> Set<String> {
        var ids: Set<String> = []
        for directory in PluginLoader.discover(in: Self.pluginsRoot) {
            let manifest = try PluginLoader.loadManifest(at: directory)
            for provision in manifest.intents.provides where provision.palette?.fillsPane == true {
                ids.insert(provision.name.rawValue)
            }
        }
        return ids
    }
}
