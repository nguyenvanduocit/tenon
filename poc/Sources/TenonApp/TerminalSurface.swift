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

    /// The SwiftUI view for this surface.
    func makeView() -> AnyView

    /// Route keyboard focus back to this surface after shell interaction.
    func focus()

    /// The current visible screen as plain text — feeds `tenon-cli pane.read` and the
    /// tui-idle heuristic. PTY-less backends have nothing to show and default to "".
    var renderedText: String { get }

    /// Whether the pane's child process has exited — feeds `tenon-cli pane.wait --for exit`.
    var processExited: Bool { get }

    /// How many shell commands have finished (OSC 133) — feeds `pane.wait --for command-finished`.
    var commandFinishedCount: Int { get }
}

extension TerminalSurface {
    /// A backend with no directory reporting. Assigning is accepted and discarded, so a
    /// conformer opts in by declaring its own stored property rather than by being special-cased.
    var onPwdChange: ((String) -> Void)? {
        get { nil }
        set {}
    }

    func focus() {}
    var renderedText: String { "" }
    var processExited: Bool { false }
    var commandFinishedCount: Int { 0 }
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
    private(set) var focusCount = 0

    func focus() {
        focusCount += 1
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
