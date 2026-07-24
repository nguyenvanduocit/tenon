import XCTest
@testable import TenonCore

/// `tenon.views` — the plugin surface that fills a slot (`SlotContent.pluginView`). It is
/// free tier (UI contribution, VISION §5), keyed by viewID so one plugin can offer several.
final class PluginViewsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-views-\(UUID().uuidString)")
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

    func testPermissionlessPluginContributesSlotViews() throws {
        try writePlugin(
            dir: "viewer",
            manifest: #"{"name":"viewer","version":"1","permissions":[]}"#,
            js: """
            tenon.views.register("graph", { title: "Git Graph" });
            tenon.views.set("graph", { items: [ {id:"c1", label:"commit one"}, {id:"c2", label:"commit two", icon:"circle"} ] });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        let views = host.pluginViews.filter { $0.pluginName == "viewer" }
        XCTAssertEqual(views.map(\.viewID), ["graph"])
        XCTAssertEqual(views.first?.title, "Git Graph")
        XCTAssertEqual(views.first?.items.map(\.label), ["commit one", "commit two"])
        XCTAssertEqual(views.first?.items.last?.icon, "circle")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [], "views are free-tier UI — no permission needed")
    }

    func testViewSelectRoutesToTheHandler() throws {
        try writePlugin(
            dir: "viewer",
            manifest: #"{"name":"viewer","version":"1"}"#,
            js: """
            tenon.views.register("files", { title: "Files" });
            tenon.views.set("files", { items: [ {id:"/a", label:"a"} ] });
            tenon.views.onSelect("files", function (id) { tenon.log("picked " + id); });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.invokeViewSelect(pluginName: "viewer", viewID: "files", itemID: "/a"))
        XCTAssertTrue(host.log.contains("[viewer] picked /a"), "log: \(host.log)")
    }

    func testOnePluginCanProvideSeveralViews() throws {
        try writePlugin(
            dir: "multi",
            manifest: #"{"name":"multi","version":"1"}"#,
            js: """
            tenon.views.register("graph", { title: "Graph" });
            tenon.views.set("graph", { items: [] });
            tenon.views.register("log", { title: "Log" });
            tenon.views.set("log", { items: [ {id:"1", label:"entry"} ] });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        let ids = host.pluginViews.filter { $0.pluginName == "multi" }.map(\.viewID).sorted()
        XCTAssertEqual(ids, ["graph", "log"])
    }

    /// Disabling the providing plugin removes its views — the slot the shell was rendering
    /// falls back to a placeholder, keeping the empty state valid (VISION §6).
    func testDisablingAPluginRemovesItsViews() throws {
        try writePlugin(
            dir: "viewer",
            manifest: #"{"name":"viewer","version":"1"}"#,
            js: #"tenon.views.register("graph", { title: "Graph" }); tenon.views.set("graph", { items: [] });"#
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()
        XCTAssertEqual(host.pluginViews.count, 1)

        host.setEnabled(false, pluginNamed: "viewer")

        XCTAssertTrue(host.pluginViews.isEmpty, "a disabled plugin contributes no views")
    }
}
