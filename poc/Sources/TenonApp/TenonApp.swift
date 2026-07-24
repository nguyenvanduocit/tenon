import AppKit
import SwiftUI
import TenonCore

@main
struct TenonApp: App {
    @State private var host: PluginHost
    @State private var store: WorkspaceStore
    @State private var pool: SurfacePool
    @State private var router = DragRouter()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)

        let host = PluginHost(pluginsRoot: resolvedPluginsRoot())
        let initialWorkspacePath = resolvedInitialWorkspacePath()
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(path: initialWorkspacePath)
        )
        let stub = ProcessInfo.processInfo.environment["TENON_STUB_TERMINAL"] != nil
        let pool = SurfacePool(backendName: stub ? "Stub" : "libghostty") {
            workspacePath in
            stub
                ? StubTerminalSurface() as TerminalSurface
                : GhosttySurface(workingDirectory: workspacePath)
        }
        Self.wire(host: host, store: store, pool: pool)

        _host = State(initialValue: host)
        _store = State(initialValue: store)
        _pool = State(initialValue: pool)
    }

    /// The whole app, as plumbing: workspace events fan out to plugins and clean up
    /// surfaces; terminal surfaces drive the workspace back (ghostty keybindings,
    /// shell exits, focus clicks) and feed the plugin bus (titles).
    private static func wire(host: PluginHost, store: WorkspaceStore, pool: SurfacePool) {
        store.onEvents = { [weak host, weak pool] events, snapshot in
            host?.emit(workspaceEvents: events, in: snapshot)
            pool?.retainOnly(Set(snapshot.allSlotIDs))
            for event in events {
                if case .slotFocused(let slotID, _, _) = event {
                    // Deferred so a just-split slot's view is in the window first.
                    DispatchQueue.main.async { pool?.focusSurface(for: slotID) }
                }
            }
        }

        pool.onTitleChange = { [weak host] title, slotID in
            host?.terminalTitleChanged(title, slotID: slotID)
        }

        // The plugin platform's view of (and hands on) the workspace + terminal.
        host.onTerminalWrite = { [weak store, weak pool] text in
            guard let slotID = store?.catalog.activeSlotID else { return }
            pool?.sendText(text, to: slotID)
        }
        host.workspaceStateProvider = { [weak store] in
            guard let catalog = store?.catalog else {
                return [
                    "workspaces": [],
                    "tabs": [],
                    "activeWorkspaceId": NSNull(),
                    "activeSlotId": NSNull(),
                ]
            }
            return workspacePayload(catalog)
        }
        host.onWorkspaceCommand = { [weak store] command in
            // Deferred: a plugin may issue this mid-event-dispatch.
            DispatchQueue.main.async {
                switch command {
                case .newTab: store?.newTab()
                case .split(let axis): store?.splitActiveSlot(axis)
                case .focusSlot(let slotID): store?.focusSlot(slotID)
                case .closeSlot(let slotID): store?.closeSlot(slotID)
                }
            }
        }
        pool.onNewTab = { [weak store] in store?.newTab() }
        pool.onNewSplit = { [weak store] axis in store?.splitActiveSlot(axis) }
        pool.onFocusNextSlot = { [weak store] in store?.focusNextSlot() }
        pool.onSlotFocusGained = { [weak store] slotID in store?.focusSlot(slotID) }
        pool.onShellExited = { [weak store] slotID in store?.closeSlot(slotID) }
    }

    var body: some Scene {
        WindowGroup("Tenon") {
            ContentView(host: host, store: store, pool: pool, router: router)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    host.loadAll()
                    host.startWatching()
                    host.startTicking(interval: 1.0)
                    NSApp.activate(ignoringOtherApps: true)
                    // Terminal surfaces no longer self-focus on mount, so the
                    // launch focus is bootstrapped here from the model's active
                    // slot. Deferred so the first canvas configure has created
                    // and mounted the surface first.
                    if let slotID = store.catalog.activeSlotID {
                        DispatchQueue.main.async { pool.focusSurface(for: slotID) }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t")
                Button("Split Right") { store.splitActiveSlot(.horizontal) }
                    .keyboardShortcut("d")
                Button("Split Down") { store.splitActiveSlot(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Slot") { store.closeActiveSlot() }
                    .keyboardShortcut("w")
                Divider()
                Button("Next Tab") { store.selectNextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { store.selectPreviousTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Slot") { store.focusNextSlot() }
                    .keyboardShortcut("]")
            }
        }

        Settings {
            SettingsView(host: host)
        }
    }
}

/// Resolve the first workspace independently of how the app was launched.
/// Finder/LaunchServices commonly starts apps with `/` as their process cwd,
/// which is not a useful project root.
func resolvedInitialWorkspacePath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    if let override = environment["TENON_WORKSPACE_PATH"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
        return URL(
            fileURLWithPath: (override as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }

    let launchDirectory = URL(
        fileURLWithPath: currentDirectoryPath,
        isDirectory: true
    ).standardizedFileURL
    guard launchDirectory.path == "/" else {
        return launchDirectory
    }
    return homeDirectory.standardizedFileURL
}

func workspacePayload(_ catalog: WorkspaceCatalog) -> [String: Any] {
    let workspaces = catalog.workspaces.map { workspace -> [String: Any] in
        [
            "id": workspace.id.uuidString,
            "name": workspace.name,
            "path": workspace.path.path,
            "selected": workspace.id == catalog.activeWorkspaceID,
            "activeTabId": workspace.activeTabID.uuidString,
            "tabs": workspace.tabs.map { tab -> [String: Any] in
                [
                    "id": tab.id.uuidString,
                    "selected": tab.id == workspace.activeTabID,
                    "activeSlotId": tab.activeSlotID?.uuidString as Any? ?? NSNull(),
                    "slotIds": tab.slots.map { $0.id.uuidString },
                    "slots": tab.slots.map { slot -> [String: Any] in
                        [
                            "id": slot.id.uuidString,
                            "content": slot.content.busValue,
                            "rect": [
                                "x": slot.rect.x,
                                "y": slot.rect.y,
                                "width": slot.rect.width,
                                "height": slot.rect.height,
                            ],
                        ]
                    },
                ]
            },
        ]
    }
    let activeTabs = catalog.activeWorkspace?.tabs.map { tab -> [String: Any] in
        [
            "id": tab.id.uuidString,
            "slotIds": tab.slots.map { $0.id.uuidString },
            "selected": tab.id == catalog.activeWorkspace?.activeTabID,
        ]
    } ?? []

    return [
        "workspaces": workspaces,
        "tabs": activeTabs,
        "activeWorkspaceId": catalog.activeWorkspaceID.uuidString,
        "activeSlotId": catalog.activeSlotID?.uuidString as Any? ?? NSNull(),
    ]
}

/// Installed builds use a writable plugin root. The bundled plugin folders are
/// copied there once; user settings and plugin-local state stay outside the app
/// bundle. Developers can point at a source tree with `TENON_PLUGINS_DIR`.
private func resolvedPluginsRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["TENON_PLUGINS_DIR"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
    let root = applicationSupport
        .appendingPathComponent("Tenon", isDirectory: true)
        .appendingPathComponent("plugins", isDirectory: true)
    do {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("plugins", isDirectory: true) {
            try seedBundledPlugins(from: bundled, into: root, fileManager: fileManager)
        }
    } catch {
        NSLog("tenon: failed to prepare plugin directory: \(error)")
    }
    return root
}

private func seedBundledPlugins(
    from bundledRoot: URL,
    into writableRoot: URL,
    fileManager: FileManager
) throws {
    guard fileManager.fileExists(atPath: bundledRoot.path) else { return }
    for bundledPlugin in try fileManager.contentsOfDirectory(
        at: bundledRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) where
        (try bundledPlugin.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    {
        let destination = writableRoot.appendingPathComponent(
            bundledPlugin.lastPathComponent,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else { continue }
        try fileManager.copyItem(at: bundledPlugin, to: destination)
    }
}
