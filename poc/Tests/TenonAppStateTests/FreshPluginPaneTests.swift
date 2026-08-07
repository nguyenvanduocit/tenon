import Foundation
import TenonIntentCore
import XCTest

@testable import TenonApp
@testable import TenonCore

@MainActor
final class FreshPluginPaneTests: XCTestCase {
    func testFirstPluginPaneOpensWithoutAnotherWorkspaceMutation() async throws {
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
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: pluginRoot,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "dev.test.fresh-panel",
          "name": "fresh-panel",
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

        let paths = try AppStatePaths.resolve(
            environment: [
                "TENON_PLUGINS_DIR": inventoryRoot.path,
                "TENON_TRUST_PLUGIN_INVENTORY": "1",
            ],
            applicationSupportDirectory: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            bundledPluginsRoot: nil
        )
        let composition = try await AppComposition.make(paths: paths)
        addTeardownBlock { await composition.stop() }
        await composition.start()
        XCTAssertTrue(
            composition.isStarted,
            composition.startupError ?? "composition did not start"
        )

        // The title-bar launcher reserves an empty tab before its selected result is
        // resolved. Those two mutations publish independent async event tasks.
        composition.store.newTab(content: .empty)
        let slotID = try XCTUnwrap(composition.store.catalog.activeSlotID)
        composition.store.setSlotContent(
            slotID,
            .pluginView(
                pluginID: PluginID("dev.test.fresh-panel"),
                viewID: "panel"
            )
        )

        var section: PluginViewSection?
        for _ in 0 ..< 200 {
            section = composition.host.pluginViews.first { candidate in
                candidate.pluginID == PluginID("dev.test.fresh-panel")
                    && candidate.viewID == "panel"
                    && candidate.instanceID == slotID.uuidString
            }
            if section != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(
            section,
            "the first plugin pane must open without a tab switch or third mutation"
        )
    }
}
