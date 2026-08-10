// @domain: diagnostics

import AppKit
import SwiftUI
import TenonCore

/// The menu half of T-092: a person can hand the journal to someone else.
///
/// Same-owner DIRECT under `docs/architecture-interaction-boundaries.md` — the host's own
/// menu calling the host's own journal, one semantic owner, so no intent and no new
/// capability. The save panel is the consent: nothing leaves the machine until a person
/// picks where it goes.
struct DiagnosticsCommands: View {
    let journal: DiagnosticsJournal

    var body: some View {
        Button("Export Diagnostics…") { export() }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Tenon Diagnostics"
        panel.nameFieldStringValue = "tenon-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let journal = journal
        Task { @MainActor in
            do {
                _ = try await Task.detached(priority: .utility) {
                    try journal.export(to: destination)
                }.value
                TenonLog.diagnostics.notice("exported diagnostics")
            } catch {
                TenonLog.diagnostics.error(
                    "diagnostics export failed: \((error as NSError).code, privacy: .public)"
                )
                let alert = NSAlert()
                alert.messageText = "Could not export diagnostics"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
