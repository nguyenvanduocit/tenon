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

    var body: some View {
        if palette.isPresented {
            content(results)
        }
    }

    private func content(_ matches: [CommandMatch]) -> some View {
        let selected = matches.isEmpty ? 0 : min(palette.selection, matches.count - 1)
        return ZStack(alignment: .top) {
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
                resultsList(matches, selected: selected)
            }
            .frame(width: 640)
            .background(TenonTheme.chromeRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(TenonTheme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.top, 96)

            // Escape closes the palette even while the search field holds focus.
            Button("", action: { palette.dismiss() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear { searchFocused = true }
        // Arrows bubble up from the focused single-line field; Enter is the field's own
        // submit (avoids a double-run). Escape is the hidden `.cancelAction` button
        // below — a focused TextField swallows the raw Escape keyDown, so
        // `.onKeyPress(.escape)` never fires, but a `.cancelAction` key binding
        // still does (the same command mechanism as the ⌘⇧P menu item that opens the
        // palette over the terminal). Verified by PaletteFlowUITests.
        .onKeyPress(.downArrow) { move(1, in: matches); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: matches); return .handled }
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
                .onChange(of: palette.query) { _, _ in
                    palette.selection = 0
                    palette.errorMessage = nil
                }
                .accessibilityIdentifier("tenon.palette.search")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    private func resultsList(_ matches: [CommandMatch], selected: Int) -> some View {
        if matches.isEmpty {
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
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            PaletteRow(match: match, isSelected: index == selected)
                                .id(match.id)
                                .contentShape(Rectangle())
                                .onTapGesture { run(match) }
                                .accessibilityIdentifier("tenon.palette.row.\(match.command.id)")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
                // Keep the keyboard-selected row visible as the user arrows past the fold.
                .onChange(of: palette.selection) { _, index in
                    guard matches.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(matches[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func move(_ delta: Int, in matches: [CommandMatch]) {
        guard !matches.isEmpty else { return }
        palette.selection = min(max(palette.selection + delta, 0), matches.count - 1)
    }

    private func runSelected() {
        let matches = results
        guard !matches.isEmpty else { return }
        run(matches[min(max(palette.selection, 0), matches.count - 1)])
    }

    /// Map the ranked presentation back to its plugin-owned intent contract, record the
    /// pick for frecency, and invoke it through the palette principal. An intent unloaded
    /// mid-session produces a visible unavailable error.
    private func run(_ match: CommandMatch) {
        guard !palette.isRunning,
              let presentation = host.intentPresentations.first(
                where: { $0.intentID.rawValue == match.command.id }
              )
        else {
            palette.errorMessage = "Intent is no longer available."
            return
        }

        palette.isRunning = true
        palette.errorMessage = nil
        let target = KeyBindingTarget(
            pluginID: presentation.pluginID,
            intentID: presentation.intentID
        )
        Task { @MainActor in
            guard let result = await PaletteIntentInvoker.send(
                target: target,
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
}

/// One palette row: leading icon, title with matched characters accented, and the
/// dimmed subtitle / assigned-key accessory on the trailing edge.
private struct PaletteRow: View {
    let match: CommandMatch
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = match.command.icon {
                    Image(systemName: icon)
                } else {
                    Image(systemName: "command")
                }
            }
            .frame(width: 18)
            .foregroundStyle(isSelected ? TenonTheme.amber : TenonTheme.muted)

            title
                .font(TenonTheme.interfaceFont(size: 14))
                .lineLimit(1)

            Spacer(minLength: 12)

            if let subtitle = match.command.subtitle {
                Text(subtitle)
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
            }
            if let key = match.command.key {
                Text(key.display)
                    .font(TenonTheme.utilityFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(isSelected ? TenonTheme.amber.opacity(0.16) : Color.clear)
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
