import AppKit
import Observation
import SwiftUI
import TenonCore
import TenonIntentCore

@main
struct TenonApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var appDelegate

    @State private var composition: AppComposition?
    @State private var constructionError: String?

    init() {
        DiffSnapshot.renderIfRequested()

        do {
            _composition = State(
                initialValue: try AppComposition()
            )
            _constructionError = State(initialValue: nil)
        } catch {
            _composition = State(initialValue: nil)
            _constructionError = State(
                initialValue: String(describing: error)
            )
        }
    }

    var body: some Scene {
        WindowGroup("Tenon") {
            if let composition {
                ContentView(
                    host: composition.host,
                    store: composition.store,
                    pool: composition.terminalSurfaces,
                    webPool: composition.webSurfaces,
                    intentRuntime: composition.intentRuntime,
                    router: composition.router,
                    palette: composition.palette,
                    pluginUI: composition.userInterface
                )
                .frame(minWidth: 980, minHeight: 620)
                .overlay(alignment: .top) {
                    if let error = composition.startupError {
                        StartupErrorBanner(message: error)
                    }
                }
                .task {
                    appDelegate.bind(composition)
                    await composition.start()
                }
            } else {
                StartupFailureView(
                    message: constructionError
                        ?? "The app could not create its local runtime."
                )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            if let composition {
                CommandGroup(after: .newItem) {
                    Button("Command Palette") {
                        composition.palette.toggle()
                    }
                    .keyboardShortcut(
                        "p",
                        modifiers: [.command, .shift]
                    )
                }
                PluginKeyBindingCommands(
                    host: composition.host,
                    intentRuntime: composition.intentRuntime
                )
            }
        }

        Settings {
            if let composition {
                SettingsView(
                    host: composition.host,
                    prefs: AppPreferencesStore.shared
                )
            } else {
                StartupFailureView(
                    message: constructionError
                        ?? "The app runtime is unavailable."
                )
            }
        }
    }
}

@MainActor
@Observable
final class AppComposition {
    let host: PluginHost
    let store: WorkspaceStore
    let terminalSurfaces: SurfacePool
    let webSurfaces: PluginWebSurfacePool
    let intentRuntime: AppIntentRuntime
    let cliServer: CLISocketServer
    let router = DragRouter()
    let palette = CommandPaletteState()
    let userInterface: PluginUIState
    let catalogStore: WorkspaceCatalogStore

    private(set) var startupError: String?
    private(set) var isStarted = false

    @ObservationIgnored
    private var lifecycleTask: Task<Void, Never>?

    @ObservationIgnored
    private var lifecycleID: UUID?

    /// T-029: owns the fire-only-in-background rule and the one-alert-per-burst rule
    /// for panes that finish while Tenon is not frontmost.
    private let attentionNotifier: PaneAttentionNotifier

    /// T-029: the fixed-interval observation feed. The machine's `IdleDetector` counts
    /// consecutive identical polls, so this MUST stay a clock loop — an event-driven
    /// feed would never see two identical samples and idle would be unreachable.
    @ObservationIgnored
    private var attentionPollTask: Task<Void, Never>?

    @ObservationIgnored
    private var appActivationObservers: [NSObjectProtocol] = []

    convenience init() throws {
        try self.init(paths: AppStatePaths.resolve())
    }

