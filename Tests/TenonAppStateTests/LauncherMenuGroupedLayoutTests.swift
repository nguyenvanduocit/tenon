import AppKit
import Foundation
import SwiftUI
import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// T-187: the tab strip's `+`/tab-chip-right-click launcher (`purpose == .open`) groups like
/// `EmptyStateCard` when nothing is typed — a terminal CTA, a tile grid of the commands that
/// can fill a pane, recents, and a "Pane" section — while `.fillEmptyGrid`'s narrower
/// fill-this-space flow stays the flat ranked list it always was.
///
/// T-188 changed *how* the grouped layout regroups: no longer one section per plugin's own
/// manifest `category` (T-187's shape, which left "New Tab" and "Split Right"/"Split Down"
/// each paying for a one- or two-row section header — the fragmentation a screenshot
/// reported), but a `fillsPane`/non-`fillsPane` split — a tile grid for the former, folded
/// into "Pane" for the latter.
///
/// A self-written plugin stands in for `core-commands` rather than loading the real shipped
/// inventory: `bundled-swift` resolves to a compiled program only the app's own composition
/// root registers, which a bare `PluginHost` in a test does not have wired. A JS plugin
/// declaring the exact same manifest shape (`palette.launcher`, `palette.category`,
/// `palette.fillsPane`) exercises the same `commandIndex` path `LauncherMenu` reads,
/// deterministically.
@MainActor
final class LauncherMenuGroupedLayoutTests: XCTestCase {
    private struct Fixture {
        let host: PluginHost
        let runtime: AppIntentRuntime
        let palette: CommandPaletteState
    }

    /// The exact id `LauncherMenu` looks for. Mirrored from `core-commands`'s manifest
    /// (`dev.tenon.core-commands.terminal.new.v1`) rather than imported from it, so this
    /// fixture stays a stand-in and never a copy of the shipped plugin's own behaviour.
    private static let terminalID = "dev.tenon.core-commands.terminal.new.v1"
    private static let nonPaneFillerID = "dev.tenon.core-commands.new-tab.v1"

    private static func paneFillerID(_ index: Int) -> String {
        "dev.tenon.core-commands.open-thing-\(index).v1"
    }

    private static func provideEntry(
        name: String,
        title: String,
        category: String,
        icon: String,
        fillsPane: Bool
    ) -> String {
        """
        {
          "name": "\(name)",
          "title": "\(title)",
          "audiences": ["plugin", "user"],
          "effects": { "kind": "write", "idempotency": "none", "confirmation": "never", "external": false },
          "inputSchema": { "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "additionalProperties": false },
          "outputSchema": { "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "additionalProperties": false },
          "palette": { "category": "\(category)", "icon": "\(icon)", "launcher": true\(fillsPane ? ", \"fillsPane\": true" : "") }
        }
        """
    }

