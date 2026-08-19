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
/// suggestions detected once by the shell.
///
/// A typed query, or the narrower `.fillEmptyGrid` fill-this-space flow, draws one flat
/// ranked list. `.open` with nothing typed — the tab strip's own open-a-tab launcher —
/// groups instead, the same presentation `EmptyStateCard` draws for an empty tab or pane:
/// a terminal CTA, agents, commands regrouped by category, recents, and pane utilities.
/// One ranking, one dispatch path, two presentations of it.
struct LauncherMenu: View {
    private static func agentIcon(_ agent: AgentCLI) -> String {
        switch agent {
        case .codex: "sparkles"
        case .claude: "brain.head.profile"
        case .opencode: "curlybraces"
        }
    }

    var host: PluginHost
    var intentRuntime: AppIntentRuntime
    /// Shared with ⌘⇧P: same frecency store, so a habit formed in one surface shows in
    /// the other. Its `query`/`selection` belong to the overlay and stay untouched here.
    var palette: CommandPaletteState
    var agentSuggestions: [AgentLaunchSuggestion] = []
    var launchAgent: ((AgentLaunchSuggestion) -> LauncherOutcome)? = nil
    /// A tab anchor may expose its same-owner identity utility below the shared command
    /// projection. It never enters ranking/search because copying an address is not an
    /// open command and has no public intent principal.
    var copyTabID: (() -> Void)? = nil
    /// Whole-tab geometry is another fixed host utility, not a plugin command pretending
    /// to have won fuzzy ranking. The anchor supplies only presets valid for its exact tab.
    var paneArrangements: [PaneArrangementPreset] = []
    var arrangePanes: ((PaneArrangementPreset) -> Void)? = nil
    /// This workspace's recently opened content, same source and same cap `EmptyStateCard`
    /// draws from. Only the grouped layout draws it; an anchor with nothing to ask (the
    /// empty-grid launcher has no workspace-scoped recents concept) leaves it empty.
    var recents: [SlotContent] = []
    /// How a picked recent is opened. `nil` anchors simply do not draw the section — this is
    /// a placement decision only the anchor can make (a new tab vs. the tab that was
    /// right-clicked), the same reason `send` above is threaded rather than owned here.
    var openRecent: ((SlotContent) -> Void)? = nil
    /// How a chosen row is dispatched. `nil` inherits the focused pane through the shared
    /// invoker. Anchors with stronger placement meaning receive the invocation already
    /// bound at the accepted click: the title-bar `+` creates a tab, a tab chip names the
    /// tab that was clicked, and an empty-grid launcher scopes the command to its exact
    /// reserved rectangle. No anchor maps the visible row back to a provider a second time.
    var send: ((PaletteIntentInvocation) async -> LauncherOutcome)? = nil
    /// A typed query offered as a shell command line to run in a fresh terminal — the exact
    /// parity `EmptyStateCard`'s own search field already has. `nil` anchors simply do not
    /// draw the row, same convention as every other optional callback here.
    var runCommand: ((String) -> LauncherOutcome)? = nil
    var purpose: LauncherPurpose = .open
    /// Where the control this popover hangs off sits on the screen, and which way the
    /// popover grows away from it. Together they are the only honest answer to how tall the
    /// result list may be: the anchor is not always near the top of the window — a tab strip
    /// drawn at the foot opens upward — and a list sized for room that is off the display
    /// scrolls when it did not have to, or floats in chrome when it should not.
    var anchorRectInScreen: CGRect = .zero
    var opening: LauncherListHeight.Opening = .below
    let dismiss: () -> Void

