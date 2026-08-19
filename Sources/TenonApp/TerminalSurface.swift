// @domain: terminal-surface
import AppKit
import SwiftUI

/// The seam between Tenon and whatever draws the terminal.
///
/// Plugins never see this type — they only ever see the `tenon` JS object, and the
/// only thing the emulator contributes to that surface is the `terminal.title-changed`
/// event. A new backend means writing one more conformance here and changing one
/// line in `TenonApp.swift`. No plugin code changes.
@MainActor
protocol TerminalSurface: AnyObject {
    /// Shown in the UI so it's obvious which backend is live.
    var backendName: String { get }

    /// Emulator reported a new window title (OSC 0/2). Wired to `PluginHost.terminalTitleChanged`.
    var onTitleChange: ((String) -> Void)? { get set }

    /// Shell reported its working directory (OSC 7). Wired to `SurfacePool`, which resolves
    /// the pane's project root from it. A backend that cannot report one keeps the default
    /// below and the pane simply holds the directory it started in.
    var onPwdChange: ((String) -> Void)? { get set }

    /// The pane took keyboard focus from the window server — a person clicked into it, or
    /// AppKit restored it as first responder. It is a FACT about the responder chain and
    /// belongs to every backend, not only the emulator one: `SurfacePool` turns it into the
    /// workspace's active pane, so a backend that cannot report it leaves the model's focus
    /// where it was. A backend keeps the discard default below unless it declares storage.
    var onFocusGained: (() -> Void)? { get set }

    /// A row dragged out of Files (or any other file-URL drag source) was dropped on this
    /// pane's real surface. `SurfacePool` turns it into quoted path text delivered through
    /// `sendText`, so a backend with no drop target of its own keeps the discard default below.
    var onFileDrop: (([URL]) -> Void)? { get set }

    /// The SwiftUI view for this surface.
    func makeView() -> AnyView

    /// Route keyboard focus back to this surface after shell interaction.
    func focus()

    /// Deliver text into the pane's PTY (`terminal.write.v1`, queued `pendingText`
    /// flushing on first view). A backend with no PTY keeps the discard default below;
    /// the stub records instead, so delivery is assertable without a terminal (T-031).
    func sendText(_ text: String)

    /// The current visible screen as plain text — feeds `tenon-cli pane.read` and
    /// `terminal.wait.v1`, both of which read the characters. PTY-less backends have nothing to
    /// show and default to "".
    ///
    /// This is the expensive answer, and callers that only need "did the screen change?" want
    /// `screenFingerprint` instead.
    var renderedText: String { get }

    /// A value that changes when the visible screen changes, and costs no string building.
    ///
    /// The attention poll runs five times a second over every open pane on the main thread, and
    /// all it ever does with a screen is compare it to the previous one — `IdleDetector.record`
    /// is a single `==`. Rendering text for that comparison put 83% of the main thread inside
    /// `renderedText` during incident `0005-87f24878`: one Swift `String` per row built
    /// character by character, plus one ICU regular expression per row, per pane, per poll.
    /// A backend that only has text can hash it; an emulator hashes its cells directly (T-141).
    var screenFingerprint: Int { get }

    /// Every row the pane retains, oldest first — scrollback *and* viewport. Feeds
    /// `terminal.scrollback.read.v1`, which pages over it; the paging rule itself is pure
    /// and lives in `TenonCore.ScrollbackPaging`, so this seam only has to say what the
    /// emulator holds, never how much of it a caller may see. PTY-less backends retain
    /// nothing and default to empty.
    var scrollbackLines: [String] { get }

    /// Stop everything this pane started, because the pane is going away (T-084).
    ///
    /// Called exactly when the slot leaves the catalog, before the surface is released. It is a
    /// seam and not a side effect of deallocation for the reason Kero writes into its own
    /// teardown (`TerminalSession.swift:136-138`): a close must not depend on a later
    /// reconciliation pass to happen at all. A backend with no processes keeps the no-op below.
    func terminate()

    /// Whether the pane's child process has exited — feeds `tenon-cli pane.wait --for exit`.
    var processExited: Bool { get }

    /// How many shell commands have finished (OSC 133) — feeds `pane.wait --for command-finished`.
    var commandFinishedCount: Int { get }

    /// One more finish, reported from outside the terminal stream: a running agent's own
    /// `Stop` hook fired (`AgentHookLensBus`, T-178's own test names `Stop` "a turn boundary,
    /// not a session ending"). OSC 133 marks a *shell* command's foreground process exiting,
    /// which never happens between turns of a REPL agent — `claude`, `codex`, `opencode` all
    /// stay the shell's one foreground command for the whole session, so `commandFinishedCount`
    /// alone leaves every turn but the first indistinguishable from a prompt sitting idle. A
    /// backend with no notion of commands finishing keeps the no-op default below.
    func noteAgentTurnFinished()

    /// Foreground process-group leader when the backend can identify it. Host-internal
    /// agent presentation uses this to prove a composer still targets the same TUI before
    /// writing; it is not projected onto the public terminal intent surface.
    var foregroundPID: UInt64? { get }

