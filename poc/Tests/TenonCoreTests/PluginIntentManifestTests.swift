import Foundation
import TenonIntentCore
@testable import TenonCore
import XCTest

final class PluginIntentManifestTests: XCTestCase {
    func testLoaderRejectsManifestWithoutCompleteIntentsEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-incomplete-manifest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        {
          "id": "dev.tenon.incomplete",
          "name": "incomplete",
          "version": "1.0.0",
          "permissions": []
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try PluginLoader.loadManifest(at: directory)
        ) { error in
            guard case let .manifestInvalid(path, diagnostic) =
                error as? PluginLoadError
            else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
            XCTAssertEqual(
                path,
                directory.appendingPathComponent("manifest.json").path
            )
            XCTAssertTrue(diagnostic.contains("intents"))
        }
    }

    func testDecodesUsesContractReferencesAndOwnedContractsBeforeRuntimeEvaluation() throws {
        let manifest = try decode(
            """
            {
              "id": "dev.tenon.git",
              "name": "git",
              "version": "1.0.0",
              "permissions": ["process.exec"],
              "intents": {
                "uses": ["process.exec.v1"],
                "provides": [
                  { "name": "file.open.v1" },
                  {
                    "name": "dev.tenon.git.refresh.v1",
                    "title": "Git: Refresh",
                    "audiences": ["plugin", "palette"],
                    "effects": {
                      "kind": "read",
                      "idempotency": "none",
                      "confirmation": "never",
                      "external": false
                    },
                    "inputSchema": {
                      "$schema": "https://json-schema.org/draft/2020-12/schema",
                      "type": "object"
                    },
                    "outputSchema": {
                      "$schema": "https://json-schema.org/draft/2020-12/schema",
                      "type": "object"
                    },
                    "palette": {
                      "category": "Git",
                      "icon": "arrow.clockwise",
                      "keywords": ["reload"],
                      "key": "cmd+shift+r"
                    }
                  }
                ]
              }
            }
            """
        )

        XCTAssertEqual(manifest.id, PluginID("dev.tenon.git"))
        XCTAssertEqual(manifest.intents.uses, [try IntentID("process.exec.v1")])
        XCTAssertTrue(manifest.intents.provides[0].isContractReference)
        let declaration = try XCTUnwrap(
            manifest.intents.provides[1].declaration(owner: manifest.id)
        )
        XCTAssertEqual(declaration.owner, .plugin(PluginID("dev.tenon.git")))
        XCTAssertEqual(declaration.contractClass, .pluginOwned)
        XCTAssertEqual(declaration.audiences, [.plugin, .palette])
        XCTAssertEqual(
            manifest.intents.provides[1].palette?.key,
            "cmd+shift+r"
        )
    }

    func testRejectsMissingStablePluginID() {
        XCTAssertThrowsError(
            try decode(
                """
                {
                  "name":"git",
                  "version":"1.0.0",
                  "permissions":[],
                  "intents":{"uses":[],"provides":[]}
                }
                """
            )
        )
    }

    func testRejectsDuplicateUsesAndProvisions() {
        XCTAssertThrowsError(
            try decode(
                """
                {
                  "id":"dev.tenon.git",
                  "name":"git",
                  "version":"1",
                  "intents":{
                    "uses":["file.open.v1","file.open.v1"],
                    "provides":[]
                  }
                }
                """
            )
        ) { error in
            XCTAssertEqual(error as? PluginManifestError, .duplicateIntentUse)
        }
        XCTAssertThrowsError(
            try decode(
                """
                {
                  "id":"dev.tenon.git",
                  "name":"git",
                  "version":"1",
                  "intents":{
                    "uses":[],
                    "provides":[
                      {"name":"file.open.v1"},
                      {"name":"file.open.v1"}
                    ]
                  }
                }
                """
            )
        ) { error in
            XCTAssertEqual(error as? PluginManifestError, .duplicateIntentProvision)
        }
    }

    func testRejectsDuplicateSettingKeysBeforeHostActivation() {
        XCTAssertThrowsError(
            try decode(
                """
                {
                  "id":"dev.tenon.settings",
                  "name":"settings",
                  "version":"1",
                  "intents":{"uses":[],"provides":[]},
                  "settings":[
                    {"key":"theme","label":"Theme","type":"string"},
                    {"key":"theme","label":"Theme again","type":"string"}
                  ]
                }
                """
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestError,
                .duplicateSettingKey("theme")
            )
        }
    }

    func testRejectsPartialAndForeignOwnedContracts() throws {
        let partial = try IntentID("dev.tenon.git.refresh.v1")
        XCTAssertThrowsError(
            try decode(
                """
                {
                  "id":"dev.tenon.git",
                  "name":"git",
                  "version":"1",
                  "intents":{
                    "uses":[],
                    "provides":[{
                      "name":"dev.tenon.git.refresh.v1",
                      "title":"Refresh"
                    }]
                  }
                }
                """
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestError,
                .partialIntentContract(partial)
            )
        }

        let foreign = try IntentID("dev.attacker.refresh.v1")
        let owner = PluginID("dev.tenon.git")
        XCTAssertThrowsError(
            try decode(
                completeContractJSON(name: foreign.rawValue, audiences: ["plugin"])
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestError,
                .intentOutsidePluginNamespace(intent: foreign, owner: owner)
            )
        }
    }

    func testPalettePresentationRequiresPaletteAudience() throws {
        let intent = try IntentID("dev.tenon.git.refresh.v1")
        XCTAssertThrowsError(
            try decode(
                completeContractJSON(
                    name: intent.rawValue,
                    audiences: ["plugin"],
                    palette:
                        #","palette":{"category":"Git","keywords":[]}"#
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestError,
                .paletteIntentMissingAudience(intent)
            )
        }
    }

    func testRejectsUnknownPaletteField() {
        XCTAssertThrowsError(
            try decode(
                completeContractJSON(
                    name: "dev.tenon.git.refresh.v1",
                    audiences: ["plugin", "palette"],
                    palette:
                        #","palette":{"binding":"cmd+r"}"#
                )
            )
        ) { error in
            guard case let DecodingError.dataCorrupted(context) = error
            else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(
                context.debugDescription.contains(
                    "unknown palette field binding"
                )
            )
        }
    }

    func testRejectsLegacyPaletteShortcutField() {
        XCTAssertThrowsError(
            try decode(
                completeContractJSON(
                    name: "dev.tenon.git.refresh.v1",
                    audiences: ["plugin", "palette"],
                    palette:
                        #","palette":{"shortcut":"cmd+r"}"#
                )
            )
        ) { error in
            guard case let DecodingError.dataCorrupted(context) = error
            else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(
                context.debugDescription.contains(
                    "unknown palette field shortcut"
                )
            )
        }
    }

    func testPluginProvisionAudienceBoundaryIsExactAndRejectsCore() throws {
        XCTAssertEqual(
            PluginIntentProvision.allowedAudiences,
            [.plugin, .palette, .cli, .agent]
        )

        let intent = try IntentID("dev.tenon.git.refresh.v1")
        XCTAssertThrowsError(
            try decode(
                completeContractJSON(
                    name: intent.rawValue,
                    audiences: ["core"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestError,
                .unsupportedIntentAudience(
                    intent: intent,
                    audience: .core
                )
            )
        }
    }

    private func decode(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private func completeContractJSON(
        name: String,
        audiences: [String],
        palette: String = ""
    ) -> String {
        let encodedAudiences = audiences.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "id":"dev.tenon.git",
          "name":"git",
          "version":"1",
          "intents":{
            "uses":[],
            "provides":[{
              "name":"\(name)",
              "audiences":[\(encodedAudiences)],
              "effects":{
                "kind":"read",
                "idempotency":"none",
                "confirmation":"never",
                "external":false
              },
              "inputSchema":{
                "$schema":"https://json-schema.org/draft/2020-12/schema",
                "type":"object"
              },
              "outputSchema":{
                "$schema":"https://json-schema.org/draft/2020-12/schema",
                "type":"object"
              }\(palette)
            }]
          }
        }
        """
    }
}
