// @domain: row-list
import AppKit
import SwiftUI
import TenonCore

/// Renders a list of `TreeRowItem` as a real file-manager tree: disclosure chevrons, native
/// context menus, inline editing, drag-out, selection, section headings.
///
/// The ONE indented list in the product. A plugin's rows arrive here through the `views.set`
/// decoder and a host-native pane's rows are built in Swift, but neither gets its own renderer:
/// the Changes pane and the file explorer are the same list of the same files, and two
/// implementations of that meant two answers to indent, hover, and what a right-click does.
///
/// Rows only. What the list has to SAY about itself — its name, its state, its controls — goes
/// in the pane's one chrome header, published as `PaneHeader` alongside these items, so a rows
/// pane and a body pane say it in the same place and neither spends a second strip on it.
///
/// Every affordance here is driven by a field on the row its author published — no view knows
/// which plugin, or whether a plugin, it is drawing, and no plugin ever sees an AppKit type
/// (VISION §6). A row click and a context-menu pick take the same route back (`onSelect`, with
/// the menu id in the value slot); committing an inline edit takes `onSubmit`.
struct TreeRowsView: View {
    let items: [TreeRowItem]
    /// (itemID, menuID?) — a plain click passes nil.
    let onSelect: (String, String?) -> Void
    /// (itemID, typed text) — empty text means the edit was cancelled.
    let onSubmit: (String, String) -> Void
    /// Whether this list scrolls itself. The offscreen snapshot renders into an unbounded
    /// height and must not nest a scroll view inside one.
    var scrolls = true

    @State private var hoveredID: String?

