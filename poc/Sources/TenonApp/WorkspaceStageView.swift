import SwiftUI
import TenonCore

/// The tab-local canvas: the active tab's spatial slots, an empty-state call to
/// action when a tab has no slots, and a launch placeholder when no tab exists.
struct WorkspaceStageView: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var host: PluginHost
    var router: DragRouter

    var body: some View {
        if let workspace = store.catalog.activeWorkspace,
           let tab = workspace.activeTab {
            ZStack {
                SpatialCanvasView(
                    tab: tab,
                    workspacePath: workspace.path,
                    allLiveSlotIDs: Set(store.catalog.allSlotIDs),
                    activeSlotID: tab.activeSlotID,
                    store: store,
                    pool: pool,
                    host: host,
                    router: router
                )

                if tab.slots.isEmpty {
                    EmptyTabCallToAction(
                        addTerminal: { store.addSlot(content: .terminal) },
                        newTab: { store.newTab() }
                    )
                }
            }
            .background(TenonTheme.ink)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(TenonTheme.muted)
                Text("Add terminal")
                    .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))
                Button("New tab") {
                    store.newTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.ink)
        }
    }
}

private struct EmptyTabCallToAction: View {
    let addTerminal: () -> Void
    let newTab: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            iconBadge

            VStack(spacing: 6) {
                Text("This tab is empty")
                    .font(TenonTheme.interfaceFont(size: 15, weight: .semibold))
                    .foregroundStyle(TenonTheme.text)
                Text("No terminal running yet")
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
            }

            VStack(spacing: 8) {
                EmptyStateActionButton(
                    title: "Add terminal",
                    shortcut: "\u{21A9}",
                    kind: .primary,
                    action: addTerminal
                )
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("empty-tab-add-terminal")

                EmptyStateActionButton(
                    title: "New tab",
                    shortcut: "\u{2318}T",
                    kind: .secondary,
                    action: newTab
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .frame(width: 296)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [TenonTheme.chromeRaised, TenonTheme.chrome],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TenonTheme.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, y: 16)
    }

    private var iconBadge: some View {
        Image(systemName: "terminal")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(TenonTheme.amber)
            .frame(width: 58, height: 58)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(TenonTheme.amber.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(TenonTheme.amber.opacity(0.30), lineWidth: 1)
            }
            .shadow(color: TenonTheme.amber.opacity(0.35), radius: 14)
    }
}

/// One row in the empty-tab card: a full-width action with its keyboard hint
/// aligned right. `primary` is the filled amber call to action; `secondary` is
/// a quiet outlined button that lights up on hover.
private struct EmptyStateActionButton: View {
    enum Kind { case primary, secondary }

    let title: String
    let shortcut: String
    let kind: Kind
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(TenonTheme.interfaceFont(size: 13, weight: .medium))
                Spacer(minLength: 12)
                Text(shortcut)
                    .font(TenonTheme.utilityFont(size: 11, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.75))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return TenonTheme.ink
        case .secondary: return hovering ? TenonTheme.text : TenonTheme.muted
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return hovering ? TenonTheme.amber : TenonTheme.amber.opacity(0.92)
        case .secondary: return hovering ? TenonTheme.chromeRaised : .clear
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return TenonTheme.line
        }
    }
}
