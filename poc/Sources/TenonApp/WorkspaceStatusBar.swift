import SwiftUI
import TenonCore

/// The bottom utility strip. Everything shown here is contributed by plugins via
/// `tenon.statusBar` — the shell adds nothing of its own. An empty strip (no plugin
/// items) is a valid state.
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
        .padding(.horizontal, 10)
        .background(TenonTheme.chrome)
    }
}
