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

        let pool = SurfacePool(backendName: "Sidebar snapshot") { _, _ in
            StubTerminalSurface()
        }
        PaneViewSnapshotWriter.write(
            bare: WorkspaceSidebarView(
                store: store,
                pool: pool,
                closeCoordinator: ShellCloseCoordinator(store: store, pool: pool),
                isCollapsed: size.width <= SidebarResize.collapsedWidth
            )
            .frame(width: size.width, height: size.height),
            size: size,
            to: path
        )
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
