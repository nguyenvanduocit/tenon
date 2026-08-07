import AppKit
import Foundation
import XCTest
@testable import TenonApp
@testable import TenonCore
import TenonIntentCore

/// The PLUGIN half of the pane header action route, driven through the real canvas.
///
/// `PaneHeaderSchemaTests` proves a plugin's `onSelect`/`onSubmit` deliver what they are handed.
/// What is proved here is the step before that, and it is the step that has no other witness:
/// the canvas takes one `PaneHeaderAction` — an item id and an optional string, with no kind on
/// it — and has to decide, alone, which of the two contracts it travels back on and whose view
/// it belongs to. That decision is the whole of what makes the browser plugin's address bar
/// work: type an address, press return, navigate. Get it wrong and every control still looks
/// right, still highlights, still clicks, and simply reports through the wrong handler to
/// possibly the wrong pane — which is exactly the class of defect a green suite could not tell
/// from a working one until this file existed.
///
/// The assertions read the PLUGIN'S own log, because that is the only place that can say all
/// four facts at once: which handler ran, with what value, in which instance, inside which
/// plugin.
@MainActor
final class PluginPaneHeaderRouteTests: XCTestCase {
    /// A `textfield` commits; everything else selects.
    ///
    /// The discriminator is a property of the item's KIND, read off the header the plugin
    /// actually published — never a guess about ids and never a flag on the action — so the
    /// test publishes one of every interactive kind under one view and clicks all five.
    func testATextfieldCommitsThroughSubmitAndEveryOtherControlReportsThroughSelect()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let card = try XCTUnwrap(fixture.card(for: fixture.firstPaneID))

        card.onHeaderAction?(
            fixture.firstPaneID,
            PaneHeaderAction(itemID: "go", value: "https://tenon.dev")
        )
        card.onHeaderAction?(
            fixture.firstPaneID,
            PaneHeaderAction(itemID: "layout", value: "flat")
        )
        card.onHeaderAction?(
            fixture.firstPaneID,
            PaneHeaderAction(itemID: "sort", value: "size")
        )
        card.onHeaderAction?(fixture.firstPaneID, PaneHeaderAction(itemID: "hidden"))
        card.onHeaderAction?(fixture.firstPaneID, PaneHeaderAction(itemID: "reveal"))

