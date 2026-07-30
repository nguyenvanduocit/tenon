import Foundation

/// One palette presentation projected from a plugin-owned intent contract.
///
/// `id` is the canonical intent ID. This value carries ranking/rendering metadata only;
/// invocation still enters the intent dispatcher through the palette principal.
public struct Command: Sendable, Equatable, Identifiable {
    public let id: String          // globally unique, e.g. "core.split-right", "git.commit"
    public let title: String       // "Split Right"
    public let subtitle: String?   // context/domain, rendered dimmed
    public let category: String?   // "Pane", "Git" → section heading
    public let icon: String?       // SF Symbol name or emoji
    public let keywords: [String]  // search aliases ("prefs" finds "Settings")
    public let key: KeyChord?      // assigned binding; nil commands remain palette-only
    public let when: String?       // visibility predicate; nil = always visible
    public let isLauncher: Bool    // a creation verb → offered by the tab strip's `+`

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        category: String? = nil,
        icon: String? = nil,
        keywords: [String] = [],
        key: KeyChord? = nil,
        when: String? = nil,
        isLauncher: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.icon = icon
        self.keywords = keywords
        self.key = key
        self.when = when
        self.isLauncher = isLauncher
    }
}

/// One ranked palette row: the command, its score, and which title characters matched
/// (empty when it surfaced via a keyword or via frecency on an empty query).
public struct CommandMatch: Sendable, Equatable, Identifiable {
    public let command: Command
    public let score: Double
    public let titleMatch: [Int]
    public var id: String { command.id }

    public init(command: Command, score: Double, titleMatch: [Int]) {
        self.command = command
        self.score = score
        self.titleMatch = titleMatch
    }
}

/// The tiny visibility language on a `Command.when`: context keys joined by `&&`/`||`
/// with `!` negation, no parentheses. `nil`/empty is always visible. This is the
/// phase-1 subset of VS Code's when-clause grammar — enough for `terminalFocus`,
/// `!hasSelection`, `a && b` — and it stays pure so visibility is unit-tested.
public enum WhenClause {
    public static func evaluate(_ clause: String?, context: Set<String>) -> Bool {
        guard let clause, !clause.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        // OR binds loosest, then AND, then the atoms.
        return clause.components(separatedBy: "||").contains { orTerm in
            orTerm.components(separatedBy: "&&").allSatisfy { atom($0, context) }
        }
    }

    private static func atom(_ raw: String, _ context: Set<String>) -> Bool {
        let term = raw.trimmingCharacters(in: .whitespaces)
        if term.hasPrefix("!") {
            let key = String(term.dropFirst()).trimmingCharacters(in: .whitespaces)
            return !context.contains(key)
        }
        return context.contains(term)
    }
}

/// The pure palette index the shell projects. Given a query it returns ranked,
/// `when`-filtered intent presentations; the shell never decides ordering itself
/// (`docs/tdd.md`: the shell is a projection with no rules of its own).
public struct CommandIndex: Sendable, Equatable {
    public private(set) var commands: [Command]

    public init(_ commands: [Command] = []) {
        self.commands = commands
    }

    public mutating func setCommands(_ commands: [Command]) {
        self.commands = commands
    }

    /// The subset a launcher surface projects: the creation verbs plugins declared with
    /// `palette.launcher`. Ranking is untouched — the `+` menu is the palette with a
    /// narrower set, not a second ordering.
    public var launcherOnly: CommandIndex {
        CommandIndex(commands.filter(\.isLauncher))
    }

    /// Rank commands for `query`. Empty query → visible commands by frecency then
    /// title (the recents empty-state). Typed query → title fuzzy-matches (with
    /// highlight) or keyword matches (no highlight), ordered by match score, then
    /// frecency, then title. `context` supplies the active `when` keys.
    public func rank(
        query: String,
        frecency: Frecency = Frecency(),
        now: Date,
        context: Set<String> = []
    ) -> [CommandMatch] {
        let visible = commands.filter { WhenClause.evaluate($0.when, context: context) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return visible
                .map { CommandMatch(command: $0, score: frecency.score($0.id, now: now), titleMatch: []) }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return titleBefore(lhs.command, rhs.command)
                }
        }

        var matches: [CommandMatch] = []
        for command in visible {
            if let hit = Fuzzy.match(trimmed, in: command.title) {
                matches.append(CommandMatch(command: command, score: Double(hit.score), titleMatch: hit.matchedIndices))
            } else if let keywordHit = command.keywords
                .compactMap({ Fuzzy.match(trimmed, in: $0) })
                .max(by: { $0.score < $1.score }) {
                matches.append(CommandMatch(command: command, score: Double(keywordHit.score), titleMatch: []))
            }
        }

        return matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lf = frecency.score(lhs.command.id, now: now)
            let rf = frecency.score(rhs.command.id, now: now)
            if lf != rf { return lf > rf }
            return titleBefore(lhs.command, rhs.command)
        }
    }

    private func titleBefore(_ lhs: Command, _ rhs: Command) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
