import Foundation
import Observation

/// What the UI needs to know about one loaded, disabled, or failed plugin.
public struct PluginSnapshot: Equatable, Identifiable {
    public let name: String
    public let version: String
    public let permissions: [String]
    public let unknownPermissions: [String]
    /// Manifest-declared settings, so the settings UI can render a form per plugin.
    public let settingSpecs: [PluginSettingSpec]
    public let isLoaded: Bool
    public let isEnabled: Bool
    public let permissionViolations: [String]
    public let error: String?

    public var id: String { name }
}

/// A status-bar item contributed by a plugin.
public struct StatusItem: Equatable, Identifiable {
    public let pluginName: String
    public let text: String
    public var id: String { pluginName }
}

/// A plugin's sidebar contribution — one section per plugin, like the status bar.
public struct SidebarSection: Equatable, Identifiable {
    public let pluginName: String
    public let title: String
    public let items: [SidebarItem]
    public var id: String { pluginName }
}

/// A plugin view fillable into a slot (`SlotContent.pluginView`). A plugin may offer many.
public struct PluginViewSection: Equatable, Identifiable {
    public let pluginName: String
    public let viewID: String
    public let title: String
    public let items: [SidebarItem]
    public var id: String { "\(pluginName).\(viewID)" }
}

/// A workspace mutation requested by a plugin through `tenon.workspace.*`
/// (gated behind `workspace.control`). The app shell decides how to apply it.
public enum WorkspaceCommand: Equatable {
    case newTab
    case split(SplitAxis)
    case focusSlot(UUID)
    case closeSlot(UUID)
}

/// Owns every plugin runtime, aggregates their contributions, and drives hot reload.
///
/// All mutation happens on whatever thread calls in; the watcher and tick timer both
/// hop to the main queue first, so in practice everything is main-thread serialized.
@Observable
public final class PluginHost {
    public private(set) var plugins: [PluginSnapshot] = []
    public private(set) var statusItems: [StatusItem] = []
    public private(set) var commands: [PluginCommand] = []
    public private(set) var sidebarSections: [SidebarSection] = []
    public private(set) var pluginViews: [PluginViewSection] = []
    public private(set) var log: [String] = []

    @ObservationIgnored public let pluginsRoot: URL

    /// Per-plugin setting overrides (`.settings.json`). `tenon.settings.get`
    /// reads through this; `setSetting(_:forKey:pluginNamed:)` writes it.
    public let settings: SettingsStore
    /// Per-plugin persistent KV behind `tenon.storage` (`.storage.json`).
    private let storage: PluginStorage

    /// The app shell points this at the focused terminal; `tenon.terminal.write`
    /// is delivered through it. nil means no terminal is attached, and plugins
    /// get an explicit `{ok: false, error: "no terminal attached"}` back.
    @ObservationIgnored public var onTerminalWrite: ((String) -> Void)?

    /// The app shell answers `tenon.workspace.get()` through this. nil (nothing
    /// attached) reads as an empty workspace: `{tabs: [], activeSlotId: null}`.
    @ObservationIgnored public var workspaceStateProvider: (() -> [String: Any])?
    /// Receives every allowed `tenon.workspace.*` mutation. nil drops the command.
    @ObservationIgnored public var onWorkspaceCommand: ((WorkspaceCommand) -> Void)?

    @ObservationIgnored private var runtimes: [String: PluginRuntime] = [:]
    /// Directory name → plugin name, so a reload can find the runtime a changed folder owns.
    @ObservationIgnored private var directoryNames: [String: String] = [:]
    @ObservationIgnored private var failures: [String: PluginSnapshot] = [:]
    /// Snapshots for plugins that are present on disk but switched off, keyed by directory name.
    @ObservationIgnored private var disabledSnapshots: [String: PluginSnapshot] = [:]
    /// Plugin names the user switched off. Persisted as `.disabled.json` next to the
    /// plugins (dot-prefixed, so discovery and the watcher both ignore it).
    @ObservationIgnored public private(set) var disabledPluginNames: Set<String> = []
    @ObservationIgnored private var watcher: PluginWatcher?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var tickCount = 0

    @ObservationIgnored public var maxLogLines = 500

    public init(pluginsRoot: URL) {
        self.pluginsRoot = pluginsRoot
        self.settings = SettingsStore(pluginsRoot: pluginsRoot)
        self.storage = PluginStorage(pluginsRoot: pluginsRoot)
        disabledPluginNames = Self.readDisabledNames(in: pluginsRoot)
    }

    // MARK: - Loading

    public func loadAll() {
        runtimes.removeAll()
        directoryNames.removeAll()
        failures.removeAll()
        disabledSnapshots.removeAll()

        let dirs = PluginLoader.discover(in: pluginsRoot)
        if dirs.isEmpty {
            appendLog("host: no plugins found under \(pluginsRoot.path)")
        }
        for dir in dirs {
            load(directory: dir)
        }
        publish()
    }

