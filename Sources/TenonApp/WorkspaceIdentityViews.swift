// @domain: workspace-model
import SwiftUI
import TenonCore

/// The density budget this popover is composed from, derived from the compact surfaces
/// `docs/designs.md` names — the Launcher's popover width, `PluginUIPrompt`'s 30 pt field
/// and footer buttons — and kept in one pure place so a regression test can read it.
enum WorkspaceIdentityFormMetrics {
    static let width: CGFloat = 320
    static let controlHeight: CGFloat = 30
    static let controlRadius: CGFloat = 6
    /// Marks and tints are square targets on the same 28 pt grid the sidebar footer uses.
    static let swatch: CGFloat = 28
    static let swatchSpacing: CGFloat = 6
    static let inset: CGFloat = 14
    static let sectionSpacing: CGFloat = 12

    /// The mark grid's shape: the fewest rows the vocabulary fits in, spread evenly across
    /// them. Filling each row to the popover's width instead would leave the last row a
    /// stub — 8 marks then 4 — which reads as an interrupted list rather than as a block.
    /// Computed from the width, so widening the popover cannot leave a stale count behind.
    static var columns: Int {
        let count = WorkspaceSymbol.allCases.count
        return Int((Double(count) / Double(markRows)).rounded(.up))
    }

    /// The rows the mark grid occupies — what the popover's height is budgeted from.
    static var markRows: Int {
        let content = width - inset * 2
        let fitted = max(1, Int((content + swatchSpacing) / (swatch + swatchSpacing)))
        return max(
            1,
            Int((Double(WorkspaceSymbol.allCases.count) / Double(fitted)).rounded(.up))
        )
    }
}

/// The glyph a workspace is marked with, drawn identically wherever the host represents
/// that workspace. Kept as one view so the mark, its size, and its tint are decided once.
struct WorkspaceMark: View {
    let workspace: Workspace
    /// The active workspace shows its tint; the rest stay muted, exactly as the row read
    /// before a workspace could carry a colour of its own.
    let isActive: Bool
    var size: CGFloat = 11

    /// Which colour a mark is drawn in. A function rather than an expression buried in the
    /// body, because it is a rule two things depend on — that an unselected row stays quiet,
    /// and that a selected one shows the workspace's own tint rather than the app accent.
    static func tint(for workspace: Workspace, isActive: Bool) -> Color {
        isActive
            ? TenonTheme.accentColor(workspace.appearance.accent)
            : TenonTheme.muted
    }

    var body: some View {
        Image(systemName: workspace.appearance.symbol.systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Self.tint(for: workspace, isActive: isActive))
            .accessibilityHidden(true)
    }
}

/// What VoiceOver reads for one workspace row.
///
/// The row draws a mark and, when selected, a tint. Neither is speakable on its own, so the
/// announcement carries the name and the mark's own word — and keeps the tab and unseen
/// counts the row was already reading, which an explicit label would otherwise replace.
enum WorkspaceRowAnnouncement {
    static func text(for workspace: Workspace, unseenCount: Int) -> String {
        var parts = [
            workspace.name,
            workspace.appearance.symbol.label,
            "\(workspace.tabs.count) \(workspace.tabs.count == 1 ? "tab" : "tabs")",
        ]
        if unseenCount > 0 {
            parts.append("\(unseenCount) unseen")
        }
        return parts.joined(separator: ", ")
    }
}

/// Name, mark, and tint for one workspace.
///
/// Every control writes straight through to `WorkspaceStore` — the typed same-owner service
/// that already owns every other workspace mutation — so there is no draft to reconcile and
/// no second copy of the truth. The name commits on Enter and on dismissal; the store
/// refuses a no-op, so committing twice costs nothing.
struct WorkspaceIdentityForm: View {
    let workspace: Workspace
    var store: WorkspaceStore
    let dismiss: () -> Void

    @State private var typedName: String
    @FocusState private var nameFocused: Bool

    init(workspace: Workspace, store: WorkspaceStore, dismiss: @escaping () -> Void) {
        self.workspace = workspace
        self.store = store
        self.dismiss = dismiss
        // The derived name is the field's placeholder, not its text: a workspace that was
        // never named shows an empty field whose Reset is already a no-op.
        _typedName = State(initialValue: workspace.customName ?? "")
    }