    @State private var query: String
    @State private var selection = 0
    @State private var isRunning = false
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    /// `initialQuery` seeds `query` the same way `EmptyStateCard.initialQuery` does — real
    /// mounts always start empty; the seam exists so the typed-query run-command row can be
    /// measured offscreen, the only way to prove it draws without a live popover.
    init(
        host: PluginHost,
        intentRuntime: AppIntentRuntime,
        palette: CommandPaletteState,
        agentSuggestions: [AgentLaunchSuggestion] = [],
        launchAgent: ((AgentLaunchSuggestion) -> LauncherOutcome)? = nil,
        copyTabID: (() -> Void)? = nil,
        paneArrangements: [PaneArrangementPreset] = [],
        arrangePanes: ((PaneArrangementPreset) -> Void)? = nil,
        recents: [SlotContent] = [],
        openRecent: ((SlotContent) -> Void)? = nil,
        send: ((PaletteIntentInvocation) async -> LauncherOutcome)? = nil,
        runCommand: ((String) -> LauncherOutcome)? = nil,
        purpose: LauncherPurpose = .open,
        anchorRectInScreen: CGRect = .zero,
        opening: LauncherListHeight.Opening = .below,
        initialQuery: String = "",
        dismiss: @escaping () -> Void
    ) {
        self.host = host
        self.intentRuntime = intentRuntime
        self.palette = palette
        self.agentSuggestions = agentSuggestions
        self.launchAgent = launchAgent
        self.copyTabID = copyTabID
        self.paneArrangements = paneArrangements
        self.arrangePanes = arrangePanes
        self.recents = recents
        self.openRecent = openRecent
        self.send = send
        self.runCommand = runCommand
        self.purpose = purpose
        self.anchorRectInScreen = anchorRectInScreen
        self.opening = opening
        self.dismiss = dismiss
        _query = State(initialValue: initialQuery)
    }

    /// The canonical intent id `core-commands` declares for "New Terminal". Pinned here so
    /// the grouped layout can promote that one ranked row to its CTA button without a second,
    /// bypassing way to open a terminal — the CTA still runs through `run(_ match:)` below,
    /// same as every other row.
    private static let terminalCommandID = "dev.tenon.core-commands.terminal.new.v1"

