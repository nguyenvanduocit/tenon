// @domain: terminal-surface
import AppKit
import GhosttyKit
import SwiftUI
import TenonCore

enum GhosttyClipboardConfirmationKind: Equatable {
    case unsafePaste
    case osc52Read
    case osc52Write
}

struct GhosttyClipboardConfirmationResolution: Equatable {
    let contents: String
    let confirmed: Bool
}

@MainActor
enum GhosttyClipboardConfirmationPresenter {
    typealias DecisionHandler = (
        GhosttyClipboardConfirmationKind,
        String,
        @escaping (Bool) -> Void
    ) -> Void

    /// Test seam and embedding seam. Production leaves this nil and uses NSAlert.
    static var decisionHandler: DecisionHandler?

    static func request(
        kind: GhosttyClipboardConfirmationKind,
        contents: String,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        if let decisionHandler {
            decisionHandler(kind, contents, completion)
            return
        }

        guard let window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .unsafePaste:
            alert.messageText = "Allow unsafe paste?"
            alert.informativeText =
                "The clipboard contains content Ghostty considers unsafe to paste."
        case .osc52Read:
            alert.messageText = "Allow terminal clipboard access?"
            alert.informativeText =
                "A process in this terminal requested the system clipboard."
        case .osc52Write:
            alert.messageText = "Allow terminal to change the clipboard?"
            alert.informativeText =
                "A process in this terminal requested permission to write to the system clipboard."
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    static func resolution(
        approved: Bool,
        contents: String
    ) -> GhosttyClipboardConfirmationResolution {
        GhosttyClipboardConfirmationResolution(
            contents: approved ? contents : "",
            confirmed: approved
        )
    }
}

@MainActor
enum GhosttyClipboardWriter {
    /// Test seam. Production writes to the standard macOS pasteboard.
    static var writeHandler: ((String) -> Void)?

    static func request(
        contents: String,
        requiresConfirmation: Bool,
        window: NSWindow?
    ) {
        guard requiresConfirmation else {
            write(contents)
            return
        }
        GhosttyClipboardConfirmationPresenter.request(
            kind: .osc52Write,
            contents: contents,
            window: window
        ) { approved in
            guard approved else { return }
            write(contents)
        }
    }

    private static func write(_ contents: String) {
        if let writeHandler {
            writeHandler(contents)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }
}

struct GhosttyRenderedCell: Equatable {
    let codepoint: UInt32
    let flags: UInt16
}

struct GhosttySurfaceSize: Equatable {
    let columns: Int
    let rows: Int
    let widthPixels: Int
    let heightPixels: Int
    let cellWidthPixels: Int
    let cellHeightPixels: Int
}

// The libghostty embedding, following Muxy's proven pattern but reduced to what
// Tenon needs: render, type, resize, focus, clipboard, and the one plugin-visible
// event (`terminal.title-changed`). Deliberately out of scope: splits, IME preedit
// polish, cmd-click links, selection reading, search, scrollbar overlay.

// MARK: - Process-wide runtime  @domain: terminal-surface

/// Owns the single `ghostty_app_t`. libghostty is initialized once per process;
/// every surface shares this app and gets its own `ghostty_surface_t`.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    /// Surface callbacks carry an opaque monotonically increasing token rather
    /// than an unretained Swift object pointer. A callback already queued when a
    /// surface is torn down therefore resolves to nil instead of dereferencing
    /// freed memory, and tokens are never reused during the process lifetime.
    private final class WeakView {
        weak var value: GhosttyNSView?

        init(_ value: GhosttyNSView) {
            self.value = value
        }
    }

    private static var nextViewToken: UInt = 1
    private static var liveViews: [UInt: WeakView] = [:]

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        if let resources = Self.resourcesDir() {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        } else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
        }
        if let terminfo = Self.terminfoDir() {
            setenv("TERMINFO", terminfo, 1)
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            TenonLog.terminal.error("ghostty_init failed")
            return
        }