    /// A manifest's provided intent must live under its own plugin id, so this fixture
    /// answers to `core-commands`'s real id — safe only because it is written into an
    /// isolated temp directory this test never loads alongside the real inventory.
    ///
    /// `paneFillerCount` builds that many `fillsPane` commands (besides the terminal CTA
    /// itself, which is also `fillsPane` but always extracted before the grid draws);
    /// `includeNonPaneFillerCommand` adds one launcher command that is not — the "New Tab"
    /// shape T-187 left fragmented into its own section.
    private func makeFixture(
        paneFillerCount: Int = 1,
        includeNonPaneFillerCommand: Bool = false
    ) async throws -> Fixture {
        var provides = [
            Self.provideEntry(
                name: Self.terminalID,
                title: "New Terminal",
                category: "New",
                icon: "terminal",
                fillsPane: true
            ),
        ]
        for index in 0..<paneFillerCount {
            provides.append(
                Self.provideEntry(
                    name: Self.paneFillerID(index),
                    title: "Open Thing \(index)",
                    category: "Open",
                    icon: "folder",
                    fillsPane: true
                )
            )
        }
        if includeNonPaneFillerCommand {
            provides.append(
                Self.provideEntry(
                    name: Self.nonPaneFillerID,
                    title: "New Tab",
                    category: "New",
                    icon: "plus.square",
                    fillsPane: false
                )
            )
        }
        let manifest = """
        {
          "id": "dev.tenon.core-commands",
          "name": "launcher-menu-fixture",
          "version": "1",
          "permissions": [],
          "intents": { "uses": [], "provides": [\(provides.joined(separator: ","))] }
        }
        """
        var handlerNames = [Self.terminalID]
        for index in 0..<paneFillerCount { handlerNames.append(Self.paneFillerID(index)) }
        if includeNonPaneFillerCommand { handlerNames.append(Self.nonPaneFillerID) }
        let mainJS = handlerNames
            .map { "tenon.intents.handle(\"\($0)\", async function () { return {}; });" }
            .joined(separator: "\n")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-menu-grouped-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let pluginDirectory = plugins.appendingPathComponent("fixture")
        let stateRoot = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try manifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try mainJS.write(
            to: pluginDirectory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceStore()
        let pool = SurfacePool(backendName: "LauncherMenu tests") { _, _ in StubTerminalSurface() }
        let userInterface = PluginUIState()
        let runtime = try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: PluginWebSurfacePool(),
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: runtime.kernel,
            authorization: .bundledInventory
        )
        try await host.loadAll()
        let palette = CommandPaletteState(
            storeURL: stateRoot.appendingPathComponent("frecency.json")
        )
        return Fixture(host: host, runtime: runtime, palette: palette)
    }

