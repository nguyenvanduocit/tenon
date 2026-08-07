import Foundation
import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

@MainActor
final class PaletteIntentInvokerTests: XCTestCase {
    func testInvocationTargetsOwnerMintsGestureAndRejectsStaleBinding()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-palette-invoker-\(UUID().uuidString)",
                isDirectory: true
            )
        let inventory = root.appendingPathComponent(
            "inventory",
            isDirectory: true
        )
        let pluginDirectory = inventory.appendingPathComponent(
            "owner",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let pluginID: PluginID = "dev.test.palette-owner"
        let intentID = try IntentID(
            "dev.test.palette-owner.run.v1"
        )
        try manifest(
            pluginID: pluginID,
            intentID: intentID
        ).write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        tenon.intents.handle(
          "dev.test.palette-owner.run.v1",
          async function () { return { owner: "plugin" }; }
        );
        """.write(
            to: pluginDirectory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let paths = try AppStatePaths.resolve(
            environment: [
                "TENON_PLUGINS_DIR": inventory.path,
                "TENON_TRUST_PLUGIN_INVENTORY": "1",
            ],
            applicationSupportDirectory: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            bundledPluginsRoot: nil
        )
        let composition = try await AppComposition.make(paths: paths)
        addTeardownBlock {
            await composition.stop()
        }
        await composition.start()
        XCTAssertTrue(
            composition.isStarted,
            composition.startupError ?? "composition did not start"
        )

        let target = KeyBindingTarget(
            pluginID: pluginID,
            intentID: intentID
        )
        let binding = try XCTUnwrap(
            composition.host.keyBindingIndex.binding(for: target)
        )
        let first = try XCTUnwrap(
            PaletteIntentInvoker.prepare(
                target: target,
                expectedBinding: binding,
                host: composition.host
            )
        )
        let second = try XCTUnwrap(
            PaletteIntentInvoker.prepare(
                target: target,
                expectedBinding: binding,
                host: composition.host
            )
        )
        XCTAssertEqual(first.target, target)
        XCTAssertEqual(
            first.providerID,
            try ProviderID(pluginID.rawValue)
        )
        XCTAssertNotEqual(first.userGestureID, second.userGestureID)

        // The plugin stays enabled here, so only the action-time assignment
        // check can refuse a chord that moved since the menu was rendered.
        let movedAssignment = KeyBinding(
            target: target,
            chord: try KeyChord(parsing: "cmd+shift+j")
        )
        XCTAssertNil(
            PaletteIntentInvoker.prepare(
                target: target,
                expectedBinding: movedAssignment,
                host: composition.host
            ),
            "an assignment that changed since rendering must not invoke"
        )

        let invocationResult = await PaletteIntentInvoker.send(
            target: target,
            expectedBinding: binding,
            host: composition.host,
            runtime: composition.intentRuntime
        )
        let result = try XCTUnwrap(invocationResult)
        guard case .success(let success) = result else {
            return XCTFail("expected plugin-owned invocation, got \(result)")
        }
        XCTAssertEqual(
            success.meta.providerID,
            try ProviderID(pluginID.rawValue)
        )
        XCTAssertEqual(
            success.value,
            .object(["owner": .string("plugin")])
        )

        try await composition.host.setEnabled(
            false,
            pluginID: pluginID
        )
        let staleResult = await PaletteIntentInvoker.send(
            target: target,
            expectedBinding: binding,
            host: composition.host,
            runtime: composition.intentRuntime
        )
        XCTAssertNil(staleResult)
    }

    private func manifest(
        pluginID: PluginID,
        intentID: IntentID
    ) -> String {
        """
        {
          "id": "\(pluginID.rawValue)",
          "name": "palette-owner",
          "version": "1",
          "permissions": [],
          "intents": {
            "uses": [],
            "provides": [{
              "name": "\(intentID.rawValue)",
              "title": "Run",
              "audiences": ["plugin", "user"],
              "effects": {
                "kind": "read",
                "idempotency": "none",
                "confirmation": "never",
                "external": false
              },
              "inputSchema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": false
              },
              "outputSchema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "properties": {
                  "owner": { "type": "string" }
                },
                "required": ["owner"],
                "additionalProperties": false
              },
              "palette": {
                "category": "Tests",
                "keywords": [],
                "key": "cmd+shift+k"
              }
            }]
          }
        }
        """
    }
}
