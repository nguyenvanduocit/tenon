import Foundation
import JavaScriptCore

/// A command a plugin registered through `tenon.commands.register`.
public struct PluginCommand: Equatable, Identifiable {
    public let pluginName: String
    public let commandID: String
    public let title: String

    /// Globally unique — two plugins may both register a command called "reload".
    public var id: String { "\(pluginName).\(commandID)" }
}

/// One row of a plugin's sidebar section or slot view — the shared declarative row shape.
public struct SidebarItem: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let depth: Int
    public let icon: String?
}

/// A view a plugin provides through `tenon.views` — the content of a `.pluginView` slot.
/// Unlike the one-section sidebar, a plugin may provide several, keyed by `viewID`.
public struct PluginViewInfo: Equatable, Identifiable {
    public let viewID: String
    public let title: String
    public let items: [SidebarItem]
    public var id: String { viewID }
}

/// One plugin == one JSContext. Tearing this object down destroys the context,
/// its callbacks, and every JSValue the plugin ever handed us. That is the whole
/// hot-reload story: drop the runtime, build a new one.
public final class PluginRuntime {
    public let manifest: PluginManifest
    public let directory: URL

    /// Last value passed to `tenon.statusBar.set`. nil until the plugin sets one.
    public private(set) var statusBarText: String?
    public private(set) var commands: [PluginCommand] = []

    /// This plugin's sidebar section — one per plugin, like the status bar item.
    /// nil title means the plugin never called `tenon.sidebar.set`.
    public private(set) var sidebarTitle: String?
    public private(set) var sidebarItems: [SidebarItem] = []

    /// One entry per distinct blocked call — e.g. subscribing to a `terminal.*`
    /// event without declaring `terminal.read`. Deduplicated so a retry loop
    /// can't flood the log or the UI.
    public private(set) var permissionViolations: [String] = []

    /// Views this plugin provides through `tenon.views`, keyed by viewID.
    private struct ViewState { var title: String; var items: [SidebarItem]; var select: JSValue? }
    private var viewStates: [String: ViewState] = [:]

    /// Snapshot of this plugin's views, for the host to aggregate. Sorted for stable UI.
    public var views: [PluginViewInfo] {
        viewStates
            .map { PluginViewInfo(viewID: $0.key, title: $0.value.title, items: $0.value.items) }
            .sorted { $0.viewID < $1.viewID }
    }

    private var context: JSContext
    private var commandFunctions: [String: JSValue] = [:]
    private var eventHandlers: [String: [JSValue]] = [:]
    private var sidebarSelectHandler: JSValue?
    /// Settings keys the plugin asked for without declaring — warned about once each.
    private var warnedSettingKeys: Set<String> = []
    private let emitLog: (String) -> Void
    private let onStateChange: () -> Void
    /// Delivers `tenon.terminal.write` text to whatever terminal the host has
    /// attached. Returns false when no terminal is attached, so the plugin gets
    /// an explicit error instead of a write into the void.
    private let terminalWrite: (String) -> Bool
    /// The user's override for one of this plugin's settings, nil when unchanged —
    /// `tenon.settings.get` falls back to the manifest default then.
    private let settingOverride: (String) -> Any?
    /// This plugin's persistent KV namespace, owned by the host so values
    /// survive reloads.
    private let storageGet: (String) -> Any?
    private let storageSet: (String, Any) -> Void
    /// Answers `tenon.workspace.get()` with the structural workspace state.
    private let workspaceState: () -> [String: Any]
    /// Delivers allowed `tenon.workspace.*` mutations to the host.
    private let workspaceCommand: (WorkspaceCommand) -> Void

