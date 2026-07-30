import AppKit
import SwiftUI
import TenonCore

/// The tab strip's `+` menu: a search-first launcher listing the creation verbs plugins
/// declared with `palette.launcher`. It ranks through the same `CommandIndex` the palette
/// does and shares its frecency, so the two surfaces learn one set of habits and the
/// shell keeps no ordering of its own. Adding an entry here is a `manifest.json` change.
struct LauncherMenu: View {
    var host: PluginHost
    var intentRuntime: AppIntentRuntime
    /// Shared with ⌘⇧P: same frecency store, so a habit formed in one surface shows in
    /// the other. Its `query`/`selection` belong to the overlay and stay untouched here.
    var palette: CommandPaletteState
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var isRunning = false
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    /// Rank, then group — one order, produced in one place. Everything downstream (the
    /// rows, the highlight, ↓/↑, Enter) reads `displayed`, so no surface can disagree
    /// with another about what row N is.
    private var order: LauncherSections {
        LauncherSections(
            ranked: host.commandIndex.launcherOnly.rank(
                query: query,
                frecency: palette.frecency,
                now: Date()
            ),
            query: query
        )
    }

    var body: some View {
        let order = self.order
        let selected = order.displayed.isEmpty ? 0 : min(selection, order.displayed.count - 1)

        VStack(spacing: 0) {
            searchField
            Rectangle().fill(TenonTheme.line).frame(height: 1)
            if let errorMessage {
                Text(errorMessage)
                    .font(TenonTheme.utilityFont(size: 10))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            results(order, selected: selected, ceiling: listCeiling)
        }
        .frame(width: 300)
        .background(TenonTheme.chromeRaised)
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) { move(1, in: order); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: order); return .handled }
        .accessibilityIdentifier("tenon.launcher")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .frame(width: 15)
                .foregroundStyle(TenonTheme.muted)
            TextField("Open a terminal, view, or tool…", text: $query)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.text)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .disabled(isRunning)
                .onChange(of: query) { _, _ in
                    selection = 0
                    errorMessage = nil
                }
                .accessibilityIdentifier("tenon.launcher.search")
        }
        // Aligned with the compact row's icon column, so the field's magnifier and
        // every result icon sit on one vertical line.
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    /// How tall the result list may grow: everything left between the popover's anchor
    /// under the title bar and the bottom of the screen it opens on. The list stops where
    /// the display stops — a taller screen simply shows more rows, and scrolling starts
    /// only once there is genuinely nowhere left to put them.
    @MainActor
    private var listCeiling: CGFloat {
        // Search field + its rule + the list's own vertical padding, plus the popover's
        // arrow and a margin so the last row never sits flush against the screen edge.
        let chrome: CGFloat = 32 + 1 + 10 + 28
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main
        else {
            return 320
        }
        let anchor = window.frame.maxY - TenonTheme.titleBarHeight
        return max(140, anchor - screen.visibleFrame.minY - chrome)
    }

    @ViewBuilder
    private func results(
        _ order: LauncherSections,
        selected: Int,
        ceiling: CGFloat
    ) -> some View {
        if order.displayed.isEmpty {
            Text(query.isEmpty
                 ? "No plugin offers anything to open yet."
                 : "No matches")
                .font(TenonTheme.interfaceFont(size: 11))
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 34)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(order.sections.enumerated()), id: \.element.id) {
                        sectionIndex, section in
                        if sectionIndex > 0 {
                            Rectangle()
                                .fill(TenonTheme.line.opacity(0.6))
                                .frame(height: 1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        ForEach(Array(section.matches.enumerated()), id: \.element.id) {
                            rowIndex, match in
                            PaletteRow(
                                match: match,
                                isSelected: section.startIndex + rowIndex == selected,
                                density: .compact
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { run(match) }
                            .accessibilityIdentifier("tenon.launcher.row.\(match.command.id)")
                        }
                    }
                }
                .padding(.vertical, 5)
            }
            .frame(maxHeight: ceiling)
        }
    }

    /// ↓/↑ step through the rows as drawn, which after grouping is not the ranking.
    private func move(_ delta: Int, in order: LauncherSections) {
        guard !order.displayed.isEmpty else { return }
        selection = min(max(selection + delta, 0), order.displayed.count - 1)
    }

    /// Enter runs the highlighted row, resolved through the same displayed order the
    /// highlight was drawn from.
    private func runSelected() {
        let displayed = order.displayed
        guard !displayed.isEmpty else { return }
        run(displayed[min(max(selection, 0), displayed.count - 1)])
    }

    /// Same path as the palette: the ranked presentation maps back to its plugin-owned
    /// intent, which is invoked through the palette principal.
    private func run(_ match: CommandMatch) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        Task { @MainActor in
            guard let result = await PaletteIntentInvoker.send(
                commandID: match.command.id,
                host: host,
                runtime: intentRuntime
            ) else {
                isRunning = false
                errorMessage = "Intent is no longer available."
                return
            }
            switch result {
            case .success:
                palette.record(match.command.id)
                dismiss()
            case .failure(let failure):
                isRunning = false
                errorMessage = failure.error.code.rawValue
            }
        }
    }
}
