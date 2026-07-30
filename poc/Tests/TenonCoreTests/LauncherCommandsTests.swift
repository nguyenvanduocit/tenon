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
            from: Data(#"{"category": "New", "icon": "terminal", "launcher": true}"#.utf8)
        )
        XCTAssertTrue(declared.launcher)
    }

    /// Omitting the flag must keep an intent out of the launcher: a palette command is
    /// not a creation verb by default, or "Close Pane" would offer itself under a `+`.
    func testPaletteDeclarationWithoutTheFlagIsNotALauncherEntry() throws {
        let declared = try JSONDecoder().decode(
            PluginPalettePresentation.self,
            from: Data(#"{"category": "Git"}"#.utf8)
        )
        XCTAssertFalse(declared.launcher)
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

    // MARK: - Shipped plugins

    /// The regression that matters for the title bar: the launcher must still offer
    /// everything the removed "Add slot" menu did — Terminal, Files, Diff, Docs,
    /// Browser — plus the split verbs that menu never had.
    func testShippedLauncherOffersEverythingTheAddSlotMenuDid() throws {
        let launchers = try shippedLauncherIntentIDs()

        for expected in [
            "dev.tenon.core-commands.terminal.new.v1",   // Terminal
            "dev.tenon.file-explorer.open.v1",           // Files
            "dev.tenon.core-commands.changes.open.v1",   // Diff
            "dev.tenon.core-commands.docs.open.v1",      // Docs
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
            "dev.tenon.core-commands.pane.close.v1",
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

    private func shippedLauncherIntentIDs() throws -> Set<String> {
        var ids: Set<String> = []
        for directory in try PluginLoader.discover(in: Self.pluginsRoot) {
            let manifest = try PluginLoader.loadManifest(at: directory)
            for provision in manifest.intents.provides where provision.palette?.launcher == true {
                ids.insert(provision.name.rawValue)
            }
        }
        return ids
    }
}