    /// Loads and evaluates `main.js` immediately. Any JS exception is reported through `log`
    /// rather than thrown — a broken plugin must not take down the host.
    public init(
        manifest: PluginManifest,
        directory: URL,
        log: @escaping (String) -> Void,
        onStateChange: @escaping () -> Void,
        terminalWrite: @escaping (String) -> Bool,
        settingOverride: @escaping (String) -> Any?,
        storageGet: @escaping (String) -> Any?,
        storageSet: @escaping (String, Any) -> Void,
        workspaceState: @escaping () -> [String: Any],
        workspaceCommand: @escaping (WorkspaceCommand) -> Void
    ) throws {
        self.manifest = manifest
        self.directory = directory
        self.emitLog = log
        self.onStateChange = onStateChange
        self.terminalWrite = terminalWrite
        self.settingOverride = settingOverride
        self.storageGet = storageGet
        self.storageSet = storageSet
        self.workspaceState = workspaceState
        self.workspaceCommand = workspaceCommand

        guard let ctx = JSContext() else {
            throw PluginLoadError.manifestInvalid(directory.path, "could not create JSContext")
        }
        self.context = ctx

        let entrypoint = directory.appendingPathComponent("main.js")
        guard let source = try? String(contentsOf: entrypoint, encoding: .utf8) else {
            throw PluginLoadError.entrypointMissing(entrypoint.path)
        }

        let pluginName = manifest.name
        context.exceptionHandler = { _, exception in
            log("[\(pluginName)] JS exception: \(exception?.toString() ?? "unknown")")
        }

        installAPI()
        context.evaluateScript(source, withSourceURL: entrypoint)
    }

    // MARK: - The `tenon` object. This is the ENTIRE plugin-visible surface.

