import Foundation
import TenonIntentCore
import XCTest

@testable import TenonApp
@testable import TenonCore

/// T-053: launching over a persisted catalog must open the plugin panes it restores.
/// Reconcile used to run only from workspace mutations, so a restored pane rendered
/// "Plugin view unavailable" until the human happened to change the workspace.
@MainActor
final class RestoredPluginPanesTests: XCTestCase {
    func testARestoredPluginPaneIsOpenAfterStartAlone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "inventory",
            isDirectory: true
        )
        let pluginRoot = inventoryRoot.appendingPathComponent(
            "panel",
            isDirectory: true
        )
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: pluginRoot,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "dev.test.restored-panel",
          "name": "restored-panel",
          "version": "1",
          "permissions": [],
          "intents": {
            "uses": [],
            "provides": []
          }
        }
        """.write(
            to: pluginRoot.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        tenon.views.register("panel", { title: "Panel", instanced: true });
        tenon.views.onOpen("panel", function (instanceID) {
          tenon.views.set("panel", { title: "Panel", items: [] }, instanceID);
        });
        """.write(
            to: pluginRoot.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        func makePaths() throws -> AppStatePaths {
            try AppStatePaths.resolve(
                environment: [
                    "TENON_PLUGINS_DIR": inventoryRoot.path,
                    "TENON_TRUST_PLUGIN_INVENTORY": "1",
                ],
                applicationSupportDirectory: applicationSupport,
                bundledPluginsRoot: nil
            )
        }

        // First session: a pane carries the plugin view; quitting persists the catalog.
        let first = try await AppComposition.make(paths: makePaths())
        let slotID = try XCTUnwrap(first.store.catalog.activeSlotID)
        first.store.setSlotContent(
            slotID,
            .pluginView(
                pluginID: PluginID("dev.test.restored-panel"),
                viewID: "panel"
            )
        )
        await first.stop()

        // Relaunch: start() alone — no workspace mutation — must open the restored pane.
        let second = try await AppComposition.make(paths: makePaths())
        addTeardownBlock { await second.stop() }
        await second.start()
        XCTAssertTrue(
            second.isStarted,
            second.startupError ?? "composition did not start"
        )

        // The pane's own instance section is what the shell renders; its absence is
        // exactly the "Plugin view unavailable" placeholder.
        let pluginID = PluginID("dev.test.restored-panel")
        let instanceID = slotID.uuidString
        var section: PluginViewSection?
        for _ in 0 ..< 200 {
            section = second.host.pluginViews.first { candidate in
                let samePlugin = candidate.pluginID == pluginID
                let sameView = candidate.viewID == "panel"
                let sameInstance = candidate.instanceID == instanceID
                return samePlugin && sameView && sameInstance
            }
            if section != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(
            section,
            "a restored plugin pane must be opened by start() itself, "
                + "not by the next workspace mutation"
        )
    }
}
