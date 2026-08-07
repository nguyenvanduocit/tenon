// @domain: command-surface
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

enum LauncherPurpose: Equatable {
    case open
    case fillEmptyGrid
}

/// The search-first launcher shared by the tab strip's `+`, a tab chip's right-click,
/// and empty spatial-grid space. Plugin creation verbs still rank through the palette's
/// `CommandIndex`; the small host-native agent section projects the machine-local
/// suggestions detected once by the shell. Every anchor uses this one presentation.
struct LauncherMenu: View {
    var host: PluginHost
    var intentRuntime: AppIntentRuntime
    /// Shared with ⌘⇧P: same frecency store, so a habit formed in one surface shows in
    /// the other. Its `query`/`selection` belong to the overlay and stay untouched here.
    var palette: CommandPaletteState
    var agentSuggestions: [AgentLaunchSuggestion] = []
    var launchAgent: ((AgentLaunchSuggestion) -> LauncherOutcome)? = nil
    /// How a chosen row is dispatched. `nil` inherits the focused pane through the shared
    /// invoker. Anchors with stronger placement meaning inject a send: the title-bar `+`
    /// creates a tab, a tab chip names the tab that was clicked, and an empty-grid
    /// launcher scopes the command to its exact reserved rectangle.
    var send: ((String) async -> LauncherOutcome)? = nil
    var purpose: LauncherPurpose = .open
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
        let index = switch purpose {
        case .open: host.commandIndex.launcherOnly
        case .fillEmptyGrid: host.commandIndex.paneFillersOnly
        }
        return LauncherSections(
            ranked: index.rank(
                query: query,
                frecency: palette.frecency,
                now: Date()
            ),
            query: query
        )
    }

    private var agentMatches: [(suggestion: AgentLaunchSuggestion, match: CommandMatch)] {
        guard launchAgent != nil else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return agentSuggestions.compactMap { suggestion in
            let titleMatch = query.isEmpty
                ? FuzzyMatch(score: 0, matchedIndices: [])
                : Fuzzy.match(query, in: suggestion.agent.label)
            guard query.isEmpty
                    || titleMatch != nil
                    || Fuzzy.match(query, in: suggestion.displayCommand) != nil
                    || suggestion.habitDescription.map({
                        Fuzzy.match(query, in: $0) != nil
                    }) == true
            else { return nil }
            let command = Command(
                id: "host.agent.\(suggestion.agent.rawValue)",
                title: suggestion.agent.label,
                subtitle: suggestion.habitDescription,
                icon: suggestion.agent == .codex ? "sparkles" : "brain.head.profile"
            )
            return (
                suggestion,
                CommandMatch(
                    command: command,
                    score: Double(titleMatch?.score ?? 0),
                    titleMatch: titleMatch?.matchedIndices ?? []
                )
            )
        }
    }

    var body: some View {
        let order = self.order
        let agents = agentMatches
        let count = agents.count + order.displayed.count
        let selected = count == 0 ? 0 : min(selection, count - 1)

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
            results(agents: agents, order: order, selected: selected, ceiling: listCeiling)
        }
        .frame(width: 300)
        .background(TenonTheme.chromeRaised)
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) { move(1, count: count); return .handled }
        .onKeyPress(.upArrow) { move(-1, count: count); return .handled }
        .accessibilityIdentifier("tenon.launcher")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .frame(width: 15)
                .foregroundStyle(TenonTheme.muted)
            TextField(
                purpose == .fillEmptyGrid
                    ? "Fill this space…"
                    : "Open a terminal, view, or tool…",
                text: $query
            )
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
        agents: [(suggestion: AgentLaunchSuggestion, match: CommandMatch)],
        order: LauncherSections,
        selected: Int,
        ceiling: CGFloat
    ) -> some View {
        let count = agents.count + order.displayed.count
        if count == 0 {
            Text(query.isEmpty
                 ? emptyMessage
                 : "No matches")
                .font(TenonTheme.interfaceFont(size: 11))
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 34)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.suggestion.id) {
                        rowIndex, agent in
                        Button {
                            run(agent.suggestion)
                        } label: {
                            PaletteRow(
                                match: agent.match,
                                isSelected: rowIndex == selected,
                                density: .compact
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Launches \(agent.suggestion.displayCommand)")
                        .accessibilityIdentifier(
                            "tenon.launcher.agent.\(agent.suggestion.agent.rawValue)"
                        )
                    }
                    if !agents.isEmpty, !order.sections.isEmpty {
                        launcherSeparator
                    }
                    ForEach(Array(order.sections.enumerated()), id: \.element.id) {
                        sectionIndex, section in
                        if sectionIndex > 0 {
                            launcherSeparator
                        }
                        ForEach(Array(section.matches.enumerated()), id: \.element.id) {
                            rowIndex, match in
                            Button {
                                run(match)
                            } label: {
                                PaletteRow(
                                    match: match,
                                    isSelected: agents.count + section.startIndex + rowIndex
                                        == selected,
                                    density: .compact
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tenon.launcher.row.\(match.command.id)")
                        }
                    }
                }
                .padding(.vertical, LauncherListHeight.listPadding)
            }
            .tenonScrollbarStyle()
            // Stated, not offered: a ScrollView handed a maxHeight inside a popover
            // greedily takes all of it, floating ten rows in a screen-tall sheet.
            .frame(height: LauncherListHeight.height(
                rows: count,
                sections: order.sections.count + (agents.isEmpty ? 0 : 1),
                ceiling: ceiling
            ))
        }
    }

    private var launcherSeparator: some View {
        Rectangle()
            .fill(TenonTheme.line.opacity(0.6))
            .frame(height: LauncherListHeight.separatorRule)
            .padding(.horizontal, 6)
            .padding(.vertical, LauncherListHeight.separatorPadding)
    }

    private var emptyMessage: String {
        switch purpose {
        case .open: "No plugin offers anything to open yet."
        case .fillEmptyGrid: "Nothing available can fill this space."
        }
    }

    /// ↓/↑ step through the rows as drawn, which after grouping is not the ranking.
    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// Enter runs the highlighted row, resolved through the same displayed order the
    /// highlight was drawn from.
    private func runSelected() {
        let agents = agentMatches
        let total = agents.count + order.displayed.count
        guard total > 0 else { return }
        let selected = min(max(selection, 0), total - 1)
        if agents.indices.contains(selected) {
            run(agents[selected].suggestion)
            return
        }
        let displayed = order.displayed
        guard !displayed.isEmpty else { return }
        let commandIndex = selected - agents.count
        guard displayed.indices.contains(commandIndex) else { return }
        run(displayed[commandIndex])
    }

    private func run(_ suggestion: AgentLaunchSuggestion) {
        guard !isRunning, let launchAgent else { return }
        isRunning = true
        errorMessage = nil
        let outcome = launchAgent(suggestion)
        if outcome.dismisses {
            dismiss()
        } else {
            isRunning = false
            errorMessage = outcome.errorMessage
        }
    }

    /// Same path as the palette: the ranked presentation maps back to its plugin-owned
    /// intent, which is invoked through the palette principal. The result settles
    /// through `LauncherOutcome`, so frecency learns only from a command that ran and a
    /// failure stays visible where the click happened.
    private func run(_ match: CommandMatch) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        Task { @MainActor in
            let outcome: LauncherOutcome
            if let send {
                outcome = await send(match.command.id)
            } else {
                outcome = LauncherOutcome(
                    await PaletteIntentInvoker.send(
                        commandID: match.command.id,
                        host: host,
                        runtime: intentRuntime
                    )
                )
            }
            if outcome.recordsFrecency {
                palette.record(match.command.id)
            }
            if outcome.dismisses {
                dismiss()
            } else {
                isRunning = false
                errorMessage = outcome.errorMessage
            }
        }
    }
}
