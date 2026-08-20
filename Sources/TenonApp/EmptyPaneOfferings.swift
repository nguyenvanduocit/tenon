// @domain: command-surface
import Foundation
import TenonCore

/// Everything an empty tab or pane can offer, in both directions: as the ranker's vocabulary,
/// and as the map from a picked row back to the thing it does.
///
/// Both directions are written here, next to each other, because they are one agreement. A
/// row whose id no longer resolves is a row that draws, highlights, accepts Enter, and does
/// nothing — the exact failure that is invisible in a passing render and obvious to whoever
/// pressed the key. `EmptyPaneOfferingsTests` walks every id this produces back through
/// `pick` for that reason.
struct EmptyPaneOfferings {
    /// What picking a row means. The card turns this into the mutation its mount performs:
    /// an empty tab adds a slot, an empty pane fills itself in place.
    enum Pick: Equatable {
        case terminal
        case agent(AgentLaunchSuggestion)
        case content(SlotContent)
    }

    /// Views the card offers besides the terminal. Browser opens the bundled browser plugin's
    /// pane; Files opens the file explorer's tree.
    struct View: Equatable {
        let content: SlotContent
        let label: String
        let keywords: [String]
    }

    static let terminalID = "add-terminal"
    private static let agentPrefix = "agent."
    private static let viewPrefix = "view."
    private static let recentPrefix = "recent."

    // Kept in sync by hand with every plugin manifest's `fillsPane` declaration —
    // `EmptyPaneSearchTests.testOpenAViewOffersEveryFillsPaneCommandInTheRealPluginInventory`
    // fails the day a manifest adds or drops one without a matching edit here. The real fix
    // is T-149's dynamic `SlotContent` mapping (`command-surfaces.prd.md` §3); this list is
    // the deliberately-named "second command registry" until then.
    static let views: [View] = [
        View(
            content: .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"),
            label: "Files",
            keywords: ["explorer", "tree", "finder"]
        ),
        View(content: .changes, label: "Changes", keywords: ["git", "diff", "status"]),
        View(content: .automation, label: "Automation", keywords: ["schedule", "cron", "job"]),
        View(
            content: .pluginView(pluginID: "dev.tenon.browser", viewID: "browser"),
            label: "Browser",
            keywords: ["web", "url", "page"]
        ),
        View(
            content: .pluginView(pluginID: "dev.tenon.kanban", viewID: "board"),
            label: "Kanban",
            keywords: ["kanban", "board", "tasks", "todo"]
        ),
        View(
            content: .pluginView(pluginID: "dev.tenon.claude-sessions", viewID: "sessions"),
            label: "Agent Sessions",
            keywords: ["agent", "claude", "codex", "session", "resume", "history", "transcript"]
        ),
    ]

    let agents: [AgentLaunchSuggestion]
    /// Already capped to what the card draws, so the ids the ranker sees are the ids the
    /// grouped layout would have drawn.
    let recents: [SlotContent]

    init(agents: [AgentLaunchSuggestion], recents: [SlotContent], recentLimit: Int = 4) {
        self.agents = agents
        self.recents = Array(recents.prefix(recentLimit))
    }

    var commands: [Command] {
        var commands = [
            Command(
                id: Self.terminalID,
                title: "Add terminal",
                icon: SlotPresentation.glyph(for: .terminal),
                keywords: ["shell", "console", "terminal", "ghostty"]
            )
        ]
        for agent in agents {
            commands.append(
                Command(
                    id: Self.agentPrefix + agent.agent.rawValue,
                    title: agent.agent.label,
                    subtitle: agent.habitDescription,
                    icon: SlotPresentation.glyph(for: .terminal),
                    keywords: ["agent", "ai"]
                )
            )
        }
        for (index, view) in Self.views.enumerated() {
            commands.append(
                Command(
                    id: "\(Self.viewPrefix)\(index)",
                    title: view.label,
                    icon: SlotPresentation.glyph(for: view.content),
                    keywords: view.keywords
                )
            )
        }
        for (index, content) in recents.enumerated() {
            commands.append(
                Command(
                    id: "\(Self.recentPrefix)\(index)",
                    title: Self.label(for: content),
                    subtitle: "Recently opened",
                    icon: SlotPresentation.glyph(for: content)
                )
            )
        }
        return commands
    }

    func pick(itemID: String) -> Pick? {
        if itemID == Self.terminalID { return .terminal }
        if itemID.hasPrefix(Self.agentPrefix) {
            let raw = String(itemID.dropFirst(Self.agentPrefix.count))
            return agents.first { $0.agent.rawValue == raw }.map(Pick.agent)
        }
        if itemID.hasPrefix(Self.viewPrefix),
           let index = Int(itemID.dropFirst(Self.viewPrefix.count)),
           Self.views.indices.contains(index) {
            return .content(Self.views[index].content)
        }
        if itemID.hasPrefix(Self.recentPrefix),
           let index = Int(itemID.dropFirst(Self.recentPrefix.count)),
           recents.indices.contains(index) {
            return .content(recents[index])
        }
        return nil
    }

    static func label(for content: SlotContent) -> String {
        switch content {
        case .terminal: return "Terminal"
        case .changes: return "Changes"
        case .automation: return "Automation"
        case .file(let path): return (path as NSString).lastPathComponent
        case .pluginView(_, let viewID): return viewID
        case .diff(let request): return request.title
        case .agentSession(let ref): return ref.displayName
        case .empty: return "Empty"
        }
    }
}
