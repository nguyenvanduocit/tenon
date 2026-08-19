// @domain: plugin-contributions, plugin-host
import Foundation
import TenonCore

enum ClaudeSessionsView {
    static let viewID = "sessions"
    static let title = "Agent Sessions"

    static func registration() -> BundledPluginContribution {
        BundledPluginContribution(
            viewRegistrations: [
                BundledPluginViewRegistration(
                    viewID: viewID,
                    title: title,
                    instanced: true
                ),
            ]
        )
    }

    static func contribution(
        panes: [ClaudeSessionsPaneState],
        favourites: [ClaudeFavouriteRecord]
    ) -> BundledPluginContribution {
        BundledPluginContribution(
            viewRegistrations: [
                BundledPluginViewRegistration(viewID: viewID, title: title, instanced: true),
            ],
            viewBodies: panes.sorted { $0.id < $1.id }.map { pane in
                BundledPluginViewBody(
                    viewID: viewID,
                    instanceID: pane.id,
                    body: body(for: pane, favourites: favourites),
                    header: header(for: pane)
                )
            }
        )
    }

    private static func body(
        for pane: ClaudeSessionsPaneState,
        favourites: [ClaudeFavouriteRecord]
    ) -> PluginViewNode {
        var children: [PluginViewNode] = []
        if let favouriteError = pane.favouriteError {
            children.append(
                .card(children: [.text(favouriteError, style: .body, weight: .regular, color: .red)])
            )
        }

        let marked = pane.sessions.filter {
            ClaudeSessionsScan.isFavourite(
                favourites,
                project: pane.project,
                provider: $0.provider,
                sessionID: $0.id
            )
        }
        let recent = pane.sessions.filter {
            !ClaudeSessionsScan.isFavourite(
                favourites,
                project: pane.project,
                provider: $0.provider,
                sessionID: $0.id
            )
        }

        if !marked.isEmpty {
            children.append(listCard(pane: pane, sessions: marked, heading: "Favourites", favourites: favourites))
            if !recent.isEmpty {
                children.append(listCard(pane: pane, sessions: recent, heading: "Recent", favourites: favourites))
            }
        } else if !recent.isEmpty {
            children.append(listCard(pane: pane, sessions: recent, heading: nil, favourites: favourites))
        } else if !isScanning(pane), !pane.notice.isEmpty {
            children.append(.card(children: [.text(pane.notice, style: .body, weight: .regular, color: .muted)]))
        } else if !isScanning(pane) {
            children.append(
                .card(children: [
                    .text("No agent sessions here yet", style: .body, weight: .semibold, color: .default),
                    .text(
                        "Run `claude`, `codex`, or `opencode` in this directory and it will show up.",
                        style: .caption,
                        weight: .regular,
                        color: .muted
                    ),
                ])
            )
        }

        return .vstack(spacing: 10, children: children)
    }

    private static func listCard(
        pane: ClaudeSessionsPaneState,
        sessions: [ClaudeSessionRecord],
        heading: String?,
        favourites: [ClaudeFavouriteRecord]
    ) -> PluginViewNode {
        var children: [PluginViewNode] = []
        if let heading {
            children.append(.text(heading, style: .caption, weight: .medium, color: .muted))
        }
        for (index, session) in sessions.enumerated() {
            if index > 0 || heading != nil { children.append(.divider) }
            children.append(sessionRow(pane: pane, session: session, favourites: favourites))
        }
        return .card(children: children)
    }

    private static func sessionRow(
        pane: ClaudeSessionsPaneState,
        session: ClaudeSessionRecord,
        favourites: [ClaudeFavouriteRecord]
    ) -> PluginViewNode {
        var facts: [String] = []
        if session.prompts > 0 { facts.append(plural(session.prompts, "prompt", "prompts")) }
        if session.replies > 0 { facts.append(plural(session.replies, "reply", "replies")) }
        if session.tokens > 0 { facts.append(compactCount(session.tokens) + " tokens") }
        if session.size > 0 { facts.append(size(session.size)) }

        var metadata: [PluginViewNode] = [
            .badge(providerBadge(session.provider).0, tint: providerBadge(session.provider).1),
        ]
        if !session.branch.isEmpty { metadata.append(.badge(session.branch, tint: .green)) }
        if !facts.isEmpty {
            metadata.append(.text(facts.joined(separator: " · "), style: .caption, weight: .regular, color: .muted))
        }
        metadata.append(.spacer)
        metadata.append(.button(label: "Details", action: .string("details:\(session.id)"), style: .plain))
        for agent in pane.agents {
            metadata.append(
                .button(
                    label: agent.id == session.provider.rawValue ? "Resume" : "In \(agent.label)",
                    action: .string("open:\(agent.id):\(session.id)"),
                    style: .plain
                )
            )
        }

        let marked = ClaudeSessionsScan.isFavourite(
            favourites,
            project: pane.project,
            provider: session.provider,
            sessionID: session.id
        )
        return .vstack(spacing: 4, children: [
            .hstack(spacing: 8, children: [
                .text(sessionTitle(session), style: .body, weight: .semibold, color: .default),
                .spacer,
                .button(
                    label: marked ? "★ Unfavourite" : "☆ Favourite",
                    action: .string("fav:\(session.provider.rawValue):\(session.id)"),
                    style: .plain
                ),
                .text(ago(session.mtime), style: .caption, weight: .regular, color: .muted),
            ]),
            .hstack(spacing: 8, children: metadata),
        ])
    }