        // Compared as a SET, deliberately. `routePluginHeaderAction` sends each action into its
        // own unstructured `Task`, so five clicks are five tasks that each suspend into the
        // host actor and then the plugin runtime actor. Swift guarantees no ordering between
        // them, and the product does not need one: a header control reports its own fact, not a
        // position in a sequence. Asserting arrival order would pin an implementation accident
        // and go red under load — which is exactly what it did before this comment existed.
        let reported = await fixture.settle(untilLines: 5)
        XCTAssertEqual(
            Set(reported),
            [
                "submit:go=https://tenon.dev",
                "select:layout=flat",
                "select:sort=size",
                "select:hidden=null",
                "select:reveal=null",
            ],
            "a field commits its text through onSubmit and the four pickers and buttons "
                + "report through onSelect, each carrying its own value or nothing at all"
        )
        XCTAssertEqual(
            reported.count,
            5,
            "five clicks must report five times — a set comparison alone would let a duplicate "
                + "hide a lost report"
        )
    }

    /// The same click, one pane over, must not land in this one.
    ///
    /// Two panes of one instanced view is the T-012 defect's shape, and a header makes it
    /// reachable by mouse: the two chrome strips are identical, the item ids are identical, and
    /// the only thing separating them is the instance the canvas resolves from the slot the
    /// card belongs to. A second plugin publishing the same view id under the same item ids is
    /// the other half — the route reads the slot's own plugin, not the first section that
    /// happens to answer to "pane".
    func testAHeaderClickReachesItsOwnInstanceAndItsOwnPluginAndNoOther() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let first = try XCTUnwrap(fixture.card(for: fixture.firstPaneID))
        let second = try XCTUnwrap(fixture.card(for: fixture.secondPaneID))
        let other = try XCTUnwrap(fixture.card(for: fixture.otherPluginPaneID))

        first.onHeaderAction?(fixture.firstPaneID, PaneHeaderAction(itemID: "go", value: "one"))
        second.onHeaderAction?(
            fixture.secondPaneID,
            PaneHeaderAction(itemID: "go", value: "two")
        )
        other.onHeaderAction?(
            fixture.otherPluginPaneID,
            PaneHeaderAction(itemID: "go", value: "three")
        )

        // A SET again, and for the same reason as the sibling above: three clicks are three
        // independent tasks racing into two actors. What this test is about is WHICH instance
        // and WHICH plugin each commit reached — membership — never the order they landed in.
        _ = await fixture.settle(untilLines: 3)
        XCTAssertEqual(
            Set(fixture.reportedInstances(of: Self.headerPluginID)),
            [
                "submit:go=one@\(fixture.firstPaneID.uuidString)",
                "submit:go=two@\(fixture.secondPaneID.uuidString)",
            ],
            "each pane's commit carries its OWN instance id — a sibling pane's chrome is not "
                + "this pane's chrome, however identical it looks"
        )
        XCTAssertEqual(
            fixture.reportedInstances(of: Self.otherPluginID),
            ["submit:go=three@\(fixture.otherPluginPaneID.uuidString)"],
            "the third commit went to the plugin that owns that slot, and only to it"
        )
    }

    // MARK: - Fixture

    private static let headerPluginID: PluginID = "dev.test.header-route"
    private static let otherPluginID: PluginID = "dev.test.header-route-other"

    /// The view both plugins publish: one of every interactive kind, all five under ids that
    /// collide across plugins and instances on purpose, and one handler per contract that
    /// reports everything it was given.
    private static func mainSource(reportingInstance: Bool) -> String {
        let suffix = reportingInstance ? #" + "@" + instanceID"# : ""
        return """
        tenon.views.register("pane", { title: "Pane", instanced: true });
        function publish(instanceID) {
          tenon.views.set("pane", {
            header: {
              trailing: [
                { type: "textfield", id: "go", value: "", placeholder: "Address", flex: true },
                { type: "segmented", id: "layout", selection: "tree", segments: [
                    { value: "tree", label: "Tree" },
                    { value: "flat", label: "Flat" }
                ] },
                { type: "menu", id: "sort", systemName: "arrow.up.arrow.down", entries: [
                    { value: "name", label: "Name" },
                    { value: "size", label: "Size" }
                ] },
                { type: "toggle", id: "hidden", systemName: "eye", isOn: false },
                { type: "iconButton", id: "reveal", systemName: "arrow.up.forward.app" }
              ]
            }
          }, instanceID);
        }
        tenon.views.onOpen("pane", function (instanceID) { publish(instanceID); });
        tenon.views.onSelect("pane", function (itemID, value, instanceID) {
          tenon.log("select:" + itemID + "=" + value\(suffix));
        });
        tenon.views.onSubmit("pane", function (itemID, text, instanceID) {
          tenon.log("submit:" + itemID + "=" + text\(suffix));
        });
        """
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-header-route-\(UUID().uuidString)", isDirectory: true)
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-header-route-state-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateRoot)
        }
        try install(
            pluginID: Self.headerPluginID,
            name: "header-route",
            source: Self.mainSource(reportingInstance: true),
            under: root
        )
        try install(
            pluginID: Self.otherPluginID,
            name: "header-route-other",
            source: Self.mainSource(reportingInstance: true),
            under: root
        )

        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let otherPluginPaneID = UUID()
        let tab = TenonCore.Tab(
            slots: [
                slot(firstPaneID, x: 0, y: 0, plugin: Self.headerPluginID),
                slot(secondPaneID, x: 4, y: 0, plugin: Self.headerPluginID),
                slot(otherPluginPaneID, x: 8, y: 0, plugin: Self.otherPluginID),
            ],
            activeSlotID: firstPaneID
        )
        let workspace = Workspace(
            name: "Test",
            path: root,
            tabs: [tab],
            activeTabID: tab.id
        )
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )
        )
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
        let webPool = PluginWebSurfacePool()
        let userInterface = PluginUIState()
        let intentRuntime = try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: webPool,
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: root,
            stateRoot: stateRoot,
            kernel: intentRuntime.kernel,
            authorization: .bundledInventory
        )
        addTeardownBlock { await host.shutdown() }
        try await host.loadAll()
        // The app's own path for opening an instanced view's per-pane instance. Without it a
        // pane has no instance, and a route that resolved the singleton instead would pass a
        // test that meant nothing.
        await host.reconcileViewInstances(from: store.catalog)
        let published = await settle {
            host.pluginViews.filter { $0.instanceID != nil }.count == 3
        }
        XCTAssertTrue(published, "\(host.pluginViews.map(\.id))")

        let paneHeaders = PaneHeaderStore()
        let router = DragRouter()
        let container = FlippedHeaderRouteView(
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 1_200)
        )
        let canvas = SpatialCanvasNSView(frame: container.bounds)
        container.addSubview(canvas)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        canvas.configure(
            tab: tab,
            workspacePath: root,
            allLiveSlotIDs: Set(tab.slots.map(\.id)),
            activeSlotID: firstPaneID,
            store: store,
            pool: pool,
            agentLens: AgentLensPool(),
            webPool: webPool,
            host: host,
            intentRuntime: intentRuntime,
            palette: CommandPaletteState(
                storeURL: stateRoot.appendingPathComponent("frecency.json")
            ),
            agentSuggestions: [],
            editorStates: EditorPaneStateStore(),
            pluginSnapshots: [],
            pluginViewSections: host.pluginViews,
            webSurfaceTitles: [:],
            paneAttention: [:],
            paneHeaders: paneHeaders.headers,
            paneHeaderStore: paneHeaders,
            router: router,
            automation: AutomationScheduler(),
            automationSchedulesEnabled: true,
            automationActions: AutomationPaneActions(
                runNow: { _, _ in },
                setPaused: { _, _, _ in },
                createWithAI: {}
            )
        )
        canvas.layout()
        // Everything the plugins said while loading and opening. The assertions read what
        // arrives AFTER this, so a route that delivered nothing cannot borrow a startup line.
        let baseline = host.log.count
        return Fixture(
            window: window,
            canvas: canvas,
            host: host,
            baseline: baseline,
            firstPaneID: firstPaneID,
            secondPaneID: secondPaneID,
            otherPluginPaneID: otherPluginPaneID
        )
    }

    private func install(
        pluginID: PluginID,
        name: String,
        source: String,
        under root: URL
    ) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "\(pluginID.rawValue)",
          "name": "\(name)",
          "version": "1",
          "permissions": [],
          "intents": { "uses": [], "provides": [] }
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func slot(_ id: UUID, x: Int, y: Int, plugin: PluginID) -> WorkspaceSlot {
        WorkspaceSlot(
            id: id,
            rect: GridRect(x: x, y: y, width: 4, height: 12),
            content: .pluginView(pluginID: plugin, viewID: "pane")
        )
    }

    private func settle(
        attempts: Int = 400,
        _ operation: @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private struct Fixture {
        let window: NSWindow
        let canvas: SpatialCanvasNSView
        let host: PluginHost
        let baseline: Int
        let firstPaneID: UUID
        let secondPaneID: UUID
        let otherPluginPaneID: UUID

        @MainActor
        func card(for id: UUID) -> SpatialSlotCardView? {
            canvas.subviews
                .compactMap { $0 as? SpatialSlotCardView }
                .first { $0.slotID == id }
        }

        /// Every line the plugins logged since the fixture was built, in arrival order, with
        /// the runtime's `[name]` attribution and the instance suffix stripped.
        @MainActor
        func reported() -> [String] {
            host.log.dropFirst(baseline).compactMap { line in
                guard let body = attributedBody(of: line) else { return nil }
                return body.split(separator: "@", maxSplits: 1).first.map(String.init)
            }
        }

        /// The same lines, keeping the instance suffix, for one plugin only.
        @MainActor
        func reportedInstances(of pluginID: PluginID) -> [String] {
            let name = pluginID == PluginPaneHeaderRouteTests.headerPluginID
                ? "header-route"
                : "header-route-other"
            return host.log.dropFirst(baseline).compactMap { line in
                guard line.hasPrefix("[\(name)] ") else { return nil }
                return String(line.dropFirst(name.count + 3))
            }
        }

        /// A click travels through a `Task` onto the plugin's own thread and back, so the
        /// assertion waits for the FACT — the lines arriving — with a bounded timeout that
        /// reports what did arrive when they do not.
        @MainActor
        func settle(untilLines count: Int) async -> [String] {
            for _ in 0 ..< 400 {
                if reported().count >= count { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return reported()
        }

        @MainActor
        private func attributedBody(of line: String) -> String? {
            for name in ["header-route-other", "header-route"]
                where line.hasPrefix("[\(name)] ")
            {
                return String(line.dropFirst(name.count + 3))
            }
            return nil
        }
    }
}

private final class FlippedHeaderRouteView: NSView {
    override var isFlipped: Bool { true }
}