    private var derivedName: String { WorkspaceName.derived(for: workspace.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceIdentityFormMetrics.sectionSpacing) {
            header
            nameField
            marks
            tints
            footer
        }
        .padding(.horizontal, WorkspaceIdentityFormMetrics.inset)
        .padding(.vertical, WorkspaceIdentityFormMetrics.inset)
        .frame(width: WorkspaceIdentityFormMetrics.width)
        .background(TenonTheme.chromeRaised)
        .tint(TenonTheme.accentColor(workspace.appearance.accent))
        .onDisappear(perform: commitName)
        .accessibilityIdentifier("tenon.workspaceIdentityForm")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspace")
                .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(TenonTheme.text)
            Text(workspace.path.path)
                .font(TenonTheme.utilityFont(size: 9))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
                .help(workspace.path.path)
        }
    }

    private var nameField: some View {
        TextField(derivedName, text: $typedName)
            .textFieldStyle(.plain)
            .font(TenonTheme.interfaceFont(size: 12))
            .foregroundStyle(TenonTheme.text)
            .focused($nameFocused)
            .padding(.horizontal, 9)
            .frame(height: WorkspaceIdentityFormMetrics.controlHeight)
            .background(
                TenonTheme.panel,
                in: .rect(cornerRadius: WorkspaceIdentityFormMetrics.controlRadius)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: WorkspaceIdentityFormMetrics.controlRadius,
                    style: .continuous
                )
                .stroke(TenonTheme.line, lineWidth: 1)
            }
            .onSubmit(commitName)
            .accessibilityLabel("Workspace name")
            .accessibilityHint("Leave empty to use the folder name, \(derivedName)")
            .accessibilityIdentifier("tenon.workspaceNameField")
    }

    private var marks: some View {
        section("Icon") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .fixed(WorkspaceIdentityFormMetrics.swatch),
                        spacing: WorkspaceIdentityFormMetrics.swatchSpacing
                    ),
                    count: WorkspaceIdentityFormMetrics.columns
                ),
                alignment: .leading,
                spacing: WorkspaceIdentityFormMetrics.swatchSpacing
            ) {
                ForEach(WorkspaceSymbol.allCases, id: \.self) { symbol in
                    let isChosen = symbol == workspace.appearance.symbol
                    swatchButton(
                        isChosen: isChosen,
                        label: symbol.label,
                        identifier: "tenon.workspaceMarkOption"
                    ) {
                        var appearance = workspace.appearance
                        appearance.symbol = symbol
                        store.setWorkspaceAppearance(workspace.id, to: appearance)
                    } content: {
                        Image(systemName: symbol.systemName)
                            .font(.system(size: 12, weight: .medium))
                            // The accent marks the current selection here as it does
                            // everywhere else in Tenon; the ring around it says the same
                            // thing in shape, so the choice survives without colour.
                            .foregroundStyle(isChosen ? TenonTheme.amber : TenonTheme.muted)
                    }
                }
            }
        }
    }

    private var tints: some View {
        section("Colour") {
            HStack(spacing: WorkspaceIdentityFormMetrics.swatchSpacing) {
                tintButton(nil, label: "App accent")
                ForEach(AccentColor.allCases, id: \.self) { accent in
                    tintButton(accent, label: accent.label)
                }
            }
        }
    }

    /// A tint is never announced or distinguished by colour alone: the chosen one carries a
    /// check, and every swatch carries its own name for VoiceOver and its tooltip.
    private func tintButton(_ accent: AccentColor?, label: String) -> some View {
        let isChosen = accent == workspace.appearance.accent
        return swatchButton(
            isChosen: isChosen,
            label: label,
            identifier: "tenon.workspaceTintOption"
        ) {
            var appearance = workspace.appearance
            appearance.accent = accent
            store.setWorkspaceAppearance(workspace.id, to: appearance)
        } content: {
            ZStack {
                // "Follow the app accent" is drawn as an outline, not as a dimmer version of
                // the accent: two dots of the same hue would be told apart by brightness
                // alone, and the option means *inherited*, which is a shape, not a colour.
                if accent == nil {
                    Circle()
                        .strokeBorder(
                            TenonTheme.amber,
                            style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5])
                        )
                        .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .fill(TenonTheme.accentColor(accent))
                        .frame(width: 14, height: 14)
                }
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent == nil ? TenonTheme.amber : TenonTheme.ink)
                }
            }
        }
    }

    private func swatchButton(
        isChosen: Bool,
        label: String,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Button(action: action) {
            content()
                .frame(
                    width: WorkspaceIdentityFormMetrics.swatch,
                    height: WorkspaceIdentityFormMetrics.swatch
                )
                .background(
                    isChosen ? Color.primary.opacity(0.09) : .clear,
                    in: .rect(cornerRadius: WorkspaceIdentityFormMetrics.controlRadius)
                )
                .overlay {
                    if isChosen {
                        RoundedRectangle(
                            cornerRadius: WorkspaceIdentityFormMetrics.controlRadius,
                            style: .continuous
                        )
                        .stroke(TenonTheme.amber, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Reset", action: reset)
                .buttonStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 13))
                .foregroundStyle(TenonTheme.muted)
                .padding(.horizontal, 14)
                .frame(height: WorkspaceIdentityFormMetrics.controlHeight)
                .background(
                    TenonTheme.panel,
                    in: .rect(cornerRadius: WorkspaceIdentityFormMetrics.controlRadius)
                )
                .disabled(!workspace.hasCustomIdentity)
                .opacity(workspace.hasCustomIdentity ? 1 : 0.45)
                .help("Restore the folder name, the default icon, and the app accent")
                .accessibilityIdentifier("tenon.workspaceIdentityReset")

            Spacer()

            Button("Done") {
                commitName()
                dismiss()
            }
            .buttonStyle(.plain)
            .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
            .foregroundStyle(TenonTheme.ink)
            .padding(.horizontal, 14)
            .frame(height: WorkspaceIdentityFormMetrics.controlHeight)
            .background(
                TenonTheme.amber,
                in: .rect(cornerRadius: WorkspaceIdentityFormMetrics.controlRadius)
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("tenon.workspaceIdentityDone")
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(TenonTheme.utilityFont(size: 9, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func commitName() {
        store.renameWorkspace(workspace.id, to: typedName)
    }

    private func reset() {
        store.resetWorkspaceIdentity(workspace.id)
        typedName = ""
    }
}
