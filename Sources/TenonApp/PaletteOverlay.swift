// @domain: command-surface
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The command palette overlay (⌘⇧P). Renders nothing until presented. It ranks the
/// host's aggregated `CommandIndex` live against the query, highlights the matched
/// title characters, and runs the selected command on Enter. The shell owns no
/// ordering of its own — it projects `CommandIndex` (`docs/tdd.md`).
struct PaletteOverlay: View {
    var host: PluginHost
    var intentRuntime: AppIntentRuntime
    @Bindable var palette: CommandPaletteState
    @FocusState private var searchFocused: Bool

    private var results: [CommandMatch] {
        host.commandIndex.rank(query: palette.query, frecency: palette.frecency, now: Date())
    }

    /// The one flattened order the overlay renders: the static ranked rows first —
    /// computed without ever calling a plugin — then each provider section that has
    /// results for the current query revision or an answer still in flight.
    private var display: PaletteDisplay {
        PaletteDisplay(matches: results, sections: host.paletteSections)
    }

    var body: some View {
        if palette.isPresented {
            content(display)
        }
    }

    private func content(_ display: PaletteDisplay) -> some View {
        let selected = display.selectableCount == 0
            ? 0
            : min(palette.selection, display.selectableCount - 1)
        return GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { palette.dismiss() }

                VStack(spacing: 0) {
                    searchField
                    Rectangle().fill(TenonTheme.line).frame(height: 1)
                    if let errorMessage = palette.errorMessage {
                        Text(errorMessage)
                            .font(TenonTheme.utilityFont(size: 10))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    resultsList(
                        display,
                        selected: selected,
                        ceiling: listCeiling(inWindowOfHeight: proxy.size.height)
                    )
                }
                .frame(width: 640)
                .background(TenonTheme.chromeRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(TenonTheme.line, lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if palette.actionsPresented {
                        actionsSubmenu(display, selected: selected)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                .padding(.top, 96)

                // Escape closes the palette even while the search field holds focus —
                // closing the ⌘K submenu first when it is open.
                Button(
                    "",
                    action: {
                        if palette.actionsPresented {
                            palette.actionsPresented = false
                        } else {
                            palette.dismiss()
                        }
                    }
                )
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)

                // ⌘K opens the actions submenu when the selected row declares any.
                // Focused-view-local control: it toggles overlay state and dispatches
                // nothing.
                Button("", action: { toggleActions(display, selected: selected) })
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            searchFocused = true
            host.setPaletteQuery(palette.query)
        }
        .onDisappear { host.invalidatePaletteQuery() }
        // Arrows bubble up from the focused single-line field; Enter is the field's own
        // submit (avoids a double-run). Escape is the hidden `.cancelAction` button
        // below — a focused TextField swallows the raw Escape keyDown, so
        // `.onKeyPress(.escape)` never fires, but a `.cancelAction` key binding
        // still does (the same command mechanism as the ⌘⇧P menu item that opens the
        // palette over the terminal). Verified by PaletteFlowUITests.
        .onKeyPress(.downArrow) { move(1, in: display); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: display); return .handled }
    }

    /// The ⌘K submenu over the selected dynamic result: each entry is a separate
    /// plugin-owned intent riding the result, never a closure.
    private func actionsSubmenu(
        _ display: PaletteDisplay,
        selected: Int
    ) -> some View {
        let actions = display.actions(forSelection: selected)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button {
                    palette.actionSelection = index
                    runSelected()
                } label: {
                    Text(action.title)
                        .font(TenonTheme.interfaceFont(size: 12))
                        .foregroundStyle(TenonTheme.text)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    index == palette.actionSelection
                                        ? TenonTheme.amber.opacity(0.16)
                                        : .clear
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        index == palette.actionSelection ? .isSelected : []
                    )
                    .accessibilityIdentifier("tenon.palette.action.\(index)")
            }
        }
        .padding(6)
        .frame(width: 220)
        .background(TenonTheme.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(TenonTheme.line, lineWidth: 1)
        )
        .padding(10)
    }

    private func toggleActions(_ display: PaletteDisplay, selected: Int) {
        if palette.actionsPresented {
            palette.actionsPresented = false
            return
        }
        guard !display.actions(forSelection: selected).isEmpty else { return }
        palette.actionSelection = 0
        palette.actionsPresented = true
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TenonTheme.muted)
            TextField("Run a command…", text: $palette.query)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 16))
                .foregroundStyle(TenonTheme.text)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .disabled(palette.isRunning)
                .onChange(of: palette.query) { _, newValue in
                    palette.selection = 0
                    palette.errorMessage = nil
                    palette.actionsPresented = false
                    palette.actionSelection = 0
                    // One keystroke = one query revision. Synchronous host mutation:
                    // providers hear the fact, the ranked list above never waits.
                    host.setPaletteQuery(newValue)
                }
                .accessibilityIdentifier("tenon.palette.search")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// The list grows into whatever the window leaves below the palette's inset, so a
    /// tall window shows more commands instead of scrolling inside an arbitrary box.
    private func listCeiling(inWindowOfHeight height: CGFloat) -> CGFloat {
        // Top inset + the search field and its rule + a margin under the panel.
        let chrome: CGFloat = 96 + 52 + 1 + 48
        return max(200, height - chrome)
    }

    @ViewBuilder
    private func resultsList(
        _ display: PaletteDisplay,
        selected: Int,
        ceiling: CGFloat
    ) -> some View {
        if display.rows.isEmpty {
            Text(palette.query.isEmpty
                 ? "No commands yet — plugins contribute them here."
                 : "No matching commands")
                .font(TenonTheme.interfaceFont(size: 13))
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 56)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            Array(display.rows.enumerated()),
                            id: \.element.id
                        ) { index, row in
                            displayRow(
                                row,
                                isSelected: display.selectableIndices[
                                    safeOrdinal: selected
                                ] == index
                            )
                            .id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .tenonScrollbarStyle()
                .frame(maxHeight: ceiling)
                // Keep the keyboard-selected row visible as the user arrows past the fold.
                .onChange(of: palette.selection) { _, ordinal in
                    guard let rowIndex = display.selectableIndices[
                        safeOrdinal: ordinal
                    ] else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(display.rows[rowIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func displayRow(
        _ row: PaletteDisplayRow,
        isSelected: Bool
    ) -> some View {
        switch row {
        case let .command(match):
            Button { run(match) } label: {
                PaletteRow(match: match, isSelected: isSelected)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("tenon.palette.row.\(match.command.id)")
        case let .result(pluginID, result):
            Button {
                run(intentID: result.intentID, input: result.input, pluginID: pluginID)
            } label: {
                PaletteRow(
                    match: CommandMatch(
                        command: Command(
                            id: result.id,
                            title: result.title,
                            subtitle: result.subtitle,
                            icon: result.icon
                        ),
                        score: 0,
                        titleMatch: []
                    ),
                    isSelected: isSelected
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(
                "tenon.palette.result.\(pluginID.rawValue).\(result.id)"
            )
        case let .sectionHeader(sectionID, title):
            Text(title.uppercased())
                .font(TenonTheme.utilityFont(size: 10))
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .accessibilityIdentifier("tenon.palette.section.\(sectionID)")
        case let .pending(sectionID, title):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching \(title)…")
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .frame(height: 30)
            .accessibilityIdentifier("tenon.palette.pending.\(sectionID)")
        }
    }

    private func move(_ delta: Int, in display: PaletteDisplay) {
        if palette.actionsPresented {
            let count = display.actions(forSelection: palette.selection).count
            guard count > 0 else { return }
            palette.actionSelection =
                min(max(palette.actionSelection + delta, 0), count - 1)
            return
        }
        guard display.selectableCount > 0 else { return }
        palette.selection =
            min(max(palette.selection + delta, 0), display.selectableCount - 1)
    }

    private func runSelected() {
        let display = display
        guard display.selectableCount > 0 else { return }
        let selected = min(max(palette.selection, 0), display.selectableCount - 1)
        if palette.actionsPresented {
            let actions = display.actions(forSelection: selected)
            guard actions.indices.contains(palette.actionSelection),
                  case let .result(pluginID, _)? =
                      display.selectableRow(at: selected)
            else {
                palette.actionsPresented = false
                return
            }
            let action = actions[palette.actionSelection]
            palette.actionsPresented = false
            run(intentID: action.intentID, input: action.input, pluginID: pluginID)
            return
        }
        switch display.selectableRow(at: selected) {
        case let .command(match)?:
            run(match)
        case let .result(pluginID, result)?:
            run(intentID: result.intentID, input: result.input, pluginID: pluginID)
        default:
            break
        }
    }

    /// Map the ranked presentation back to its plugin-owned intent contract, record the
    /// pick for frecency, and invoke it through the palette principal. An intent unloaded
    /// mid-session produces a visible unavailable error.
    private func run(_ match: CommandMatch) {
        guard !palette.isRunning else { return }

        palette.isRunning = true
        palette.errorMessage = nil
        Task { @MainActor in
            guard let result = await PaletteIntentInvoker.send(
                commandID: match.command.id,
                host: host,
                runtime: intentRuntime
            ) else {
                palette.isRunning = false
                palette.errorMessage = "Intent is no longer available."
                return
            }
            switch result {
            case .success:
                palette.record(match.command.id)
                palette.dismiss()
            case .failure(let failure):
                palette.isRunning = false
                palette.errorMessage =
                    "\(failure.error.code.rawValue)"
            }
        }
    }

    /// Run a dynamic result or one of its ⌘K actions: the same shared invoker and the
    /// same production dispatcher as a static row, with the result's bounded input.
    /// Dynamic rows are ephemeral, so they leave no frecency record.
    private func run(intentID: IntentID, input: IntentValue, pluginID: PluginID) {
        guard !palette.isRunning else { return }

        palette.isRunning = true
        palette.errorMessage = nil
        Task { @MainActor in
            guard let result = await PaletteIntentInvoker.send(
                intentID: intentID,
                input: input,
                pluginID: pluginID,
                host: host,
                runtime: intentRuntime
            ) else {
                palette.isRunning = false
                palette.errorMessage = "Intent is no longer available."
                return
            }
            switch result {
            case .success:
                palette.dismiss()
            case .failure(let failure):
                palette.isRunning = false
                palette.errorMessage = "\(failure.error.code.rawValue)"
            }
        }
    }
}

private extension [Int] {
    /// The row index behind the Nth selectable ordinal, or nil past the end — the
    /// palette clamps selection to the live selectable count, but the display can
    /// shrink between a keystroke and the next render.
    subscript(safeOrdinal index: Int) -> Int? {
        indices.contains(index) ? self[index] : nil
    }
}

/// One command row: leading icon, title with matched characters accented, and the
/// dimmed subtitle / assigned-key accessory on the trailing edge. Shared by the
/// palette overlay and the tab strip's `+` launcher so both read identically; the
/// launcher asks for the `compact` density because a popover anchored to a 36-pt
/// title bar reads as a menu, not as a full-window search surface.
struct PaletteRow: View {
    /// Row metrics. The overlay is a destination the user summons and looks at; the
    /// launcher is a menu they flick through. Same anatomy, two scales.
    enum Density {
        case regular
        case compact

        var height: CGFloat { self == .compact ? 28 : 40 }
        var horizontalPadding: CGFloat { self == .compact ? 12 : 14 }
        /// Inset of the highlight from the row edge, so the accent reads as a pill
        /// inside the surface instead of a full-bleed band.
        var railInset: CGFloat { self == .compact ? 6 : 8 }
        var cornerRadius: CGFloat { self == .compact ? 6 : 8 }
        var spacing: CGFloat { self == .compact ? 8 : 10 }
        var iconWidth: CGFloat { self == .compact ? 15 : 18 }
        var iconSize: CGFloat { self == .compact ? 11 : 13 }
        var titleSize: CGFloat { self == .compact ? 12 : 14 }
        var accessorySize: CGFloat { self == .compact ? 11 : 12 }
    }

    let match: CommandMatch
    let isSelected: Bool
    var density: Density = .regular

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: density.spacing) {
            Group {
                if let icon = match.command.icon {
                    Image(systemName: icon)
                } else {
                    Image(systemName: "command")
                }
            }
            .font(.system(size: density.iconSize))
            .frame(width: density.iconWidth)
            .foregroundStyle(isSelected ? TenonTheme.amber : TenonTheme.muted)

            title
                .font(TenonTheme.interfaceFont(size: density.titleSize))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            if let subtitle = match.command.subtitle {
                Text(subtitle)
                    .font(TenonTheme.interfaceFont(size: density.accessorySize))
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let key = match.command.key {
                Text(key.display)
                    .font(TenonTheme.utilityFont(size: density.accessorySize))
                    .foregroundStyle(TenonTheme.muted)
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .frame(height: density.height)
        .background {
            RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous)
                .fill(highlight)
                .padding(.horizontal, density.railInset)
        }
        // Keyboard selection and pointer hover are separate signals: arrowing never
        // moves under the mouse, so the hovered row gets its own quieter wash and the
        // accent stays with whatever Enter would run.
        .onHover { isHovered = $0 }
    }

    private var highlight: Color {
        if isSelected {
            return TenonTheme.amber.opacity(isHovered ? 0.24 : 0.16)
        }
        return isHovered ? TenonTheme.text.opacity(0.07) : .clear
    }

    /// Concatenate one `Text` per character so matched indices render accented+bold —
    /// the "why did this match" affordance every good palette shows.
    private var title: Text {
        let characters = Array(match.command.title)
        let matched = Set(match.titleMatch)
        var line = Text("")
        for (index, character) in characters.enumerated() {
            let isHit = matched.contains(index)
            line = line + Text(String(character))
                .foregroundColor(isHit ? TenonTheme.amber : TenonTheme.text)
                .fontWeight(isHit ? .semibold : .regular)
        }
        return line
    }
}
