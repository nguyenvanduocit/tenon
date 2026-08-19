import AppKit
import Foundation
import SwiftUI
import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// T-188: `LauncherMenu`'s typed-query flat list gains the same "offer this as a command line
/// to run" row `EmptyStateCard`'s search field already draws — the functional half of the
/// inconsistency a screenshot reported (only the empty-pane card could run typed text).
///
/// `RunCommandOffer.placement(for:)` (`TenonCore/EmptyPaneLauncher.swift`) is the one rule read
/// here, unchanged and already covered by its own tests — this file only proves `LauncherMenu`
/// draws (or correctly withholds) the row its placement calls for. `initialQuery` is the same
/// offscreen-measurement seam `EmptyStateCard` already carries; a live popover cannot be typed
/// into headlessly, so height is the only signal available, matching every other test in this
/// file's sibling suites.
@MainActor
final class LauncherMenuRunCommandTests: XCTestCase {
    private struct Fixture {
        let host: PluginHost
        let runtime: AppIntentRuntime
        let palette: CommandPaletteState
    }

    /// No provided intents at all: the run-command row's presence must not depend on any
    /// ranked command existing, only on the query and on `runCommand` being supplied.
    private static let manifest = """
    {
      "id": "dev.tenon.core-commands",
      "name": "launcher-menu-run-command-fixture",
      "version": "1",
      "permissions": [],
      "intents": { "uses": [], "provides": [] }
    }
    """
    private static let mainJS = ""

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-menu-run-command-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let pluginDirectory = plugins.appendingPathComponent("fixture")
        let stateRoot = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try Self.manifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try Self.mainJS.write(
            to: pluginDirectory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceStore()
        let pool = SurfacePool(backendName: "LauncherMenu run-command tests") { _, _ in
            StubTerminalSurface()
        }
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
        query: String,
        offersRunCommand: Bool
    ) -> CGFloat {
        let hosting = NSHostingView(
            rootView: LauncherMenu(
                host: fixture.host,
                intentRuntime: fixture.runtime,
                palette: fixture.palette,
                runCommand: offersRunCommand ? { _ in .ran } : nil,
                purpose: purpose,
                initialQuery: query,
                dismiss: {}
            )
            .preferredColorScheme(.dark)
        )
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    func testACommandShapedQueryDrawsTheRunRowOnlyWhenRunCommandIsSupplied() async throws {
        let fixture = try await makeFixture()
        let withOffer = height(
            fixture, purpose: .fillEmptyGrid, query: "npm run dev", offersRunCommand: true
        )
        let withoutOffer = height(
            fixture, purpose: .fillEmptyGrid, query: "npm run dev", offersRunCommand: false
        )
        XCTAssertGreaterThan(
            withOffer, withoutOffer,
            "a command-shaped query with runCommand supplied must draw one more row than the " +
            "same query without it"
        )
        await fixture.host.shutdown()
    }

    func testAPlainWordQueryStillDrawsTheRunRowTrailing() async throws {
        let fixture = try await makeFixture()
        let withOffer = height(
            fixture, purpose: .open, query: "judge", offersRunCommand: true
        )
        let withoutOffer = height(
            fixture, purpose: .open, query: "judge", offersRunCommand: false
        )
        XCTAssertGreaterThan(
            withOffer, withoutOffer,
            "a plain-word query still offers to run it (trailing), same as EmptyStateCard's " +
            "own search field"
        )
        await fixture.host.shutdown()
    }

    func testAnEmptyQueryNeverDrawsTheRunRowEvenWhenRunCommandIsSupplied() async throws {
        let fixture = try await makeFixture()
        let withOffer = height(fixture, purpose: .fillEmptyGrid, query: "", offersRunCommand: true)
        let withoutOffer = height(
            fixture, purpose: .fillEmptyGrid, query: "", offersRunCommand: false
        )
        XCTAssertEqual(
            withOffer, withoutOffer,
            "RunCommandOffer.placement(for: \"\") is .none — nothing typed is never a command line"
        )
        await fixture.host.shutdown()
    }
}
