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

    private(set) var startupError: String?
    private(set) var isStarted = false

    @ObservationIgnored
    private var lifecycleTask: Task<Void, Never>?

    @ObservationIgnored
    private var lifecycleID: UUID?

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
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                path: resolvedInitialWorkspacePath(),
                content: prefs.preferences.newWorkspaceContent
                    .slotContent()
            ),
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
            // The inventory root is the app bundle (or the developer root standing in for
            // it), so everything the host loads shipped with the app and carries the
            // consent the user gave by installing it. A user-installed plugin directory
            // would need its own authorization rather than this one.
            authorization: .bundledInventory,
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

        self.host = host
        self.store = store
        self.terminalSurfaces = terminalSurfaces
        self.webSurfaces = webSurfaces
        self.intentRuntime = intentRuntime
        self.cliServer = cliServer
        self.userInterface = userInterface

        Self.wire(
            host: host,
            store: store,
            terminalSurfaces: terminalSurfaces,
            webSurfaces: webSurfaces
        )
        Self.wireDefaultContent(store: store, prefs: prefs)

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

    func stop() async {
        let starting = lifecycleTask
        starting?.cancel()
        await starting?.value
        lifecycleID = nil
        lifecycleTask = nil

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
        webSurfaces: PluginWebSurfacePool
    ) {
        host.onPluginLifecycleChanged = {
            [weak host, weak store, weak webSurfaces] _ in
            guard let host, let store else { return }
            webSurfaces?.reconcile(catalog: store.catalog, host: host)
        }

        store.onEvents = {
            [weak host, weak terminalSurfaces, weak webSurfaces]
                events,
                snapshot in
            terminalSurfaces?.retainOnly(Set(snapshot.allSlotIDs))
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

/// Resolve the first workspace independently of how the app was launched.
func resolvedInitialWorkspacePath(
    environment: [String: String] =
        ProcessInfo.processInfo.environment,
    currentDirectoryPath: String =
        FileManager.default.currentDirectoryPath,
    homeDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
) -> URL {
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
    guard launchDirectory.path == "/" else {
        return launchDirectory
    }
    return homeDirectory.standardizedFileURL
}
