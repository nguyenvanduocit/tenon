// @domain: command-surface
import SwiftUI
import TenonCore

/// The search-first launcher an empty tab and an empty pane both open with.
///
/// The card leads with a focused search field, because the reason a person is looking at an
/// empty pane is that they want something in it — and the fastest way to say which thing is
/// to type its name. Nothing typed keeps the grouped layout: the primary terminal action, the
/// agents this machine has, the views, and what this workspace opened recently. A query
/// replaces those groups with one ranked list, which ↓/↑ walks and Enter runs. A typed query
/// is also always offered as a command line to run in a fresh terminal, so `npm run dev` is
/// something an empty pane accepts rather than something it sends you elsewhere to type.
///
/// The two mounts differ only in what a pick does: an empty tab adds a slot, an empty pane
/// fills itself in place.
struct EmptyStateCard: View {
    let recents: [SlotContent]
    let agentSuggestions: [AgentLaunchSuggestion]
    /// Whether the keyboard belongs to this card. Only one empty pane in a split may hold the
    /// search field's focus, or two fields would fight over every keystroke.
    let isActive: Bool
    let onLaunch: (SlotContent) -> Void
    let onLaunchAgent: (AgentLaunchSuggestion) -> Void
    let onRunCommand: (String) -> Void

    @State private var query: String
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    /// `initialQuery` is what the field starts with. Both real mounts open empty; the seam
    /// exists so the card's typed states can be asserted for height and photographed
    /// offscreen, which is the only way to see that a query genuinely replaces the grouped
    /// layout rather than appearing beside it.
    init(
        recents: [SlotContent],
        agentSuggestions: [AgentLaunchSuggestion],
        isActive: Bool,
        initialQuery: String = "",
        onLaunch: @escaping (SlotContent) -> Void,
        onLaunchAgent: @escaping (AgentLaunchSuggestion) -> Void,
        onRunCommand: @escaping (String) -> Void
    ) {
        self.recents = recents
        self.agentSuggestions = agentSuggestions
        self.isActive = isActive
        self.onLaunch = onLaunch
        self.onLaunchAgent = onLaunchAgent
        self.onRunCommand = onRunCommand
        _query = State(initialValue: initialQuery)
    }

    private var offerings: EmptyPaneOfferings {
        EmptyPaneOfferings(agents: agentSuggestions, recents: recents)
    }

    private var results: [EmptyPaneLauncherRow] {
        EmptyPaneLauncher.rows(query: query, items: offerings.commands)
    }

    var body: some View {
        let results = self.results
        let selected = results.isEmpty ? 0 : min(selection, results.count - 1)

        VStack(spacing: 14) {
            searchField

            if results.isEmpty {
                groupedOfferings
            } else {
                resultList(results, selected: selected)
            }

            cheatsheet
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 320)
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
        .onAppear { searchFocused = isActive }
        .onChange(of: isActive) { _, active in searchFocused = active }
        .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
        // Escape empties the field rather than dismissing anything: there is nothing to
        // dismiss — the card *is* the pane — so the key that means "back out" returns the
        // card to the grouped layout it opened with.
        .onKeyPress(.escape) {
            guard !query.isEmpty else { return .ignored }
            query = ""
            selection = 0
            return .handled
        }
    }