        // Defaults only — deliberately not loading the user's ghostty config so the
        // terminal behaves the same on every machine.
        guard let cfg = ghostty_config_new() else {
            TenonLog.terminal.error("ghostty_config_new failed")
            return
        }
        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in
            GhosttyRuntime.wakeupCallback()
        }
        rt.action_cb = { _, target, action in
            GhosttyRuntime.actionCallback(target: target, action: action)
        }
        rt.read_clipboard_cb = { userdata, _, state in
            GhosttyRuntime.readClipboardCallback(userdata: userdata, state: state)
        }
        rt.confirm_read_clipboard_cb = { userdata, content, state, request in
            GhosttyRuntime.confirmReadClipboardCallback(
                userdata: userdata,
                content: content,
                state: state,
                request: request
            )
        }
        rt.write_clipboard_cb = { userdata, _, content, len, requiresConfirmation in
            GhosttyRuntime.writeClipboardCallback(
                userdata: userdata,
                content: content,
                length: len,
                requiresConfirmation: requiresConfirmation
            )
        }
        rt.close_surface_cb = { userdata, _ in
            GhosttyRuntime.closeSurfaceCallback(userdata: userdata)
        }

        guard let created = ghostty_app_new(&rt, cfg) else {
            TenonLog.terminal.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = created
        config = cfg
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    fileprivate static func register(_ view: GhosttyNSView) -> UInt {
        let token = nextViewToken
        precondition(token != 0, "ghostty callback token space exhausted")
        nextViewToken &+= 1
        liveViews[token] = WeakView(view)
        return token
    }

    fileprivate static func unregister(_ token: UInt) {
        liveViews.removeValue(forKey: token)
    }

    private nonisolated static func wakeupCallback() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                shared.tick()
            }
            return
        }
        DispatchQueue.main.async {
            shared.tick()
        }
    }

    private nonisolated static func actionCallback(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                handleAction(target: target, action: action)
            }
        }
        DispatchQueue.main.async {
            _ = handleAction(target: target, action: action)
        }
        return false
    }

    private nonisolated static func readClipboardCallback(
        userdata: UnsafeMutableRawPointer?,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        let userdataBits = userdata.map(UInt.init(bitPattern:))
        let stateBits = state.map(UInt.init(bitPattern:))
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                readClipboard(userdataBits: userdataBits, stateBits: stateBits)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                readClipboard(userdataBits: userdataBits, stateBits: stateBits)
            }
        }
    }

    private nonisolated static func confirmReadClipboardCallback(
        userdata: UnsafeMutableRawPointer?,
        content: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let content else { return }
        let contents = String(cString: content)
        let userdataBits = userdata.map(UInt.init(bitPattern:))
        let stateBits = state.map(UInt.init(bitPattern:))
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                confirmReadClipboard(
                    userdataBits: userdataBits,
                    contents: contents,
                    stateBits: stateBits,
                    request: request
                )
            }
            return
        }
        DispatchQueue.main.async {
            confirmReadClipboard(
                userdataBits: userdataBits,
                contents: contents,
                stateBits: stateBits,
                request: request
            )
        }
    }

    private nonisolated static func writeClipboardCallback(
        userdata: UnsafeMutableRawPointer?,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        length: Int,
        requiresConfirmation: Bool
    ) {
        guard let content, length > 0 else { return }
        var contents: String?
        for item in UnsafeBufferPointer(start: content, count: length) {
            guard let data = item.data, let mime = item.mime,
                  String(cString: mime).hasPrefix("text/plain")
            else {
                continue
            }
            contents = String(cString: data)
            break
        }
        guard let contents else { return }
        let userdataBits = userdata.map(UInt.init(bitPattern:))
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                writeClipboard(
                    userdataBits: userdataBits,
                    contents: contents,
                    requiresConfirmation: requiresConfirmation
                )
            }
            return
        }
        DispatchQueue.main.async {
            writeClipboard(
                userdataBits: userdataBits,
                contents: contents,
                requiresConfirmation: requiresConfirmation
            )
        }
    }

    private nonisolated static func closeSurfaceCallback(
        userdata: UnsafeMutableRawPointer?
    ) {
        let userdataBits = userdata.map(UInt.init(bitPattern:))
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                closeSurface(userdataBits: userdataBits)
            }
            return
        }
        DispatchQueue.main.async {
            closeSurface(userdataBits: userdataBits)
        }
    }

    private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = view(fromTarget: target),
                  let titlePtr = action.action.set_title.title else { return true }
            let title = String(cString: titlePtr)
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true

        // ghostty's own keybindings (super+t, super+d, …) fire these actions after
        // performKeyEquivalent hands the key to the surface — route them into the
        // workspace instead of dropping them.
        case GHOSTTY_ACTION_NEW_TAB:
            guard let view = view(fromTarget: target) else { return true }
            DispatchQueue.main.async { view.onNewTab?() }
            return true
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let view = view(fromTarget: target) else { return true }
            let direction = action.action.new_split
            let axis: SplitAxis =
                (direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT)
                    ? .horizontal : .vertical
            DispatchQueue.main.async { view.onNewSplit?(axis) }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let view = view(fromTarget: target) else { return true }
            DispatchQueue.main.async { view.onGotoSplit?() }
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            // OSC 133 semantic-prompt marker: a foreground shell command just finished.
            guard let view = view(fromTarget: target) else { return true }
            DispatchQueue.main.async { view.commandFinishedCount += 1 }
            return true

        case GHOSTTY_ACTION_PWD:
            // OSC 7: the shell reports its working directory, on each prompt after a `cd`.
            // Push, not poll — which is why the pane's cwd needs no timer and no
            // foreground-pid inspection. A full-screen TUI emits no prompt, so the last
            // reported directory persists for its duration; that is the directory the work
            // belongs to, and the value we want the panels anchored to.
            guard let view = view(fromTarget: target),
                  let pwdPtr = action.action.pwd.pwd else { return true }
            let pwd = String(cString: pwdPtr)
            DispatchQueue.main.async { view.onPwdChange?(pwd) }
            return true

        default:
            return false
        }
    }

    private static func readClipboard(
        userdataBits: UInt?,
        stateBits: UInt?
    ) -> Bool {
        guard let view = view(fromTokenBits: userdataBits),
              let surface = view.surface
        else {
            return false
        }
        let state = stateBits.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(
        userdataBits: UInt?,
        contents: String,
        stateBits: UInt?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = view(fromTokenBits: userdataBits),
              let state = stateBits.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        else {
            return
        }

        let kind: GhosttyClipboardConfirmationKind
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            kind = .unsafePaste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            kind = .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            // OSC 52 writes carry their confirmation requirement on
            // write_clipboard_cb and do not complete through this state.
            return
        default:
            return
        }
        view.requestClipboardConfirmation(
            kind: kind,
            contents: contents,
            state: state
        )
    }

    private static func writeClipboard(
        userdataBits: UInt?,
        contents: String,
        requiresConfirmation: Bool
    ) {
        guard let view = view(fromTokenBits: userdataBits) else { return }
        GhosttyClipboardWriter.request(
            contents: contents,
            requiresConfirmation: requiresConfirmation,
            window: view.window
        )
    }

    private static func closeSurface(userdataBits: UInt?) {
        view(fromTokenBits: userdataBits)?.onProcessExit?()
    }

    private static func view(fromUserdata userdata: UnsafeMutableRawPointer?) -> GhosttyNSView? {
        view(fromTokenBits: userdata.map(UInt.init(bitPattern:)))
    }

    private static func view(fromTokenBits token: UInt?) -> GhosttyNSView? {
        guard let token else { return nil }
        return liveViews[token]?.value
    }

    private static func view(fromTarget target: ghostty_target_s) -> GhosttyNSView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return nil }
        return view(fromUserdata: userdata)
    }

    private static func resourcesDir() -> String? {
        if let override = ProcessInfo.processInfo.environment[
            "TENON_GHOSTTY_RESOURCES_DIR"
        ] {
            return override
        }
        guard let candidate = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
        else { return nil }
        guard FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("shell-integration").path
        ) else { return nil }
        return candidate.path
    }

    private static func terminfoDir() -> String? {
        if let override = ProcessInfo.processInfo.environment["TENON_TERMINFO_DIR"] {
            return override
        }
        guard let candidate = Bundle.main.resourceURL?
            .appendingPathComponent("terminfo", isDirectory: true),
            FileManager.default.fileExists(atPath: candidate.path)
        else { return nil }
        return candidate.path
    }
}

