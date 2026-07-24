import XCTest
@testable import TenonCore

/// Every test builds its own throwaway plugin tree in a temp dir, so nothing here
/// depends on the repo's `plugins/` folder or on a GUI.
final class PluginHostTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func writePlugin(dir: String, manifest: String, js: String) throws -> URL {
        let pluginDir = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try js.write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return pluginDir
    }

    // MARK: - Manifest

    func testLoadManifestParsesNameVersionPermissions() throws {
        let dir = try writePlugin(
            dir: "alpha",
            manifest: #"{"name":"alpha","version":"1.2.3","permissions":["terminal.read"]}"#,
            js: "// noop"
        )
        let manifest = try PluginLoader.loadManifest(at: dir)
        XCTAssertEqual(manifest.name, "alpha")
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.permissions, ["terminal.read"])
        XCTAssertTrue(manifest.unknownPermissions.isEmpty)
    }

    func testManifestPermissionsDefaultToEmpty() throws {
        let dir = try writePlugin(dir: "beta", manifest: #"{"name":"beta","version":"0.1"}"#, js: "// noop")
        let manifest = try PluginLoader.loadManifest(at: dir)
        XCTAssertEqual(manifest.permissions, [])
    }

    func testUnknownPermissionIsDetected() throws {
        let dir = try writePlugin(
            dir: "gamma",
            manifest: #"{"name":"gamma","version":"0.1","permissions":["terminal.read","nuke.the.disk"]}"#,
            js: "// noop"
        )
        let manifest = try PluginLoader.loadManifest(at: dir)
        XCTAssertEqual(manifest.unknownPermissions, ["nuke.the.disk"])
    }

    func testMissingManifestThrows() {
        let dir = root.appendingPathComponent("nope")
        XCTAssertThrowsError(try PluginLoader.loadManifest(at: dir)) { error in
            guard case PluginLoadError.manifestMissing = error as! PluginLoadError else {
                return XCTFail("expected manifestMissing, got \(error)")
            }
        }
    }

    func testMissingEntrypointThrows() throws {
        let dir = root.appendingPathComponent("noentry")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"noentry","version":"0.1"}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PluginLoader.loadManifest(at: dir)) { error in
            guard case PluginLoadError.entrypointMissing = error as! PluginLoadError else {
                return XCTFail("expected entrypointMissing, got \(error)")
            }
        }
    }

    func testDiscoverFindsOnlyDirectoriesWithManifests() throws {
        try writePlugin(dir: "one", manifest: #"{"name":"one","version":"1"}"#, js: "")
        try writePlugin(dir: "two", manifest: #"{"name":"two","version":"1"}"#, js: "")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-plugin"), withIntermediateDirectories: true)

        let found = PluginLoader.discover(in: root).map(\.lastPathComponent)
        XCTAssertEqual(found, ["one", "two"])
    }

    // MARK: - Evaluation + statusBar

    func testStatusBarSetIsReflectedInHostState() throws {
        try writePlugin(
            dir: "status",
            manifest: #"{"name":"status","version":"1"}"#,
            js: #"tenon.statusBar.set("hello from js");"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.loadedPluginNames, ["status"])
        XCTAssertEqual(host.statusItems.map(\.text), ["hello from js"])
        XCTAssertEqual(host.statusItems.first?.pluginName, "status")
    }

    func testCommandRegistrationAndInvocation() throws {
        try writePlugin(
            dir: "cmd",
            manifest: #"{"name":"cmd","version":"1"}"#,
            js: """
            var n = 0;
            tenon.commands.register("bump", "Bump Counter", function () {
              n = n + 1;
              tenon.log("bumped to " + n);
            });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.commands.count, 1)
        let command = try XCTUnwrap(host.commands.first)
        XCTAssertEqual(command.commandID, "bump")
        XCTAssertEqual(command.title, "Bump Counter")
        XCTAssertEqual(command.id, "cmd.bump") // qualified, unique across plugins

        XCTAssertTrue(host.invoke(command))
        XCTAssertTrue(host.invoke(command))
        XCTAssertTrue(host.log.contains("[cmd] bumped to 1"))
        XCTAssertTrue(host.log.contains("[cmd] bumped to 2"))
    }

    func testEventsAreDeliveredToPluginWithPayload() throws {
        try writePlugin(
            dir: "ev",
            manifest: #"{"name":"ev","version":"1","permissions":["terminal.read"]}"#,
            js: """
            tenon.events.on("tick", function (e) {
              tenon.statusBar.set("tick " + e.count + " at " + e.time);
            });
            tenon.events.on("terminal.title-changed", function (e) {
              tenon.log("title:" + e.title);
            });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertTrue(host.statusItems.isEmpty)

        host.emit(event: "tick", payload: ["count": 7, "time": "12:00:00"])
        XCTAssertEqual(host.statusItems.map(\.text), ["tick 7 at 12:00:00"])

        host.terminalTitleChanged("~/projects")
        XCTAssertTrue(host.log.contains("[ev] title:~/projects"))
    }

    func testTerminalTitleChangeCarriesTheSlotIdentity() throws {
        try writePlugin(
            dir: "titles",
            manifest: #"{"name":"titles","version":"1","permissions":["terminal.read"]}"#,
            js: #"tenon.events.on("terminal.title-changed", function (e) { tenon.log(e.title + " @ " + e.slotId); });"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        let slot = UUID()
        host.terminalTitleChanged("vim", slotID: slot)
        XCTAssertTrue(host.log.contains("[titles] vim @ \(slot.uuidString)"), "log: \(host.log)")
    }

    func testUnknownPermissionLogsWarningOnLoad() throws {
        try writePlugin(
            dir: "sketchy",
            manifest: #"{"name":"sketchy","version":"1","permissions":["network.fetch"]}"#,
            js: "// noop"
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(
            host.log.contains { $0.contains("unknown permission") && $0.contains("network.fetch") },
            "expected an unknown-permission warning, log was: \(host.log)"
        )
        let snapshot = try XCTUnwrap(host.plugins.first { $0.name == "sketchy" })
        XCTAssertEqual(snapshot.unknownPermissions, ["network.fetch"])
        XCTAssertTrue(snapshot.isLoaded, "unknown permissions must not block loading in v0")
    }

    func testBrokenPluginIsReportedAndDoesNotKillHost() throws {
        try writePlugin(dir: "good", manifest: #"{"name":"good","version":"1"}"#,
                        js: #"tenon.statusBar.set("ok");"#)
        try writePlugin(dir: "bad", manifest: "{ this is not json",
                        js: "// noop")

        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.loadedPluginNames, ["good"])
        let bad = try XCTUnwrap(host.plugins.first { $0.name == "bad" })
        XCTAssertFalse(bad.isLoaded)
        XCTAssertNotNil(bad.error)
    }

    func testJSExceptionIsCapturedNotCrashed() throws {
        try writePlugin(
            dir: "throwy",
            manifest: #"{"name":"throwy","version":"1"}"#,
            js: "throw new Error('boom');"
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.loadedPluginNames, ["throwy"])
        XCTAssertTrue(host.log.contains { $0.contains("JS exception") && $0.contains("boom") })
    }

    // MARK: - Sandbox discipline

    func testPluginsSeeOnlyTheTenonGlobal() throws {
        try writePlugin(dir: "probe", manifest: #"{"name":"probe","version":"1"}"#, js: "// noop")
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        let runtime = try XCTUnwrap(host.runtime(named: "probe"))

        for forbidden in ["require", "setTimeout", "setInterval", "console", "process", "fetch", "XMLHttpRequest"] {
            let result = runtime.evaluateForTesting("typeof \(forbidden)")?.toString()
            XCTAssertEqual(result, "undefined", "\(forbidden) must not be reachable from a plugin")
        }
        XCTAssertEqual(runtime.evaluateForTesting("typeof tenon")?.toString(), "object")
        XCTAssertEqual(runtime.evaluateForTesting("typeof tenon.statusBar.set")?.toString(), "function")
        XCTAssertEqual(runtime.evaluateForTesting("typeof tenon.commands.register")?.toString(), "function")
        XCTAssertEqual(runtime.evaluateForTesting("typeof tenon.events.on")?.toString(), "function")
    }

    func testEachPluginGetsItsOwnIsolatedContext() throws {
        try writePlugin(dir: "a", manifest: #"{"name":"a","version":"1"}"#,
                        js: "var secret = 'from-a'; tenon.statusBar.set(secret);")
        try writePlugin(dir: "b", manifest: #"{"name":"b","version":"1"}"#,
                        js: "tenon.statusBar.set(typeof secret);")

        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.statusItems.map(\.text), ["from-a", "undefined"])
    }

    // MARK: - Hot reload

    func testReloadReplacesTheContextAndItsState() throws {
        let dir = try writePlugin(
            dir: "reloadme",
            manifest: #"{"name":"reloadme","version":"1"}"#,
            js: #"var version = "v1"; tenon.statusBar.set(version);"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.statusItems.map(\.text), ["v1"])

        let firstRuntime = try XCTUnwrap(host.runtime(named: "reloadme"))

        // Edit the plugin on disk, exactly like a user would.
        try #"var version = "v2-edited"; tenon.statusBar.set(version);"#
            .write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

        host.reload(directoryNamed: "reloadme")

        XCTAssertEqual(host.statusItems.map(\.text), ["v2-edited"])
        let secondRuntime = try XCTUnwrap(host.runtime(named: "reloadme"))
        XCTAssertFalse(firstRuntime === secondRuntime, "reload must create a brand-new JSContext")

        // The old context's state is gone, not merged into the new one.
        XCTAssertEqual(secondRuntime.evaluateForTesting("version")?.toString(), "v2-edited")
    }

    func testReloadDropsCommandsRemovedFromSource() throws {
        let dir = try writePlugin(
            dir: "shrink",
            manifest: #"{"name":"shrink","version":"1"}"#,
            js: """
            tenon.commands.register("one", "One", function () {});
            tenon.commands.register("two", "Two", function () {});
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.commands.count, 2)

        try #"tenon.commands.register("one", "One (renamed)", function () {});"#
            .write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        host.reload(directoryNamed: "shrink")

        XCTAssertEqual(host.commands.map(\.commandID), ["one"])
        XCTAssertEqual(host.commands.first?.title, "One (renamed)")
    }

    func testReloadPicksUpManifestPermissionChanges() throws {
        let dir = try writePlugin(
            dir: "perms",
            manifest: #"{"name":"perms","version":"1"}"#,
            js: "// noop"
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.plugins.first?.permissions, [])

        try #"{"name":"perms","version":"2","permissions":["terminal.read"]}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        host.reload(directoryNamed: "perms")

        XCTAssertEqual(host.plugins.first?.version, "2")
        XCTAssertEqual(host.plugins.first?.permissions, ["terminal.read"])
    }

    func testReloadOfDeletedDirectoryUnloadsThePlugin() throws {
        let dir = try writePlugin(dir: "ephemeral", manifest: #"{"name":"ephemeral","version":"1"}"#,
                                  js: #"tenon.statusBar.set("here");"#)
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.loadedPluginNames, ["ephemeral"])

        try FileManager.default.removeItem(at: dir)
        host.reload(directoryNamed: "ephemeral")

        XCTAssertEqual(host.loadedPluginNames, [])
        XCTAssertTrue(host.statusItems.isEmpty)
    }

    /// The end-to-end claim: touch a file on disk, the watcher notices, the UI state changes.
    func testFileSystemWatcherTriggersReload() throws {
        let dir = try writePlugin(
            dir: "watched",
            manifest: #"{"name":"watched","version":"1"}"#,
            js: #"tenon.statusBar.set("before-edit");"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        host.startWatching()
        defer { host.stopWatching() }

        XCTAssertEqual(host.statusItems.map(\.text), ["before-edit"])

        let reloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in host.statusItems.first?.text == "after-edit" },
            object: nil
        )

        // Give FSEvents a moment to arm, then edit the file for real.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? #"tenon.statusBar.set("after-edit");"#
                .write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        }

        wait(for: [reloaded], timeout: 15.0)
        XCTAssertEqual(host.statusItems.map(\.text), ["after-edit"])
    }
}