    /// Load or reload a single plugin directory. Replaces any existing runtime for that
    /// name; a disabled plugin gets a snapshot (so the UI can re-enable it) but no runtime.
    public func load(directory: URL) {
        let dirName = directory.lastPathComponent
        do {
            let manifest = try PluginLoader.loadManifest(at: directory)

            guard !disabledPluginNames.contains(manifest.name) else {
                if let existing = directoryNames[dirName] {
                    runtimes.removeValue(forKey: existing)
                }
                directoryNames[dirName] = manifest.name
                failures.removeValue(forKey: dirName)
                disabledSnapshots[dirName] = PluginSnapshot(
                    name: manifest.name,
                    version: manifest.version,
                    permissions: manifest.permissions,
                    unknownPermissions: manifest.unknownPermissions,
                    settingSpecs: manifest.settings,
                    isLoaded: false,
                    isEnabled: false,
                    permissionViolations: [],
                    error: nil
                )
                appendLog("host: \(manifest.name) is disabled — not loading")
                return
            }
            disabledSnapshots.removeValue(forKey: dirName)

            for perm in manifest.unknownPermissions {
                appendLog("⚠️ host: plugin \"\(manifest.name)\" declares unknown permission \"\(perm)\" — ignored")
            }

            let pluginName = manifest.name
            let runtime = try PluginRuntime(
                manifest: manifest,
                directory: directory,
                log: { [weak self] line in self?.appendLog(line) },
                onStateChange: { [weak self] in self?.publish() },
                terminalWrite: { [weak self] text in
                    guard let handler = self?.onTerminalWrite else { return false }
                    handler(text)
                    return true
                },
                settingOverride: { [weak self] key in
                    self?.settings.value(for: key, plugin: pluginName)
                },
                storageGet: { [weak self] key in
                    self?.storage.value(forKey: key, plugin: pluginName)
                },
                storageSet: { [weak self] key, value in
                    self?.storage.setValue(value, forKey: key, plugin: pluginName)
                },
                workspaceState: { [weak self] in
                    self?.workspaceStateProvider?() ?? ["tabs": [], "activeSlotId": NSNull()]
                },
                workspaceCommand: { [weak self] command in
                    self?.onWorkspaceCommand?(command)
                }
            )
            runtimes[manifest.name] = runtime
            directoryNames[dirName] = manifest.name
            failures.removeValue(forKey: dirName)
            appendLog("host: loaded \(manifest.name) v\(manifest.version) [\(manifest.permissions.joined(separator: ", "))]")
        } catch {
            let message = (error as? PluginLoadError)?.description ?? "\(error)"
            appendLog("host: failed to load \(dirName): \(message)")
            if let existing = directoryNames[dirName] {
                runtimes.removeValue(forKey: existing)
            }
            failures[dirName] = PluginSnapshot(
                name: dirName,
                version: "—",
                permissions: [],
                unknownPermissions: [],
                settingSpecs: [],
                isLoaded: false,
                isEnabled: true,
                permissionViolations: [],
                error: message
            )
        }
    }

    /// Hot reload: destroy the JSContext for this directory and build a fresh one.
    public func reload(directoryNamed dirName: String) {
        let directory = pluginsRoot.appendingPathComponent(dirName)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            // Directory disappeared — drop whatever it contributed.
            if let name = directoryNames.removeValue(forKey: dirName) {
                runtimes.removeValue(forKey: name)
                appendLog("host: unloaded \(name) (directory removed)")
            }
            failures.removeValue(forKey: dirName)
            disabledSnapshots.removeValue(forKey: dirName)
            publish()
            return
        }