// MARK: - The NSView hosting one ghostty surface  @domain: terminal-surface

/// Uniquely owned native resources whose teardown is independent of actor state.
///
/// Swift 6 treats `NSView.deinit` as nonisolated even when the view is
/// `@MainActor`. Keeping these values behind one plain owner lets ARC perform
/// deterministic teardown without weakening the view's actor isolation.
private final class GhosttyNSViewResources {
    var surface: ghostty_surface_t?
    var keyWindowObservers: [NSObjectProtocol] = []
    var cStrings: [UnsafeMutablePointer<CChar>] = []
    var envVarsBuffer: UnsafeMutablePointer<ghostty_env_var_s>?

    deinit {
        keyWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let surface {
            ghostty_surface_free(surface)
        }
        cStrings.forEach { free($0) }
        envVarsBuffer?.deallocate()
    }
}

@MainActor
final class GhosttyNSView: NSView {
    var onTitleChange: ((String) -> Void)?
    /// The shell's working directory, reported through OSC 7 (`GHOSTTY_ACTION_PWD`).
    var onPwdChange: ((String) -> Void)?
    var onProcessExit: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onNewSplit: ((SplitAxis) -> Void)?
    var onGotoSplit: (() -> Void)?
    var onFocusGained: (() -> Void)?

    private let resources = GhosttyNSViewResources()
    private(set) var surface: ghostty_surface_t? {
        get { resources.surface }
        set { resources.surface = newValue }
    }
    private(set) var appliedDisplayID: UInt32?
    private var callbackToken: UInt?
    /// Bumped each time the shell reports a finished command (OSC 133 → COMMAND_FINISHED), so
    /// `tenon-cli pane.wait --for command-finished` can detect a completion since it started.
    var commandFinishedCount = 0
    private var pendingSurfaceCreation = false
    /// Input handed to this pane before its surface existed, flushed once it does.
    private var pendingInput = ""
    /// Owned backing for `ghostty_surface_config_s.env_vars` — the pointer must outlive the config
    /// passed to `ghostty_surface_new`, so it lives in `resources`, not a local.
    private let command: String?
    private let workingDirectory: URL
    private let environment: [String: String]

