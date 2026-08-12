// @domain: workspace-model
import AppKit
import Observation
import SwiftUI
import TenonCore
import TenonIntentCore

@main
struct TenonApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var appDelegate

    /// The workspace window's stable scene identity.
    static let mainWindowID = "main"

    @State private var composition: AppComposition?
    @State private var constructionError: String?
    @State private var isConstructing = false

    init() {
        DiffSnapshot.renderIfRequested()
        PluginViewSnapshot.renderIfRequested()
        AgentTimelineSnapshot.renderIfRequested()
        SidebarSnapshot.renderIfRequested()
    }

    var body: some Scene {
        // One window, declared as one window.
        //
        // Everything the workspace is made of is single-instance by construction: one
        // `AppComposition`, one `SurfacePool` holding one surface per slot, and a Ghostty
        // surface that hands back the same `NSView` to every caller. `Window` is the scene
        // that matches: the File menu offers no second workspace, so no window can be
        // furnished by taking the terminal view out of another one.
        Window("Tenon", id: Self.mainWindowID) {
            if let composition {
                ContentView(
                    host: composition.host,
                    store: composition.store,
                    pool: composition.terminalSurfaces,
                    agentLens: composition.agentLens,
                    webPool: composition.webSurfaces,
                    intentRuntime: composition.intentRuntime,
                    router: composition.router,
                    palette: composition.palette,
                    quickCommands: composition.quickCommands,
                    pluginUI: composition.userInterface,
                    automation: composition.automationScheduler,
                    resourceMonitor: composition.resourceMonitor,
                    automationSchedulesEnabled:
                        composition.prefs.preferences.automationSchedulesEnabled,
                    automationActions: AutomationPaneActions(
                        runNow: { pluginID, scheduleID in
                            await composition.runAutomationNow(
                                pluginID: pluginID,
                                scheduleID: scheduleID
                            )
                        },
                        setPaused: { pluginID, scheduleID, paused in
                            composition.setAutomationSchedulePaused(
                                pluginID: pluginID,
                                scheduleID: scheduleID,
                                paused: paused
                            )
                        },
                        createWithAI: {
                            composition.openAutomationAuthoringPane()
                        },
                        openRunDetail: { pluginID, viewID in
                            composition.store.openContent(
                                .pluginView(pluginID: pluginID, viewID: viewID)
                            )
                        }
                    )
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
            } else if let constructionError {
                StartupFailureView(
                    message: constructionError
                )
            } else {
                ProgressView("Preparing Tenon…")
                    .frame(minWidth: 980, minHeight: 620)
                    .task { await constructCompositionIfNeeded() }
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
                CommandGroup(after: .appInfo) {
                    DiagnosticsCommands(journal: composition.diagnosticsJournal)
                }
            }
        }

        Settings {
            if let composition {
                SettingsView(
                    host: composition.host,
                    prefs: composition.prefs,
                    instanceChannel: composition.instanceChannel
                )
            } else {
                StartupFailureView(
                    message: constructionError
                        ?? "The app runtime is unavailable."
                )
            }
        }
    }

    @MainActor
    private func constructCompositionIfNeeded() async {
        guard composition == nil, constructionError == nil, !isConstructing else {
            return
        }
        isConstructing = true
        defer { isConstructing = false }
        do {
            composition = try await AppComposition.make()
        } catch is CancellationError {
            return
        } catch {
            constructionError = String(describing: error)
        }
    }
}

/// Immutable values and pre-opened actor-owned stores produced without occupying the UI
/// executor. UI/AppKit objects are deliberately absent and are assembled afterwards by
/// `AppComposition` on `MainActor`.
private struct AppStartupPreparation: Sendable {
    private enum PreparationError: Error, CustomStringConvertible {
        case controlChannelUnavailable(String)

        var description: String {
            switch self {
            case let .controlChannelUnavailable(reason):
                "Tenon could not safely claim this install channel: \(reason)"
            }
        }
    }

