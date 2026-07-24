import XCTest
@testable import TenonCore

/// Exercises the plugins actually shipped in `poc/plugins/` — the same files the app loads.
///
/// They're copied into a temp dir first so the tests can edit them (to prove hot reload)
/// without mutating the repo.
final class ShippedPluginsTests: XCTestCase {
    private var sandbox: URL!

    /// Tests/TenonCoreTests/ShippedPluginsTests.swift → up 3 → package root
    private static var repoPluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-shipped-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.repoPluginsRoot, to: sandbox)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testAllShippedPluginsLoad() {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()
        XCTAssertEqual(host.loadedPluginNames, ["clock", "file-explorer", "git", "hello-palette", "workspace-status"])
    }

    /// workspace-status is the end-to-end proof for the workspace bridge: a zero-
    /// permission plugin that turns `workspace.changed` into a status bar item.
    func testWorkspaceStatusPluginTracksTabsAndSlots() throws {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        let store = WorkspaceStore()
        store.onEvents = { [weak host] events, snapshot in
            host?.emit(workspaceEvents: events, in: snapshot)
        }
        store.newTab()
        store.splitActiveSlot(.vertical)

        let item = try XCTUnwrap(host.statusItems.first { $0.pluginName == "workspace-status" })
        XCTAssertEqual(item.text, "⊞ 2 tabs · 3 slots")

        store.closeTab(store.catalog.activeWorkspace!.tabs[1].id)
        let after = try XCTUnwrap(host.statusItems.first { $0.pluginName == "workspace-status" })
        XCTAssertEqual(after.text, "⊞ 1 tab · 1 slot")
    }

    func testClockPluginRendersStatusBarFromTickEvents() throws {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        let initial = try XCTUnwrap(host.statusItems.first { $0.pluginName == "clock" })
        XCTAssertTrue(initial.text.contains("waiting for first tick"))

        host.emit(event: "tick", payload: ["time": "09:41:00", "count": 42])

        let ticked = try XCTUnwrap(host.statusItems.first { $0.pluginName == "clock" })
        XCTAssertTrue(ticked.text.contains("09:41:00"), "got: \(ticked.text)")
        XCTAssertTrue(ticked.text.contains("tick 42"), "got: \(ticked.text)")
    }

    func testHelloPaletteRegistersCommandsThatAppendToTheLog() throws {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        let commands = host.commands.filter { $0.pluginName == "hello-palette" }
        XCTAssertEqual(commands.map(\.commandID), ["greet", "reset"])

        let greet = try XCTUnwrap(commands.first { $0.commandID == "greet" })
        host.invoke(greet)
        host.invoke(greet)
        XCTAssertTrue(host.log.contains("[hello-palette] hello #1 👋"), "log: \(host.log)")
        XCTAssertTrue(host.log.contains("[hello-palette] hello #2 👋"), "log: \(host.log)")

        let reset = try XCTUnwrap(commands.first { $0.commandID == "reset" })
        host.invoke(reset)
        host.invoke(greet)
        XCTAssertTrue(host.log.contains("[hello-palette] counter reset"))
        XCTAssertTrue(host.log.filter { $0 == "[hello-palette] hello #1 👋" }.count == 2,
                      "counter should have restarted at 1")
    }

    func testHelloPaletteReactsToTerminalTitleChanges() {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()
        host.terminalTitleChanged("~/projects/tenon")
        XCTAssertTrue(host.log.contains("[hello-palette] terminal title → ~/projects/tenon"),
                      "log: \(host.log)")
    }

    /// The shipped plugins must be clean citizens of the permission policy:
    /// clock renders UI with zero permissions (VISION §5), hello-palette declares
    /// `terminal.read` for its title listener, and nobody trips the gate.
    /// file-explorer is a core plugin built ONLY on the public API: fs.readDir +
    /// settings + sidebar. Point its rootPath at a known directory and the sidebar
    /// must show that directory's entries.
    func testFileExplorerListsTheConfiguredRootInTheSidebar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-fx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try "hi".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        host.setSetting(dir.path, forKey: "rootPath", pluginNamed: "file-explorer")

        let section = try XCTUnwrap(host.sidebarSections.first { $0.pluginName == "file-explorer" })
        XCTAssertEqual(section.title, "Files")
        XCTAssertEqual(section.items.map(\.label), ["subdir", "notes.txt"], "directories first, then files")

        // Selecting a directory expands it in place.
        try "x".write(
            to: dir.appendingPathComponent("subdir/inner.txt"), atomically: true, encoding: .utf8)
        host.invokeSidebarSelect(pluginName: "file-explorer", itemID: dir.appendingPathComponent("subdir").path)
        let expanded = try XCTUnwrap(host.sidebarSections.first { $0.pluginName == "file-explorer" })
        XCTAssertEqual(expanded.items.map(\.label), ["subdir", "inner.txt", "notes.txt"])
        XCTAssertEqual(expanded.items.map(\.depth), [0, 1, 0])
    }

    /// The same file-explorer, dogfooding `tenon.views`: it offers its tree as a fillable
    /// slot view too, on the same public API — a real shipped plugin driving a `.pluginView`
    /// slot. Selecting a directory through the view expands it, exactly like the sidebar.
    func testFileExplorerAlsoProvidesASlotView() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-fxview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try "hi".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()
        host.setSetting(dir.path, forKey: "rootPath", pluginNamed: "file-explorer")

        let view = try XCTUnwrap(host.pluginViews.first { $0.pluginName == "file-explorer" && $0.viewID == "tree" })
        XCTAssertEqual(view.title, "Files")
        XCTAssertEqual(view.items.map(\.label), ["subdir", "notes.txt"])

        // Expanding through the slot view mutates the same state the sidebar shows.
        try "x".write(to: dir.appendingPathComponent("subdir/inner.txt"), atomically: true, encoding: .utf8)
        host.invokeViewSelect(pluginName: "file-explorer", viewID: "tree",
                              itemID: dir.appendingPathComponent("subdir").path)
        let expanded = try XCTUnwrap(host.pluginViews.first { $0.pluginName == "file-explorer" && $0.viewID == "tree" })
        XCTAssertEqual(expanded.items.map(\.label), ["subdir", "inner.txt", "notes.txt"])
    }

    /// git is a core plugin built ONLY on the public API: process.exec + settings +
    /// statusBar + sidebar. Against a real repository it must report the branch.
    func testGitPluginReportsBranchOfARealRepository() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        for args in [
            ["init", "-b", "tenon-test-branch"],
            ["config", "user.email", "t@t.t"],
            ["config", "user.name", "t"],
            ["commit", "--allow-empty", "-m", "init"],
        ] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", repo.path] + args
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0, "git \(args) failed")
        }
        try "dirty".write(to: repo.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)

        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        let branchShown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                host.statusItems.contains { $0.pluginName == "git" && $0.text.contains("tenon-test-branch") && $0.text.contains("±1") }
            },
            object: nil
        )

        host.setSetting(repo.path, forKey: "repoPath", pluginNamed: "git")

        wait(for: [branchShown], timeout: 15.0)
        let gitPlugin = try XCTUnwrap(host.plugins.first { $0.name == "git" })
        XCTAssertEqual(gitPlugin.permissionViolations, [])
    }

    func testShippedPluginsProduceNoPermissionViolations() throws {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        for plugin in host.plugins {
            XCTAssertEqual(plugin.permissionViolations, [], "\(plugin.name) tripped the permission gate")
        }
        let clock = try XCTUnwrap(host.plugins.first { $0.name == "clock" })
        XCTAssertEqual(clock.permissions, [])
        XCTAssertTrue(host.statusItems.contains { $0.pluginName == "clock" },
                      "a permissionless plugin must still render UI")
    }

    func testShippedManifestDeclaringUnknownPermissionIsWarnedAboutButStillLoads() throws {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()

        let palette = try XCTUnwrap(host.plugins.first { $0.name == "hello-palette" })
        XCTAssertEqual(palette.unknownPermissions, ["network.fetch"])
        XCTAssertTrue(palette.isLoaded)
        XCTAssertTrue(host.log.contains { $0.contains("unknown permission") && $0.contains("network.fetch") })
    }

    /// The headline claim, end to end, against the real clock plugin:
    /// edit main.js on disk → FSEvents → context torn down and rebuilt → UI state changes.
    func testEditingTheClockPluginOnDiskHotReloadsIt() throws {
        let host = PluginHost(pluginsRoot: sandbox)
        host.loadAll()
        host.startWatching()
        defer { host.stopWatching() }

        let before = try XCTUnwrap(host.statusItems.first { $0.pluginName == "clock" })
        XCTAssertTrue(before.text.contains("🕐"))

        let reloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                host.statusItems.contains { $0.pluginName == "clock" && $0.text.contains("🦊") }
            },
            object: nil
        )

        let clockJS = sandbox.appendingPathComponent("clock/main.js")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let edited = (try? String(contentsOf: clockJS, encoding: .utf8))?
                .replacingOccurrences(of: "\"🕐\"", with: "\"🦊\"")
            try? edited?.write(to: clockJS, atomically: true, encoding: .utf8)
        }

        wait(for: [reloaded], timeout: 15.0)

        // And the freshly built context still works: it responds to new events.
        host.emit(event: "tick", payload: ["time": "10:00:00", "count": 1])
        let after = try XCTUnwrap(host.statusItems.first { $0.pluginName == "clock" })
        XCTAssertTrue(after.text.contains("🦊"), "got: \(after.text)")
        XCTAssertTrue(after.text.contains("10:00:00"), "got: \(after.text)")
    }
}