    /// Nothing typed and this is the tab strip's own open-a-tab launcher: the exact case
    /// `EmptyStateCard` groups for. A typed query, or `.fillEmptyGrid`'s narrower
    /// fill-this-space flow, keep the flat ranked list unchanged — grouping is a statement
    /// about *this* anchor's empty state, not about ranking in general.
    private var showsGroupedLayout: Bool {
        purpose == .open && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The one ranking call every other computed property reads from, so the grouped
    /// layout's CTA and the keyboard-navigable order below it can never disagree about which
    /// row is the terminal command.
    private var rankedCommands: [CommandMatch] {
        let index = switch purpose {
        case .open: host.commandIndex.launcherOnly
        case .fillEmptyGrid: host.commandIndex.paneFillersOnly
        }
        return index.rank(query: query, frecency: palette.frecency, now: Date())
    }

    /// Rank, then group — one order, produced in one place. Everything downstream (the
    /// rows, the highlight, ↓/↑, Enter) reads `displayed`, so no surface can disagree
    /// with another about what row N is. Grouped layout draws the terminal command as its
    /// own CTA above this list, so it is filtered out here rather than drawn twice.
    private var order: LauncherSections {
        let ranked = rankedCommands
        let filtered = showsGroupedLayout
            ? ranked.filter { $0.command.id != Self.terminalCommandID }
            : ranked
        return LauncherSections(ranked: filtered, query: query)
    }

    /// The ranked terminal-launch command, pulled out for the grouped layout's CTA. `nil`
    /// when core-commands is unavailable — the CTA simply does not draw rather than
    /// fabricating a row nothing backs.
    private var terminalMatch: CommandMatch? {
        guard showsGroupedLayout else { return nil }
        return rankedCommands.first { $0.command.id == Self.terminalCommandID }
    }

    /// Capped the same as `EmptyStateCard`'s own recents section, so a workspace with a long
    /// history does not turn "Recently opened" into the tallest section in the popover.
    private var groupedRecents: [SlotContent] {
        Array(recents.prefix(4))
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
                icon: Self.agentIcon(suggestion.agent)
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

    /// The id a synthetic "run this as a command line" row carries. Never a real command id
    /// — `run(_ match:)` reads it to route to `runCommand` instead of the intent path.
    private static let runCommandRowID = "host.runCommand"

    /// A typed query offered as a shell command line, placed the same way
    /// `EmptyPaneLauncher` places it for the empty-pane card — leading when the query reads
    /// as a command line, trailing when it reads as a name. `RunCommandOffer` is the one rule
    /// both surfaces read; this never restates it. `nil` whenever `runCommand` was not
    /// supplied, the grouped layout is showing (there is no typed text to read), or the query
    /// does not qualify.
    private var runCommandOffer: (match: CommandMatch, placement: RunCommandOffer.Placement)? {
        guard runCommand != nil, !showsGroupedLayout else { return nil }
        let placement = RunCommandOffer.placement(for: query)
        guard placement != .none else { return nil }
        let commandLine = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = Command(
            id: Self.runCommandRowID,
            title: commandLine,
            subtitle: "Run in a new terminal",
            icon: "terminal"
        )
        return (CommandMatch(command: command, score: 0, titleMatch: []), placement)
    }

    var body: some View {
        let order = self.order
        let agents = agentMatches
        let runOffer = runCommandOffer
        let count = agents.count + order.displayed.count + (runOffer == nil ? 0 : 1)
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
            if showsGroupedLayout {
                groupedContent(agents: agents)
            } else {
                results(
                    agents: agents,
                    order: order,
                    runOffer: runOffer,
                    selected: selected,
                    ceiling: listCeiling
                )
                if utilityRowCount > 0 {
                    Rectangle().fill(TenonTheme.line).frame(height: 1)
                }
                if let arrangePanes, !paneArrangements.isEmpty {
                    PaneArrangementMenu(
                        presets: paneArrangements,
                        arrange: arrangePanes,
                        dismissLauncher: dismiss
                    )
                }
                if let copyTabID {
                    // Same chrome as every row above it, so the pointer gets the same answer
                    // here as it does anywhere else in the popover. `isSelected` is fixed
                    // `false` because this utility never joins the ranked order ↓/↑ walks,
                    // which is exactly why it could not be drawn as a ranked row.
                    Button {
                        copyTabID()
                        dismiss()
                    } label: {
                        PaletteRowChrome(
                            icon: "doc.on.doc",
                            title: Text("Copy Tab ID"),
                            isSelected: false,
                            density: .compact
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tenon.launcher.copyTabID")
                }
            }
        }
        .frame(width: 300)
        .background(TenonTheme.chromeRaised)
        .onAppear { searchFocused = true }
        // The grouped layout has no ranked, index-addressable rows of its own — same as
        // `EmptyStateCard`'s grouped state, where ↓/↑ do nothing until a query replaces it
        // with a ranked list. Every grouped row is a plain click, the same way Copy Tab ID
        // already was.
        .onKeyPress(.downArrow) {
            if !showsGroupedLayout { move(1, count: count) }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !showsGroupedLayout { move(-1, count: count) }
            return .handled
        }
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

    /// How tall the result list may grow: the room the display actually leaves between this
    /// popover's anchor and the edge it opens toward. The list stops where the display stops
    /// — a taller screen simply shows more rows, and scrolling starts only once there is
    /// genuinely nowhere left to put them.
    ///
    /// The anchor and the direction come from whoever opened it, because only the anchor
    /// knows them. This used to measure downward from the window's top edge on the
    /// assumption that every launcher hung under the title bar, which was already wrong for
    /// the empty-grid anchor and is wrong for the whole tab strip once it is drawn at the
    /// foot.
    @MainActor
    private var listCeiling: CGFloat {
        // Search field + its rule + the list's own vertical padding, plus the popover's
        // arrow and a margin so the last row never sits flush against the screen edge.
        // The footer is one compact chrome row plus the 1-pt rule above it. The grouped
        // layout has no separate footer chrome to add: its utility rows are measured as
        // part of `groupedContentHeight` instead of sitting below the scrollable list.
        let chrome: CGFloat
        if showsGroupedLayout {
            chrome = 32 + 1 + 10 + 28
        } else {
            let utilityHeight = CGFloat(utilityRowCount) * LauncherListHeight.row
                + (utilityRowCount == 0 ? 0 : LauncherListHeight.separatorRule)
            chrome = 32 + 1 + 10 + 28 + utilityHeight
        }
        guard !anchorRectInScreen.isEmpty,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.intersects(anchorRectInScreen)
              }) ?? NSScreen.main
        else {
            return 320
        }
        return LauncherListHeight.ceiling(
            anchor: anchorRectInScreen,
            opening: opening,
            visibleFrame: screen.visibleFrame,
            chrome: chrome
        )
    }

    private var utilityRowCount: Int {
        (arrangePanes == nil || paneArrangements.isEmpty ? 0 : 1)
            + (copyTabID == nil ? 0 : 1)
    }

    @ViewBuilder
    private func results(
        agents: [(suggestion: AgentLaunchSuggestion, match: CommandMatch)],
        order: LauncherSections,
        runOffer: (match: CommandMatch, placement: RunCommandOffer.Placement)?,
        selected: Int,
        ceiling: CGFloat
    ) -> some View {
        // A leading run-command row shifts every other row's selectable index by one; a
        // trailing one does not, since it sits after everything else already does.
        let leadingOffset = runOffer?.placement == .leading ? 1 : 0
        let count = agents.count + order.displayed.count + (runOffer == nil ? 0 : 1)
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
                    if let runOffer, runOffer.placement == .leading {
                        runCommandRow(runOffer.match, isSelected: selected == 0)
                    }
                    ForEach(Array(agents.enumerated()), id: \.element.suggestion.id) {
                        rowIndex, agent in
                        Button {
                            run(agent.suggestion)
                        } label: {
                            PaletteRow(
                                match: agent.match,
                                isSelected: rowIndex + leadingOffset == selected,
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
                                        + leadingOffset == selected,
                                    density: .compact
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tenon.launcher.row.\(match.command.id)")
                        }
                    }
                    if let runOffer, runOffer.placement == .trailing {
                        runCommandRow(
                            runOffer.match,
                            isSelected: selected == agents.count + order.displayed.count
                        )
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

    /// The flat list's own run-command row: the same `PaletteRow` chrome every ranked row
    /// draws, so it reads as one more row rather than a different kind of thing.
    private func runCommandRow(_ match: CommandMatch, isSelected: Bool) -> some View {
        Button {
            run(match)
        } label: {
            PaletteRow(match: match, isSelected: isSelected, density: .compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tenon.launcher.runCommand")
    }

    // MARK: - Grouped layout (nothing typed, purpose == .open)  @domain: command-surface

    /// Every constant `groupedContentHeight` sums is drawn with the identical `.frame`
    /// below, the same discipline `LauncherListHeight` holds the flat list to: the rule and
    /// the pixels cannot drift apart because there is exactly one place either is stated.
    private static let groupedCTAHeight: CGFloat = 34
    private static let groupedAgentRowHeight: CGFloat = 32
    private static let groupedRecentRowHeight: CGFloat = 30
    /// `SectionLabel`'s own height (14) plus the spacing `groupedSection` places under it
    /// (6) before its first row.
    private static let groupedSectionHeaderHeight: CGFloat = 20
    private static let groupedRowSpacing: CGFloat = 4
    private static let groupedGroupSpacing: CGFloat = 14
    private static let groupedVerticalPadding: CGFloat = 12
    /// `LaunchTile`/`CommandTile`'s own fixed row height, and the `LazyVGrid` row spacing
    /// `EmptyStateCard.launcher` already draws its own "Open a view" grid with — the same
    /// two numbers, so the two grids read as the same grid.
    private static let groupedTileHeight: CGFloat = 32
    private static let groupedTileSpacing: CGFloat = 8

    /// Ranked launcher commands that can fill a pane, minus the CTA — `EmptyStateCard`'s
    /// exact "Open a view" vocabulary read off `CommandIndex` instead of duplicated: `.open`
    /// and `.fillEmptyGrid` already rank this identical subset (`fillsPane`), grouping only
    /// changes how `.open` presents it. Drawn as a tile grid, never as one section per
    /// plugin's own `category` — that was the fragmentation a screenshot reported.
    private var groupedPaneFillers: [CommandMatch] {
        guard showsGroupedLayout else { return [] }
        return rankedCommands.filter { $0.command.fillsPane && $0.command.id != Self.terminalCommandID }
    }

    /// Launcher commands that do not fill a pane — tab/pane lifecycle verbs like New Tab or
    /// Split Right/Down. Each used to draw its own one- or two-row category section; folded
    /// into "Pane" instead, the section they actually belong beside (Copy Tab ID, Arrange
    /// Panes), so three section headers become one.
    private var groupedOtherCommands: [CommandMatch] {
        guard showsGroupedLayout else { return [] }
        return rankedCommands.filter { !$0.command.fillsPane && $0.command.id != Self.terminalCommandID }
    }

    /// The grouped presentation `EmptyStateCard` draws when its own query is empty: a
    /// terminal CTA, the agents this machine detected, a tile grid of the ranked commands
    /// that can fill a pane, this workspace's recents, and a "Pane" section holding every
    /// other ranked command alongside the popover-only utilities — one card language for all
    /// of it instead of a dense ranked list.
    @ViewBuilder
    private func groupedContent(
        agents: [(suggestion: AgentLaunchSuggestion, match: CommandMatch)]
    ) -> some View {
        let recents = groupedRecents
        let terminalMatch = self.terminalMatch
        let paneFillers = groupedPaneFillers
        let otherCommands = groupedOtherCommands
        ScrollView {
            VStack(alignment: .leading, spacing: Self.groupedGroupSpacing) {
                if let terminalMatch {
                    EmptyStateActionButton(
                        title: "Add terminal",
                        shortcut: "\u{21A9}",
                        action: { run(terminalMatch) }
                    )
                    .accessibilityIdentifier("tenon.launcher.addTerminal")
                }

                if !agents.isEmpty {
                    groupedSection("Start an agent") {
                        ForEach(agents, id: \.suggestion.id) { agent in
                            AgentLaunchCardRow(
                                suggestion: agent.suggestion,
                                action: { run(agent.suggestion) }
                            )
                            .accessibilityIdentifier(
                                "tenon.launcher.agent.\(agent.suggestion.agent.rawValue)"
                            )
                        }
                    }
                }

                if !paneFillers.isEmpty {
                    groupedSection("Open a view") {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: Self.groupedTileSpacing),
                                GridItem(.flexible(), spacing: Self.groupedTileSpacing),
                            ],
                            spacing: Self.groupedTileSpacing
                        ) {
                            ForEach(paneFillers) { match in
                                CommandTile(
                                    icon: match.command.icon,
                                    title: match.command.title,
                                    action: { run(match) }
                                )
                                .accessibilityIdentifier("tenon.launcher.row.\(match.command.id)")
                            }
                        }
                    }
                }

                if !recents.isEmpty {
                    groupedSection("Recently opened") {
                        ForEach(Array(recents.enumerated()), id: \.offset) { _, content in
                            RecentRow(
                                glyph: SlotPresentation.glyph(for: content),
                                label: EmptyPaneOfferings.label(for: content),
                                action: {
                                    openRecent?(content)
                                    dismiss()
                                }
                            )
                        }
                    }
                }

                if !otherCommands.isEmpty || utilityRowCount > 0 {
                    groupedSection("Pane") {
                        ForEach(otherCommands) { match in
                            groupedCommandRow(match)
                        }
                        if let arrangePanes, !paneArrangements.isEmpty {
                            PaneArrangementMenu(
                                presets: paneArrangements,
                                arrange: arrangePanes,
                                dismissLauncher: dismiss
                            )
                        }
                        if let copyTabID {
                            Button {
                                copyTabID()
                                dismiss()
                            } label: {
                                PaletteRowChrome(
                                    icon: "doc.on.doc",
                                    title: Text("Copy Tab ID"),
                                    isSelected: false,
                                    density: .compact
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tenon.launcher.copyTabID")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, Self.groupedVerticalPadding)
        }
        .tenonScrollbarStyle()
        // Same discipline as the flat list's own `.frame(height:)` above: offered a
        // popover's unconstrained height, a ScrollView takes all of it.
        .frame(height: min(
            groupedContentHeight(
                hasTerminalCTA: terminalMatch != nil,
                agentCount: agents.count,
                paneFillerCount: paneFillers.count,
                otherCommandCount: otherCommands.count,
                recentsCount: recents.count
            ),
            listCeiling
        ))
    }

    /// A section's label, spaced the same as every other section, over whatever rows it is
    /// handed. The one place `groupedContentHeight` mirrors below.
    @ViewBuilder
    private func groupedSection<Content: View>(
        _ title: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
                .frame(height: 14)
            VStack(spacing: Self.groupedRowSpacing) {
                rows()
            }
        }
    }

    /// One ranked command drawn in the grouped layout: the same `PaletteRow` chrome the flat
    /// list uses, just never keyboard-selected — grouped rows are mouse-only, matching
    /// `EmptyStateCard`'s own grouped state.
    private func groupedCommandRow(_ match: CommandMatch) -> some View {
        Button {
            run(match)
        } label: {
            PaletteRow(match: match, isSelected: false, density: .compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tenon.launcher.row.\(match.command.id)")
    }

    /// Sums the exact heights `groupedContent` draws with, group by group, the same way
    /// `LauncherListHeight.height` sums the flat list's uniform rows — just over rows whose
    /// heights differ by section.
    private func groupedContentHeight(
        hasTerminalCTA: Bool,
        agentCount: Int,
        paneFillerCount: Int,
        otherCommandCount: Int,
        recentsCount: Int
    ) -> CGFloat {
        var groups: [CGFloat] = []
        if hasTerminalCTA {
            groups.append(Self.groupedCTAHeight)
        }
        if agentCount > 0 {
            groups.append(groupHeight(rows: agentCount, rowHeight: Self.groupedAgentRowHeight))
        }
        if paneFillerCount > 0 {
            groups.append(tileGridHeight(itemCount: paneFillerCount))
        }
        if recentsCount > 0 {
            groups.append(groupHeight(rows: recentsCount, rowHeight: Self.groupedRecentRowHeight))
        }
        let paneRows = otherCommandCount + utilityRowCount
        if paneRows > 0 {
            groups.append(groupHeight(rows: paneRows, rowHeight: LauncherListHeight.row))
        }

        let content = groups.reduce(0, +)
            + CGFloat(max(0, groups.count - 1)) * Self.groupedGroupSpacing
        return content + Self.groupedVerticalPadding * 2
    }

    private func groupHeight(rows: Int, rowHeight: CGFloat) -> CGFloat {
        Self.groupedSectionHeaderHeight
            + CGFloat(rows) * rowHeight
            + CGFloat(max(0, rows - 1)) * Self.groupedRowSpacing
    }

    /// A 2-column grid's height: `ceil(itemCount / 2)` rows of the fixed tile height, joined
    /// by the same spacing the `LazyVGrid` itself draws between rows — the one place this
    /// arithmetic is stated, so it cannot drift from the grid it is measuring.
    private func tileGridHeight(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let rows = (itemCount + 1) / 2
        return Self.groupedSectionHeaderHeight
            + CGFloat(rows) * Self.groupedTileHeight
            + CGFloat(max(0, rows - 1)) * Self.groupedTileSpacing
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
    /// highlight was drawn from. The grouped layout has no highlighted row — Enter there
    /// mirrors `EmptyStateCard`'s own grouped state and runs the CTA.
    private func runSelected() {
        if showsGroupedLayout {
            if let terminalMatch {
                run(terminalMatch)
            }
            return
        }
        let agents = agentMatches
        let runOffer = runCommandOffer
        let leadingOffset = runOffer?.placement == .leading ? 1 : 0
        let total = agents.count + order.displayed.count + (runOffer == nil ? 0 : 1)
        guard total > 0 else { return }
        let selected = min(max(selection, 0), total - 1)
        if let runOffer {
            if runOffer.placement == .leading, selected == 0 {
                run(runOffer.match)
                return
            }
            if runOffer.placement == .trailing, selected == agents.count + order.displayed.count {
                run(runOffer.match)
                return
            }
        }
        let agentIndex = selected - leadingOffset
        if agents.indices.contains(agentIndex) {
            run(agents[agentIndex].suggestion)
            return
        }
        let displayed = order.displayed
        guard !displayed.isEmpty else { return }
        let commandIndex = agentIndex - agents.count
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

    /// The typed query, delivered to a fresh terminal through the exact placement/delivery
    /// path `EmptyStateCard`'s own run-command row and every detected agent already share
    /// (`TerminalCommandLaunch`) — no second "run this command line" mechanism.
    private func runTypedCommand() {
        guard !isRunning, let runCommand else { return }
        let commandLine = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandLine.isEmpty else { return }
        isRunning = true
        errorMessage = nil
        let outcome = runCommand(commandLine)
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
    ///
    /// The one exception is the synthetic run-command row, whose id never names a real
    /// intent — it routes to `runTypedCommand()` instead of `PaletteIntentInvoker`.
    private func run(_ match: CommandMatch) {
        guard match.command.id != Self.runCommandRowID else {
            runTypedCommand()
            return
        }
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        guard let invocation = PaletteIntentInvoker.prepare(
            commandID: match.command.id,
            host: host
        ) else {
            isRunning = false
            errorMessage = LauncherOutcome.unavailable.errorMessage
            return
        }
        Task { @MainActor in
            let outcome: LauncherOutcome
            if let send {
                outcome = await send(invocation)
            } else {
                outcome = LauncherOutcome(
                    await PaletteIntentInvoker.send(
                        invocation,
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