    let paths: AppStatePaths
    let underTest: Bool
    let cliServer: CLISocketServer
    let codexHomePath: String
    let codexHomeURL: URL
    let claudeHomeURL: URL
    let agentSessionRegistry: AgentSessionRegistry
    let agentHookServer: AgentHookServer
    let agentHookScriptURL: URL
    let codexHookInstallResult: AgentHookInstallResult
    let claudeHookInstallResult: AgentHookInstallResult
    let launch: RestoredWorkspaceCatalog
    let recentViews: [WorkspaceRecentViews]
    let recentWorkspaces: [RecentWorkspaceStore.Entry]
    let kernel: IntentKernelComponents
    let pluginPersistence: PluginHostPersistence

    @concurrent
    static func prepare(
        paths requestedPaths: AppStatePaths?,
        launchContent: SlotContent,
        confirmationAuthorizer: IntentConfirmationAuthorizer
    ) async throws -> Self {
        try Task.checkCancellation()
        let paths = try requestedPaths ?? AppStatePaths.resolve()
        let environment = ProcessInfo.processInfo.environment
        let underTest = environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let cliServer = CLISocketServer(
            enabled: !underTest,
            instanceChannel: paths.instanceChannel
        )
        // Preserve the single-instance fast path: a secondary launch must not install
        // hooks or open durable stores while the primary instance owns them.
        switch cliServer.role {
        case .primary:
            break
        case .secondary:
            exit(0)
        case .unavailable:
            throw PreparationError.controlChannelUnavailable(
                cliServer.degradation?.message ?? "unknown control-channel error"
            )
        }

        let codexHomePath = environment["CODEX_HOME"]
            .map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true).path
        let codexHomeURL = URL(fileURLWithPath: codexHomePath, isDirectory: true)
        let claudeHomePath = environment["CLAUDE_CONFIG_DIR"]
            .map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true).path
        let claudeHomeURL = URL(fileURLWithPath: claudeHomePath, isDirectory: true)
        let agentSessionRegistry = AgentSessionRegistry(
            allowedTranscriptRoots: [
                codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
                claudeHomeURL.appendingPathComponent("projects", isDirectory: true),
            ]
        )
        let agentHookServer = AgentHookServer(enabled: !underTest) { event in
            Task { await agentSessionRegistry.record(event) }
            // The registry answers "which transcript is this pane's"; the lens needs the
            // work the hook reports, which the transcript will not describe until the turn
            // ends. Two readers of one fact, neither derived from the other.
            Task { @MainActor in AgentHookLensBus.deliver(event) }
        }
        let agentHookScriptURL = paths.runtimeStateRoot
            .appendingPathComponent("agent-hooks", isDirectory: true)
            .appendingPathComponent("agent-hook.sh")
        let codexHookInstallResult: AgentHookInstallResult = underTest
            ? .alreadyInstalled
            : AgentHookInstaller.install(
                provider: .codex,
                scriptURL: agentHookScriptURL,
                hooksURL: codexHomeURL.appendingPathComponent("hooks.json")
            )
        let claudeHookInstallResult: AgentHookInstallResult = underTest
            ? .alreadyInstalled
            : AgentHookInstaller.install(
                provider: .claude,
                scriptURL: agentHookScriptURL,
                hooksURL: claudeHomeURL.appendingPathComponent("settings.json")
            )
        if !underTest {
            // The install can lose a race against whatever else writes these files. Record
            // the outcome and how to repeat it, so a pane can say so and offer the retry
            // instead of leaving the Session view mysteriously empty.
            let claudeSettingsURL = claudeHomeURL.appendingPathComponent("settings.json")
            let codexHooksURL = codexHomeURL.appendingPathComponent("hooks.json")
            await AgentHookInstallStatus.shared.register(
                provider: .claude,
                result: claudeHookInstallResult
            ) {
                AgentHookInstaller.install(
                    provider: .claude,
                    scriptURL: agentHookScriptURL,
                    hooksURL: claudeSettingsURL
                )
            }
            await AgentHookInstallStatus.shared.register(
                provider: .codex,
                result: codexHookInstallResult
            ) {
                AgentHookInstaller.install(
                    provider: .codex,
                    scriptURL: agentHookScriptURL,
                    hooksURL: codexHooksURL
                )
            }
        }

        try Task.checkCancellation()
        let installedPluginIDs = Set(
            PluginLoader.discover(
                in: [paths.pluginInventoryRoot, paths.userPluginInventoryRoot]
            ).compactMap {
                (try? PluginLoader.loadManifest(at: $0))?.id.rawValue
            }
        )
        let fileManager = FileManager.default
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
            launchContent: launchContent,
            fallbackDirectory: fileManager.homeDirectoryForCurrentUser
                .standardizedFileURL
        )
        let recentViewsURL = paths.workspaceStateRoot.appendingPathComponent(
            ".recent-views.json"
        )
        let recentWorkspacesURL = paths.workspaceStateRoot.appendingPathComponent(
            ".recent-workspaces.json"
        )
        let recentViews = RecentStore.load(from: recentViewsURL)
        let recentWorkspaces = RecentWorkspaceStore.load(from: recentWorkspacesURL)
        let kernel = try await AppIntentRuntime.prepareKernel(
            stateRoot: paths.runtimeStateRoot,
            confirmationAuthorizer: confirmationAuthorizer,
            standingConsent: StandingConsentStore(
                fileURL: paths.standingConsentFile
            )
        )
        let pluginPersistence = try PluginHostPersistence(
            stateRoot: paths.pluginStateRoot
        )
        try Task.checkCancellation()
        return Self(
            paths: paths,
            underTest: underTest,
            cliServer: cliServer,
            codexHomePath: codexHomePath,
            codexHomeURL: codexHomeURL,
            claudeHomeURL: claudeHomeURL,
            agentSessionRegistry: agentSessionRegistry,
            agentHookServer: agentHookServer,
            agentHookScriptURL: agentHookScriptURL,
            codexHookInstallResult: codexHookInstallResult,
            claudeHookInstallResult: claudeHookInstallResult,
            launch: launch,
            recentViews: recentViews,
            recentWorkspaces: recentWorkspaces,
            kernel: kernel,
            pluginPersistence: pluginPersistence
        )
    }
}

