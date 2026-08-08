// @domain: plugin-contributions
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// Renders one plugin's view tree to a PNG with no window, so layout defects stop passing
/// as green.
///
///     TENON_PLUGINS_DIR=plugins TENON_TRUST_PLUGIN_INVENTORY=1 \
///     TENON_VIEW_SNAPSHOT='dev.tenon.kanban/board:/tmp/board.png' swift run tenon
///
/// The argument is `<plugin-id>/<view-id>:<output-path>`. `TENON_VIEW_SNAPSHOT_SIZE=WxH`
/// changes the pane size (default 900×620) and `TENON_VIEW_SNAPSHOT_WORKSPACE` sets the
/// workspace the plugin reads; both are optional.
///
/// Why this exists (T-063, measured on T-055): `swift test` proves a view tree's *shape* and
/// nothing about its geometry. A kanban board passed 24 tests and rendered as scattered cards
/// floating at different heights — an `hstack` centring its columns, an empty column
/// collapsing to the width of its own heading, card titles wrapping into a column of single
/// words. An adversarial review panel read that diff and found none of it. One offscreen
/// render showed all three at once.
///
/// No window and no Screen Recording grant: `NSHostingView` + `layoutSubtreeIfNeeded` +
/// `cacheDisplay`, the same recipe `DiffSnapshot` uses. `screencapture` is not an option here
/// — this process has no capture permission and fails with "could not create image from
/// window".
///
/// The host is real and the inventory is the one the app would load: same
/// `AppStatePaths.resolve`, same manifests, same JavaScript, same `PluginSlotView`. Only the
/// plugin *state* root is a throwaway, so rendering a picture never mutates what the running
/// app has saved.
enum PluginViewSnapshot {
    @MainActor
    static func renderIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TENON_VIEW_SNAPSHOT"], !raw.isEmpty else { return }
        guard let request = Request(raw) else {
            fail("TENON_VIEW_SNAPSHOT must read <plugin-id>/<view-id>:<path>, got \(raw)")
        }
        // A snapshot is the whole run: this blocks the main thread until the PNG is on disk
        // and then exits, exactly as the diff snapshot does, so no window ever opens.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await render(request, environment: environment)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    // MARK: - Request

    struct Request: Equatable {
        let pluginID: PluginID
        let viewID: String
        let outputPath: String

        /// `<plugin-id>/<view-id>:<path>`. Split on the FIRST colon and the FIRST slash: a
        /// plugin id is a dotted DNS name and a view id is a bare identifier, so neither can
        /// contain either character, and everything after the colon is the path — which may
        /// contain both.
        init?(_ raw: String) {
            guard let colon = raw.firstIndex(of: ":") else { return nil }
            let target = String(raw[raw.startIndex ..< colon])
            let path = String(raw[raw.index(after: colon)...])
            guard let slash = target.firstIndex(of: "/") else { return nil }
            let viewID = String(target[target.index(after: slash)...])
            // The id is validated here rather than at the render, so a typo fails with the
            // usage message instead of halfway through booting a plugin host.
            guard let pluginID = try? PluginID(
                String(target[target.startIndex ..< slash])
            ), !viewID.isEmpty, !path.isEmpty else { return nil }
            self.pluginID = pluginID
            self.viewID = viewID
            outputPath = path
        }
    }

    /// `WxH`, ignored when it is not two positive numbers.
    static func size(from raw: String?) -> CGSize? {
        guard let raw else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Render

    @MainActor
    private static func render(_ request: Request, environment: [String: String]) async {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let paths: AppStatePaths
        do {
            paths = try AppStatePaths.resolve(environment: environment)
        } catch {
            fail("cannot resolve the plugin inventory: \(error)")
        }

        // Throwaway plugin state: a snapshot must never write into what the running app has
        // saved, and it must not inherit a pane's remembered scroll position either.
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-view-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let workspacePath = environment["TENON_VIEW_SNAPSHOT_WORKSPACE"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        let slotID = UUID()
        let tab = TenonCore.Tab(
            slots: [
                WorkspaceSlot(
                    id: slotID,
                    rect: GridRect(x: 0, y: 0, width: 12, height: 12),
                    content: .pluginView(
                        pluginID: request.pluginID,
                        viewID: request.viewID
                    )
                ),
            ],
            activeSlotID: slotID
        )
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

        let webPool = PluginWebSurfacePool()
        let userInterface = PluginUIState()
        let host: PluginHost
        // Held for the whole render: the runtime owns the providers the plugin's intents
        // resolve through, and a plugin whose `workspace.pane.owner.v1` call fails renders
        // its error state instead of its board.
        let intentRuntime: AppIntentRuntime
        do {
            intentRuntime = try AppIntentRuntime(
                kernel: IntentKernelComponents(
                    persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                    confirmationAuthorizer: userInterface.confirmationAuthorizer()
                ),
                workspaceStore: store,
                terminalSurfaces: SurfacePool(backendName: "Snapshot") { _, _ in
                    StubTerminalSurface()
                },
                webSurfaces: webPool,
                userInterface: userInterface
            )
            host = try PluginHost(
                pluginsRoot: paths.pluginInventoryRoot,
                stateRoot: stateRoot,
                kernel: intentRuntime.kernel,
                // A snapshot answers no prompts, so a plugin that had to ask would render as
                // whatever it shows while waiting. The inventory is the app's own, and this
                // is the same standing consent the app grants it.
                authorization: .bundledInventory,
                invocationScopeProvider: { @MainActor [weak store] in
                    InvocationScope(
                        workspaceID: store?.catalog.activeWorkspaceID,
                        paneID: store?.catalog.activeSlotID
                    )
                }
            )
            try await intentRuntime.start()
            try await host.loadAll()
        } catch {
            fail("cannot start the plugin host: \(error)")
        }
        defer { withExtendedLifetime(intentRuntime) {} }

        await host.reconcileViewInstances(from: store.catalog)

        // Wait on the fact — the plugin's section appearing — rather than on a duration. Its
        // first render may take an intent round trip or a file read.
        let deadline = ContinuousClock.now + .seconds(20)
        var section: PluginViewSection?
        while ContinuousClock.now < deadline {
            section = host.pluginViews.first {
                PaneHeaderProjection.matches(
                    $0,
                    pluginID: request.pluginID,
                    viewID: request.viewID,
                    slotID: slotID
                )
            }
            if section?.body != nil || section?.items.isEmpty == false { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let section else {
            let offered = host.pluginViews.map(\.id).joined(separator: ", ")
            fail(
                "\(request.pluginID.rawValue)/\(request.viewID) contributed no view. "
                    + "Loaded views: [\(offered)]"
            )
        }

        let headerStore = PaneHeaderStore()
        headerStore.publish(section.header, for: slotID)
        PaneViewSnapshotWriter.write(
            PluginSlotView(
                pluginID: request.pluginID,
                viewID: request.viewID,
                slotID: slotID,
                host: host,
                webPool: webPool
            ),
            slot: tab.slots[0],
            title: section.title,
            headerStore: headerStore,
            size: size(from: environment["TENON_VIEW_SNAPSHOT_SIZE"])
                ?? CGSize(width: 900, height: 620),
            to: request.outputPath
        )
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("view-snapshot: \(message)\n".utf8))
        exit(2)
    }
}
