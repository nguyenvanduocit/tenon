// @domain: command-surface, spatial-canvas
import SwiftUI
import TenonCore

/// A launcher utility that behaves like a native cascading menu: resting the pointer on
/// the row opens the presets beside it, while clicking/keyboard activation remains an
/// equivalent path for accessibility and precise pointer use.
struct PaneArrangementMenu: View {
    let presets: [PaneArrangementPreset]
    let arrange: (PaneArrangementPreset) -> Void
    let dismissLauncher: () -> Void

    @State private var submenuPresented = false
    @State private var delayedDismiss: Task<Void, Never>?

    var body: some View {
        Button {
            delayedDismiss?.cancel()
            submenuPresented = true
        } label: {
            PaletteRowChrome(
                icon: "rectangle.3.group",
                title: Text("Arrange Panes"),
                isSelected: false,
                density: .compact,
                trailing: "›"
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows whole-tab layout presets")
        .accessibilityIdentifier("tenon.launcher.arrangePanes")
        .onHover(perform: hoverChanged)
        .popover(isPresented: $submenuPresented, arrowEdge: .trailing) {
            presetList
                .onHover(perform: submenuHoverChanged)
        }
        .onDisappear { delayedDismiss?.cancel() }
    }

    private var presetList: some View {
        VStack(spacing: 0) {
            ForEach(presets, id: \.self) { preset in
                Button {
                    arrange(preset)
                    submenuPresented = false
                    dismissLauncher()
                } label: {
                    PaletteRowChrome(
                        icon: preset.icon,
                        title: Text(preset.title),
                        isSelected: false,
                        density: .compact,
                        trailing: preset.ratio
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(preset.hint)
                .accessibilityIdentifier("tenon.launcher.arrangement.\(preset.rawValue)")
            }
        }
        .padding(.vertical, LauncherListHeight.listPadding)
        .frame(width: 210)
        .background(TenonTheme.chromeRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane arrangements")
    }

    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            delayedDismiss?.cancel()
            submenuPresented = true
        } else {
            scheduleDismiss()
        }
    }

    private func submenuHoverChanged(_ hovering: Bool) {
        if hovering {
            delayedDismiss?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    /// Keep the submenu alive across the few pixels between the parent and child popovers.
    /// Without this bridge, leaving the row dismisses the destination before its own hover
    /// region can receive the pointer.
    private func scheduleDismiss() {
        delayedDismiss?.cancel()
        delayedDismiss = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            submenuPresented = false
        }
    }
}

private extension PaneArrangementPreset {
    var title: String {
        switch self {
        case .tiled: "Grid"
        case .evenColumns: "Equal Columns"
        case .evenRows: "Equal Rows"
        case .mainLeft: "Main Left"
        case .mainRight: "Main Right"
        case .mainTop: "Main Top"
        case .mainBottom: "Main Bottom"
        }
    }

    var icon: String {
        switch self {
        case .tiled: "square.grid.2x2"
        case .evenColumns: "rectangle.split.3x1"
        case .evenRows: "rectangle.split.1x2"
        case .mainLeft: "rectangle.leadinghalf.inset.filled"
        case .mainRight: "rectangle.trailinghalf.inset.filled"
        case .mainTop: "rectangle.tophalf.inset.filled"
        case .mainBottom: "rectangle.bottomhalf.inset.filled"
        }
    }

    var ratio: String? {
        switch self {
        case .mainLeft, .mainRight, .mainTop, .mainBottom: "2/3"
        case .tiled, .evenColumns, .evenRows: nil
        }
    }

    var hint: String {
        switch self {
        case .tiled:
            "Balances every pane across rows and columns"
        case .evenColumns:
            "Makes every pane an equal-width column"
        case .evenRows:
            "Makes every pane an equal-height row"
        case .mainLeft:
            "Gives the focused pane two thirds on the left"
        case .mainRight:
            "Gives the focused pane two thirds on the right"
        case .mainTop:
            "Gives the focused pane two thirds at the top"
        case .mainBottom:
            "Gives the focused pane two thirds at the bottom"
        }
    }
}