    var body: some View {
        if scrolls {
            ScrollView {
                rows
            }
            .tenonScrollbarStyle()
            .scrollIndicators(.hidden)
            .background(TenonTheme.panel)
        } else {
            rows.background(TenonTheme.panel)
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 1) {
            ForEach(items) { item in
                TreeRow(
                    item: item,
                    isHovering: hoveredID == item.id,
                    onHover: { hovering in
                        if hovering { hoveredID = item.id }
                        else if hoveredID == item.id { hoveredID = nil }
                    },
                    onSelect: onSelect,
                    onSubmit: onSubmit
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One row. Split out so its hover, focus and edit state stay local — a tree of a
/// thousand files must not re-render because one row is hovered.
private struct TreeRow: View {
    let item: TreeRowItem
    let isHovering: Bool
    let onHover: (Bool) -> Void
    let onSelect: (String, String?) -> Void
    let onSubmit: (String, String) -> Void

    @State private var editingText = ""
    /// Enter commits and then drops focus, and losing focus commits too — without this
    /// latch the author would get the same rename twice, the second time against a file
    /// that no longer exists under its old name.
    @State private var committed = false
    @FocusState private var fieldFocused: Bool

    private var isContainer: Bool { item.expanded != nil }
    private var isDotfile: Bool { item.label.hasPrefix(".") }

    var body: some View {
        Group {
            switch item.kind {
            case .sectionHeader:
                sectionHeader
            case .row:
                if item.editing {
                    editRow
                } else {
                    clickableRow
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(background)
        )
    }

    private var background: Color {
        // A heading names the rows below it; it is not one of them, so it takes no hover and
        // no selection. Tinting it would invite a click that has nothing to do.
        if item.kind == .sectionHeader { return .clear }
        if item.editing { return TenonTheme.text.opacity(0.05) }
        if item.selected { return TenonTheme.text.opacity(0.09) }
        return isHovering ? TenonTheme.text.opacity(0.06) : .clear
    }

    /// The heading over a run of rows — `STAGED`, `CHANGES`, `RECENT`.
    ///
    /// Small, tracked and muted, which is what makes it read as a divider rather than as a
    /// first row: the eye needs to skip it while scanning file names. Its accessory carries
    /// the count, so the number sits in the same right-hand column every row's status does.
    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Text(item.label.uppercased())
                .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            accessory
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }

    private var clickableRow: some View {
        Button {
            onSelect(item.id, nil)
        } label: {
            HStack(spacing: 5) {
                leadingGlyphs
                Text(item.label)
                    .font(TenonTheme.interfaceFont(size: 11.5))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Secondary, so it gives up its width first: `layoutPriority(0)` against the
                // label's default 0 would tie, and a tie splits the shortfall between them —
                // which is how a directory hint ends up eating half of a file's name.
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                accessory
            }
            .padding(.leading, CGFloat(item.depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .modifier(RowDragModifier(path: item.path))
        .modifier(RowMenuModifier(menu: item.menu, itemID: item.id, onSelect: onSelect))
    }

    /// The trailing token — a git status letter, a count. Fixed to the same width whatever it
    /// says, so the column stays a column: a row reading `M` and a row reading `??` that
    /// ended at different x positions would make the eye track a ragged edge down the list.
    @ViewBuilder
    private var accessory: some View {
        if let accessory = item.accessory {
            Text(accessory.text)
                .font(TenonTheme.utilityFont(size: 10, weight: .semibold))
                .foregroundStyle(ViewTokenPalette.color(accessory.tint, style: .caption))
                .lineLimit(1)
                .frame(minWidth: 14, alignment: .trailing)
                .accessibilityHidden(false)
        }
    }

    private var labelColor: Color {
        if item.selected { return TenonTheme.text }
        return isDotfile ? TenonTheme.muted.opacity(0.55) : TenonTheme.text.opacity(0.85)
    }

    /// The inline text field for a rename or a brand-new file. Seeded with the row's
    /// label, focused on the next runloop tick (a context menu may still be dismissing),
    /// committed on Enter or blur, cancelled on Escape — Finder's rules.
    private var editRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            TextField(item.placeholder ?? "", text: $editingText)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 11.5))
                .foregroundStyle(TenonTheme.text)
                .focused($fieldFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3).fill(TenonTheme.ink)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(TenonTheme.amber.opacity(0.7), lineWidth: 1)
                )
                .onSubmit { commit(editingText) }
                .onKeyPress(.escape) {
                    commit("")
                    return .handled
                }
                .onChange(of: fieldFocused) { _, focused in
                    // Commit on blur, like Finder. An empty field reads as a cancel.
                    if !focused { commit(editingText) }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingText = item.label
            committed = false
            // Focus on the next tick: a dismissing context menu steals a synchronous one.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    /// Guarded so the commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commit(_ text: String) {
        guard !committed else { return }
        committed = true
        fieldFocused = false
        onSubmit(item.id, text)
    }

    private var leadingGlyphs: some View {
        Group {
            if let expanded = item.expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(TenonTheme.muted.opacity(0.7))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
            } else {
                // A leaf keeps the slot empty so names stay vertically aligned.
                Spacer().frame(width: 10)
            }
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(isContainer ? TenonTheme.amber.opacity(0.85) : TenonTheme.muted)
                    .frame(width: 14)
            }
        }
    }
}

/// Attaches the row's declarative context menu, or nothing at all when it has none —
/// an always-on `.contextMenu` would swallow the right-click that should fall through
/// to the pane behind an empty row.
private struct RowMenuModifier: ViewModifier {
    let menu: [RowMenuItem]
    let itemID: String
    let onSelect: (String, String?) -> Void

    func body(content: Content) -> some View {
        if menu.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(menu) { entry in
                    if entry.separatorBefore {
                        Divider()
                    }
                    Button(entry.label, role: entry.destructive ? .destructive : nil) {
                        onSelect(itemID, entry.id)
                    }
                }
            }
        }
    }
}

/// Makes a row draggable as a file URL when it declared a `path` — dropping it on the
/// terminal inserts the path, dropping it in Finder copies the file. A click still
/// selects; the drag only starts once the pointer moves.
private struct RowDragModifier: ViewModifier {
    let path: String?

    func body(content: Content) -> some View {
        if let path, !path.isEmpty {
            content.onDrag { NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
        } else {
            content
        }
    }
}