        if let name = directoryNames[dirName] {
            runtimes.removeValue(forKey: name) // deinit tears down the JSContext
        }
        appendLog("host: 🔁 reloading \(dirName)")
        load(directory: directory)
        publish()
    }

    // MARK: - Settings & sidebar

    /// Persist a user override for one plugin setting and tell that plugin — and
    /// only that plugin — via a `settings.changed` event.
    public func setSetting(_ value: Any, forKey key: String, pluginNamed name: String) {
        settings.setValue(value, forKey: key, plugin: name)
        runtimes[name]?.emit(event: "settings.changed", payload: ["key": key, "value": value])
    }

    /// A sidebar row was clicked; route it to the owning plugin's onSelect handler.
    @discardableResult
    public func invokeSidebarSelect(pluginName: String, itemID: String) -> Bool {
        guard let runtime = runtimes[pluginName] else {
            appendLog("host: plugin \(pluginName) is not loaded")
            return false
        }
        return runtime.invokeSidebarSelect(itemID: itemID)
    }

    /// A row in a plugin view slot was clicked; route it to that view's onSelect handler.
    @discardableResult
    public func invokeViewSelect(pluginName: String, viewID: String, itemID: String) -> Bool {
        guard let runtime = runtimes[pluginName] else {
            appendLog("host: plugin \(pluginName) is not loaded")
            return false
        }
        return runtime.invokeViewSelect(viewID: viewID, itemID: itemID)
    }

    // MARK: - Enable / disable

    /// Disabling tears down the plugin's runtime — its JSContext, contributions, and
    /// subscriptions die with it. Enabling rebuilds it from disk with fresh state.
    /// The choice is persisted and survives restarts.
    public func setEnabled(_ enabled: Bool, pluginNamed name: String) {
        if enabled {
            guard disabledPluginNames.contains(name) else { return }
            disabledPluginNames.remove(name)
            persistDisabledNames()
            appendLog("host: enabled \(name)")
            if let dirName = directoryNames.first(where: { $0.value == name })?.key {
                load(directory: pluginsRoot.appendingPathComponent(dirName))
            }
        } else {
            guard !disabledPluginNames.contains(name) else { return }
            disabledPluginNames.insert(name)
            persistDisabledNames()
            appendLog("host: disabled \(name)")
            if let dirName = directoryNames.first(where: { $0.value == name })?.key {
                // Re-running load records the disabled snapshot and drops the runtime.
                load(directory: pluginsRoot.appendingPathComponent(dirName))
            } else {
                runtimes.removeValue(forKey: name)
            }
        }
        publish()
    }

    private static func disabledFile(in root: URL) -> URL {
        root.appendingPathComponent(".disabled.json")
    }

    private static func readDisabledNames(in root: URL) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: disabledFile(in: root).path),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }

    private func persistDisabledNames() {
        let file = Self.disabledFile(in: pluginsRoot)
        do {
            if disabledPluginNames.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } else {
                try JSONEncoder().encode(disabledPluginNames.sorted()).write(to: file, options: .atomic)
            }
        } catch {
            appendLog("host: could not persist the disabled-plugin list: \(error)")
        }
    }

    // MARK: - Hot reload wiring

    public func startWatching() {
        guard watcher == nil else { return }
        let w = PluginWatcher(root: pluginsRoot) { [weak self] changed in
            guard let self else { return }
            for dirName in changed.sorted() {
                self.reload(directoryNamed: dirName)
            }
        }
        w.start()
        watcher = w
        appendLog("host: watching \(pluginsRoot.path) for changes")
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Events

    /// Fires `tick` once per `interval` with `{ time, count }`. This is the demo event
    /// that proves the host can call back into JS repeatedly.
    /// `HH:mm:ss` for the `tick` demo payload. Hoisted to a single instance so the
    /// timer doesn't build a fresh DateFormatter — an expensive object — every fire.
    private static let tickTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public func startTicking(interval: TimeInterval = 1.0) {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickCount += 1
            self.emit(event: "tick", payload: [
                "time": Self.tickTimeFormatter.string(from: Date.now),
                "count": self.tickCount,
            ])
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    public func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    public func emit(event: String, payload: [String: Any]) {
        for runtime in runtimes.values {
            runtime.emit(event: event, payload: payload)
        }
    }

    /// Convenience for terminal surfaces. `slotID` identifies the terminal slot.
    public func terminalTitleChanged(_ title: String, slotID: UUID? = nil) {
        var payload: [String: Any] = ["title": title]
        if let slotID {
            payload["slotId"] = slotID.uuidString
        }
        emit(event: "terminal.title-changed", payload: payload)
    }

    // MARK: - Commands

    @discardableResult
    public func invoke(_ command: PluginCommand) -> Bool {
        guard let runtime = runtimes[command.pluginName] else {
            appendLog("host: plugin \(command.pluginName) is not loaded")
            return false
        }
        return runtime.invoke(commandID: command.commandID)
    }

    // MARK: - State

    public func appendLog(_ line: String) {
        log.append(line)
        if log.count > maxLogLines {
            log.removeFirst(log.count - maxLogLines)
        }
    }

    /// Recomputes the aggregate view of every runtime. Cheap; called on any plugin state change.
    private func publish() {
        let sorted = runtimes.values.sorted { $0.manifest.name < $1.manifest.name }

        statusItems = sorted.compactMap { runtime in
            guard let text = runtime.statusBarText else { return nil }
            return StatusItem(pluginName: runtime.manifest.name, text: text)
        }

        commands = sorted.flatMap(\.commands)

        sidebarSections = sorted.compactMap { runtime in
            guard let title = runtime.sidebarTitle else { return nil }
            return SidebarSection(pluginName: runtime.manifest.name, title: title, items: runtime.sidebarItems)
        }

        pluginViews = sorted.flatMap { runtime in
            runtime.views.map {
                PluginViewSection(pluginName: runtime.manifest.name, viewID: $0.viewID, title: $0.title, items: $0.items)
            }
        }

        var snapshots = sorted.map { runtime in
            PluginSnapshot(
                name: runtime.manifest.name,
                version: runtime.manifest.version,
                permissions: runtime.manifest.permissions,
                unknownPermissions: runtime.manifest.unknownPermissions,
                settingSpecs: runtime.manifest.settings,
                isLoaded: true,
                isEnabled: true,
                permissionViolations: runtime.permissionViolations,
                error: nil
            )
        }
        snapshots.append(contentsOf: disabledSnapshots.values)
        snapshots.append(contentsOf: failures.values)
        plugins = snapshots.sorted { $0.name < $1.name }
    }

    // MARK: - Test hooks

    public func runtime(named name: String) -> PluginRuntime? { runtimes[name] }
    public var loadedPluginNames: [String] { runtimes.keys.sorted() }
}
