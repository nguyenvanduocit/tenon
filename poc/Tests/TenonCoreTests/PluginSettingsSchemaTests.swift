import XCTest
@testable import TenonCore

/// The current manifest envelope supports rich settings presentation while keeping
/// presentation-only fields optional for scalar controls.
final class PluginSettingsSchemaTests: XCTestCase {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    func testSelectSettingDecodesOptionsAndGroup() throws {
        let m = try manifest(#"""
        {
          "id": "dev.tenon.browser",
          "name": "browser", "version": "1.0.0", "permissions": [],
          "intents": { "uses": [], "provides": [] },
          "settings": [
            { "key": "searchEngine", "label": "Search engine", "type": "select",
              "default": "duckduckgo", "group": "Home & search",
              "options": [
                { "value": "duckduckgo", "label": "DuckDuckGo" },
                { "value": "google", "label": "Google" }
              ] }
          ]
        }
        """#)

        let spec = try XCTUnwrap(m.settings.first)
        XCTAssertEqual(spec.type, .select)
        XCTAssertEqual(spec.group, "Home & search")
        XCTAssertEqual(spec.defaultValue, .string("duckduckgo"))
        XCTAssertEqual(spec.options, [
            PluginSettingOption(value: "duckduckgo", label: "DuckDuckGo"),
            PluginSettingOption(value: "google", label: "Google"),
        ])
    }

    func testManifestDecodesOptionalIconAndDisplayName() throws {
        let m = try manifest(#"""
        {
          "id": "dev.tenon.browser",
          "name": "browser",
          "version": "1.0.0",
          "permissions": [],
          "intents": { "uses": [], "provides": [] },
          "icon": "globe",
          "displayName": "Web Browser"
        }
        """#)

        XCTAssertEqual(m.icon, "globe")
        XCTAssertEqual(m.displayName, "Web Browser")
    }

    func testScalarSettingDecodesWithoutSelectPresentationFields() throws {
        let m = try manifest(#"""
        {
          "id": "dev.tenon.file-explorer",
          "name": "file-explorer", "version": "0.1.0",
          "permissions": ["filesystem.read"],
          "intents": { "uses": [], "provides": [] },
          "settings": [ { "key": "rootPath", "label": "Root path", "type": "string", "default": "~" } ]
        }
        """#)

        XCTAssertNil(m.icon)
        XCTAssertNil(m.displayName)
        let spec = try XCTUnwrap(m.settings.first)
        XCTAssertEqual(spec.type, .string)
        XCTAssertNil(spec.options)
        XCTAssertNil(spec.group)
    }

    func testSelectWithoutOptionsIsNotADecodeFailure() throws {
        // A malformed select (missing options) is a plugin bug the UI handles, not a
        // decode error that would fail the whole manifest.
        let m = try manifest(#"""
        {
          "id": "dev.tenon.select",
          "name": "p", "version": "1.0.0",
          "permissions": [],
          "intents": { "uses": [], "provides": [] },
          "settings": [ { "key": "k", "label": "K", "type": "select", "default": "a" } ]
        }
        """#)

        XCTAssertEqual(m.settings.first?.type, .select)
        XCTAssertNil(m.settings.first?.options)
    }
}
