// @domain: command-surface
import SwiftUI
import TenonCore

/// The shared "nothing here yet" launcher card, reused verbatim by an empty tab
/// (the whole canvas has no slots) and an empty slot (one `.empty` pane in a
/// split). The only thing that differs between the two is what `onLaunch` does:
/// an empty tab adds a new slot, an empty slot fills itself in place. Everything
/// visible — icon badge, title, "Add terminal", the launcher grid, recently
/// opened, the shortcut cheatsheet — is identical.
struct EmptyStateCard: View {
    let title: String
    let subtitle: String
    let recents: [SlotContent]
    let agentSuggestions: [AgentLaunchSuggestion]
    /// Bind the ↩ hint to the return key. Only one card can own the default
    /// action at a time, so an empty tab always claims it and an empty slot
    /// claims it only while it is the active pane.
    let isDefaultAction: Bool
    let onLaunch: (SlotContent) -> Void
    let onLaunchAgent: (AgentLaunchSuggestion) -> Void

    /// Built-in views the launcher grid offers (terminal is the primary button above
    /// the grid). Browser opens the bundled browser plugin's pane.
    private var launchable: [(content: SlotContent, label: String)] {
        [
            (
                .pluginView(
                    pluginID: "dev.tenon.file-explorer",
                    viewID: "tree"
                ),
                "Files"
            ),
            (.changes, "Changes"),
            (.automation, "Automation"),
            (
                .pluginView(
                    pluginID: "dev.tenon.browser",
                    viewID: "browser"
                ),
                "Browser"
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 16) {
            iconBadge

            VStack(spacing: 6) {
                Text(title)
                    .font(TenonTheme.interfaceFont(size: 15, weight: .semibold))
                    .foregroundStyle(TenonTheme.text)
                Text(subtitle)
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
            }

            addTerminalButton

            if !agentSuggestions.isEmpty {
                agentLauncher
            }

            launcher

            if !recents.isEmpty {
                recentlyOpened
            }

            cheatsheet
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
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
    }

    @ViewBuilder
    private var addTerminalButton: some View {
        let button = EmptyStateActionButton(
            title: "Add terminal",
            shortcut: "\u{21A9}",
            kind: .primary,
            action: { onLaunch(.terminal) }
        )
        .accessibilityIdentifier("empty-state-add-terminal")

        if isDefaultAction {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private var iconBadge: some View {
        Image(systemName: "terminal")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(TenonTheme.amber)
            .frame(width: 58, height: 58)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(TenonTheme.amber.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(TenonTheme.amber.opacity(0.30), lineWidth: 1)
            }
            .shadow(color: TenonTheme.amber.opacity(0.35), radius: 14)
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
                ForEach(Array(launchable.enumerated()), id: \.offset) { _, item in
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
                ForEach(Array(recents.prefix(4).enumerated()), id: \.offset) { _, content in
                    RecentRow(
                        glyph: SlotPresentation.glyph(for: content),
                        label: Self.label(for: content),
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

    private static func label(for content: SlotContent) -> String {
        switch content {
        case .terminal: return "Terminal"
        case .changes: return "Changes"
        case .automation: return "Automation"
        case .file(let path): return (path as NSString).lastPathComponent
        case .pluginView(_, let viewID): return viewID
        case .diff(let request): return request.title
        case .empty: return "Empty"
        }
    }
}

/// A detected agent stays visually quieter than the primary Terminal action. The learned
/// option is always visible when it changes authority, so convenience never hides bypass.
private struct AgentLaunchCardRow: View {
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
private struct SectionLabel: View {
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

/// One entry in the "recently opened" list: reopens that view on click.
private struct RecentRow: View {
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

/// A full-width action with its keyboard hint aligned right. `primary` is the
/// filled amber call to action; `secondary` is a quiet outlined button that
/// lights up on hover.
private struct EmptyStateActionButton: View {
    enum Kind { case primary, secondary }

    let title: String
    let shortcut: String
    let kind: Kind
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
                    .foregroundStyle(foreground.opacity(0.75))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return TenonTheme.ink
        case .secondary: return hovering ? TenonTheme.text : TenonTheme.muted
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return hovering ? TenonTheme.amber : TenonTheme.amber.opacity(0.92)
        case .secondary: return hovering ? TenonTheme.chromeRaised : .clear
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return TenonTheme.line
        }
    }
}