@MainActor
@Observable
final class AppComposition {
    let host: PluginHost
    /// The composition retains the one observable preferences owner so scheduling and
    /// both shell surfaces read the same persisted enablement value.
    let prefs: AppPreferencesStore
    let store: WorkspaceStore
    let terminalSurfaces: SurfacePool
    /// T-100: the read-only process resource monitor. Its sampler, coordinator, and bridge are
    /// host-private — no intent, no principal, no `tenon` member — so the whole feature enters
    /// composition as this one typed value.
    let resourceMonitor: ResourceMonitorModel
    /// Held so shutdown can cancel sampling demand and wait for quiescence.
    @ObservationIgnored let telemetryCoordinator: ProcessTelemetryCoordinator
    let agentLens: AgentLensPool
    let agentSessionRegistry: AgentSessionRegistry
    let agentHookServer: AgentHookServer
    let codexHookInstallResult: AgentHookInstallResult
    let claudeHookInstallResult: AgentHookInstallResult
    let webSurfaces: PluginWebSurfacePool
    let intentRuntime: AppIntentRuntime
    let cliServer: CLISocketServer
    let instanceChannel: AppInstanceChannel
    let router = DragRouter()
    let palette: CommandPaletteState
    /// T-092: what the app records about its own health, and the watchdog that fills it.
    /// Held here so the menu can export it and `performStart` can arm it.
    let diagnosticsJournal: DiagnosticsJournal
    @ObservationIgnored
    private let diagnostics: DiagnosticsRuntime
    /// Which plugins this person has let handle a delegable contract. Nothing is granted
    /// by installing — not even for a plugin that ships with the app.
    let openHandlerApprovals: OpenHandlerApprovals
    let quickCommands = QuickCommandStore()
    let userInterface: PluginUIState
    let catalogStore: WorkspaceCatalogStore
    /// T-046: wall-clock automation schedules. `Date()` enters only at this
    /// composition root's edges (reconcile, tick); the scheduler itself always
    /// takes time as a parameter.
    let automationScheduler = AutomationScheduler()

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

    /// T-046: the automation tick loop; firing resolution, not firing count.
    @ObservationIgnored
    private var automationTickTask: Task<Void, Never>?

    @ObservationIgnored
    private var appActivationObservers: [NSObjectProtocol] = []

