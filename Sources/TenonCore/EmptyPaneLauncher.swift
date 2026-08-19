// @domain: command-surface
import Foundation

/// Whether a typed query should also be offered as a shell command to run, and where that
/// offer ranks against the rows it matched.
///
/// An empty pane is the one place in the product where "I want to run something" and "I want
/// to open something" arrive through the same keystrokes, so the surface cannot ask which one
/// was meant — it has to read the query. The rule is deliberately shallow and stated in one
/// place: a query carrying inner whitespace or a shell-shaped character is a command line and
/// leads; a single plain word is a name and follows the things actually named that.
///
/// `.` and `-` are *not* shell-shaped here. `judge.go` and `agent-lens` are the ordinary
/// spelling of a recently opened file and a view, and putting `Run "judge.go"` above the file
/// itself would break the commonest pick in the list to serve the rarer one.
public enum RunCommandOffer {
    public enum Placement: Equatable, Sendable {
        /// Nothing typed: the card draws its grouped layout and offers no command.
        case none
        /// The query reads as a command line; it is offered above the rows it matched.
        case leading
        /// The query reads as a name; the rows that carry that name come first.
        case trailing
    }

    /// Characters that only appear in a query because someone is writing a command line:
    /// paths, home, variables, pipes, redirection, background, separators, globs.
    private static let shellShaped: Set<Character> = ["/", "~", "$", "|", ">", "<", "&", ";", "*"]

    public static func placement(for query: String) -> Placement {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if trimmed.contains(where: \.isWhitespace) { return .leading }
        if trimmed.contains(where: { shellShaped.contains($0) }) { return .leading }
        return .trailing
    }
}

/// One row an empty pane's launcher draws for a typed query.
///
/// `kind` is what the surface does with a pick, and nothing else in the row is allowed to
/// decide that: `item` names an offering the surface handed in, `runCommand` carries the
/// exact command line to deliver to a fresh terminal.
public struct EmptyPaneLauncherRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case item(String)
        case runCommand(String)
    }

    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let glyph: String
    /// Indices in `title` the query matched, for emboldening. Empty when the row surfaced
    /// through a keyword rather than its title, and for the run offer, which matched nothing.
    public let titleMatch: [Int]

    public var id: String {
        switch kind {
        case .item(let itemID): "item:\(itemID)"
        case .runCommand: "run"
        }
    }

    public init(
        kind: Kind,
        title: String,
        subtitle: String?,
        glyph: String,
        titleMatch: [Int] = []
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        self.titleMatch = titleMatch
    }
}

/// The ranked list an empty tab or pane draws once someone types.
///
/// With nothing typed this returns nothing at all, because the card's own grouped layout —
/// the primary terminal action, the detected agents, the views, the recents — is what an
/// empty query should read as. A query replaces that grouping with one relevance order, which
/// is the same trade `LauncherSections` makes for the popover launcher.
///
/// Ranking is `CommandIndex.rank`, the palette's matcher, reached through a `Command` per
/// offering. There is no second scorer here: a row that ranks differently in this card than
/// in the palette would be a bug with two places to fix.
///
/// What the card does not bring is the palette's frecency store, so an exact tie in match
/// score is broken by name. The offerings are a handful of fixed verbs and the pane's own
/// recents — a set small enough that a stable, readable order beats a learned one.
public enum EmptyPaneLauncher {
    public static func rows(query: String, items: [Command]) -> [EmptyPaneLauncherRow] {
        let placement = RunCommandOffer.placement(for: query)
        guard placement != .none else { return [] }
        let command = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let matched = CommandIndex(items)
            .rank(query: command, now: Date())
            .map { match in
                EmptyPaneLauncherRow(
                    kind: .item(match.command.id),
                    title: match.command.title,
                    subtitle: match.command.subtitle,
                    glyph: match.command.icon ?? "·",
                    titleMatch: match.titleMatch
                )
            }

        // The row shows exactly the string that will be delivered to the shell, so what is
        // read before pressing Enter is what runs.
        let offer = EmptyPaneLauncherRow(
            kind: .runCommand(command),
            title: command,
            subtitle: "Run in a new terminal",
            glyph: ">_"
        )
        return placement == .leading ? [offer] + matched : matched + [offer]
    }
}