    init(paths: AppStatePaths) throws {
        let underTest =
            ProcessInfo.processInfo
                .environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        let cliServer = CLISocketServer(enabled: !underTest)
        if cliServer.role == .secondary {
            exit(0)
        }
        let socketPath = cliServer.socketPath ?? ""

        NSApplication.shared.setActivationPolicy(.regular)

        let pluginsRoot = paths.pluginInventoryRoot
        let prefs = AppPreferencesStore.shared
        let catalogStore = WorkspaceCatalogStore(
            fileURL: paths.workspaceCatalogFile
        )
        let fileManager = FileManager.default
        // Plugin directories are short-named; the stable full id lives in each manifest.
        // This is what init can know before `host.loadAll()` runs: a restored plugin-view
        // pane whose plugin left the inventory degrades now, and a view id unknown within
        // a live plugin is the host's instance reconciliation's business once it loads.
        let installedPluginIDs: Set<String> = Set(
            ((try? fileManager.contentsOfDirectory(
                at: pluginsRoot,
                includingPropertiesForKeys: nil
            )) ?? []).compactMap { entry in
                guard let data = try? Data(
                    contentsOf: entry.appendingPathComponent("manifest.json")
                ),
                    let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                else { return nil }
                return object["id"] as? String
            }
        )
        let restored = WorkspaceCatalogStore
            .loadDocument(at: paths.workspaceCatalogFile)
            .flatMap { document in
                WorkspaceCatalogSnapshot.restore(
                    document,
                    isDirectory: { path in
                        var isDirectory: ObjCBool = false
                        return fileManager.fileExists(
                            atPath: path,
                            isDirectory: &isDirectory
                        ) && isDirectory.boolValue
                    },
                    isFileReadable: { fileManager.fileExists(atPath: $0) },
                    isKnownPluginView: { pluginID, _ in
                        installedPluginIDs.contains(pluginID)
                    }
                )
            }
        let launch = WorkspaceCatalogSnapshot.launchCatalog(
            restored: restored,
            launchDirectory: resolvedLaunchDirectory(),
            launchContent: prefs.preferences.newWorkspaceContent
                .slotContent(),
            fallbackDirectory: FileManager.default
                .homeDirectoryForCurrentUser.standardizedFileURL
        )
        let store = WorkspaceStore(
            catalog: launch.catalog,
            recent: RecentStore(
                fileURL: paths.workspaceStateRoot.appendingPathComponent(
                    ".recent-views.json"
                )
            ),
            recentWorkspaces: RecentWorkspaceStore(
                fileURL: paths.workspaceStateRoot.appendingPathComponent(
                    ".recent-workspaces.json"
                )
            )
        )

        let useStub =
            ProcessInfo.processInfo
                .environment["TENON_STUB_TERMINAL"] != nil
        let terminalSurfaces = SurfacePool(
            backendName: useStub ? "Stub" : "libghostty"
        ) { slotID, workspacePath in
            if useStub {
                return StubTerminalSurface()
            }
            return GhosttySurface(
                workingDirectory: workspacePath,
                environment: [
                    "TENON_SOCKET_PATH": socketPath,
                    "TENON_PANE_ID": slotID.uuidString,
                ]
            )
        }
        // T-031: seed each restored pane's recorded title and cwd as placeholder data —
        // the pane renders something useful immediately, and not one surface (so not one
        // shell) is built for it until the human actually opens it. Cwd lands before the
        // pins below so a pinned pane re-resolves against its recorded directory.
        for (slotID, title) in launch.titles {
            terminalSurfaces.setTitle(title, for: slotID)
        }
        for (slotID, cwd) in launch.cwds {
            terminalSurfaces.seedRestoredDirectory(cwd, for: slotID)
        }
        // T-030 handoff: re-apply the persisted per-pane pins verbatim. No surface exists
        // yet, so each call just records its pin; it takes effect when the pane's surface
        // seeds its first directory. `onPinChange` is not wired yet, so restoring pins
        // schedules no write.
        for (slotID, root) in launch.pins {
            terminalSurfaces.pinProjectRoot(root, for: slotID)
        }

        let webSurfaces = PluginWebSurfacePool()
        let userInterface = PluginUIState()
        let intentRuntime = try AppIntentRuntime(
            stateRoot: paths.runtimeStateRoot,
            workspaceStore: store,
            terminalSurfaces: terminalSurfaces,
            webSurfaces: webSurfaces,
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: pluginsRoot,
            stateRoot: paths.pluginStateRoot,
            kernel: intentRuntime.kernel,
            // Bundled authorization is for an inventory the host controls: everything in
            // the app bundle shipped with it and carries the consent the user gave by
            // installing Tenon. An inventory named by `TENON_PLUGINS_DIR` is an arbitrary
            // user directory, so it loads untrusted and its plugins ask — unless the
            // developer stands that directory in for the bundle with
            // `TENON_TRUST_PLUGIN_INVENTORY=1`.
            authorization: paths.trustsPluginInventory
                ? .bundledInventory
                : PluginHostAuthorization(
                    approvedOpenIntentIDs: { _, _ in [] }
                ),
            invocationScopeProvider: { @MainActor [weak store] in
                guard let store else {
                    return InvocationScope()
                }
                return InvocationScope(
                    workspaceID: store.catalog.activeWorkspaceID,
                    paneID: store.catalog.activeSlotID
                )
            }
        )

        let attentionNotifier = PaneAttentionNotifier(
            isAppFrontmost: { NSApplication.shared.isActive },
            deliver: { SystemNotificationDelivery.shared.deliver($0) }
        )

        self.host = host
        self.store = store
        self.terminalSurfaces = terminalSurfaces
        self.webSurfaces = webSurfaces
        self.intentRuntime = intentRuntime
        self.cliServer = cliServer
        self.userInterface = userInterface
        self.catalogStore = catalogStore
        self.attentionNotifier = attentionNotifier

        Self.wire(
            host: host,
            store: store,
            terminalSurfaces: terminalSurfaces,
            webSurfaces: webSurfaces,
            catalogStore: catalogStore
        )
        Self.wireDefaultContent(store: store, prefs: prefs)

        // T-029: panes that start needing a human while Tenon is in the background
        // raise one coalesced system notification per poll pass; clicking it focuses
        // the pane, which makes it viewed, which clears the bold — no second path.
        terminalSurfaces.onPanesBecameUnseen = { [weak terminalSurfaces] slotIDs in
            guard let terminalSurfaces else { return }
            attentionNotifier.panesBecameUnseen(
                slotIDs,
                titles: terminalSurfaces.titles
            )
        }
        SystemNotificationDelivery.shared.onActivate = { [weak store] slotID in
            NSApplication.shared.activate(ignoringOtherApps: true)
            store?.focusSlot(slotID)
        }
        // The viewed rule recomputes on exactly its two input signals: app activation
        // transitions here, and catalog changes inside `wire`'s onEvents. No timer.
        appActivationObservers = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyViewedProjection(at: Date())
                }
            }
        }

        cliServer.onRequest = { action, respond in
            Task { @MainActor in
                respond(
                    await CLICommandExecutor.execute(
                        action,
                        runtime: intentRuntime
                    )
                )
            }
        }
    }

    func start() async {
        if let lifecycleTask {
            await lifecycleTask.value
            return
        }
        guard !isStarted else { return }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        lifecycleID = id
        lifecycleTask = task
        await task.value
        if lifecycleID == id {
            lifecycleID = nil
            lifecycleTask = nil
        }
    }

    /// T-029: recompute the three-condition viewed rule (app frontmost + workspace
    /// selected + pane displayed on the active tab's canvas) and hand the pool the
    /// diff. Called from activation transitions and catalog events — never a timer.
    func applyViewedProjection(at now: Date) {
        terminalSurfaces.applyViewed(
            PaneAttentionProjection.viewedSlots(
                appFrontmost: NSApplication.shared.isActive,
                catalog: store.catalog
            ),
            at: now
        )
    }

    func stop() async {
        let starting = lifecycleTask
        starting?.cancel()
        await starting?.value
        lifecycleID = nil
        lifecycleTask = nil

        attentionPollTask?.cancel()
        attentionPollTask = nil
        for observer in appActivationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appActivationObservers = []

        // The quit path persists the final live state without waiting for a debounce
        // window that would outlive the process. Restore itself never rewrites the file;
        // only live state does, here and via the coalesced saves during the session.
        await catalogStore.noteChange(
            WorkspaceCatalogSnapshot.document(
                capturing: store.catalog,
                pins: terminalSurfaces.pinnedProjectRoots,
                titles: terminalSurfaces.titles,
                cwds: terminalSurfaces.directories.mapValues(\.cwd)
            )
        )
        await catalogStore.flush()

        await host.shutdown()
        webSurfaces.disposeAll()
        do {
            try await intentRuntime.stop()
        } catch {
            startupError = String(describing: error)
        }
        isStarted = false
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private weak var composition: AppComposition?
    private var terminationTask: Task<Void, Never>?

    func bind(_ composition: AppComposition) {
        self.composition = composition
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let composition else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { @MainActor [weak self] in
            await composition.stop()
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }
}

private extension AppComposition {
    /// T-029, the feed: the same fixed 200 ms / 20 ms-tolerance cadence
    /// `terminal.wait.v1`'s loop uses (`TerminalIntentProvider`). `Date()` is supplied
    /// here, at the imperative edge; every mutation below it takes time as a parameter.
    func startAttentionPolling() {
        guard attentionPollTask == nil else { return }
        attentionPollTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(
                        for: .milliseconds(200),
                        tolerance: .milliseconds(20)
                    )
                } catch {
                    return
                }
                guard let self else { return }
                self.terminalSurfaces.pollActivity(at: Date())
            }
        }
    }

    func performStart() async {
        do {
            try Task.checkCancellation()
            try await intentRuntime.start()
            try Task.checkCancellation()
            try await host.loadAll()
            webSurfaces.reconcile(catalog: store.catalog, host: host)
            try Task.checkCancellation()
            try host.startWatching()

            for workspace in store.catalog.workspaces {
                store.recentWorkspaces?.record(
                    name: workspace.name,
                    path: workspace.path
                )
            }
            isStarted = true
            startupError = nil
            startAttentionPolling()
            NSApp.activate(ignoringOtherApps: true)
            await Task.yield()
            if let slotID = store.catalog.activeSlotID {
                terminalSurfaces.focusSurface(for: slotID)
            }
        } catch is CancellationError {
            return
        } catch {
            startupError = String(describing: error)
        }
    }

    static func wire(
        host: PluginHost,
        store: WorkspaceStore,
        terminalSurfaces: SurfacePool,
        webSurfaces: PluginWebSurfacePool,
        catalogStore: WorkspaceCatalogStore
    ) {
        host.onPluginLifecycleChanged = {
            [weak host, weak store, weak webSurfaces] _ in
            guard let host, let store else { return }
            webSurfaces?.reconcile(catalog: store.catalog, host: host)
        }

        store.onEvents = {
            [weak host, weak store, weak terminalSurfaces, weak webSurfaces]
                events,
                snapshot in
            terminalSurfaces?.retainOnly(Set(snapshot.allSlotIDs))
            // T-029: catalog changes (workspace/tab selection, pane moves) change
            // which panes are displayed, so the viewed projection recomputes here.
            terminalSurfaces?.applyViewed(
                PaneAttentionProjection.viewedSlots(
                    appFrontmost: NSApplication.shared.isActive,
                    catalog: snapshot
                ),
                at: Date()
            )
            if let host {
                webSurfaces?.reconcile(catalog: snapshot, host: host)
            }
            Task { @MainActor [weak host] in
                await host?.emit(
                    workspaceEvents: events,
                    in: snapshot
                )
            }
            for event in events {
                if case let .slotFocused(slotID, _, _) = event {
                    Task { @MainActor [weak terminalSurfaces] in
                        await Task.yield()
                        terminalSurfaces?.focusSurface(for: slotID)
                    }
                }
            }
            // Coalesced catalog persistence: every mutation notes the full state; the
            // store debounces to one durable write per burst (T-027). The task reads the
            // live state at run time instead of capturing this event's snapshot: actor
            // jobs are not ordered, so a late-running note must converge on the newest
            // tree, never push an older one over the quit-path save.
            Task { @MainActor [weak store, weak terminalSurfaces] in
                guard let store, let terminalSurfaces else { return }
                await catalogStore.noteChange(WorkspaceCatalogSnapshot.document(
                    capturing: store.catalog,
                    pins: terminalSurfaces.pinnedProjectRoots,
                    titles: terminalSurfaces.titles,
                    cwds: terminalSurfaces.directories.mapValues(\.cwd)
                ))
            }
        }

        terminalSurfaces.onPinChange = {
            [weak store, weak terminalSurfaces] in
            Task { @MainActor [weak store, weak terminalSurfaces] in
                guard let store, let terminalSurfaces else { return }
                await catalogStore.noteChange(WorkspaceCatalogSnapshot.document(
                    capturing: store.catalog,
                    pins: terminalSurfaces.pinnedProjectRoots,
                    titles: terminalSurfaces.titles,
                    cwds: terminalSurfaces.directories.mapValues(\.cwd)
                ))
            }
        }

        terminalSurfaces.onTitleChange = {
            [weak host] title, slotID in
            Task { @MainActor [weak host] in
                await host?.terminalTitleChanged(
                    title,
                    slotID: slotID
                )
            }
        }
        terminalSurfaces.onPaneDirectoryChange = {
            [weak host] directory, slotID in
            Task { @MainActor [weak host] in
                await host?.paneCwdChanged(directory, slotID: slotID)
            }
        }
        terminalSurfaces.onNewTab = {
            [weak store] in store?.newTab()
        }
        terminalSurfaces.onNewSplit = {
            [weak store] axis in
            store?.splitActiveSlot(axis)
        }
        terminalSurfaces.onFocusNextSlot = {
            [weak store] in store?.focusNextSlot()
        }
        terminalSurfaces.onSlotFocusGained = {
            [weak store] slotID in store?.focusSlot(slotID)
        }
        terminalSurfaces.onShellExited = {
            [weak store] slotID in store?.closeSlot(slotID)
        }
        webSurfaces.onNavigationEvent = {
            [weak host] event in
            Task { @MainActor [weak host] in
                guard let host,
                      host.plugins.contains(where: {
                          $0.id == event.key.pluginID
                              && $0.installationID
                                  == event.key.installation.installationID
                              && $0.isEnabled
                              && $0.isLoaded
                              && $0.permissions.contains("web.view")
                      })
                else {
                    return
                }
                await host.emit(
                    event: event.name,
                    payload: event.payload,
                    to: event.key.pluginID
                )
            }
        }
    }

    static func wireDefaultContent(
        store: WorkspaceStore,
        prefs: AppPreferencesStore
    ) {
        store.newTabContentProvider = {
            prefs.preferences.newTabContent.slotContent()
        }
        store.newSplitContentProvider = {
            prefs.preferences.newSplitContent.slotContent()
        }
        store.newWorkspaceContentProvider = {
            prefs.preferences.newWorkspaceContent.slotContent()
        }
    }
}

