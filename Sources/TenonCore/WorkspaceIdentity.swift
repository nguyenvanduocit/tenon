// @domain: workspace-model
import Foundation

/// How a workspace is named, marked, and tinted wherever the host represents it.
///
/// Identity is deliberately *not* identity: a workspace is a `UUID`, and everything here is
/// presentation. Renaming, re-marking and re-tinting a workspace leave its id, root
/// directory, tabs, panes and plugin scope exactly where they were, which is why two
/// workspaces may carry the same display name without anything downstream becoming
/// ambiguous.
///
/// The name is stored on `Workspace` because every surface already reads `workspace.name`.
/// What lives here is the pair of rules that were previously written out at each call site:
/// what Tenon calls a workspace when nobody has named it, and what a typed name becomes
/// before it is stored.
public enum WorkspaceName {
    /// A row, a menu item, and a scope label all render a name on one line. 60 characters is
    /// past the point where any of them still shows the end of it, so it is where a typed
    /// name stops rather than where a layout starts lying.
    public static let maximumLength = 60

    /// What Tenon calls a workspace rooted at `path` when nobody has named it — the name a
    /// new workspace opens with, and the one `resetIdentity` restores.
    public static func derived(for path: URL) -> String {
        sanitized(path.lastPathComponent) ?? path.path
    }

    /// A typed name as it will be stored, or nil when it carries no name at all.
    ///
    /// Surrounding and interior whitespace collapse to single spaces — a name pasted out of
    /// a terminal arrives with newlines and runs of padding, and a one-line row would render
    /// those as a ragged gap it cannot explain. Nil is the reset signal: clearing the field
    /// asks for the derived name back, so "no name" never has to be spelled two ways.
    public static func sanitized(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}

/// The curated glyph a workspace is marked with.
///
/// A closed vocabulary rather than a free SF Symbol name: the host draws these at 11 points
/// inside a 29-point frame, and an arbitrary symbol name is both undrawable when misspelled
/// and unannounceable to VoiceOver. Each case carries its own spoken label, so the mark is
/// never carried by shape alone.
public enum WorkspaceSymbol: String, CaseIterable, Codable, Sendable {
    case folder
    case terminal
    case hammer
    case book
    case globe
    case bolt
    case package
    case design
    case metrics
    case bug
    case sandbox
    case starred

    /// What a workspace is marked with until someone chooses otherwise.
    public static let `default` = WorkspaceSymbol.folder

    /// The SF Symbol the shell draws. Held here beside the label so the two cannot drift.
    public var systemName: String {
        switch self {
        case .folder: return "folder"
        case .terminal: return "terminal"
        case .hammer: return "hammer"
        case .book: return "book"
        case .globe: return "globe"
        case .bolt: return "bolt"
        case .package: return "shippingbox"
        case .design: return "paintbrush"
        case .metrics: return "chart.bar"
        case .bug: return "ant"
        case .sandbox: return "leaf"
        case .starred: return "star"
        }
    }

    /// What the picker shows and VoiceOver announces.
    public var label: String {
        switch self {
        case .folder: return "Folder"
        case .terminal: return "Terminal"
        case .hammer: return "Build"
        case .book: return "Docs"
        case .globe: return "Web"
        case .bolt: return "Automation"
        case .package: return "Package"
        case .design: return "Design"
        case .metrics: return "Metrics"
        case .bug: return "Bugs"
        case .sandbox: return "Sandbox"
        case .starred: return "Starred"
        }
    }
}

/// A workspace's mark and tint. The name lives on `Workspace` itself; these are the two
/// values that had nowhere to live before.
///
/// `accent` is optional and nil is not a colour: it means this workspace follows the app
/// accent the person chose in Settings, so an uncustomised catalog keeps looking exactly as
/// it did and the app-wide preference keeps its meaning.
public struct WorkspaceAppearance: Equatable, Sendable {
    public var symbol: WorkspaceSymbol
    public var accent: AccentColor?

    public init(symbol: WorkspaceSymbol = .default, accent: AccentColor? = nil) {
        self.symbol = symbol
        self.accent = accent
    }

    /// What every workspace looks like until someone customises it, and what `resetIdentity`
    /// restores.
    public static let `default` = WorkspaceAppearance()

    public var isDefault: Bool { self == .default }
}
