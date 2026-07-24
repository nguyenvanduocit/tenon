import XCTest
@testable import TenonCore

/// The plugin-management policy layer: the permission gate (VISION §5 — a plugin
/// without permissions can render UI and react to events, sensitive capabilities
/// need a declaration) and enable/disable with persistence.
final class PluginPolicyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-policy-tests-\(UUID().uuidString)")
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

    // MARK: - The permission gate

    /// VISION §5, as an executable claim: zero permissions still buys UI + events.
    func testPermissionlessPluginCanRenderUIAndReactToEvents() throws {
        try writePlugin(
            dir: "freetier",
            manifest: #"{"name":"freetier","version":"1","permissions":[]}"#,
            js: """
            tenon.statusBar.set("free");
            tenon.commands.register("hi", "Say Hi", function () { tenon.log("hi!"); });
            tenon.events.on("tick", function (e) { tenon.statusBar.set("tick " + e.count); });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.statusItems.map(\.text), ["free"])
        XCTAssertEqual(host.commands.map(\.commandID), ["hi"])
        host.emit(event: "tick", payload: ["count": 3])
        XCTAssertEqual(host.statusItems.map(\.text), ["tick 3"])

        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations, [])
    }

    func testTerminalTopicRequiresTerminalRead() throws {
        try writePlugin(
            dir: "peeker",
            manifest: #"{"name":"peeker","version":"1","permissions":[]}"#,
            js: #"tenon.events.on("terminal.title-changed", function (e) { tenon.log("saw " + e.title); });"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        // The subscription was blocked with a suggestion, not silently dropped…
        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations.count, 1)
        XCTAssertTrue(snapshot.permissionViolations[0].contains("terminal.read"))
        XCTAssertTrue(host.log.contains { $0.contains("⛔") && $0.contains("terminal.read") && $0.contains("manifest.json") },
                      "log: \(host.log)")

        // …and the handler really never runs.
        host.terminalTitleChanged("secret pwd")
        XCTAssertFalse(host.log.contains { $0.contains("saw secret pwd") })

        // The plugin itself stays loaded — one blocked capability isn't fatal.
        XCTAssertTrue(snapshot.isLoaded)
    }

    func testTerminalTopicWithTerminalReadWorks() throws {
        try writePlugin(
            dir: "reader",
            manifest: #"{"name":"reader","version":"1","permissions":["terminal.read"]}"#,
            js: #"tenon.events.on("terminal.title-changed", function (e) { tenon.log("saw " + e.title); });"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        host.terminalTitleChanged("~/projects")
        XCTAssertTrue(host.log.contains("[reader] saw ~/projects"), "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    func testRepeatedViolationIsReportedOnce() throws {
        try writePlugin(
            dir: "spammy",
            manifest: #"{"name":"spammy","version":"1","permissions":[]}"#,
            js: """
            for (var i = 0; i < 5; i++) {
              tenon.events.on("terminal.title-changed", function () {});
            }
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.plugins.first?.permissionViolations.count, 1)
        XCTAssertEqual(host.log.filter { $0.contains("⛔") }.count, 1)
    }

    // MARK: - Enable / disable

    func testDisableTearsDownContributionsAndKeepsTheSnapshot() throws {
        try writePlugin(dir: "status", manifest: #"{"name":"status","version":"1"}"#,
                        js: #"tenon.statusBar.set("on air");"#)
        try writePlugin(dir: "cmd", manifest: #"{"name":"cmd","version":"1"}"#,
                        js: #"tenon.commands.register("x", "X", function () {});"#)
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.statusItems.count, 1)
        XCTAssertEqual(host.commands.count, 1)

        host.setEnabled(false, pluginNamed: "status")

        // Its contributions are gone, the other plugin is untouched…
        XCTAssertTrue(host.statusItems.isEmpty)
        XCTAssertEqual(host.commands.count, 1)
        XCTAssertNil(host.runtime(named: "status"), "disable must destroy the runtime")

        // …but the plugin stays visible so the UI can switch it back on.
        let snapshot = try XCTUnwrap(host.plugins.first { $0.name == "status" })
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertFalse(snapshot.isLoaded)
        XCTAssertNil(snapshot.error)
    }

    func testDisableIsPersistedAndSurvivesANewHost() throws {
        try writePlugin(dir: "sticky", manifest: #"{"name":"sticky","version":"1"}"#,
                        js: #"tenon.statusBar.set("here");"#)
        let first = PluginHost(pluginsRoot: root)
        first.loadAll()
        first.setEnabled(false, pluginNamed: "sticky")

        // A brand-new host over the same folder — as after an app restart.
        let second = PluginHost(pluginsRoot: root)
        second.loadAll()

        XCTAssertEqual(second.loadedPluginNames, [])
        XCTAssertTrue(second.statusItems.isEmpty)
        let snapshot = try XCTUnwrap(second.plugins.first { $0.name == "sticky" })
        XCTAssertFalse(snapshot.isEnabled)
    }

    func testEnableRestoresThePluginWithFreshState() throws {
        try writePlugin(dir: "phoenix", manifest: #"{"name":"phoenix","version":"1"}"#,
                        js: #"var lives = 1; tenon.statusBar.set("lives " + lives);"#)
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        host.setEnabled(false, pluginNamed: "phoenix")
        XCTAssertTrue(host.statusItems.isEmpty)

        host.setEnabled(true, pluginNamed: "phoenix")

        XCTAssertEqual(host.loadedPluginNames, ["phoenix"])
        XCTAssertEqual(host.statusItems.map(\.text), ["lives 1"])
        XCTAssertEqual(host.plugins.first?.isEnabled, true)
        // Nothing disabled anymore → the persistence file is cleaned up too.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".disabled.json").path))
    }

    func testEditsWhileDisabledDoNotExecuteButApplyOnEnable() throws {
        let dir = try writePlugin(dir: "dormant", manifest: #"{"name":"dormant","version":"1"}"#,
                                  js: #"tenon.statusBar.set("v1");"#)
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        host.setEnabled(false, pluginNamed: "dormant")

        // A file edit lands while the plugin is off — the reload path must not run it.
        try #"tenon.statusBar.set("v2");"#
            .write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        host.reload(directoryNamed: "dormant")
        XCTAssertNil(host.runtime(named: "dormant"))
        XCTAssertTrue(host.statusItems.isEmpty)

        // Switching it back on picks up the edited source.
        host.setEnabled(true, pluginNamed: "dormant")
        XCTAssertEqual(host.statusItems.map(\.text), ["v2"])
    }
}
