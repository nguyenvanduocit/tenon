// @domain: pane-chrome
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// Dev-only offscreen capture of the three states a pane can report on its own title.
///
///     TENON_PANE_RENAME_SNAPSHOT=/tmp/pane-rename.png swift run tenon
///
/// Three panes, side by side: one being renamed by hand, one generating, one that failed.
/// It photographs the real `SpatialCanvasView` over a real `WorkspaceStore`, because the
/// thing worth checking is geometry — a rename field that overlaps the close control, a
/// `Naming…` that truncates to `Nam…`, a glyph whose baseline leaves the title. `swift test`
/// proves the words; only a render proves they fit.
///
/// `TENON_PANE_RENAME_SNAPSHOT_SIZE=WxH` changes the canvas (default 1000×260 — the header
/// band is what is being read, so the panes are deliberately short).
enum PaneRenameSnapshot {
    @MainActor
    static func renderIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TENON_PANE_RENAME_SNAPSHOT"], !path.isEmpty else {
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await render(to: path, environment: environment)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @MainActor
    private static func render(to path: String, environment: [String: String]) async {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let workspacePath = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let slots = (0..<3).map { column in
            WorkspaceSlot(
                rect: GridRect(x: column * 4, y: 0, width: 4, height: 12),
                content: .terminal
            )
        }
        let tab = TenonCore.Tab(slots: slots, activeSlotID: slots[0].id)
        let workspace = Workspace(
            name: workspacePath.lastPathComponent,
            path: workspacePath,
            tabs: [tab],
            activeTabID: tab.id
        )
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )
        )
        let pool = SurfacePool(backendName: "Rename snapshot") { _, _ in StubTerminalSurface() }
        let webPool = PluginWebSurfacePool()
        let userInterface = PluginUIState()
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-rename-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let intentRuntime: AppIntentRuntime
        let host: PluginHost
        do {
            intentRuntime = try AppIntentRuntime(
                kernel: IntentKernelComponents(
                    persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                    confirmationAuthorizer: userInterface.confirmationAuthorizer()
                ),
                workspaceStore: store,
                terminalSurfaces: pool,
                webSurfaces: webPool,
                userInterface: userInterface
            )
            host = try PluginHost(
                pluginsRoot: stateRoot.appendingPathComponent("plugins", isDirectory: true),
                stateRoot: stateRoot,
                kernel: intentRuntime.kernel
            )
        } catch {
            FileHandle.standardError.write(
                Data("pane-rename-snapshot: cannot build the app graph: \(error)\n".utf8)
            )
            exit(2)
        }
        defer { withExtendedLifetime(intentRuntime) {} }

        // The states are set through the coordinator, so the picture is of what the running
        // app would produce and not of three strings arranged to look like it. The generating
        // pane holds a generator that never answers, which is exactly what a slow Companion
        // looks like from the header's side.
        let renamer = PaneRenameCoordinator(
            store: store,
            pool: pool,
            generator: SnapshotTitleGenerator(),
            // Long enough that the failure is still on the title when the shutter opens; the
            // shipping linger would clear it mid-capture.
            failureLinger: .seconds(600)
        )
        renamer.beginManual(slotID: slots[0].id, currentTitle: "Ghostty — shell")
        renamer.beginAI(slotID: slots[1].id, currentTitle: "Ghostty — shell")
        // The third pane fails through the real path — a generator that throws — rather than
        // through a back door that sets the state directly. No agent installed is the most
        // common way this fails on a fresh machine.
        renamer.beginAI(slotID: slots[2].id, currentTitle: SnapshotTitleGenerator.failingTitle)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case .failed = renamer.phase(for: slots[2].id) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let size = PluginViewSnapshot.size(from: environment["TENON_PANE_RENAME_SNAPSHOT_SIZE"])
            ?? CGSize(width: 1_000, height: 260)
        PaneViewSnapshotWriter.write(
            bare: SpatialCanvasView(
                tab: tab,
                workspaceID: workspace.id,
                workspacePath: workspacePath,
                allLiveSlotIDs: Set(slots.map(\.id)),
                activeSlotID: slots[0].id,
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
                pluginViewSections: [],
                webSurfaceTitles: [:],
                paneAttention: [:],
                paneHeaders: [:],
                paneHeaderStore: PaneHeaderStore(),
                paneRenames: renamer.phases,
                paneRenamer: renamer,
                router: DragRouter(),
                automation: AutomationScheduler(),
                automationSchedulesEnabled: false,
                automationActions: AutomationPaneActions(
                    runNow: { _, _ in },
                    setPaused: { _, _, _ in },
                    createWithAI: {},
                    openRunDetail: { _, _ in }
                )
            )
            .frame(width: size.width, height: size.height)
            .background(TenonTheme.ink),
            size: size,
            to: path
        )
    }
}

/// A Companion that stalls for one pane and fails for the other, so the capture holds both
/// states at once without either being staged.
private struct SnapshotTitleGenerator: PaneTitleGenerating {
    static let failingTitle = "Ghostty — no agent"

    func generateTitle(from brief: PaneRenameBrief) async throws -> String {
        guard brief.currentTitle != Self.failingTitle else {
            throw CompanionTaskFailure.unavailable
        }
        try await Task.sleep(for: .seconds(600))
        return ""
    }
}