    static func make(paths: AppStatePaths? = nil) async throws -> AppComposition {
        let userInterface = PluginUIState()
        let prefs = AppPreferencesStore.shared
        // The Permissions switch governs whether a confirmation is presented at all. Read
        // live from the store, so changing it in Settings needs no further wiring.
        userInterface.adopt(prefs)
        let prepared = try await AppStartupPreparation.prepare(
            paths: paths,
            launchContent: prefs.preferences.newWorkspaceContent.slotContent(),
            confirmationAuthorizer: userInterface.confirmationAuthorizer()
        )
        try Task.checkCancellation()
        return try AppComposition(
            prepared: prepared,
            prefs: prefs,
            userInterface: userInterface
        )
    }

    private init(
        prepared: AppStartupPreparation,
        prefs: AppPreferencesStore,
        userInterface: PluginUIState
    ) throws {
        NSApplication.shared.setActivationPolicy(.regular)

        let paths = prepared.paths
        // T-092: constructed immediately after startup preparation and armed first in
        // `performStart`, before plugin runtime loading or restored-pane reconciliation.
        // Preparation — including catalog loading — is outside this readiness-scoped monitor.
        let diagnosticsJournal = DiagnosticsJournal(fileURL: paths.diagnosticsJournalFile)
        self.diagnosticsJournal = diagnosticsJournal
        self.diagnostics = DiagnosticsRuntime(
            journal: diagnosticsJournal,
            channel: paths.instanceChannel.rawValue
        )
        let pluginsRoot = paths.pluginInventoryRoot
        let catalogStore = WorkspaceCatalogStore(
            fileURL: paths.workspaceCatalogFile
        )
        let recentViewsURL = paths.workspaceStateRoot.appendingPathComponent(
            ".recent-views.json"
        )
        let recentWorkspacesURL = paths.workspaceStateRoot.appendingPathComponent(
            ".recent-workspaces.json"
        )
        let store = WorkspaceStore(
            catalog: prepared.launch.catalog,
            recent: RecentStore(
                fileURL: recentViewsURL,
                preloaded: prepared.recentViews,
                // The catalog just restored is what the persisted lists are matched against:
                // a launch that had to decline the catalog document mints fresh workspace
                // ids for the same folders, and this is where a list finds its workspace
                // again instead of silently reading as empty.
                liveWorkspaces: prepared.launch.catalog.workspaces.map {
                    WorkspaceRoot(id: $0.id, path: $0.path)
                }
            ),
            recentWorkspaces: RecentWorkspaceStore(
                fileURL: recentWorkspacesURL,
                preloaded: prepared.recentWorkspaces
            )
        )

        let useStub =
            ProcessInfo.processInfo
                .environment["TENON_STUB_TERMINAL"] != nil
        // A degraded staging server must still point its panes at staging. Falling back to
        // an empty override would make the CLI use production's compatibility socket.
        let socketPath = prepared.cliServer.clientSocketPath
        let terminalSurfaces = SurfacePool(
            backendName: useStub ? "Stub" : "libghostty",
            makeSurfaceWithIdentity: { slotID, surfaceToken, workspacePath in
                if useStub {
                    return StubTerminalSurface()
                }
                var environment = [
                    "CODEX_HOME": prepared.codexHomePath,
                    "TENON_SOCKET_PATH": socketPath,
                    "TENON_AGENT_HOOK_SCRIPT": prepared.agentHookScriptURL.path,
                    "TENON_PANE_ID": slotID.uuidString,
                    "TENON_AGENT_SURFACE_TOKEN": surfaceToken.uuidString,
                ]
                if let port = prepared.agentHookServer.port {
                    environment["TENON_AGENT_HOOK_PORT"] = String(port)
                    environment["TENON_AGENT_HOOK_TOKEN"] =
                        prepared.agentHookServer.bearerToken
                }
                return GhosttySurface(
                    workingDirectory: workspacePath,
                    environment: environment
                )
            }
        )
        // T-031: seed each restored pane's recorded title and cwd as placeholder data —
        // the pane renders something useful immediately, and not one surface (so not one
        // shell) is built for it until the human actually opens it.
        for (slotID, title) in prepared.launch.titles {
            terminalSurfaces.setTitle(title, for: slotID)
        }
        for (slotID, cwd) in prepared.launch.cwds {
            terminalSurfaces.seedSpawnDirectory(cwd, for: slotID)
        }
        let webSurfaces = PluginWebSurfacePool()
        let agentLens = AgentLensPool(
            discovery: AgentLensDiscovery(
                sessionRegistry: prepared.agentSessionRegistry,
                codexSessionsRoot: prepared.codexHomeURL
                    .appendingPathComponent("sessions", isDirectory: true),
                codexHookDegradation: Self.agentHookDegradation(
                    server: prepared.agentHookServer,
                    installResult: prepared.codexHookInstallResult
                ),
                claudeHookDegradation: Self.agentHookDegradation(
                    server: prepared.agentHookServer,
                    installResult: prepared.claudeHookInstallResult
                )
            )
        )
        let intentRuntime = try AppIntentRuntime(
            kernel: prepared.kernel,
            workspaceStore: store,
            terminalSurfaces: terminalSurfaces,
            webSurfaces: webSurfaces,
            userInterface: userInterface
        )
        // Two inventories, ordered (T-062). The primary one ships with the app and is
        // sealed — writing into a signed bundle breaks its signature and the next
        // install erases the write. The user inventory is where an authored plugin
        // lives: writable, outside any bundle, and untrusted, because standing consent
        // is earned by installing Tenon and never by a file's location.
        // Which plugins this person lets handle a delegable contract. Shipping with the app
        // is consent to *run* a plugin; it is not consent to let it see every address and
        // path opened through it, so a bundled plugin starts with no handler approval
        // either and earns it in Settings. Scoped to what the manifest actually declares,
        // because an approval for something never offered is refused outright by
        // `ProviderActivationCoordinator`.
        let openHandlerApprovals = OpenHandlerApprovals(
            fileURL: paths.openHandlerApprovalsFile
        )
        let approvedOpenIntents: PluginHostAuthorization.OpenIntentApprovals = {
            key, manifest in
            await PluginOpenHandlerCandidacy.effectiveApprovals(
                declared: manifest.intents.provides.map(\.name),
                approved: openHandlerApprovals.approvedIntentIDs(for: key.pluginID)
            )
        }
        let host = try PluginHost(
            inventories: [
                PluginInventory(
                    root: pluginsRoot,
                    // Bundled authorization is for an inventory the host controls. An
                    // inventory named by `TENON_PLUGINS_DIR` is an arbitrary user
                    // directory, so it loads untrusted and its plugins ask — unless the
                    // developer stands that directory in for the bundle with
                    // `TENON_TRUST_PLUGIN_INVENTORY=1`.
                    authorization: paths.trustsPluginInventory
                        ? PluginHostAuthorization(
                            approvedOpenIntentIDs: approvedOpenIntents,
                            grantsStandingConsent: { _, _ in true },
                            inventoryTrust: .bundledStandingConsent
                        )
                        : PluginHostAuthorization(
                            approvedOpenIntentIDs: approvedOpenIntents
                        ),
                    isWritable: paths.pluginInventoryIsWritable,
                    enablesNewPluginsByDefault: paths.trustsPluginInventory
                ),
                PluginInventory(
                    root: paths.userPluginInventoryRoot,
                    authorization: PluginHostAuthorization(
                        approvedOpenIntentIDs: approvedOpenIntents
                    ),
                    isWritable: true,
                    enablesNewPluginsByDefault: false
                ),
            ],
            stateRoot: paths.pluginStateRoot,
            kernel: intentRuntime.kernel,
            persistence: prepared.pluginPersistence,
            invocationScopeProvider: { @MainActor [weak store] in
                guard let store else {
                    return InvocationScope()
                }
                return InvocationScope(
                    workspaceID: store.catalog.activeWorkspaceID,
                    tabID: store.catalog.activeTab?.id,
                    paneID: store.catalog.activeSlotID
                )
            }
        )

        let attentionNotifier = PaneAttentionNotifier(
            isAppFrontmost: { NSApplication.shared.isActive },
            deliver: { SystemNotificationDelivery.shared.deliver($0) }
        )

        self.host = host
        self.prefs = prefs
        self.store = store
        self.terminalSurfaces = terminalSurfaces
        // T-100. Built here because the bridge needs both the catalog and the surface pool,
        // and nothing samples until a monitor surface is actually visible.
        let telemetryBridge = ProcessTelemetryBridge(store: store, surfaces: terminalSurfaces)
        let telemetryCoordinator = ProcessTelemetryCoordinator(
            sampler: DarwinProcessSampler(),
            clock: SystemTelemetryClock(),
            ticker: TaskSleepTicker(),
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            provenance: { @Sendable in await MainActor.run { telemetryBridge.snapshot() } }
        )
        let monitor = ResourceMonitorModel(
            coordinator: telemetryCoordinator,
            bridge: telemetryBridge
        )
        monitor.revealPane = { [weak store] slotID in store?.focusSlot(slotID) }
        self.resourceMonitor = monitor
        self.telemetryCoordinator = telemetryCoordinator
        self.agentLens = agentLens
        self.agentSessionRegistry = prepared.agentSessionRegistry
        self.agentHookServer = prepared.agentHookServer
        self.codexHookInstallResult = prepared.codexHookInstallResult
        self.claudeHookInstallResult = prepared.claudeHookInstallResult
        self.webSurfaces = webSurfaces
        self.intentRuntime = intentRuntime
        self.cliServer = prepared.cliServer
        self.instanceChannel = prepared.paths.instanceChannel
        self.palette = CommandPaletteState(storeURL: paths.commandFrecencyFile)
        self.openHandlerApprovals = openHandlerApprovals
        self.userInterface = userInterface
        self.catalogStore = catalogStore
        self.attentionNotifier = attentionNotifier

        automationScheduler.setPausedScheduleKeys(
            prefs.preferences.pausedAutomationSchedules
        )

        Self.wire(
            host: host,
            store: store,
            terminalSurfaces: terminalSurfaces,
            agentLens: agentLens,
            agentSessionRegistry: prepared.agentSessionRegistry,
            webSurfaces: webSurfaces,
            catalogStore: catalogStore,
            automation: automationScheduler
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

        let agentSessionRegistry = prepared.agentSessionRegistry
        prepared.cliServer.onRequest = {
            [weak terminalSurfaces] action, origin, respond in
            Task { @MainActor in
                respond(
                    await CLICommandExecutor.execute(
                        action,
                        runtime: intentRuntime,
                        origin: origin,
                        // Read per request rather than cached: which pane is running an
                        // agent changes without asking anyone, and an identity decided from
                        // a stale reading is an identity decided from a pane that has
                        // already moved on. No surfaces means no pane can be proven, which
                        // is the ordinary CLI principal.
                        agentPanes: {
                            guard let terminalSurfaces else { return [] }
                            return await AgentPaneOccupancyReader.candidates(
                                surfaces: terminalSurfaces,
                                registry: agentSessionRegistry
                            )
                        }
                    )
                )
            }
        }
    }

    private static func agentHookDegradation(
        server: AgentHookServer,
        installResult: AgentHookInstallResult
    ) -> String? {
        guard server.port != nil else { return "the loopback listener could not bind" }
        if case let .unavailable(reason) = installResult { return reason }
        return nil
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

        let attentionPolling = attentionPollTask
        let automationTicking = automationTickTask
        attentionPolling?.cancel()
        automationTicking?.cancel()
        await attentionPolling?.value
        await automationTicking?.value
        attentionPollTask = nil
        automationTickTask = nil
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
                titles: terminalSurfaces.titles,
                cwds: terminalSurfaces.directories.mapValues(\.cwd)
            )
        )
        await catalogStore.flush()

