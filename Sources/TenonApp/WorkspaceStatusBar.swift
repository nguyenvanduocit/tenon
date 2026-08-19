// @domain: workspace-model, attention
import SwiftUI
import TenonCore

/// The utility strip. Everything shown here is contributed by plugins via
/// `tenon.statusBar` — the shell adds nothing of its own, and no host control may sit inside
/// it. An empty strip (no plugin items) is a valid state.
///
/// It is drawn in whichever chrome row the order gives it, so it owns its own type and
/// nothing about the row: the inset and the chrome fill belong to `ShellTitleBar` and
/// `ShellFootBar`, which have to agree about them across the whole window. What it does own
/// is a fixed 24-pt box, so the items read identically in a 24-pt foot row and in the 36-pt
/// title bar rather than re-centring against a different row height.
struct WorkspaceStatusBar: View {
    var host: PluginHost

    var body: some View {
        HStack(spacing: 12) {
            ForEach(host.statusItems) { item in
                Text(item.text)
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(TenonTheme.utilityFont(size: 8, weight: .medium))
        .tracking(0.35)
        .foregroundStyle(TenonTheme.muted)
        .frame(height: TenonTheme.statusBarHeight)
    }
}
