import Foundation
import TenonCore
import XCTest
@testable import TenonApp

/// T-027 end to end through the real composition root: build two workspaces / three tabs /
/// one split, quit, relaunch, same tree. This is the assertable half of the launch smoke —
/// pixels stay human-verified, but the restored catalog is proven headlessly against the
/// same init and stop paths the app runs.
@MainActor
final class WorkspaceCatalogRelaunchTests: XCTestCase {
    func testQuitAndRelaunchRestoresTheSameTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-catalog-relaunch-\(UUID().uuidString)",
                isDirectory: true
            )
        let inventory = root.appendingPathComponent("inventory", isDirectory: true)
        let betaDirectory = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inventory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: betaDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        func makePaths() throws -> AppStatePaths {
            try AppStatePaths.resolve(
                environment: ["TENON_PLUGINS_DIR": inventory.path],
                applicationSupportDirectory: root.appendingPathComponent(
                    "Application Support",
                    isDirectory: true
                ),
                bundledPluginsRoot: nil
            )
        }

        // First launch: grow the tree to two workspaces / three tabs / one split.
        // Contents are pinned to `.terminal` explicitly so the assertion does not
        // depend on this machine's preferences surviving the empty test inventory.
        let first = try AppComposition(paths: makePaths())
        let firstWorkspaceID = first.store.catalog.activeWorkspaceID
        let initialSlotID = try XCTUnwrap(first.store.catalog.activeSlotID)
        first.store.setSlotContent(initialSlotID, .terminal)
        first.store.newTab(content: .terminal)
        first.store.splitActiveSlot(.horizontal, content: .terminal)
        first.store.addWorkspace(
            name: "Beta",
            path: betaDirectory,
            content: .terminal
        )
        // End back on the first workspace: the relaunch's launch directory (the test
        // runner's cwd) folder-matches it, so launch precedence selects it again and
        // the whole catalog — selection included — must come back identical.
        first.store.selectWorkspace(firstWorkspaceID)

        let treeAtQuit = first.store.catalog
        XCTAssertEqual(treeAtQuit.workspaces.count, 2)
        XCTAssertEqual(treeAtQuit.workspaces.flatMap(\.tabs).count, 3)
        await first.stop()

        // Relaunch over the same state root.
        let second = try AppComposition(paths: makePaths())
        addTeardownBlock { await second.stop() }

        XCTAssertEqual(second.store.catalog, treeAtQuit)
    }
}