    /// The pane's controlling terminal, as a device path such as `/dev/ttys011`.
    ///
    /// This is the pane's process *provenance*, and it is a different kind of fact from
    /// `foregroundPID`: it is fixed for the lifetime of the surface, so the resource monitor
    /// can attribute a whole process tree to this pane and keep attributing it while shell
    /// jobs start, background, and exit. A foreground PID moves every time somebody runs a
    /// command, which is why it marks a row and never decides who owns one. A backend with no
    /// PTY has no provenance to give and keeps the `nil` default below.
    var ttyName: String? { get }
}

extension TerminalSurface {
    /// A backend with no directory reporting. Assigning is accepted and discarded, so a
    /// conformer opts in by declaring its own stored property rather than by being special-cased.
    var onPwdChange: ((String) -> Void)? {
        get { nil }
        set {}
    }

    /// A backend with no responder chain of its own, on the same opt-in terms.
    var onFocusGained: (() -> Void)? {
        get { nil }
        set {}
    }

    /// A backend with no real drop target of its own, on the same opt-in terms.
    var onFileDrop: (([URL]) -> Void)? {
        get { nil }
        set {}
    }

    func focus() {}
    func sendText(_ text: String) {}
    func terminate() {}
    var renderedText: String { "" }
    /// Correct for any backend whose whole screen is its text; an emulator overrides it with
    /// something that never builds the string.
    var screenFingerprint: Int { renderedText.hashValue }
    var scrollbackLines: [String] { [] }
    var processExited: Bool { false }
    var commandFinishedCount: Int { 0 }
    func noteAgentTurnFinished() {}
    var foregroundPID: UInt64? { nil }
    var ttyName: String? { nil }
}

// MARK: - Stub backend

/// No emulator at all. Useful for headless-ish runs and for proving the plugin loop
/// without a PTY. Its "Simulate title change" button drives the same event path
/// libghostty's SET_TITLE action does.
final class StubTerminalSurface: TerminalSurface {
    let backendName = "Stub"
    var onTitleChange: ((String) -> Void)?
    /// The stub has no PTY to emit OSC 7, but it carries the hook so the pane-directory
    /// rule can be driven — and asserted — without a terminal.
    var onPwdChange: ((String) -> Void)?
    /// The stub has no responder chain, but it carries the hook and fires it from `focus()`
    /// exactly as `GhosttySurface.becomeFirstResponder` does. That is what makes the
    /// model→surface→model focus cycle reproducible without a window (T-088): a stub that
    /// swallowed the callback would let the cycle pass a headless test it cannot survive.
    var onFocusGained: (() -> Void)?
    /// The stub has no real drop target, but it carries the hook so `SurfacePool`'s
    /// quote-and-deliver wiring is assertable without a window (T-181, `FC-FR-040`).
    var onFileDrop: (([URL]) -> Void)?
    private(set) var focusCount = 0
    /// Everything delivered to the (nonexistent) PTY, in order — the lifecycle tests
    /// assert the first frame after materialization loses nothing that was queued.
    private(set) var sentText: [String] = []
    /// The stub has no job tree, but it records the call so "closing a pane stops its work" is
    /// assertable without a terminal — the same trick `sentText` plays for delivery.
    private(set) var terminateCount = 0
    /// Mutable process identity makes close protection assertable without a real PTY.
    var processExited = false
    var foregroundPID: UInt64?
    /// The observations `PaneActivity` is fed, made settable for the same reason
    /// `processExited` is: every attention state becomes reachable without a PTY, so a
    /// headless run and an offscreen render drive the real machine instead of describing it.
    var commandFinishedCount = 0
    /// The screen the idle detector fingerprints. A held value goes stable after enough
    /// polls, which is `idle`.
    var heldScreenFingerprint = 0
    /// Shares `commandFinishedCount` with real OSC 133 finishes on purpose: `PaneActivity`
    /// treats a rise in that counter as one fact, whichever seam reported it (T-178).
    func noteAgentTurnFinished() {
        commandFinishedCount += 1
    }
    /// A screen that is never the same twice — which is what `working` means, and what a held
    /// value cannot express. Measured the hard way: an offscreen render spends hundreds of
    /// milliseconds in layout, the activity poll runs through it, and a fixture that had set
    /// one fixed fingerprint went stable mid-render and photographed as `idle`.
    var screenKeepsChanging = false

    var screenFingerprint: Int {
        guard screenKeepsChanging else { return heldScreenFingerprint }
        heldScreenFingerprint += 1
        return heldScreenFingerprint
    }

    func terminate() {
        terminateCount += 1
    }

    func focus() {
        focusCount += 1
        onFocusGained?()
    }

    func sendText(_ text: String) {
        sentText.append(text)
    }

    func makeView() -> AnyView {
        AnyView(StubView(onTitleChange: { [weak self] title in self?.onTitleChange?(title) }))
    }
}

private struct StubView: View {
    let onTitleChange: (String) -> Void
    @State private var counter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal surface: stub")
                .font(.system(.body, design: .monospaced))
            Text("No PTY attached.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Simulate title change") {
                counter += 1
                onTitleChange("stub-title-\(counter)")
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.85))
        .foregroundStyle(.green)
    }
}
