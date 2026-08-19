// @domain: workspace-model
import SwiftUI

/// The shell's small square icon control: the sidebar toggle in the title bar's identity
/// zone, and the `+` that opens the launcher at the end of the tab strip.
///
/// It lives in its own file because those two controls sit in different rows once the tab
/// strip can be drawn at either edge of the window, and one spelling of a chrome button is
/// what keeps them looking like the same control.
struct ShellIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TenonTheme.muted)
        .background(TenonTheme.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        // An icon-only control carries no text for VoiceOver to read. The tooltip is
        // already the sentence a person would say about it, so it is also the label.
        .accessibilityLabel(help)
    }
}