    // Set while interpretKeyEvents() runs so insertText() can tell "text from this
    // key press" apart from programmatic insertion.
    private var keyTextAccumulator: [String]?

    private var _markedText = ""
    private var _markedRange = NSRange(location: NSNotFound, length: 0)
    private var _selectedRange = NSRange(location: 0, length: 0)

    init(
        command: String? = nil,
        workingDirectory: URL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ),
        environment: [String: String] = [:]
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        super.init(frame: .zero)
        callbackToken = GhosttyRuntime.register(self)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let callbackToken {
            // Swift 6 deinits are nonisolated. The registry only holds a weak
            // reference (already nil as deallocation begins), so deferred
            // main-actor removal cannot expose the dying view to a callback.
            DispatchQueue.main.async {
                GhosttyRuntime.unregister(callbackToken)
            }
        }
    }

    // MARK: Surface lifecycle  @domain: terminal-surface

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        resources.keyWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        resources.keyWindowObservers = []

        guard let window else {
            // T-031: a card detached on a tab or workspace switch keeps its surface,
            // its PTY and its scrollback — teardown is slot-closure only. The renderer
            // alone is told nobody can see it, so hidden viewed panes stop paying for
            // frames (the Kero "hidden tab renderer memory" trim).
            if let surface {
                ghostty_surface_set_occlusion(surface, false)
            }
            return
        }

        if surface == nil {
            createSurface()
        }
        if let surface {
            ghostty_surface_set_occlusion(
                surface,
                window.occlusionState.contains(.visible)
            )
        }
        updateSurfaceGeometry()

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            resources.keyWindowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                // NotificationCenter promises this block on the main queue; the
                // imported Objective-C callback lacks an actor annotation.
                MainActor.assumeIsolated {
                    self?.syncFocus()
                }
            })
        }
        resources.keyWindowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateSurfaceGeometry()
            }
        })
        // T-031: a minimized or fully covered window is as hidden as a detached card —
        // the renderer pauses, the PTY never notices.
        resources.keyWindowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let surface = self.surface, let window = self.window
                else { return }
                ghostty_surface_set_occlusion(
                    surface,
                    window.occlusionState.contains(.visible)
                )
            }
        })

        // Focus is model-driven: this surface must NOT grab first responder on
        // mount. Cards remount whenever their tab is re-selected, so a self-grab
        // here fires `becomeFirstResponder → onFocusGained → focusSlot`, which
        // would clobber the tab's remembered `activeSlotID` with whichever slot
        // happened to mount last. The workspace's `.slotFocused` events drive
        // focus through `pool.focusSurface`; genuine user focus still flows via
        // `mouseDown`. See WorkspaceStore / TenonApp focus wiring.
    }

    private func createSurface() {
        guard surface == nil, let app = GhosttyRuntime.shared.app else { return }
        guard let backingSize = backingPixelSize() else {
            // Zero-sized until SwiftUI lays us out; setFrameSize retries.
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = callbackToken.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        config.wait_after_command = false

        if let directory = strdup(workingDirectory.path) {
            resources.cStrings.append(directory)
            config.working_directory = UnsafePointer(directory)
        }
        if let command, let commandPointer = strdup(command) {
            resources.cStrings.append(commandPointer)
            config.command = UnsafePointer(commandPointer)
        }
        if !environment.isEmpty {
            let buffer = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: environment.count)
            var count = 0
            for (key, value) in environment {
                guard let keyPointer = strdup(key), let valuePointer = strdup(value) else { continue }
                resources.cStrings.append(keyPointer)
                resources.cStrings.append(valuePointer)
                (buffer + count).initialize(to: ghostty_env_var_s(
                    key: UnsafePointer(keyPointer),
                    value: UnsafePointer(valuePointer)
                ))
                count += 1
            }
            resources.envVarsBuffer = buffer
            config.env_vars = buffer
            config.env_var_count = numericCast(count)
        }

        surface = ghostty_surface_new(app, &config)
        guard let surface else {
            TenonLog.terminal.error("ghostty_surface_new failed")
            return
        }

        ghostty_surface_set_size(surface, backingSize.width, backingSize.height)
        updateSurfaceGeometry()
        syncFocus()

        // Input that arrived before this surface existed (a pane opened and handed a command
        // in the same click) goes in now that there is a PTY to write to.
        if !pendingInput.isEmpty {
            let queued = pendingInput
            pendingInput = ""
            sendText(queued)
        }
    }

    private func backingPixelSize() -> (width: UInt32, height: UInt32)? {
        let size = convertToBacking(bounds).size
        let width = Int(floor(size.width))
        let height = Int(floor(size.height))
        guard width > 0, height > 0 else { return nil }
        return (UInt32(width), UInt32(height))
    }

    // MARK: Geometry  @domain: terminal-surface

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation {
            createSurface()
        }
        updateSurfaceGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceGeometry()
    }

    private func updateSurfaceGeometry() {
        guard let surface, let window else { return }
        layer?.contentsScale = window.backingScaleFactor
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        if let displayID = Self.displayID(for: window.screen ?? NSScreen.main) {
            ghostty_surface_set_display_id(surface, displayID)
            appliedDisplayID = displayID
        }
        if let backingSize = backingPixelSize() {
            ghostty_surface_set_size(surface, backingSize.width, backingSize.height)
        }
    }

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        guard let value = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] else { return nil }
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        return value as? UInt32
    }

    // MARK: Focus  @domain: terminal-surface

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            syncFocus()
            // Tell the workspace this slot took focus. Re-focusing the already
            // focused slot is a no-op there, so this can't loop.
            onFocusGained?()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { syncFocus() }
        return result
    }

    private func syncFocus() {
        guard let surface else { return }
        let focused = window?.isKeyWindow == true
            && (window?.firstResponder === self || window?.firstResponder === inputContext)
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: Keyboard  @domain: terminal-surface

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Let AppKit translate the press (dead keys, IME) into text via insertText.
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let accumulated = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        syncPreedit()

        if accumulated.isEmpty {
            var key = makeKeyEvent(event, action: action)
            key.composing = hasMarkedText()
            _ = ghostty_surface_key(surface, key)
        } else {
            for text in accumulated {
                var key = makeKeyEvent(event, action: action)
                key.consumed_mods = Self.consumedMods(from: flags)
                text.withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            }
        }
    }

    // Every press that reaches keyDown goes to the PTY, so the command selectors
    // interpretKeyEvents derives from those same presses (deleteBackward: for
    // Backspace, cursor moves, …) are already-handled input. NSResponder's default
    // would forward them up the chain, where they die unaccepted and AppKit beeps
    // for a key the terminal did handle. Scoped to this view: everything else
    // keeps the default, so truly unhandled input still gets its system feedback.
    override func doCommand(by selector: Selector) {}

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let key = makeKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface, !hasMarkedText() else { return }
        let action: ghostty_input_action_e = Self.isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        let key = makeKeyEvent(event, action: action)
        _ = ghostty_surface_key(surface, key)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface,
              window?.firstResponder === self || window?.firstResponder === inputContext
        else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            return false
        }
        let key = makeKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        // Only swallow the shortcut if ghostty has a binding for it (copy, paste, …);
        // otherwise AppKit continues to keyDown, which sends control input such as
        // Ctrl-D to the PTY instead of treating it as an application shortcut.
        if ghostty_surface_key_is_binding(surface, key, nil) {
            _ = ghostty_surface_key(surface, key)
            return true
        }
        return false
    }

    private func makeKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(from: event)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.text = nil
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    private static func mods(from event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        // Right-side variants come from raw device-dependent bits.
        let raw = flags.rawValue
        if raw & 0x04 != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & 0x2000 != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & 0x40 != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & 0x10 != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private static func consumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private static func isFlagPress(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 55, 54: return flags.contains(.command)
        case 57: return flags.contains(.capsLock)
        default: return false
        }
    }

    // MARK: Mouse  @domain: terminal-surface

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    /// libghostty wants top-left-origin coordinates.
    private func mousePoint(from event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, Self.mods(from: event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, Self.mods(from: event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(from: event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, Self.mods(from: event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(from: event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, Self.mods(from: event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(from: event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, Self.mods(from: event))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    func sendText(_ text: String) {
        // A pane created this instant has no `ghostty_surface_t` yet — it is built when the
        // view lands in a window. Dropping the text here made `terminal.run.v1`
        // open a terminal tab and then do nothing; hold it until `createSurface` flushes it.
        guard let surface else {
            pendingInput += text
            return
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ghostty_surface_send_input_raw(surface, base, UInt(buffer.count))
        }
    }

    func requestClipboardConfirmation(
        kind: GhosttyClipboardConfirmationKind,
        contents: String,
        state: UnsafeMutableRawPointer
    ) {
        GhosttyClipboardConfirmationPresenter.request(
            kind: kind,
            contents: contents,
            window: window
        ) { [weak self] approved in
            let resolution = GhosttyClipboardConfirmationPresenter.resolution(
                approved: approved,
                contents: contents
            )
            self?.completeClipboardConfirmation(
                contents: resolution.contents,
                state: state,
                confirmed: resolution.confirmed
            )
        }
    }

    func completeClipboardConfirmation(
        contents: String,
        state: UnsafeMutableRawPointer,
        confirmed: Bool
    ) {
        guard let surface else { return }
        contents.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                state,
                confirmed
            )
        }
    }

    var renderedCells: [GhosttyRenderedCell] {
        guard let surface else { return [] }
        var output = ghostty_cells_s()
        guard ghostty_surface_read_cells(surface, &output) else { return [] }
        defer { ghostty_surface_free_cells(surface, &output) }
        guard let cells = output.cells, output.cells_len > 0 else { return [] }
        return UnsafeBufferPointer(start: cells, count: Int(output.cells_len)).map {
            GhosttyRenderedCell(codepoint: $0.codepoint, flags: $0.flags)
        }
    }

    /// The whole retained screen, oldest row first.
    ///
    /// `GHOSTTY_POINT_SCREEN` is the coordinate space that includes scrollback, and the
    /// `TOP_LEFT`/`BOTTOM_RIGHT` coord modes name its ends without us having to know how
    /// many rows there are — which is the only way to ask, since the emulator publishes no
    /// scrollback size. That is also why this reads the whole buffer rather than the one
    /// page a caller asked for: the page bound applies to what leaves the host, and the
    /// row count the cursor is checked against has to come from somewhere.
    var scrollbackLines: [String] {
        guard let surface else { return [] }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        selection.rectangle = false

        var output = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &output) else {
            return []
        }
        defer { ghostty_surface_free_text(surface, &output) }
        guard let text = output.text, output.text_len > 0 else { return [] }
        let buffer = UnsafeBufferPointer(
            start: text,
            count: Int(output.text_len)
        )
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            return []
        }
        return string.components(separatedBy: "\n")
    }

    var renderedText: String {
        guard let surface else { return "" }
        var output = ghostty_cells_s()
        guard ghostty_surface_read_cells(surface, &output) else { return "" }
        defer { ghostty_surface_free_cells(surface, &output) }

        let columns = Int(output.cols)
        let rows = Int(output.rows)
        guard columns > 0, rows > 0, let cells = output.cells else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            var line = ""
            line.reserveCapacity(columns)
            for column in 0..<columns {
                let codepoint = cells[row * columns + column].codepoint
                if codepoint == 0 {
                    line.append(" ")
                } else if let scalar = Unicode.Scalar(codepoint) {
                    line.append(Character(scalar))
                } else {
                    line.append(" ")
                }
            }
            lines.append(line.replacingOccurrences(
                of: #"\s+$"#,
                with: "",
                options: .regularExpression
            ))
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The same screen read, answered as a value instead of as text.
    ///
    /// `renderedText` above follows this read with one Swift `String` per row, appended a
    /// `Character` at a time, plus one ICU regular expression per row to trim trailing blanks.
    /// The attention poll asks every open pane five times a second on the main thread and does
    /// nothing with the answer but compare it, so this hashes the codepoints where they already
    /// are. Incident `0005-87f24878` measured the difference: 83% of a stalled main thread
    /// inside `renderedText`, reached from `SurfacePool.pollActivity` (T-141).
    var screenFingerprint: Int {
        guard let surface else { return 0 }
        var output = ghostty_cells_s()
        guard ghostty_surface_read_cells(surface, &output) else { return 0 }
        defer { ghostty_surface_free_cells(surface, &output) }

        let columns = Int(output.cols)
        let rows = Int(output.rows)
        guard columns > 0, rows > 0, let cells = output.cells else { return 0 }
        var hasher = Hasher()
        hasher.combine(columns)
        hasher.combine(rows)
        for index in 0 ..< (rows * columns) {
            hasher.combine(cells[index].codepoint)
        }
        return hasher.finalize()
    }

    var surfaceSize: GhosttySurfaceSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return GhosttySurfaceSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            widthPixels: Int(size.width_px),
            heightPixels: Int(size.height_px),
            cellWidthPixels: Int(size.cell_width_px),
            cellHeightPixels: Int(size.cell_height_px)
        )
    }

    var foregroundPID: UInt64? {
        guard let surface else { return nil }
        return ghostty_surface_foreground_pid(surface)
    }

    /// The pane's PTY path, copied out of libghostty's allocation.
    ///
    /// `ghostty_surface_tty_name` hands back a `ghostty_string_s` that Tenon owns and must
    /// return exactly once. The bytes are copied into a Swift `String` before the `defer`
    /// frees them, so nothing here escapes holding a pointer into freed memory — and the free
    /// runs on every exit path, including the one where the bytes are not valid UTF-8.
    var ttyName: String? {
        guard let surface else { return nil }
        let reported = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(reported) }
        guard let pointer = reported.ptr, reported.len > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(reported.len))
        let copied = String(decoding: bytes, as: UTF8.self)
        return copied.isEmpty ? nil : copied
    }

    var processExited: Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: Preedit  @domain: terminal-surface

    private func syncPreedit() {
        guard let surface else { return }
        if hasMarkedText(), !_markedText.isEmpty {
            let byteCount = _markedText.utf8.count
            _markedText.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(byteCount))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: - NSTextInputClient (minimal: enough for typing + basic IME)  @domain: terminal-surface

extension GhosttyNSView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        unmarkText()
        guard !text.isEmpty else { return }

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            // Programmatic insertion (e.g. IME commit outside a key press).
            text.withCString { ptr in
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        _markedText = text
        _markedRange = text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: text.utf16.count)
        _selectedRange = NSRange(location: 0, length: 0)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard hasMarkedText() else { return }
        _markedText = ""
        _markedRange = NSRange(location: NSNotFound, length: 0)
        _selectedRange = NSRange(location: 0, length: 0)
        syncPreedit()
    }

    func selectedRange() -> NSRange { _selectedRange }
    func markedRange() -> NSRange { _markedRange }
    func hasMarkedText() -> Bool { _markedRange.location != NSNotFound }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewPt = NSPoint(x: x, y: bounds.height - y)
        let screenPt = window?.convertPoint(toScreen: convert(viewPt, to: nil)) ?? viewPt
        return NSRect(x: screenPt.x, y: screenPt.y - h, width: w, height: h)
    }
}