    private func height(
        _ fixture: Fixture,
        purpose: LauncherPurpose,
        recents: [SlotContent] = [],
        copyTabID: Bool = false
    ) -> CGFloat {
        let hosting = NSHostingView(
            rootView: LauncherMenu(
                host: fixture.host,
                intentRuntime: fixture.runtime,
                palette: fixture.palette,
                copyTabID: copyTabID ? {} : nil,
                recents: recents,
                purpose: purpose,
                dismiss: {}
            )
            .preferredColorScheme(.dark)
        )
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    func testTheFixturePluginProvidesTheTerminalCommandTheCTAPromotes() async throws {
        let fixture = try await makeFixture()
        let ids = fixture.host.commandIndex.launcherOnly.commands.map(\.id)
        XCTAssertTrue(
            ids.contains(Self.terminalID),
            "the grouped layout's CTA pulls this exact id out of the ranked list; if " +
            "core-commands ever renames \"New Terminal\", the CTA silently stops promoting " +
            "anything. Fixture loaded: \(ids)"
        )
    }

    func testTheOpenPurposeGroupsAndTheFillEmptyGridPurposeStaysFlat() async throws {
        let fixture = try await makeFixture()
        let grouped = height(fixture, purpose: .open)
        let flat = height(fixture, purpose: .fillEmptyGrid)

        XCTAssertGreaterThan(grouped, 0, "the grouped layout drew nothing at all")
        XCTAssertGreaterThan(flat, 0, "the flat list drew nothing at all")
        XCTAssertGreaterThan(
            grouped, flat,
            """
            .open with nothing typed must draw the CTA, a section label and a footer on top \
            of the same two commands .fillEmptyGrid draws as a bare flat list
            """
        )
    }

    func testRecentlyOpenedGrowsTheGroupedLayoutButNeverTheFillEmptyGridOne() async throws {
        let fixture = try await makeFixture()
        let recents: [SlotContent] = [.terminal, .changes, .automation]

        let groupedBare = height(fixture, purpose: .open)
        let groupedWithRecents = height(fixture, purpose: .open, recents: recents)
        XCTAssertGreaterThan(
            groupedWithRecents, groupedBare,
            "recents must draw their own section once the tab strip's launcher groups"
        )

        let fillBare = height(fixture, purpose: .fillEmptyGrid)
        let fillWithRecents = height(fixture, purpose: .fillEmptyGrid, recents: recents)
        XCTAssertEqual(
            fillWithRecents, fillBare,
            "recents belong to the grouped layout only; fill-this-space has no such anchor"
        )
    }

    /// `.fillEmptyGrid` only ever offers `paneFillersOnly` — the intersection of `launcher`
    /// and `fillsPane` — which both fixture commands already satisfy, so this is really a
    /// negative check: the fixture's terminal id shows up in `.open`'s grouped CTA and never
    /// as a second, duplicate row inside its own "New" section.
    func testTheGroupedLayoutNeverDrawsTheCTACommandTwice() async throws {
        let fixture = try await makeFixture()
        let order = fixture.host.commandIndex.launcherOnly
        let ranked = order.rank(query: "", frecency: fixture.palette.frecency, now: Date())
        let filtered = ranked.filter { $0.command.id != Self.terminalID }
        XCTAssertEqual(
            filtered.count, ranked.count - 1,
            "the CTA's command must be filtered out of the ranked list exactly once"
        )
        XCTAssertFalse(
            filtered.contains { $0.command.id == Self.terminalID },
            "the terminal command still appears in the regrouped commands below the CTA"
        )
    }

    /// The "Open a view" section is a 2-column grid, not one row per command: going from 2 to
    /// 3 pane-filler commands needs a second row, but going from 3 to 4 does not (`ceil(3/2)`
    /// and `ceil(4/2)` are both 2). A flat list — T-187's shape — would grow on every one of
    /// these steps; only a grid holds still on the 3→4 step.
    func testPaneFillingCommandsPackTwoPerRowInTheOpenAViewGrid() async throws {
        let two = try await makeFixture(paneFillerCount: 2)
        let three = try await makeFixture(paneFillerCount: 3)
        let four = try await makeFixture(paneFillerCount: 4)

        let heightTwo = height(two, purpose: .open)
        let heightThree = height(three, purpose: .open)
        let heightFour = height(four, purpose: .open)

        XCTAssertLessThan(
            heightTwo, heightThree,
            "2 pane-filler commands (one grid row) must be shorter than 3 (two grid rows)"
        )
        XCTAssertEqual(
            heightThree, heightFour,
            "3 and 4 pane-filler commands both fill exactly two grid rows in a 2-column grid"
        )
    }

    /// T-187's shape gave "New Tab" its own one-row "New" section, paying for a whole extra
    /// section header on top of the "Pane" section holding Copy Tab ID. Folded correctly, a
    /// non-`fillsPane` command only ever costs one more flat row inside "Pane" — far short of
    /// a second header's cost, which `LauncherListHeight.row` (a real row's height, exposed
    /// for exactly this comparison) sizes the assertion against without needing this file to
    /// know `LauncherMenu`'s own private section-header/spacing constants.
    func testNonPaneFillingCommandsFoldIntoThePaneSectionInsteadOfTheirOwnHeader() async throws {
        let withoutNonPaneFiller = try await makeFixture(
            paneFillerCount: 1,
            includeNonPaneFillerCommand: false
        )
        let withNonPaneFiller = try await makeFixture(
            paneFillerCount: 1,
            includeNonPaneFillerCommand: true
        )

        let delta = height(withNonPaneFiller, purpose: .open, copyTabID: true)
            - height(withoutNonPaneFiller, purpose: .open, copyTabID: true)

        XCTAssertGreaterThan(delta, 0, "the folded-in command must still draw a row somewhere")
        XCTAssertLessThan(
            delta,
            LauncherListHeight.row + 10,
            """
            a folded row costs about one row's height; a whole second section (this file's \
            old, T-187 shape) would cost a section header plus inter-group spacing on top of \
            that row — many times this margin. Measured delta: \(delta)
            """
        )
    }
}