    private static func header(for pane: ClaudeSessionsPaneState) -> PaneHeader {
        var leading: [PaneHeaderItem] = []
        if !pane.project.isEmpty {
            leading.append(
                .label(
                    id: "project",
                    text: pane.project,
                    weight: .regular,
                    color: .muted,
                    truncation: .head,
                    tooltip: nil
                )
            )
        }
        let claudeCount = pane.sessions.filter { $0.provider == .claude }.count
        let codexCount = pane.sessions.filter { $0.provider == .codex }.count
        let opencodeCount = pane.sessions.filter { $0.provider == .opencode }.count
        if claudeCount > 0 {
            leading.append(.badge(id: "claude", text: "\(claudeCount) Claude", tint: .amber, tooltip: nil))
        }
        if codexCount > 0 {
            leading.append(.badge(id: "codex", text: "\(codexCount) Codex", tint: .green, tooltip: nil))
        }
        if opencodeCount > 0 {
            leading.append(.badge(id: "opencode", text: "\(opencodeCount) opencode", tint: .default, tooltip: nil))
        }

        var trailing: [PaneHeaderItem] = []
        if isScanning(pane) { trailing.append(.spinner(id: "scanning")) }
        if !pane.agents.isEmpty {
            let entries = pane.agents.compactMap { agent in
                PaneHeaderMenuEntry(
                    value: "start:\(agent.id)",
                    label: "New \(agent.label) session"
                )
            }
            trailing.append(
                .menu(
                    id: "new",
                    systemName: "plus",
                    entries: entries,
                    isEnabled: !entries.isEmpty,
                    tooltip: "Start a session",
                    accessibilityID: nil
                )
            )
        }
        trailing.append(
            .iconButton(
                id: "refresh",
                systemName: "arrow.clockwise",
                tint: .default,
                isEnabled: true,
                tooltip: "Refresh",
                accessibilityID: nil
            )
        )
        return PaneHeader(leading: leading, trailing: trailing)
    }

    private static func isScanning(_ pane: ClaudeSessionsPaneState) -> Bool {
        pane.notice == "Loading…" || pane.notice == "Scanning…"
    }

    private static func sessionTitle(_ session: ClaudeSessionRecord) -> String {
        if !session.title.isEmpty { return session.title }
        switch session.provider {
        case .claude: return "Untitled Claude session"
        case .codex: return "Untitled Codex session"
        case .opencode: return "Untitled opencode session"
        }
    }

    private static func providerBadge(
        _ provider: ClaudeSessionRecord.Provider
    ) -> (String, ColorToken) {
        switch provider {
        case .claude: return ("Claude", .amber)
        case .codex: return ("Codex", .green)
        case .opencode: return ("opencode", .default)
        }
    }

    private static func ago(_ seconds: Int) -> String {
        let delta = max(0, Int(Date().timeIntervalSince1970) - seconds)
        if delta < 60 { return "just now" }
        if delta < 3_600 { return "\(delta / 60)m ago" }
        if delta < 86_400 { return "\(delta / 3_600)h ago" }
        if delta < 2_592_000 { return "\(delta / 86_400)d ago" }
        return "\(delta / 2_592_000)mo ago"
    }

    private static func size(_ bytes: Int64) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(Int((Double(bytes) / 1_024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    private static func compactCount(_ count: Int) -> String {
        if count < 1_000 { return String(count) }
        if count < 1_000_000 {
            return String(format: count < 10_000 ? "%.1fK" : "%.0fK", Double(count) / 1_000)
        }
        return String(format: count < 10_000_000 ? "%.1fM" : "%.0fM", Double(count) / 1_000_000)
    }
}
