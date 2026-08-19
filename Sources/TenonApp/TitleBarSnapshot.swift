// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// Dev-only offscreen snapshot of the real title bar, so what its identity zone does with a
/// long workspace name can be SEEN on a headless machine rather than inferred.
///
///     TENON_TITLEBAR_SNAPSHOT=/tmp/titlebar.png swift run tenon
///     TENON_TITLEBAR_SNAPSHOT_SIDEBAR=expanded TENON_TITLEBAR_SNAPSHOT=/tmp/expanded.png swift run tenon
///     TENON_TITLEBAR_SNAPSHOT_WORKSPACE=interviewassistant TENON_TITLEBAR_SNAPSHOT=/tmp/long.png swift run tenon
///
///     TENON_TITLEBAR_SNAPSHOT_ORDER=tabsOnBottom TENON_TITLEBAR_SNAPSHOT=/tmp/status.png swift run tenon
///
/// `TENON_TITLEBAR_SNAPSHOT_SIZE=WxH` changes the row (default 900 × `TenonTheme.titleBarHeight`),
/// and `TENON_TITLEBAR_SNAPSHOT_SIDEBAR` picks which state the zone is photographed in —
/// collapsed by default, since that is the state where the zone carries a workspace name.
/// `TENON_TITLEBAR_SNAPSHOT_ORDER` picks which strip the row's content zone is holding, so the
/// swap can be seen from both sides; it defaults to the shipped order, tabs in the title bar.
/// What is mounted is `ShellTitleBar` itself over a real `WorkspaceStore` and a real host, so
/// the picture is the row the shell draws. For both rows at once — which is the only way to
/// see a swap — use `ShellChromeSnapshot`.
enum TitleBarSnapshot {
    @MainActor
    static func renderIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TENON_TITLEBAR_SNAPSHOT"], !path.isEmpty else { return }
        do {
            try render(
                to: path,
                size: size(environment["TENON_TITLEBAR_SNAPSHOT_SIZE"]),
                sidebarVisible: environment["TENON_TITLEBAR_SNAPSHOT_SIDEBAR"] == "expanded",
                order: environment["TENON_TITLEBAR_SNAPSHOT_ORDER"] == "tabsOnBottom"
                    ? .tabsOnBottom
                    : .tabsOnTop,
                workspaceName: environment["TENON_TITLEBAR_SNAPSHOT_WORKSPACE"]
                    ?? "supervision-experiments"
            )
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(2)
        }
    }

    @MainActor
    private static func render(
        to path: String,
        size: CGSize,
        sidebarVisible: Bool,
        order: ShellChromeOrder,
        workspaceName: String
    ) throws -> Never {
        _ = NSApplication.shared

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlebar-snapshot-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let stateRoot = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        let store = WorkspaceStore()
        store.addWorkspace(
            name: workspaceName,
            path: URL(fileURLWithPath: "/Users/tenon/projects/\(workspaceName)", isDirectory: true)
        )
        while (store.catalog.activeWorkspace?.tabs.count ?? 0) < 3 {
            store.newTab()
        }

        let pool = SurfacePool(backendName: "Title bar snapshot") { _, _ in
            StubTerminalSurface()
        }
        let userInterface = PluginUIState()
        let runtime = try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: PluginWebSurfacePool(),
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: runtime.kernel,
            authorization: .bundledInventory
        )

        let router = DragRouter()
        let palette = CommandPaletteState(
            storeURL: stateRoot.appendingPathComponent("frecency.json")
        )

        PaneViewSnapshotWriter.write(
            bare: ShellTitleBar(
                store: store,
                pool: pool,
                quickCommands: QuickCommandStore(
                    defaults: UserDefaults(
                        suiteName: "titlebar-snapshot-\(UUID().uuidString)"
                    )!,
                    storageKey: "quick"
                ),
                sidebarVisible: sidebarVisible,
                sidebarWidth: TenonTheme.sidebarWidth,
                onToggleSidebar: {}
            ) {
                ShellChromeOccupant(
                    strip: order.titleBarStrip,
                    edge: .top,
                    host: host,
                    store: store,
                    pool: pool,
                    closeCoordinator: ShellCloseCoordinator(store: store, pool: pool),
                    intentRuntime: runtime,
                    router: router,
                    palette: palette
                )
            }
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
            return CGSize(width: 900, height: TenonTheme.titleBarHeight)
        }
        return CGSize(width: width, height: height)
    }
}