private struct StartupErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(3)
        }
        .font(TenonTheme.interfaceFont(size: 12))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.9))
        .clipShape(
            RoundedRectangle(
                cornerRadius: 8,
                style: .continuous
            )
        )
        .padding(.top, 48)
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
            Text("Tenon could not start")
                .font(.headline)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(
            minWidth: 640,
            minHeight: 420
        )
    }
}

/// The directory this launch explicitly points at, or nil for a bare launch.
/// `TENON_WORKSPACE_PATH` is explicit, and so is a terminal launch's cwd — running
/// `tenon` inside a project means "open this project". A Finder-style launch (cwd `/`)
/// names nothing: that is the bare launch that restores the saved catalog as saved.
func resolvedLaunchDirectory(
    environment: [String: String] =
        ProcessInfo.processInfo.environment,
    currentDirectoryPath: String =
        FileManager.default.currentDirectoryPath
) -> URL? {
    if let override = environment["TENON_WORKSPACE_PATH"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty
    {
        return URL(
            fileURLWithPath:
                (override as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }

    let launchDirectory = URL(
        fileURLWithPath: currentDirectoryPath,
        isDirectory: true
    ).standardizedFileURL
    return launchDirectory.path == "/" ? nil : launchDirectory
}

/// Resolve the first workspace independently of how the app was launched.
func resolvedInitialWorkspacePath(
    environment: [String: String] =
        ProcessInfo.processInfo.environment,
    currentDirectoryPath: String =
        FileManager.default.currentDirectoryPath,
    homeDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    resolvedLaunchDirectory(
        environment: environment,
        currentDirectoryPath: currentDirectoryPath
    ) ?? homeDirectory.standardizedFileURL
}
