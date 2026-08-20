// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore

/// Dev-only offscreen snapshot of the real workspace sidebar, so the density of its footer
/// can be SEEN on a headless machine rather than inferred from a passing test.
///
///     TENON_SIDEBAR_SNAPSHOT=/tmp/sidebar.png swift run tenon
///     TENON_SIDEBAR_SNAPSHOT_SIZE=110x420 TENON_SIDEBAR_SNAPSHOT=/tmp/narrow.png swift run tenon
///     TENON_SIDEBAR_SNAPSHOT_SIZE=48x420 TENON_SIDEBAR_SNAPSHOT=/tmp/rail.png swift run tenon
///
/// The three sizes worth photographing are the sidebar's own bounds: the 48 pt collapsed
/// rail, `SidebarResize.minWidth` (110), and `SidebarResize.defaultWidth` (232). What is
/// mounted is `WorkspaceSidebarView` over a real `WorkspaceStore` — the same view the shell
/// mounts, over the same mutations — so the picture is what the sidebar shows.
enum SidebarSnapshot {
    @MainActor
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TENON_SIDEBAR_SNAPSHOT"], !path.isEmpty else { return }
        render(to: path, size: size(env["TENON_SIDEBAR_SNAPSHOT_SIZE"]))
    }

    @MainActor
    private static func render(to path: String, size: CGSize) -> Never {
        _ = NSApplication.shared

        let store = WorkspaceStore()
        // Long names on purpose: a workspace whose name is clipped at 110 pt is the case
        // where a footer that also clips would be easy to miss. A full column of them on
        // purpose too — a sidebar is judged by whether one row can be picked out of the
        // others at a glance, which one or two rows cannot show.
        store.addWorkspace(name: "supervision-experiments", path: folder("supervision"))
        store.addWorkspace(name: "tenon", path: folder("tenon"))
        store.addWorkspace(name: "payments", path: folder("payments"))
        store.addWorkspace(name: "docs-site", path: folder("docs-site"))
        store.addWorkspace(name: "infra", path: folder("infra"))
        store.addWorkspace(name: "carlens", path: folder("carlens"))
        store.addWorkspace(name: "invest", path: folder("invest"))
        // Sleep Workspace: one backgrounded row, so the sidebar's "Backgrounded" section is
        // visible in the same photograph rather than needing a second snapshot run.
        if let invest = store.catalog.workspaces.first(where: { $0.name == "invest" }) {
            store.setVisibility(invest.id, to: .background)
        }

        var stubs: [UUID: StubTerminalSurface] = [:]
        let pool = SurfacePool(backendName: "Sidebar snapshot") { slotID, _ in
            let stub = StubTerminalSurface()
            stubs[slotID] = stub
            return stub
        }
        let agentPanes = AgentPaneRoster()
        stage(store: store, pool: pool, roster: agentPanes, stubs: { stubs })

        PaneViewSnapshotWriter.write(
            bare: WorkspaceSidebarView(
                store: store,
                pool: pool,
                closeCoordinator: ShellCloseCoordinator(store: store, pool: pool),
                sleepAction: WorkspaceSleepAction(),
                agentPanes: agentPanes,
                isCollapsed: size.width <= SidebarResize.collapsedWidth
            )
            .frame(width: size.width, height: size.height),
            size: size,
            to: path
        )
    }

    /// Puts an agent in the first four workspaces, one per attention state, and drives each
    /// one there through the real `PaneActivity` machine rather than asserting the state.
    ///
    /// The titles are the length that decides the picture: `supervision-experiments` gets a
    /// sentence far wider than a 110 pt row, which is the case the line has to truncate, and
    /// `docs-site` gets one that fits at both widths, which is the case it must leave whole.
    /// The last three workspaces are left agentless on purpose — a sidebar where every row
    /// names an agent cannot show that a row without one still reads as its tab count.
    @MainActor
    private static func stage(
        store: WorkspaceStore,
        pool: SurfacePool,
        roster: AgentPaneRoster,
        stubs: () -> [UUID: StubTerminalSurface]
    ) {
        let staged: [(title: String, state: PaneActivityState)] = [
            ("Fixing the token refresh race in the auth middleware", .working),
            ("Auditing the intent catalog", .finishedUnseen),
            ("Waiting on the migration review", .idle),
            ("Porting the board", .exited),
        ]
        let now = Date(timeIntervalSinceReferenceDate: 0)

        for (workspace, staged) in zip(store.catalog.workspaces, staged) {
            guard let slotID = workspace.tabs.first?.slots.first?.id else { continue }
            _ = pool.surface(for: slotID, workspacePath: workspace.path)
            guard let stub = stubs()[slotID],
                  let token = pool.surfaceToken(for: slotID)
            else { continue }

            pool.setTitle(staged.title, for: slotID)
            roster.ingest(
                AgentHookEvent(
                    paneID: slotID,
                    surfaceToken: token,
                    provider: .claude,
                    sessionID: "snapshot-\(workspace.name)",
                    transcriptPath: nil,
                    hookEventName: "SessionStart",
                    agentID: nil
                )
            )

            switch staged.state {
            case .working:
                // Left changing rather than changed three times: the activity poll goes on
                // running through the render's layout pass, and a screen that stopped moving
                // would settle to `idle` before the picture was taken.
                stub.screenKeepsChanging = true
                pool.pollActivity(at: now)
            case .idle, .seen:
                for tick in 0..<4 {
                    pool.pollActivity(at: now.addingTimeInterval(Double(tick)))
                }
            case .finishedUnseen:
                for tick in 0..<4 {
                    pool.pollActivity(at: now.addingTimeInterval(Double(tick)))
                }
                stub.commandFinishedCount = 1
                pool.pollActivity(at: now.addingTimeInterval(5))
            case .exited:
                stub.processExited = true
                pool.pollActivity(at: now.addingTimeInterval(1))
            }

            // What the machine actually reached, not what the fixture asked for. A picture
            // cannot be read back for its states, so the run says them out loud — a staging
            // that silently lands on the wrong state would otherwise photograph as a bug in
            // the view.
            let reached = pool.paneAttention[slotID]?.state
            FileHandle.standardError.write(Data(
                "snapshot: \(workspace.name) staged \(staged.state), reached \(reached.map(String.init(describing:)) ?? "none")\n"
                    .utf8
            ))
        }
    }

    private static func folder(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/tenon/projects/\(name)", isDirectory: true)
    }

    private static func size(_ value: String?) -> CGSize {
        guard let parts = value?.split(separator: "x"), parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else {
            return CGSize(width: SidebarResize.defaultWidth, height: 420)
        }
        return CGSize(width: width, height: height)
    }
}
