import AppKit
import SwiftUI

/// The seam between Tenon and whatever draws the terminal.
///
/// Plugins never see this type — they only ever see the `tenon` JS object, and the
/// only thing the emulator contributes to that surface is the `terminal.title-changed`
/// event. A new backend means writing one more conformance here and changing one
/// line in `TenonApp.swift`. No plugin code changes.
protocol TerminalSurface: AnyObject {
    /// Shown in the UI so it's obvious which backend is live.
    var backendName: String { get }

    /// Emulator reported a new window title (OSC 0/2). Wired to `PluginHost.terminalTitleChanged`.
    var onTitleChange: ((String) -> Void)? { get set }

    /// The SwiftUI view for this surface.
    func makeView() -> AnyView

    /// Route keyboard focus back to this surface after shell interaction.
    func focus()
}

extension TerminalSurface {
    func focus() {}
}

// MARK: - Stub backend

/// No emulator at all. Useful for headless-ish runs and for proving the plugin loop
/// without a PTY. Its "Simulate title change" button drives the same event path
/// libghostty's SET_TITLE action does.
final class StubTerminalSurface: TerminalSurface {
    let backendName = "Stub"
    var onTitleChange: ((String) -> Void)?
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
