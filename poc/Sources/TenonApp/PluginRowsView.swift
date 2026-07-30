import AppKit
import SwiftUI
import TenonCore

/// Renders a plugin view's declarative rows as a real file-manager tree: header strip,
/// disclosure chevrons, native context menus, inline editing, drag-out, selection.
///
/// Every affordance here is driven by a field on the row a plugin published — no view
/// knows which plugin it is drawing, and no plugin ever sees an AppKit type (VISION §6).
/// A row click and a context-menu pick take the same route back (`onSelect`, with the
/// menu id in the value slot); committing an inline edit takes `onSubmit`.
struct PluginRowsView: View {
    let title: String
    let subtitle: String?
    let actions: [ViewAction]
    let items: [PluginRowItem]
    /// (itemID, menuID?) — a plain click passes nil.
    let onSelect: (String, String?) -> Void
    /// (itemID, typed text) — empty text means the edit was cancelled.
    let onSubmit: (String, String) -> Void

    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !title.isEmpty || subtitle != nil || !actions.isEmpty {
                header
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        PluginRow(
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
            }
            .scrollIndicators(.hidden)
        }
        .background(TenonTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if !title.isEmpty {
                    Text(title)
                        .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))
                        .foregroundStyle(TenonTheme.text)
                        .lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TenonTheme.interfaceFont(size: 10))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                        // Head truncation keeps the meaningful tail of a path visible.
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(actions) { action in
                Button {
                    onSelect(action.id, nil)
                } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(TenonTheme.muted)
                }
                .buttonStyle(.plain)
                .help(action.tooltip ?? "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One row. Split out so its hover, focus and edit state stay local — a tree of a
/// thousand files must not re-render because one row is hovered.
private struct PluginRow: View {
    let item: PluginRowItem
    let isHovering: Bool
    let onHover: (Bool) -> Void
    let onSelect: (String, String?) -> Void
    let onSubmit: (String, String) -> Void

    @State private var editingText = ""
    /// Enter commits and then drops focus, and losing focus commits too — without this
    /// latch the plugin would get the same rename twice, the second time against a file
    /// that no longer exists under its old name.
    @State private var committed = false
    @FocusState private var fieldFocused: Bool

    private var isContainer: Bool { item.expanded != nil }
    private var isDotfile: Bool { item.label.hasPrefix(".") }

    var body: some View {
        Group {
            if item.editing {
                editRow
            } else {
                clickableRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(background)
        )
    }

    private var background: Color {
        if item.editing { return TenonTheme.text.opacity(0.05) }
        if item.selected { return TenonTheme.text.opacity(0.09) }
        return isHovering ? TenonTheme.text.opacity(0.06) : .clear
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
                Spacer(minLength: 0)
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
