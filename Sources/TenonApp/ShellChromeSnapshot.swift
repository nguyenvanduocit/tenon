// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// Dev-only offscreen snapshot of the **whole shell**, at a chosen chrome order.
///
///     TENON_CHROME_SNAPSHOT=/tmp/top.png swift run tenon
///     TENON_CHROME_SNAPSHOT_ORDER=tabsOnBottom TENON_CHROME_SNAPSHOT=/tmp/bottom.png swift run tenon
///     TENON_CHROME_SNAPSHOT_SIDEBAR=collapsed TENON_CHROME_SNAPSHOT_SIZE=900x560 …
///
/// `TitleBarSnapshot` photographs one row tightly, which is the right picture for asking how
/// a label sits beside the traffic lights. It is the wrong picture for a *swap*: two strips
/// trading places is a claim about both rows at once, and a crop of one of them cannot show
/// it. So this mounts the real `ContentView` — the same composition the app runs, at the same
/// order the preference would select — and photographs the window.
///
/// Two known limits, stated so nobody reads more into the file than it can carry. The order
/// is a launch argument rather than a live toggle, because each renderer exits when it is
/// done, so the two orders are two runs. And the picture is not byte-stable between machines:
/// `ContentView` scans for live agent launches, so its suggestions differ. Compare rows and
/// geometry, never bytes.
enum ShellChromeSnapshot {
    @MainActor
    static func renderIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TENON_CHROME_SNAPSHOT"], !path.isEmpty else { return }
        do {
            try render(
                to: path,
                size: size(environment["TENON_CHROME_SNAPSHOT_SIZE"]),
                sidebarVisible: environment["TENON_CHROME_SNAPSHOT_SIDEBAR"] != "collapsed",
                order: environment["TENON_CHROME_SNAPSHOT_ORDER"] == "tabsOnBottom"
                    ? .tabsOnBottom
                    : .tabsOnTop
            )
        } catch {
            FileHandle.standardError.write(Data("chrome snapshot: \(error)\n".utf8))
            exit(2)
        }
    }

    @MainActor
    private static func render(
        to path: String,
        size: CGSize,
        sidebarVisible: Bool,
        order: ShellChromeOrder
    ) throws -> Never {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-snapshot-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let stateRoot = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        let workspacePath = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let store = WorkspaceStore()
        store.addWorkspace(name: workspacePath.lastPathComponent, path: workspacePath)
        while (store.catalog.activeWorkspace?.tabs.count ?? 0) < 3 {
            store.newTab()
        }
        if let first = store.catalog.activeWorkspace?.tabs.first?.id {
            store.selectTab(first)
        }

        let pool = SurfacePool(backendName: "Chrome snapshot") { _, _ in StubTerminalSurface() }
        let webPool = PluginWebSurfacePool()
        let userInterface = PluginUIState()
        let runtime = try AppIntentRuntime(
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
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: runtime.kernel,
            authorization: .bundledInventory
        )
        defer { withExtendedLifetime(runtime) {} }

        PaneViewSnapshotWriter.write(
            bare: ContentView(
                host: host,
                store: store,
                pool: pool,
                closeCoordinator: ShellCloseCoordinator(store: store, pool: pool),
                paneRenamer: PaneRenameCoordinator(
                    store: store,
                    pool: pool,
                    generator: nil
                ),
                agentLens: AgentLensPool(),
                webPool: webPool,
                intentRuntime: runtime,
                router: DragRouter(),
                palette: CommandPaletteState(
                    storeURL: stateRoot.appendingPathComponent("frecency.json")
                ),
                quickCommands: QuickCommandStore(
                    defaults: UserDefaults(suiteName: "chrome-snapshot-\(UUID().uuidString)")!,
                    storageKey: "quick"
                ),
                pluginUI: userInterface,
                automation: AutomationScheduler(),
                resourceMonitor: nil,
                chromeOrder: order,
                automationSchedulesEnabled: false,
                automationActions: AutomationPaneActions(
                    runNow: { _, _ in },
                    setPaused: { _, _, _ in },
                    createWithAI: {},
                    openRunDetail: { _, _ in }
                )
            )
            .frame(width: size.width, height: size.height),
            size: size,
            to: path
        )
    }

    private static func size(_ value: String?) -> CGSize {
        guard let parts = value?.split(separator: "x"), parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else {
            return CGSize(width: 1100, height: 620)
        }
        return CGSize(width: width, height: height)
    }
}
