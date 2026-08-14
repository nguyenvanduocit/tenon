// @domain: workspace-model
import SwiftUI
import TenonCore

extension Color {
    /// A `WorkspaceTint` value as something SwiftUI can draw. The tint vocabulary is plain
    /// numbers in `TenonCore`, which is what keeps its palette and contrast assertable
    /// without AppKit; this is the one place that crosses back.
    init(tintHex: UInt32) {
        self.init(nsColor: NSColor(hex: tintHex))
    }
}

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

    /// Twelve named tints plus Automatic stay in two balanced rows instead of widening the
    /// popover or hiding the later choices in a horizontal scroller.
    static let tintRows = 2

    static var tintColumns: Int {
        Int(
            (Double(AccentColor.allCases.count + 1) / Double(tintRows))
                .rounded(.up)
        )
    }
}

/// The glyph a workspace is marked with, drawn identically wherever the host represents
/// that workspace. Kept as one view so the mark, its size, and its tint are decided once.
// MARK: - Shared workspace mark  @domain: workspace-model

struct WorkspaceMark: View {
    let symbol: WorkspaceSymbol
    let accent: AccentColor?
    let customIcon: WorkspaceCustomIcon?
    let path: URL
    let size: CGFloat

    init(workspace: Workspace, size: CGFloat = 15) {
        self.symbol = workspace.appearance.symbol
        self.accent = workspace.appearance.accent
        self.customIcon = workspace.appearance.customIcon
        self.path = workspace.path
        self.size = size
    }

    init(recent entry: RecentWorkspaceStore.Entry, size: CGFloat = 15) {
        self.symbol = entry.appearance.symbol
        self.accent = entry.appearance.accent
        self.customIcon = entry.appearance.customIcon
        self.path = entry.path
        self.size = size
    }

    /// Which colour a mark is drawn in — every workspace in its own, whether or not it is
    /// the selected one.
    ///
    /// Recognition serves the workspace a person is *not* in yet, so a colour that appears
    /// only on selection appears only once it is no longer needed. Selection is carried by
    /// the row's fill and its text, the way every native sidebar on this platform carries
    /// it; holding the unselected marks back instead costs contrast the mark cannot spare
    /// (at 72% opacity the darkest hue reaches 2.89:1 on `tenonChrome`, under the 3:1 WCAG
    /// asks of a graphical object).
    static func tint(for workspace: Workspace) -> Color {
        Color(tintHex: WorkspaceTint.hex(for: workspace.appearance.accent, at: workspace.path))
    }

    static func tint(for entry: RecentWorkspaceStore.Entry) -> Color {
        Color(tintHex: WorkspaceTint.hex(for: entry.appearance.accent, at: entry.path))
    }

    var body: some View {
        Group {
            if let customIcon,
               let image = WorkspaceCustomIconCache.image(for: customIcon)
            {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: symbol.systemName)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(
                        Color(tintHex: WorkspaceTint.hex(for: accent, at: path))
                    )
            }
        }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
private enum WorkspaceCustomIconCache {
    private static let images = NSCache<NSUUID, NSImage>()