    private func installAPI() {
        // JavaScriptCore seeds every new context with a `console` object. Plugins get the
        // `tenon` API and the ECMAScript builtins — nothing else — so drop it.
        for hostExtra in ["console"] {
            context.globalObject.deleteProperty(hostExtra)
        }

        let tenon = JSValue(newObjectIn: context)!

        // --- tenon.statusBar.set(text) ---
        let statusBar = JSValue(newObjectIn: context)!
        let setStatus: @convention(block) (String) -> Void = { [weak self] text in
            guard let self else { return }
            self.statusBarText = text
            self.onStateChange()
        }
        statusBar.setObject(setStatus, forKeyedSubscript: "set" as NSString)
        tenon.setObject(statusBar, forKeyedSubscript: "statusBar" as NSString)

        // --- tenon.commands.register(id, title, fn) ---
        let commandsObj = JSValue(newObjectIn: context)!
        let register: @convention(block) (String, String, JSValue) -> Void = { [weak self] id, title, fn in
            guard let self else { return }
            guard fn.isObject, !fn.isUndefined, !fn.isNull else {
                self.emitLog("[\(self.manifest.name)] commands.register(\"\(id)\"): handler is not a function")
                return
            }
            self.commandFunctions[id] = fn
            let command = PluginCommand(pluginName: self.manifest.name, commandID: id, title: title)
            if let existing = self.commands.firstIndex(where: { $0.commandID == id }) {
                self.commands[existing] = command
            } else {
                self.commands.append(command)
            }
            self.onStateChange()
        }
        commandsObj.setObject(register, forKeyedSubscript: "register" as NSString)
        tenon.setObject(commandsObj, forKeyedSubscript: "commands" as NSString)

        // --- tenon.events.on(event, fn) ---
        // Part of THE permission gate: sensitive topics are checked in this function
        // and nowhere else. Blocked calls no-op with a suggestion — they never throw,
        // so one undeclared capability can't take down the rest of the plugin.
        let eventsObj = JSValue(newObjectIn: context)!
        let on: @convention(block) (String, JSValue) -> Void = { [weak self] event, fn in
            guard let self else { return }
            guard fn.isObject, !fn.isUndefined, !fn.isNull else {
                self.emitLog("[\(self.manifest.name)] events.on(\"\(event)\"): handler is not a function")
                return
            }
            if event.hasPrefix("terminal."),
               self.requirePermission("terminal.read", api: #"events.on("\#(event)")"#) != nil {
                return
            }
            self.eventHandlers[event, default: []].append(fn)
        }
        eventsObj.setObject(on, forKeyedSubscript: "on" as NSString)
        tenon.setObject(eventsObj, forKeyedSubscript: "events" as NSString)

        // --- tenon.fs.* --- gated behind filesystem.read / filesystem.write.
        // Every call returns a plain object: {ok: true, ...} or {ok: false, error} —
        // explicit, never a silent undefined.
        let fs = JSValue(newObjectIn: context)!

        let readDir: @convention(block) (String) -> [String: Any] = { [weak self] path in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("filesystem.read", api: "fs.readDir(...)") {
                return ["ok": false, "error": error]
            }
            let expanded = (path as NSString).expandingTildeInPath
            do {
                let fm = FileManager.default
                let entries: [[String: Any]] = try fm.contentsOfDirectory(atPath: expanded)
                    .sorted()
                    .map { name in
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: expanded + "/" + name, isDirectory: &isDir)
                        return ["name": name, "isDirectory": isDir.boolValue]
                    }
                return ["ok": true, "entries": entries]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        }
        fs.setObject(readDir, forKeyedSubscript: "readDir" as NSString)

        let readFile: @convention(block) (String) -> [String: Any] = { [weak self] path in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("filesystem.read", api: "fs.readFile(...)") {
                return ["ok": false, "error": error]
            }
            let expanded = (path as NSString).expandingTildeInPath
            do {
                return ["ok": true, "content": try String(contentsOfFile: expanded, encoding: .utf8)]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        }
        fs.setObject(readFile, forKeyedSubscript: "readFile" as NSString)

        let exists: @convention(block) (String) -> [String: Any] = { [weak self] path in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("filesystem.read", api: "fs.exists(...)") {
                return ["ok": false, "error": error]
            }
            let expanded = (path as NSString).expandingTildeInPath
            return ["ok": true, "exists": FileManager.default.fileExists(atPath: expanded)]
        }
        fs.setObject(exists, forKeyedSubscript: "exists" as NSString)

        let writeFile: @convention(block) (String, String) -> [String: Any] = { [weak self] path, content in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("filesystem.write", api: "fs.writeFile(...)") {
                return ["ok": false, "error": error]
            }
            let expanded = (path as NSString).expandingTildeInPath
            do {
                try content.write(toFile: expanded, atomically: true, encoding: .utf8)
                return ["ok": true]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        }
        fs.setObject(writeFile, forKeyedSubscript: "writeFile" as NSString)

        tenon.setObject(fs, forKeyedSubscript: "fs" as NSString)

        // --- tenon.process.exec(command, args, callback) --- gated behind process.exec.
        // The process runs on a background queue with a 10s kill timeout; the JSContext
        // is main-thread only, so the callback JSValue is touched exclusively on main.
        let processObj = JSValue(newObjectIn: context)!
        let exec: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] command, argsValue, callback in
            guard let self else { return }
            guard callback.isObject, !callback.isUndefined, !callback.isNull else {
                self.emitLog("[\(self.manifest.name)] process.exec(\"\(command)\"): callback is not a function")
                return
            }
            if let error = self.requirePermission("process.exec", api: "process.exec(...)") {
                callback.call(withArguments: [["ok": false, "error": error]])
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = (argsValue.toArray() ?? []).map { "\($0)" }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let finish: ([String: Any]) -> Void = { result in
                DispatchQueue.main.async {
                    callback.call(withArguments: [result])
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    finish(["ok": false, "error": "could not run \(command): \(error.localizedDescription)"])
                    return
                }

                // Drain both pipes on their own queues *while* the child runs. Reading
                // only after waitUntilExit deadlocks any command whose output exceeds
                // the pipe buffer (~64KB): the child blocks on write(), so it never
                // exits and the 10s timeout SIGKILLs it with its output lost.
                // readDataToEndOfFile returns at EOF, i.e. once the child's write ends
                // close; the group's leave→wait ordering publishes the boxes safely.
                let stdoutBox = DataBox()
                let stderrBox = DataBox()
                let drain = DispatchGroup()
                drain.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    drain.leave()
                }
                drain.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    drain.leave()
                }

                let exited = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()
                    exited.signal()
                }
                if exited.wait(timeout: .now() + 10) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                    finish(["ok": false, "error": "\(command) timed out after 10s and was killed"])
                    return
                }
                drain.wait()
                let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
                finish([
                    "ok": true,
                    "status": Int(process.terminationStatus),
                    "stdout": stdout,
                    "stderr": stderr,
                ])
            }
        }
        processObj.setObject(exec, forKeyedSubscript: "exec" as NSString)
        tenon.setObject(processObj, forKeyedSubscript: "process" as NSString)

        // --- tenon.terminal.write(text) --- gated behind terminal.write.
        let terminal = JSValue(newObjectIn: context)!
        let write: @convention(block) (String) -> [String: Any] = { [weak self] text in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("terminal.write", api: "terminal.write(...)") {
                return ["ok": false, "error": error]
            }
            guard self.terminalWrite(text) else {
                return ["ok": false, "error": "no terminal attached"]
            }
            return ["ok": true]
        }
        terminal.setObject(write, forKeyedSubscript: "write" as NSString)
        tenon.setObject(terminal, forKeyedSubscript: "terminal" as NSString)

        // --- tenon.settings.get(key) --- free tier: reading this plugin's OWN
        // declared settings is not sensitive. An undeclared key returns null with
        // a ⚠️ hint (once per key) — a typo is a bug to surface, not a violation.
        let settingsObj = JSValue(newObjectIn: context)!
        let getSetting: @convention(block) (String) -> JSValue? = { [weak self] key in
            guard let self else { return nil }
            guard let spec = self.manifest.settings.first(where: { $0.key == key }) else {
                self.warnUndeclaredSetting(key)
                return JSValue(nullIn: self.context)
            }
            guard let value = self.settingOverride(key) ?? spec.defaultValue?.anyValue else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: value, in: self.context)
        }
        settingsObj.setObject(getSetting, forKeyedSubscript: "get" as NSString)
        tenon.setObject(settingsObj, forKeyedSubscript: "settings" as NSString)

        // --- tenon.storage.get/set --- free tier: a private, per-plugin KV
        // namespace persisted by the host — it survives reloads and restarts and
        // leaks nothing about the user or other plugins.
        let storage = JSValue(newObjectIn: context)!
        let getStored: @convention(block) (String) -> JSValue? = { [weak self] key in
            guard let self else { return nil }
            guard let value = self.storageGet(key) else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: value, in: self.context)
        }
        storage.setObject(getStored, forKeyedSubscript: "get" as NSString)

        let setStored: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            guard let object = value.toObject(), JSONSerialization.isValidJSONObject([object]) else {
                self.emitLog("[\(self.manifest.name)] storage.set(\"\(key)\"): value must be JSON-encodable")
                return
            }
            self.storageSet(key, object)
        }
        storage.setObject(setStored, forKeyedSubscript: "set" as NSString)
        tenon.setObject(storage, forKeyedSubscript: "storage" as NSString)

        // --- tenon.sidebar.set / onSelect --- free-tier UI contribution, one
        // section per plugin, mirroring statusBar: the last `set` wins.
        let sidebar = JSValue(newObjectIn: context)!
        let setSidebar: @convention(block) (JSValue) -> Void = { [weak self] section in
            guard let self else { return }
            guard let dict = section.toDictionary() as? [String: Any],
                  let title = dict["title"] as? String,
                  let rawItems = dict["items"] as? [[String: Any]]
            else {
                self.emitLog("[\(self.manifest.name)] sidebar.set(...): expected {title, items: [{id, label, depth?, icon?}]}")
                return
            }
            self.sidebarTitle = title
            self.sidebarItems = self.parseRows(rawItems, api: "sidebar.set")
            self.onStateChange()
        }
        sidebar.setObject(setSidebar, forKeyedSubscript: "set" as NSString)

        let onSelect: @convention(block) (JSValue) -> Void = { [weak self] fn in
            guard let self else { return }
            guard fn.isObject, !fn.isUndefined, !fn.isNull else {
                self.emitLog("[\(self.manifest.name)] sidebar.onSelect(...): handler is not a function")
                return
            }
            self.sidebarSelectHandler = fn
        }
        sidebar.setObject(onSelect, forKeyedSubscript: "onSelect" as NSString)
        tenon.setObject(sidebar, forKeyedSubscript: "sidebar" as NSString)

        // --- tenon.views.register / set / onSelect --- free-tier UI contribution, exactly
        // like sidebar but keyed by viewID: a plugin may provide many views, each fillable
        // into any slot (content kind `.pluginView`). No permission — VISION §5.
        let viewsObj = JSValue(newObjectIn: context)!
        let registerView: @convention(block) (String, JSValue) -> Void = { [weak self] viewID, spec in
            guard let self else { return }
            let title = (spec.toDictionary()?["title"] as? String) ?? viewID
            var state = self.viewStates[viewID] ?? ViewState(title: title, items: [], select: nil)
            state.title = title
            self.viewStates[viewID] = state
            self.onStateChange()
        }
        viewsObj.setObject(registerView, forKeyedSubscript: "register" as NSString)

        let setView: @convention(block) (String, JSValue) -> Void = { [weak self] viewID, payload in
            guard let self else { return }
            guard let dict = payload.toDictionary() as? [String: Any],
                  let rawItems = dict["items"] as? [[String: Any]]
            else {
                self.emitLog("[\(self.manifest.name)] views.set(\"\(viewID)\"): expected {title?, items: [{id, label, depth?, icon?}]}")
                return
            }
            var state = self.viewStates[viewID] ?? ViewState(title: (dict["title"] as? String) ?? viewID, items: [], select: nil)
            if let title = dict["title"] as? String { state.title = title }
            state.items = self.parseRows(rawItems, api: "views.set(\"\(viewID)\")")
            self.viewStates[viewID] = state
            self.onStateChange()
        }
        viewsObj.setObject(setView, forKeyedSubscript: "set" as NSString)

        let onSelectView: @convention(block) (String, JSValue) -> Void = { [weak self] viewID, fn in
            guard let self else { return }
            guard fn.isObject, !fn.isUndefined, !fn.isNull else {
                self.emitLog("[\(self.manifest.name)] views.onSelect(\"\(viewID)\"): handler is not a function")
                return
            }
            var state = self.viewStates[viewID] ?? ViewState(title: viewID, items: [], select: nil)
            state.select = fn
            self.viewStates[viewID] = state
        }
        viewsObj.setObject(onSelectView, forKeyedSubscript: "onSelect" as NSString)
        tenon.setObject(viewsObj, forKeyedSubscript: "views" as NSString)

        // --- tenon.workspace --- get() is free: tab/slot STRUCTURE (IDs and
        // shapes) is exactly what the free-tier workspace.* events already carry.
        // Driving the workspace is gated behind workspace.control.
        let workspace = JSValue(newObjectIn: context)!
        let getWorkspace: @convention(block) () -> [String: Any] = { [weak self] in
            guard let self else { return ["tabs": [], "activeSlotId": NSNull()] }
            return self.workspaceState()
        }
        workspace.setObject(getWorkspace, forKeyedSubscript: "get" as NSString)

        let newTab: @convention(block) () -> [String: Any] = { [weak self] in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("workspace.control", api: "workspace.newTab()") {
                return ["ok": false, "error": error]
            }
            self.workspaceCommand(.newTab)
            return ["ok": true]
        }
        workspace.setObject(newTab, forKeyedSubscript: "newTab" as NSString)

        let split: @convention(block) (String) -> [String: Any] = { [weak self] axis in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("workspace.control", api: "workspace.split(...)") {
                return ["ok": false, "error": error]
            }
            let parsed: SplitAxis
            switch axis {
            case "horizontal":
                parsed = .horizontal
            case "vertical":
                parsed = .vertical
            default:
                return [
                    "ok": false,
                    "error": #"axis must be "horizontal" or "vertical", got "\#(axis)""#,
                ]
            }
            self.workspaceCommand(.split(parsed))
            return ["ok": true]
        }
        workspace.setObject(split, forKeyedSubscript: "split" as NSString)

        let focusSlot: @convention(block) (String) -> [String: Any] = { [weak self] slotId in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("workspace.control", api: "workspace.focusSlot(...)") {
                return ["ok": false, "error": error]
            }
            guard let id = UUID(uuidString: slotId) else {
                return ["ok": false, "error": #"slotId must be a UUID string, got "\#(slotId)""#]
            }
            self.workspaceCommand(.focusSlot(id))
            return ["ok": true]
        }
        workspace.setObject(focusSlot, forKeyedSubscript: "focusSlot" as NSString)

        let closeSlot: @convention(block) (String) -> [String: Any] = { [weak self] slotId in
            guard let self else { return ["ok": false, "error": "plugin is shutting down"] }
            if let error = self.requirePermission("workspace.control", api: "workspace.closeSlot(...)") {
                return ["ok": false, "error": error]
            }
            guard let id = UUID(uuidString: slotId) else {
                return ["ok": false, "error": #"slotId must be a UUID string, got "\#(slotId)""#]
            }
            self.workspaceCommand(.closeSlot(id))
            return ["ok": true]
        }
        workspace.setObject(closeSlot, forKeyedSubscript: "closeSlot" as NSString)
        tenon.setObject(workspace, forKeyedSubscript: "workspace" as NSString)

        // --- tenon.log(text) ---
        let logFn: @convention(block) (String) -> Void = { [weak self] text in
            guard let self else { return }
            self.emitLog("[\(self.manifest.name)] \(text)")
        }
        tenon.setObject(logFn, forKeyedSubscript: "log" as NSString)

        tenon.setObject(manifest.name, forKeyedSubscript: "pluginName" as NSString)
        tenon.setObject("0.2", forKeyedSubscript: "apiVersion" as NSString)

        context.setObject(tenon, forKeyedSubscript: "tenon" as NSString)
    }

    /// The single permission check every gated capability goes through. Returns nil
    /// when the manifest grants `permission`; otherwise reports the violation (deduped)
    /// and returns the message the caller hands back to JS as `{ok: false, error}`.
    private func requirePermission(_ permission: String, api: String) -> String? {
        guard !manifest.permissions.contains(permission) else { return nil }
        let message = #"\#(api) requires the "\#(permission)" permission — add it to the permissions array in manifest.json"#
        reportViolation(message)
        return message
    }

    private func reportViolation(_ message: String) {
        guard !permissionViolations.contains(message) else { return }
        permissionViolations.append(message)
        emitLog("⛔ [\(manifest.name)] \(message)")
        onStateChange()
    }

    /// Parse the shared declarative row shape used by both `sidebar.set` and `views.set`.
    /// Rows missing an id or label are skipped with a one-line warning, never fatal.
    private func parseRows(_ rawItems: [[String: Any]], api: String) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for raw in rawItems {
            guard let id = raw["id"] as? String, let label = raw["label"] as? String else {
                emitLog("[\(manifest.name)] \(api): every item needs an id and a label — skipped one")
                continue
            }
            items.append(SidebarItem(
                id: id,
                label: label,
                depth: (raw["depth"] as? NSNumber)?.intValue ?? 0,
                icon: raw["icon"] as? String
            ))
        }
        return items
    }

    /// A typo'd settings key is a plugin bug, not a security event: warn once per key.
    private func warnUndeclaredSetting(_ key: String) {
        guard !warnedSettingKeys.contains(key) else { return }
        warnedSettingKeys.insert(key)
        emitLog(#"⚠️ [\#(manifest.name)] settings.get("\#(key)"): "\#(key)" is not declared in manifest.json's settings array — returning null"#)
    }

    // MARK: - Host → plugin calls

    @discardableResult
    public func invoke(commandID: String) -> Bool {
        guard let fn = commandFunctions[commandID] else {
            emitLog("[\(manifest.name)] no such command: \(commandID)")
            return false
        }
        fn.call(withArguments: [])
        return true
    }

    public func emit(event: String, payload: [String: Any]) {
        guard let handlers = eventHandlers[event], !handlers.isEmpty else { return }
        for handler in handlers {
            handler.call(withArguments: [payload])
        }
    }

    @discardableResult
    public func invokeSidebarSelect(itemID: String) -> Bool {
        guard let handler = sidebarSelectHandler else {
            emitLog("[\(manifest.name)] no sidebar.onSelect handler registered")
            return false
        }
        handler.call(withArguments: [itemID])
        return true
    }

    @discardableResult
    public func invokeViewSelect(viewID: String, itemID: String) -> Bool {
        guard let handler = viewStates[viewID]?.select else {
            emitLog("[\(manifest.name)] no views.onSelect handler registered for \"\(viewID)\"")
            return false
        }
        handler.call(withArguments: [itemID])
        return true
    }

    public func handles(event: String) -> Bool {
        !(eventHandlers[event]?.isEmpty ?? true)
    }

    /// Evaluate an expression inside this plugin's context. Test/diagnostic only —
    /// plugins never get this.
    public func evaluateForTesting(_ script: String) -> JSValue? {
        context.evaluateScript(script)
    }

    deinit {
        commandFunctions.removeAll()
        eventHandlers.removeAll()
        sidebarSelectHandler = nil
        viewStates.removeAll()
        context.exceptionHandler = nil
    }
}

/// A tiny reference holder so a background pipe-drain can stash its result for the
/// parent block to read after the `DispatchGroup` barrier publishes it.
private final class DataBox {
    var data = Data()
}
