import XCTest
@testable import TenonCore

/// The plugin platform surfaces: manifest-declared settings with host overrides,
/// per-plugin persistent storage, sidebar contributions, and the workspace API.
/// Settings, storage, sidebar, and workspace STRUCTURE are free tier (VISION §5);
/// driving the workspace is gated behind `workspace.control` at the single gate
/// in `PluginRuntime.installAPI`.
final class PluginPlatformTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-platform-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writePlugin(dir: String, manifest: String, js: String) throws -> URL {
        let pluginDir = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try js.write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return pluginDir
    }

    // MARK: - Manifest settings schema

    func testManifestParsesSettingsSpecsAndIgnoresUnknownFields() throws {
        let dir = try writePlugin(
            dir: "cfg",
            manifest: """
            {"name":"cfg","version":"1","permissions":[],
             "settings":[
               {"key":"greeting","label":"Greeting","type":"string","default":"hello","surprise":true},
               {"key":"size","label":"Font size","type":"number","default":14},
               {"key":"dark","label":"Dark mode","type":"boolean","default":true}
             ],
             "somethingNew":123}
            """,
            js: "// noop"
        )
        let manifest = try PluginLoader.loadManifest(at: dir)
        XCTAssertEqual(manifest.settings, [
            PluginSettingSpec(key: "greeting", label: "Greeting", type: .string, defaultValue: .string("hello")),
            PluginSettingSpec(key: "size", label: "Font size", type: .number, defaultValue: .number(14)),
            PluginSettingSpec(key: "dark", label: "Dark mode", type: .boolean, defaultValue: .boolean(true)),
        ])
    }

    func testManifestWithoutSettingsHasNone() throws {
        let dir = try writePlugin(dir: "plain", manifest: #"{"name":"plain","version":"1"}"#, js: "// noop")
        XCTAssertEqual(try PluginLoader.loadManifest(at: dir).settings, [])
    }

    // MARK: - tenon.settings (free tier)

    func testSettingsGetReturnsManifestDefaults() throws {
        try writePlugin(
            dir: "cfg",
            manifest: """
            {"name":"cfg","version":"1","settings":[
              {"key":"greeting","label":"Greeting","type":"string","default":"hello"},
              {"key":"size","label":"Size","type":"number","default":14},
              {"key":"dark","label":"Dark","type":"boolean","default":true}
            ]}
            """,
            js: #"tenon.log("greeting=" + tenon.settings.get("greeting") + " size=" + tenon.settings.get("size") + " dark=" + tenon.settings.get("dark"));"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains("[cfg] greeting=hello size=14 dark=true"), "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [], "settings.get is free tier")
    }

    func testSetSettingOverridesTheDefaultAndPersistsToDisk() throws {
        try writePlugin(
            dir: "cfg",
            manifest: #"{"name":"cfg","version":"1","settings":[{"key":"greeting","label":"Greeting","type":"string","default":"hello"}]}"#,
            js: """
            tenon.log("at-load greeting=" + tenon.settings.get("greeting"));
            tenon.commands.register("read", "Read", function () {
              tenon.log("re-read greeting=" + tenon.settings.get("greeting"));
            });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertTrue(host.log.contains("[cfg] at-load greeting=hello"), "log: \(host.log)")

        host.setSetting("howdy", forKey: "greeting", pluginNamed: "cfg")

        host.invoke(try XCTUnwrap(host.commands.first))
        XCTAssertTrue(host.log.contains("[cfg] re-read greeting=howdy"), "log: \(host.log)")
        XCTAssertEqual(host.settings.values(for: "cfg") as? [String: String], ["greeting": "howdy"])

        // Persisted: the override is on disk (dot-prefixed, so discovery ignores it)…
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".settings.json").path))
        // …and a brand-new host over the same folder serves it instead of the default.
        let second = PluginHost(pluginsRoot: root)
        second.loadAll()
        XCTAssertTrue(second.log.contains("[cfg] at-load greeting=howdy"), "log: \(second.log)")
    }

    func testSetSettingEmitsSettingsChangedOnlyToThatPlugin() throws {
        for name in ["alpha", "beta"] {
            try writePlugin(
                dir: name,
                manifest: #"{"name":"\#(name)","version":"1"}"#,
                js: #"tenon.events.on("settings.changed", function (e) { tenon.log("changed " + e.key + "=" + e.value); });"#
            )
        }
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        host.setSetting("dim", forKey: "theme", pluginNamed: "alpha")

        XCTAssertTrue(host.log.contains("[alpha] changed theme=dim"), "log: \(host.log)")
        XCTAssertFalse(host.log.contains("[beta] changed theme=dim"),
                       "the event must reach only the plugin whose setting changed: \(host.log)")
    }

    func testUndeclaredSettingsKeyIsNullPlusOneWarning() throws {
        try writePlugin(
            dir: "typo",
            manifest: #"{"name":"typo","version":"1"}"#,
            js: """
            var a = tenon.settings.get("nope");
            var b = tenon.settings.get("nope");
            tenon.log("a=" + a + " isNull=" + (a === null) + " b=" + b);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains("[typo] a=null isNull=true b=null"), "log: \(host.log)")
        // A typo'd key is a plugin bug to surface — once — not a permission violation.
        XCTAssertEqual(host.log.filter { $0.contains("⚠️") && $0.contains("nope") }.count, 1, "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    // MARK: - tenon.storage (free tier)

    func testStorageRoundTripsAndSurvivesReloadAndRestart() throws {
        try writePlugin(
            dir: "keeper",
            manifest: #"{"name":"keeper","version":"1"}"#,
            js: """
            var existing = tenon.storage.get("counter");
            tenon.log("counter=" + existing);
            if (existing === null) { tenon.storage.set("counter", 42); }
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertTrue(host.log.contains("[keeper] counter=null"), "log: \(host.log)")

        // Reload destroys the JSContext — the value must come back through the host.
        host.reload(directoryNamed: "keeper")
        XCTAssertTrue(host.log.contains("[keeper] counter=42"), "log: \(host.log)")

        // And it survives a full restart, via .storage.json on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".storage.json").path))
        let second = PluginHost(pluginsRoot: root)
        second.loadAll()
        XCTAssertTrue(second.log.contains("[keeper] counter=42"), "log: \(second.log)")
    }

    func testStorageHoldsJSONObjects() throws {
        try writePlugin(
            dir: "objects",
            manifest: #"{"name":"objects","version":"1"}"#,
            js: """
            tenon.storage.set("profile", {name: "tenon", tags: ["a", "b"], size: 3});
            var p = tenon.storage.get("profile");
            tenon.log("profile name=" + p.name + " tags=" + p.tags.join("+") + " size=" + p.size);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains("[objects] profile name=tenon tags=a+b size=3"), "log: \(host.log)")
    }

    func testStorageIsIsolatedBetweenPlugins() throws {
        try writePlugin(dir: "a", manifest: #"{"name":"a","version":"1"}"#,
                        js: #"tenon.storage.set("shared", "mine");"#)
        try writePlugin(dir: "b", manifest: #"{"name":"b","version":"1"}"#,
                        js: #"tenon.log("shared=" + tenon.storage.get("shared"));"#)
        let host = PluginHost(pluginsRoot: root)
        host.loadAll() // "a" loads before "b" (sorted), so a's value exists when b asks

        XCTAssertTrue(host.log.contains("[b] shared=null"), "log: \(host.log)")
    }

    // MARK: - tenon.sidebar (free tier)

    func testSidebarSetAggregatesOneSectionPerPlugin() throws {
        try writePlugin(
            dir: "files",
            manifest: #"{"name":"files","version":"1"}"#,
            js: """
            tenon.sidebar.set({title: "Files", items: [
              {id: "src", label: "src", icon: "folder"},
              {id: "main", label: "main.swift", depth: 1},
            ]});
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.sidebarSections, [
            SidebarSection(pluginName: "files", title: "Files", items: [
                SidebarItem(id: "src", label: "src", depth: 0, icon: "folder"),
                SidebarItem(id: "main", label: "main.swift", depth: 1, icon: nil),
            ]),
        ])
        XCTAssertEqual(host.plugins.first?.permissionViolations, [], "sidebar is free tier")
    }

    func testSidebarSetReplacesThePluginsSection() throws {
        try writePlugin(
            dir: "nav",
            manifest: #"{"name":"nav","version":"1"}"#,
            js: """
            tenon.sidebar.set({title: "One", items: [{id: "1", label: "one"}]});
            tenon.commands.register("swap", "Swap", function () {
              tenon.sidebar.set({title: "Two", items: [{id: "2", label: "two"}]});
            });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.sidebarSections.map(\.title), ["One"])

        host.invoke(try XCTUnwrap(host.commands.first))

        XCTAssertEqual(host.sidebarSections, [
            SidebarSection(pluginName: "nav", title: "Two",
                           items: [SidebarItem(id: "2", label: "two", depth: 0, icon: nil)]),
        ])
    }

    func testSidebarOnSelectCallsBackIntoJS() throws {
        try writePlugin(
            dir: "nav",
            manifest: #"{"name":"nav","version":"1"}"#,
            js: """
            tenon.sidebar.set({title: "Nav", items: [{id: "x", label: "X"}]});
            tenon.sidebar.onSelect(function (id) { tenon.log("selected " + id); });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        host.invokeSidebarSelect(pluginName: "nav", itemID: "x")

        XCTAssertTrue(host.log.contains("[nav] selected x"), "log: \(host.log)")
    }

    func testDisablingAPluginRemovesItsSidebarSection() throws {
        try writePlugin(
            dir: "gone",
            manifest: #"{"name":"gone","version":"1"}"#,
            js: #"tenon.sidebar.set({title: "Gone", items: []});"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.sidebarSections.map(\.pluginName), ["gone"])

        host.setEnabled(false, pluginNamed: "gone")
        XCTAssertTrue(host.sidebarSections.isEmpty)

        host.setEnabled(true, pluginNamed: "gone")
        XCTAssertEqual(host.sidebarSections.map(\.pluginName), ["gone"])
    }

    // MARK: - tenon.workspace.get (free tier: structure only)

    func testWorkspaceGetIsFreeAndReadsTheProvider() throws {
        try writePlugin(
            dir: "observer",
            manifest: #"{"name":"observer","version":"1","permissions":[]}"#,
            js: """
            var w = tenon.workspace.get();
            var t = w.tabs[0];
            tenon.log("tabs=" + w.tabs.length + " id=" + t.id + " slots=" + t.slotIds.join(",")
                      + " selected=" + t.selected + " active=" + w.activeSlotId);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.workspaceStateProvider = {
            [
                "tabs": [["id": "t1", "slotIds": ["s1", "s2"], "selected": true]],
                "activeSlotId": "s1",
            ]
        }
        host.loadAll()

        XCTAssertTrue(host.log.contains("[observer] tabs=1 id=t1 slots=s1,s2 selected=true active=s1"),
                      "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [], "workspace structure is free tier")
    }

    func testWorkspaceGetWithoutProviderIsAnEmptyWorkspace() throws {
        try writePlugin(
            dir: "empty",
            manifest: #"{"name":"empty","version":"1"}"#,
            js: """
            var w = tenon.workspace.get();
            tenon.log("tabs=" + w.tabs.length + " active=" + w.activeSlotId + " isNull=" + (w.activeSlotId === null));
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains("[empty] tabs=0 active=null isNull=true"), "log: \(host.log)")
    }

    // MARK: - tenon.workspace mutations (workspace.control)

    func testWorkspaceCommandsAreBlockedWithoutWorkspaceControl() throws {
        try writePlugin(
            dir: "grabby",
            manifest: #"{"name":"grabby","version":"1","permissions":[]}"#,
            js: """
            var slot = "11111111-2222-3333-4444-555555555555";
            var r = [tenon.workspace.newTab(), tenon.workspace.split("vertical"),
                     tenon.workspace.focusSlot(slot), tenon.workspace.closeSlot(slot)];
            tenon.log("ok=" + r.map(function (x) { return x.ok; }).join(","));
            """
        )
        let host = PluginHost(pluginsRoot: root)
        var received: [WorkspaceCommand] = []
        host.onWorkspaceCommand = { received.append($0) }
        host.loadAll()

        XCTAssertEqual(received, [], "a blocked command must never reach the host")
        XCTAssertTrue(host.log.contains("[grabby] ok=false,false,false,false"), "log: \(host.log)")
        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations.count, 4, "one violation per blocked API")
        for violation in snapshot.permissionViolations {
            XCTAssertTrue(violation.contains("workspace.control"), violation)
            XCTAssertTrue(violation.contains("manifest.json"), violation)
        }
        XCTAssertTrue(snapshot.isLoaded)
    }

    func testWorkspaceCommandsReachTheHostWithWorkspaceControl() throws {
        try writePlugin(
            dir: "driver",
            manifest: #"{"name":"driver","version":"1","permissions":["workspace.control"]}"#,
            js: """
            var slot = "11111111-2222-3333-4444-555555555555";
            var r = [tenon.workspace.newTab(), tenon.workspace.split("horizontal"),
                     tenon.workspace.focusSlot(slot), tenon.workspace.closeSlot(slot)];
            tenon.log("ok=" + r.map(function (x) { return x.ok; }).join(","));
            """
        )
        let host = PluginHost(pluginsRoot: root)
        var received: [WorkspaceCommand] = []
        host.onWorkspaceCommand = { received.append($0) }
        host.loadAll()

        let slot = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(received, [.newTab, .split(.horizontal), .focusSlot(slot), .closeSlot(slot)])
        XCTAssertTrue(host.log.contains("[driver] ok=true,true,true,true"), "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    func testWorkspaceSplitRejectsAnUnknownOrientation() throws {
        try writePlugin(
            dir: "diagonal",
            manifest: #"{"name":"diagonal","version":"1","permissions":["workspace.control"]}"#,
            js: """
            var r = tenon.workspace.split("diagonal");
            tenon.log("ok=" + r.ok + " error=" + r.error);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        var received: [WorkspaceCommand] = []
        host.onWorkspaceCommand = { received.append($0) }
        host.loadAll()

        XCTAssertEqual(received, [])
        XCTAssertTrue(host.log.contains { $0.contains("ok=false") && $0.contains("horizontal") && $0.contains("vertical") },
                      "log: \(host.log)")
        // Bad input with the permission granted is an error, not a violation.
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    // MARK: - Snapshots feed the settings UI

    /// The settings window renders per-plugin forms from the snapshot alone,
    /// so the manifest's setting specs must ride along on it.
    func testSnapshotCarriesTheManifestSettingSpecs() throws {
        try writePlugin(
            dir: "cfgui",
            manifest: """
            {"name":"cfgui","version":"1",
             "settings":[{"key":"rootPath","label":"Root path","type":"string","default":"~"}]}
            """,
            js: "// noop"
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.plugins.first?.settingSpecs, [
            PluginSettingSpec(key: "rootPath", label: "Root path", type: .string, defaultValue: .string("~")),
        ])
    }
}