// MARK: - TerminalSurface conformance  @domain: terminal-surface

final class GhosttySurface: TerminalSurface {
    let backendName = "libghostty"
    var onTitleChange: ((String) -> Void)?
    /// The shell's working directory, reported through OSC 7 (`GHOSTTY_ACTION_PWD`).
    var onPwdChange: ((String) -> Void)?
    var onProcessExit: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onNewSplit: ((SplitAxis) -> Void)?
    var onGotoSplit: (() -> Void)?
    var onFocusGained: (() -> Void)?

    private let view: GhosttyNSView

    init(
        command: String? = nil,
        workingDirectory: URL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ),
        environment: [String: String] = [:]
    ) {
        view = GhosttyNSView(
            command: command,
            workingDirectory: workingDirectory,
            environment: environment
        )
        view.onTitleChange = { [weak self] title in self?.onTitleChange?(title) }
        view.onPwdChange = { [weak self] pwd in self?.onPwdChange?(pwd) }
        view.onProcessExit = { [weak self] in self?.onProcessExit?() }
        view.onNewTab = { [weak self] in self?.onNewTab?() }
        view.onNewSplit = { [weak self] orientation in self?.onNewSplit?(orientation) }
        view.onGotoSplit = { [weak self] in self?.onGotoSplit?() }
        view.onFocusGained = { [weak self] in self?.onFocusGained?() }
    }

    var renderedCells: [GhosttyRenderedCell] { view.renderedCells }
    var renderedText: String { view.renderedText }
    var screenFingerprint: Int { view.screenFingerprint }
    var scrollbackLines: [String] { view.scrollbackLines }
    var commandFinishedCount: Int { view.commandFinishedCount }
    var surfaceSize: GhosttySurfaceSize? { view.surfaceSize }
    var foregroundPID: UInt64? { view.foregroundPID }
    var ttyName: String? { view.ttyName }
    var processExited: Bool { view.processExited }
    var appliedDisplayID: UInt32? { view.appliedDisplayID }
    var nativeView: NSView { view }

    /// Route keyboard focus to this surface's view after a slot focus change.
    func focus() {
        view.window?.makeFirstResponder(view)
    }

    /// T-084: stop the pane's job tree, then let the surface go.
    ///
    /// `ghostty_surface_free` in `GhosttyNSViewResources.deinit` does send SIGHUP to the
    /// child's process group, and for an ordinary foreground command that is enough. It is not
    /// enough for the two cases a supervision workspace actually accumulates: a process that
    /// ignores SIGHUP (there is no SIGKILL anywhere in the pinned libghostty), and a background
    /// job leading its own process group (measured surviving a pane close on 2026-08-07).
    /// `TerminalJobTerminator` covers both by sweeping the pane's tty and escalating.
    ///
    /// The callbacks are cleared first so a dying pane cannot report a title, a directory, or
    /// its own process exit into a slot the workspace has already forgotten.
    func terminate() {
        onTitleChange = nil
        onPwdChange = nil
        onProcessExit = nil
        onNewTab = nil
        onNewSplit = nil
        onGotoSplit = nil
        onFocusGained = nil

        let foreground = view.foregroundPID.flatMap { reported -> pid_t? in
            guard reported > 1, reported <= UInt64(pid_t.max) else { return nil }
            return pid_t(reported)
        }
        // T-140: an exited shell used to end the close right here, which left whatever it had
        // `nohup`ed or disowned running on a tty nobody would sweep again. The pane still owns
        // those jobs, and its tty still names them — `ttyName` is fixed for the surface's life,
        // where `foregroundPID` dies with the shell. A pane that never reported a pty has no
        // set of processes it can prove it owns, and signalling a bare pid would be guessing.
        guard let tty = view.ttyName else { return }
        // Nothing in the close path may block on this: the escalation waits 120 ms, and the pane
        // is already gone from the catalog by the time it runs. `terminate` is nonisolated async,
        // so its `ps` reads and its sleep leave the main thread the moment they are awaited —
        // the task stays on `MainActor` only to own the capture below. Bounded by construction:
        // two `ps` reads and one sleep, no retry loop.
        //
        // Capturing `view` strongly is the load-bearing part, not an oversight. Holding the
        // surface alive holds the pty master open, and an open master is what stops the kernel
        // reissuing this tty to another terminal mid-sweep. That is precisely the promise
        // `paneOwnedTTY` demands, and it stands in for the proof an exited shell cannot give.
        Task { @MainActor [view] in
            await TerminalJobTerminator.live.terminate(rootPID: foreground, paneOwnedTTY: tty)
            withExtendedLifetime(view) {}
        }
    }

    /// Write bytes into the slot's PTY, as if typed — backs `terminal.write.v1`.
    func sendText(_ text: String) {
        view.sendText(text)
    }

    func makeView() -> AnyView {
        AnyView(GhosttyRepresentable(view: view))
    }
}

private struct GhosttyRepresentable: NSViewRepresentable {
    let view: GhosttyNSView

    func makeNSView(context: Context) -> GhosttyNSView { view }
    func updateNSView(_ nsView: GhosttyNSView, context: Context) {}
}
