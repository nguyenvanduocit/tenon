import SwiftUI
import TenonCore

/// The bottom utility strip: live backend, slot count, the active slot's grid rect,
/// plugin-contributed status items, and the keyboard-hint legend. Read-only — it
/// re-renders only when the state it reads (backend, active tab, plugin items) moves.
struct WorkspaceStatusBar: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var host: PluginHost

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(TenonTheme.amber)
                .frame(width: 6, height: 6)
            Text(pool.backendName.uppercased())
                .foregroundStyle(TenonTheme.amber)

            if let tab = store.catalog.activeWorkspace?.activeTab {
                Text("\(tab.slots.count) \(tab.slots.count == 1 ? "SLOT" : "SLOTS")")
                if let selected = tab.activeSlot {
                    Text(
                        "\(selected.rect.x),\(selected.rect.y) · \(selected.rect.width)×\(selected.rect.height)"
                    )
                }
            }

            ForEach(host.statusItems) { item in
                Text(item.text)
                    .lineLimit(1)
            }

            Spacer()
            Text("⌘D SPLIT")
            Text("DRAG HEADER · RESIZE EDGES")
            Text("ESC CANCEL")
        }
        .font(TenonTheme.utilityFont(size: 8, weight: .medium))
        .tracking(0.35)
        .foregroundStyle(TenonTheme.muted)
        .padding(.horizontal, 10)
        .background(TenonTheme.chrome)
    }
}