        await host.shutdown()
        agentLens.retainOnly([])
        await agentSessionRegistry.retainOnly([])
        agentHookServer.stop()
        webSurfaces.disposeAll()
        do {
            try await intentRuntime.stop()
        } catch {
            startupError = String(describing: error)
        }
        isStarted = false
        diagnostics.stop()
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

extension AppComposition {
    /// T-061: Create with AI. Opens a fresh terminal tab whose shell starts in the
    /// writable inventory and types the `claude <guide>` command into it — the same typed
    /// services `terminal.open.v1`'s provider adapts, called DIRECT because this is
    /// the host's own gesture (invariant 6; the intent stays the public adapter).
    ///
    /// Reachable from the test target rather than fileprivate like its neighbours below,
    /// because the directory this hands over is the whole of T-062: an agent started in
    /// the app bundle writes into a signed bundle and breaks it, which is not a hazard a
    /// comment can be trusted with alone.
    func openAutomationAuthoringPane() {
        store.newTab(content: .terminal)
        guard let paneID = store.catalog.activeSlotID,
              store.catalog.slot(id: paneID)?.content == .terminal
        else { return }
        // The writable inventory, never the sealed bundle: an agent writing into
        // `Tenon.app` breaks its code signature and the file dies at the next install.
        guard let root = host.writableInventoryRoot else { return }
        terminalSurfaces.seedSpawnDirectory(root, for: paneID)
        terminalSurfaces.sendTextWhenReady(
            AutomationAuthoring.command(pluginsRoot: root.path) + "\n",
            to: paneID
        )
    }
}

/// Delivers one already-advanced scheduler batch while its owner-scoped policy epochs stay
/// current. The check belongs immediately before EACH delivery: `delivery` can suspend, and
/// MainActor reentrancy lets a preference change while the prior firing is in flight. A
/// global Off/On cycle invalidates the rest of the batch; a schedule pause/resume cycle
/// invalidates only that schedule, so an unrelated schedule never loses its firing.
@MainActor
enum ScheduledAutomationDelivery {
    struct BatchEpoch {
        let globalRevision: UInt64
        let scheduleRevisions: [AutomationScheduleKey: UInt64]
    }

