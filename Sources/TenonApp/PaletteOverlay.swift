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
                // A provider result is appended, never ranked, so it has no score and no
                // matched indices to show: it draws the shared chrome directly with its
                // plain title.
                PaletteRowChrome(
                    icon: result.icon,
                    title: Text(result.title),
                    isSelected: isSelected,
                    subtitle: result.subtitle
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

/// The one row that *did* win a ranking: `PaletteRowChrome` with the title's matched
/// characters accented, plus the command's own subtitle and assigned-key accessory.
/// Shared by the palette overlay and the tab strip's `+` launcher so both read
/// identically; the launcher asks for the `compact` density because a popover anchored
/// to a 36-pt title bar reads as a menu, not as a full-window search surface.
///
/// Everything about how a row looks — metrics, hover, selected accent — lives in the
/// chrome, so a row that was never ranked reaches the same appearance without inventing
/// a ranking answer for itself.
struct PaletteRow: View {
    let match: CommandMatch
    let isSelected: Bool
    var density: PaletteRowChrome.Density = .regular

    var body: some View {
        PaletteRowChrome(
            icon: match.command.icon,
            title: title,
            isSelected: isSelected,
            density: density,
            subtitle: match.command.subtitle,
            trailing: match.command.key?.display
        )
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