    // MARK: - Search  @domain: command-surface

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            TextField("Open a view or run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.text)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in selection = 0 }
                .accessibilityIdentifier("empty-state-search")
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TenonTheme.chrome.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    searchFocused ? TenonTheme.amber.opacity(0.55) : TenonTheme.line,
                    lineWidth: 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    /// Enter belongs to the field alone. The Add-terminal button carried
    /// `keyboardShortcut(.defaultAction)` before this card had a field to submit; leaving both
    /// in place would give one key two owners.
    private func runSelected() {
        let results = self.results
        guard !results.isEmpty else {
            onLaunch(.terminal)
            return
        }
        run(results[min(max(selection, 0), results.count - 1)])
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func run(_ row: EmptyPaneLauncherRow) {
        switch row.kind {
        case .runCommand(let commandLine):
            onRunCommand(commandLine)
        case .item(let id):
            switch offerings.pick(itemID: id) {
            case .terminal: onLaunch(.terminal)
            case .agent(let suggestion): onLaunchAgent(suggestion)
            case .content(let content): onLaunch(content)
            case nil: break
            }
        }
    }

    // MARK: - Ranked results  @domain: command-surface

    private func resultList(
        _ results: [EmptyPaneLauncherRow],
        selected: Int
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                Button { run(row) } label: {
                    EmptyStateResultRow(row: row, isSelected: index == selected)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("empty-state-result-\(row.id)")
            }
        }
    }

    // MARK: - Nothing typed  @domain: command-surface

    private var groupedOfferings: some View {
        VStack(spacing: 16) {
            EmptyStateActionButton(
                title: "Add terminal",
                shortcut: "\u{21A9}",
                action: { onLaunch(.terminal) }
            )
            .accessibilityIdentifier("empty-state-add-terminal")

            if !agentSuggestions.isEmpty {
                agentLauncher
            }

            launcher

            if !offerings.recents.isEmpty {
                recentlyOpened
            }
        }
    }

    private var launcher: some View {
        VStack(spacing: 8) {
            SectionLabel("Open a view")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(Array(EmptyPaneOfferings.views.enumerated()), id: \.offset) { _, item in
                    LaunchTile(
                        glyph: SlotPresentation.glyph(for: item.content),
                        label: item.label,
                        action: { onLaunch(item.content) }
                    )
                }
            }
        }
    }

    private var agentLauncher: some View {
        VStack(spacing: 6) {
            SectionLabel("Start an agent")
            VStack(spacing: 4) {
                ForEach(agentSuggestions) { suggestion in
                    AgentLaunchCardRow(
                        suggestion: suggestion,
                        action: { onLaunchAgent(suggestion) }
                    )
                }
            }
        }
    }

    private var recentlyOpened: some View {
        VStack(spacing: 6) {
            SectionLabel("Recently opened")
            VStack(spacing: 4) {
                ForEach(Array(offerings.recents.enumerated()), id: \.offset) { _, content in
                    RecentRow(
                        glyph: SlotPresentation.glyph(for: content),
                        label: EmptyPaneOfferings.label(for: content),
                        action: { onLaunch(content) }
                    )
                }
            }
        }
    }

    private var cheatsheet: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(TenonTheme.line.opacity(0.6))
                .frame(height: 1)
            Text("\u{2318}T new tab   \u{2318}D split   \u{2318}W close")
                .font(TenonTheme.utilityFont(size: 10, weight: .medium))
                .foregroundStyle(TenonTheme.muted.opacity(0.8))
        }
        .padding(.top, 2)
    }

}

/// One row of the ranked list a typed query produces. The glyph column, height and hover
/// treatment match `LaunchTile` and `RecentRow`, so switching between the two states of the
/// card does not read as switching between two cards.
private struct EmptyStateResultRow: View {
    let row: EmptyPaneLauncherRow
    let isSelected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(row.glyph)
                .font(TenonTheme.utilityFont(size: 12, weight: .semibold))
                .foregroundStyle(TenonTheme.amber.opacity(0.9))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(TenonTheme.utilityFont(size: 9, weight: .medium))
                        .foregroundStyle(TenonTheme.muted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Text("\u{21A9}")
                    .font(TenonTheme.utilityFont(size: 11, weight: .medium))
                    .foregroundStyle(TenonTheme.muted)
            }
        }
        // One height for every row, whether or not it carries a subtitle: an uneven column is
        // harder to walk with ↓/↑ than a slightly tall one is to read.
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected || hovering ? TenonTheme.chromeRaised : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? TenonTheme.line : .clear, lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The characters the query matched are drawn in the card's own foreground; everything
    /// else stays quiet, so a glance lands on why this row is in the list.
    private var highlightedTitle: Text {
        let matched = Set(row.titleMatch)
        guard !matched.isEmpty else {
            return Text(row.title)
                .font(TenonTheme.interfaceFont(size: 12, weight: .medium))
                .foregroundColor(TenonTheme.text)
        }
        return row.title.enumerated().reduce(Text("")) { accumulated, character in
            accumulated + Text(String(character.element))
                .font(
                    TenonTheme.interfaceFont(
                        size: 12,
                        weight: matched.contains(character.offset) ? .semibold : .regular
                    )
                )
                .foregroundColor(
                    matched.contains(character.offset) ? TenonTheme.amber : TenonTheme.text
                )
        }
    }
}