    struct CurrentState {
        let enabled: Bool
        let globalRevision: UInt64
        let paused: Bool
        let scheduleRevision: UInt64
    }

    static func deliver(
        _ firings: [AutomationScheduler.Firing],
        batchEpoch: BatchEpoch,
        currentState: (AutomationScheduleKey) -> CurrentState,
        delivery: (AutomationScheduler.Firing) async -> Void
    ) async {
        for firing in firings {
            let key = AutomationScheduleKey(
                pluginID: firing.pluginID,
                scheduleID: firing.scheduleID
            )
            let state = currentState(key)
            guard state.enabled,
                  state.globalRevision == batchEpoch.globalRevision
            else { return }
            guard let batchScheduleRevision = batchEpoch.scheduleRevisions[key],
                  !state.paused,
                  state.scheduleRevision == batchScheduleRevision
            else { continue }
            await delivery(firing)
        }
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

    /// T-046, the tick edge: a 30-second cadence is the firing resolution for
    /// minute-grained wall-clock schedules. The scheduler advances state per tick,
    /// so cadence affects latency only, never firing count.
    func startAutomationScheduling() {
        guard automationTickTask == nil else { return }
        automationScheduler.reconcile(host.plugins, now: Date())
        automationTickTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(
                        for: .seconds(30),
                        tolerance: .seconds(5)
                    )
                } catch {
                    return
                }
                guard let self else { return }
                // Always advance the scheduler. When delivery is disabled, dropping the
                // due values here prevents a catch-up burst when the preference is restored.
                let firings = self.automationScheduler.tick(now: Date())
                let scheduleRevisions = Dictionary(
                    uniqueKeysWithValues: firings.map { firing in
                        let key = AutomationScheduleKey(
                            pluginID: firing.pluginID,
                            scheduleID: firing.scheduleID
                        )
                        return (
                            key,
                            self.prefs.automationScheduleRevision(for: key)
                        )
                    }
                )
                await ScheduledAutomationDelivery.deliver(
                    firings,
                    batchEpoch: .init(
                        globalRevision: self.prefs.automationSchedulesRevision,
                        scheduleRevisions: scheduleRevisions
                    ),
                    currentState: { key in
                        .init(
                            enabled: self.prefs.preferences.automationSchedulesEnabled,
                            globalRevision: self.prefs.automationSchedulesRevision,
                            paused: self.prefs.preferences.pausedAutomationSchedules
                                .contains(key),
                            scheduleRevision: self.prefs
                                .automationScheduleRevision(for: key)
                        )
                    },
                    delivery: { firing in
                        await self.deliverAndRecord(firing)
                    }
                )
            }
        }
    }

    /// T-060: Run now. Mints a manual firing for an armed schedule and sends it down
    /// the exact path a scheduled one takes — the plugin sees only the payload's
    /// `trigger` differ. An unarmed schedule has nothing to fire and does nothing.
    func runAutomationNow(pluginID: PluginID, scheduleID: String) async {
        guard let firing = automationScheduler.manualFiring(
            pluginID: pluginID,
            scheduleID: scheduleID,
            now: Date()
        ) else { return }
        await deliverAndRecord(firing)
    }

    /// Host-native per-schedule delivery preference. The manifest remains the source of
    /// the schedule declaration, and manual Run Now remains available while paused.
    func setAutomationSchedulePaused(
        pluginID: PluginID,
        scheduleID: String,
        paused: Bool
    ) {
        let key = AutomationScheduleKey(
            pluginID: pluginID,
            scheduleID: scheduleID
        )
        if paused {
            prefs.preferences.pausedAutomationSchedules.insert(key)
        } else {
            prefs.preferences.pausedAutomationSchedules.remove(key)
        }
        automationScheduler.setPausedScheduleKeys(
            prefs.preferences.pausedAutomationSchedules
        )
    }

    /// The one place a firing is delivered and remembered — the tick loop and Run
    /// now share it, so the history can never disagree with delivery.
    private func deliverAndRecord(
        _ firing: AutomationScheduler.Firing
    ) async {
        let delivered = await host.automationFired(firing)
        automationScheduler.recordRun(
            firing,
            firedAt: Date(),
            delivered: delivered
        )
    }

    func performStart() async {
        // First, so the watchdog is already running while the rest of startup happens —
        // plugin runtime loading and restored-pane reconciliation can wedge the main runloop,
        // and a detector armed afterwards would miss them.
        diagnostics.start()
        do {
            try Task.checkCancellation()
            try await intentRuntime.start()
            try Task.checkCancellation()
            try await host.loadAll()
            webSurfaces.reconcile(catalog: store.catalog, host: host)
            // The restored catalog reaches the view-instance reconciler here or never:
            // reconcile otherwise runs only from workspace mutations, and a launch that
            // restores panes performs none — every restored plugin pane would sit on
            // "Plugin view unavailable" until the first unrelated workspace change.
            await host.reconcileViewInstances(from: store.catalog)
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
            startAutomationScheduling()
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
        agentLens: AgentLensPool,
        agentSessionRegistry: AgentSessionRegistry,
        webSurfaces: PluginWebSurfacePool,
        catalogStore: WorkspaceCatalogStore,
        automation: AutomationScheduler
    ) {
        host.onPluginLifecycleChanged = {
            [weak host, weak store, weak webSurfaces] plugins in
            guard let host, let store else { return }
            webSurfaces?.reconcile(catalog: store.catalog, host: host)
            // T-046: the lifecycle channel is the scheduler's reconcile trigger —
            // load, hot reload, enable/disable, and uninstall all pass through here.
            automation.reconcile(plugins, now: Date())
        }

        store.onEvents = {
            [weak host, weak store, weak terminalSurfaces, weak agentLens, weak webSurfaces]
                events,
                snapshot in
            terminalSurfaces?.retainOnly(Set(snapshot.allSlotIDs))
            agentLens?.retainOnly(Set(snapshot.allSlotIDs))
            Task { await agentSessionRegistry.retainOnly(Set(snapshot.allSlotIDs)) }
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
            Task { @MainActor [weak host, weak store] in
                guard let host else { return }
                await host.emit(
                    workspaceEvents: events,
                    in: snapshot
                )
                // Event delivery can suspend, and sibling mutation tasks are not
                // ordered. Reconcile from live state so a late task cannot restore
                // the captured catalog that preceded a plugin pane assignment.
                if let store {
                    await host.reconcileViewInstances(from: store.catalog)
                }
            }
            for event in events {
                if case let .slotFocused(slotID, _, _) = event,
                   let store, let terminalSurfaces {
                    PaneFocusRouting.scheduleFocusCommand(
                        for: slotID,
                        store: store,
                        surfaces: terminalSurfaces
                    )
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
        PaneFocusRouting.connect(store: store, surfaces: terminalSurfaces)
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
        store.newPaneSizingProvider = {
            NewPaneSizing(maximumWidth: prefs.preferences.newPaneMaximumWidth)
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