    static func image(for icon: WorkspaceCustomIcon) -> NSImage? {
        let key = icon.id as NSUUID
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(data: icon.pngData) else { return nil }
        images.setObject(image, forKey: key, cost: icon.pngData.count)
        images.totalCostLimit = 4 * 1_024 * 1_024
        return image
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
            workspace.appearance.iconLabel,
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
// MARK: - Identity form  @domain: workspace-model

struct WorkspaceIdentityForm: View {
    let workspace: Workspace
    var store: WorkspaceStore
    let dismiss: () -> Void

    @State private var typedName: String
    @State private var isChoosingCustomIcon = false
    @State private var isProcessingCustomIcon = false
    @State private var showsIconImportError = false
    @State private var iconImportError = ""
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
        .tint(WorkspaceMark.tint(for: workspace))
        .onDisappear(perform: commitName)
        .fileImporter(
            isPresented: $isChoosingCustomIcon,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importCustomIcon
        )
        .fileDialogMessage("Choose an image to use as this workspace's icon.")
        .fileDialogConfirmationLabel("Use Icon")
        .alert("Couldn't Use Icon", isPresented: $showsIconImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(iconImportError)
        }
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
            VStack(alignment: .leading, spacing: 6) {
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
                        let isChosen = workspace.appearance.customIcon == nil
                            && symbol == workspace.appearance.symbol
                        swatchButton(
                            isChosen: isChosen,
                            label: symbol.label,
                            identifier: "tenon.workspaceMarkOption"
                        ) {
                            var appearance = workspace.appearance
                            appearance.symbol = symbol
                            appearance.customIcon = nil
                            store.setWorkspaceAppearance(workspace.id, to: appearance)
                        } content: {
                            Image(systemName: symbol.systemName)
                                .font(.system(size: 12, weight: .medium))
                                // The accent marks the current selection here as it does
                                // everywhere else in Tenon; the ring around it says the same
                                // thing in shape, so the choice survives without colour.
                                .foregroundStyle(
                                    isChosen ? TenonTheme.amber : TenonTheme.muted
                                )
                        }
                    }
                }

                customIconButton
            }
        }
    }

    private var customIconButton: some View {
        Button {
            isChoosingCustomIcon = true
        } label: {
            HStack(spacing: 8) {
                if isProcessingCustomIcon {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else if workspace.appearance.customIcon != nil {
                    WorkspaceMark(workspace: workspace, size: 16)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TenonTheme.muted)
                        .frame(width: 16, height: 16)
                }
                Text(
                    workspace.appearance.customIcon == nil
                        ? "Upload Custom Icon…"
                        : "Replace Custom Icon…"
                )
                .font(TenonTheme.interfaceFont(size: 11))
                .foregroundStyle(TenonTheme.text)
            }
            .padding(.horizontal, 9)
            .frame(height: WorkspaceIdentityFormMetrics.controlHeight)
            .background(
                workspace.appearance.customIcon == nil
                    ? TenonTheme.panel
                    : Color.primary.opacity(0.09),
                in: .rect(cornerRadius: WorkspaceIdentityFormMetrics.controlRadius)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: WorkspaceIdentityFormMetrics.controlRadius,
                    style: .continuous
                )
                .stroke(
                    workspace.appearance.customIcon == nil
                        ? TenonTheme.line
                        : TenonTheme.amber,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(isProcessingCustomIcon)
        .accessibilityLabel(
            workspace.appearance.customIcon == nil
                ? "Upload custom workspace icon"
                : "Replace custom workspace icon"
        )
        .accessibilityAddTraits(
            workspace.appearance.customIcon == nil ? [] : .isSelected
        )
        .accessibilityIdentifier("tenon.workspaceCustomIcon")
    }

    private var tints: some View {
        section("Colour") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .fixed(WorkspaceIdentityFormMetrics.swatch),
                        spacing: WorkspaceIdentityFormMetrics.swatchSpacing
                    ),
                    count: WorkspaceIdentityFormMetrics.tintColumns
                ),
                alignment: .leading,
                spacing: WorkspaceIdentityFormMetrics.swatchSpacing
            ) {
                ForEach([AccentColor?.none] + AccentColor.allCases.map(Optional.some), id: \.self) {
                    accent in
                    tintButton(accent, label: accent?.label ?? "Automatic")
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
                // Automatic shows the colour it will actually use, so the choice is made
                // against the thing itself rather than against a promise. Its dashed edge
                // is what says *derived* — a shape, because two dots of one hue would
                // otherwise be told apart by nothing but the fill reaching the border.
                Circle()
                    .fill(swatchColour(accent))
                    .frame(width: 14, height: 14)
                if accent == nil {
                    Circle()
                        .strokeBorder(
                            TenonTheme.text,
                            style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5])
                        )
                        .frame(width: 18, height: 18)
                }
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(TenonTheme.ink)
                }
            }
        }
    }

    /// What one tint swatch is filled with — a named accent by its own hex, and Automatic
    /// by the colour this workspace's folder derives, so the swatch is a preview and not a
    /// symbol standing for one.
    private func swatchColour(_ accent: AccentColor?) -> Color {
        Color(tintHex: WorkspaceTint.hex(for: accent, at: workspace.path))
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
                .help("Restore the folder name, the default icon, and the automatic colour")
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

    private func importCustomIcon(_ result: Result<[URL], any Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result {
                presentIconImportError(error.localizedDescription)
            }
            return
        }

        isProcessingCustomIcon = true
        Task {
            defer { isProcessingCustomIcon = false }
            do {
                let icon = try await WorkspaceCustomIconImport.icon(from: url)
                guard let current = store.catalog.workspaces.first(where: {
                    $0.id == workspace.id
                }) else { return }
                var appearance = current.appearance
                appearance.customIcon = icon
                store.setWorkspaceAppearance(workspace.id, to: appearance)
            } catch is CancellationError {
                return
            } catch {
                presentIconImportError(error.localizedDescription)
            }
        }
    }

    private func presentIconImportError(_ message: String) {
        iconImportError = message
        showsIconImportError = true
    }
}