/// A detected agent stays visually quieter than the primary Terminal action. The learned
/// option is always visible when it changes authority, so convenience never hides bypass.
///
/// Internal rather than private so `LauncherMenu`'s grouped layout can draw the same row for
/// its own agent suggestions — one card presentation for "start an agent", not two.
struct AgentLaunchCardRow: View {
    let suggestion: AgentLaunchSuggestion
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.agent == .codex
                      ? "sparkles"
                      : "brain.head.profile")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TenonTheme.amber.opacity(0.9))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(suggestion.agent.label)
                    .font(TenonTheme.interfaceFont(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? TenonTheme.text : TenonTheme.muted)
                Spacer(minLength: 8)
                if let habit = suggestion.habitDescription {
                    Text(habit)
                        .font(TenonTheme.utilityFont(size: 9, weight: .medium))
                        .foregroundStyle(TenonTheme.muted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? TenonTheme.chromeRaised : TenonTheme.chrome.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(TenonTheme.line.opacity(hovering ? 1 : 0.6), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Launches \(suggestion.displayCommand)")
        .accessibilityHint("Launches \(suggestion.displayCommand)")
        .accessibilityIdentifier("empty-state-agent-\(suggestion.agent.rawValue)")
    }
}

/// A quiet, tracked, uppercase caption that heads a group inside the card.
///
/// Internal rather than private so `LauncherMenu`'s grouped layout can head its own sections
/// with the same caption, rather than a second implementation of one uppercase label.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TenonTheme.muted.opacity(0.7))
            Spacer(minLength: 0)
        }
    }
}

/// One cell in the launcher grid: a glyph + label that opens that view on click.
private struct LaunchTile: View {
    let glyph: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(glyph)
                    .font(TenonTheme.utilityFont(size: 12, weight: .semibold))
                    .foregroundStyle(TenonTheme.amber.opacity(0.9))
                    .frame(width: 16)
                Text(label)
                    .font(TenonTheme.interfaceFont(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? TenonTheme.text : TenonTheme.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? TenonTheme.chromeRaised : TenonTheme.chrome.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(TenonTheme.line.opacity(hovering ? 1 : 0.6), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One cell in a ranked-command tile grid: `LaunchTile`'s exact chrome, drawn for a ranked
/// command's SF Symbol icon instead of `SlotContent`'s text glyph — `Command.icon` and
/// `SlotPresentation.glyph` are two different vocabularies that never mix in one view, so this
/// is `LaunchTile`'s twin rather than a reused instance of it.
///
/// Internal rather than private so `LauncherMenu`'s grouped layout can draw its own "Open a
/// view" tile grid with the same row — a launcher row's highlight/hover chrome may compose
/// only `PaletteRowChrome` or a type declared here, never be reimplemented inside
/// `LauncherMenu.swift` itself (`InteractionBoundaryFitnessTests
/// .testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics`).
struct CommandTile: View {
    let icon: String?
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon ?? "command")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TenonTheme.amber.opacity(0.9))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(TenonTheme.interfaceFont(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? TenonTheme.text : TenonTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? TenonTheme.chromeRaised : TenonTheme.chrome.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(TenonTheme.line.opacity(hovering ? 1 : 0.6), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One entry in the "recently opened" list: reopens that view on click.
///
/// Internal rather than private so `LauncherMenu`'s grouped layout can draw the tab strip's
/// own "Recently opened" section with the exact same row.
struct RecentRow: View {
    let glyph: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(glyph)
                    .font(TenonTheme.utilityFont(size: 12, weight: .semibold))
                    .foregroundStyle(TenonTheme.amber.opacity(0.85))
                    .frame(width: 16)
                Text(label)
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(hovering ? TenonTheme.text : TenonTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? TenonTheme.chromeRaised : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The card's one filled call to action, with its keyboard hint aligned right.
///
/// Internal rather than private so `LauncherMenu`'s grouped layout can draw the same "Add
/// terminal" CTA it does, rather than a second button style for one action.
struct EmptyStateActionButton: View {
    let title: String
    let shortcut: String
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
                    .foregroundStyle(TenonTheme.ink.opacity(0.75))
            }
            .foregroundStyle(TenonTheme.ink)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? TenonTheme.amber : TenonTheme.amber.opacity(0.92))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
