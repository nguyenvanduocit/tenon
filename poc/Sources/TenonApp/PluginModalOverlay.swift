import SwiftUI
import TenonCore
import TenonIntentCore

/// The modal a plugin view is asking the shell to present, resolved to the one that will
/// actually be shown.
///
/// Selection is a pure function of the published sections so it can be asserted without a
/// window (docs/tdd.md). The rule is deliberately blunt: **at most one modal exists at a
/// time**, and when several views want one, the first in publish order wins. Publish order
/// is `PluginHost`'s stable plugin-id sort, so the choice is the same on every render
/// rather than whichever section the renderer happened to visit last — a modal that
/// flickered between two plugins would be worse than one that waits its turn.
struct PluginModalPresentation: Equatable {
    let pluginID: PluginID
    let viewID: String
    let instanceID: String?
    let modal: PluginViewModal

    static func resolve(from sections: [PluginViewSection]) -> PluginModalPresentation? {
        for section in sections {
            guard let modal = section.modal else { continue }
            return PluginModalPresentation(
                pluginID: section.pluginID,
                viewID: section.viewID,
                instanceID: section.instanceID,
                modal: modal
            )
        }
        return nil
    }
}

/// Renders that modal as a sheet over the whole shell, beside `PaletteOverlay` and
/// `PluginUIOverlay`, and renders nothing when no view is asking for one.
///
/// Presentation only. Escape, a click on the backdrop, and the close control all deliver
/// the modal's `dismissAction` to the owning view's `onSelect` — the host never clears a
/// modal itself, because the plugin owns whether one exists (invariant 6: one semantic
/// implementation, and here the semantics are the plugin's).
struct PluginModalOverlay: View {
    let host: PluginHost

    var body: some View {
        if let presentation = PluginModalPresentation.resolve(from: host.pluginViews) {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss(presentation) }

                VStack(alignment: .leading, spacing: 0) {
                    header(presentation)
                    Divider().overlay(TenonTheme.line)
                    ScrollView {
                        // The same renderer the pane uses — one implementation of the
                        // vocabulary, so a node looks and behaves identically in a modal.
                        PluginNodeView(
                            node: presentation.modal.body ?? .spacer,
                            onAction: { action, value in
                                send(presentation, action: action, value: value)
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
                .frame(width: 560)
                .frame(maxHeight: 520)
                .background(TenonTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(TenonTheme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
            // Escape dismisses, the same key that closes the palette.
            .onExitCommand { dismiss(presentation) }
        }
    }

    private func header(_ presentation: PluginModalPresentation) -> some View {
        HStack(spacing: 8) {
            Text(presentation.modal.title)
                .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(TenonTheme.text)
            Spacer(minLength: 8)
            Button { dismiss(presentation) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TenonTheme.muted)
                    .frame(width: 24, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func dismiss(_ presentation: PluginModalPresentation) {
        send(presentation, action: presentation.modal.dismissAction, value: nil)
    }

    private func send(_ presentation: PluginModalPresentation, action: String, value: String?) {
        Task { @MainActor in
            _ = await host.invokeViewSelect(
                pluginID: presentation.pluginID,
                viewID: presentation.viewID,
                instanceID: presentation.instanceID,
                itemID: action,
                value: value.map(IntentValue.string)
            )
        }
    }
}
