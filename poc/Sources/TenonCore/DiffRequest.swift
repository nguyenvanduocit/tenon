import Foundation

/// What a diff should compare. Either the host resolves both sides from git
/// natively (fast, no file bytes crossing the JS bridge, survives a plugin
/// reload), or the plugin supplies the two texts inline for a non-git diff.
public enum DiffSource: Equatable, Sendable {
    /// HEAD→index when `staged`, else index→worktree. `untracked` means the old
    /// side is empty (the whole file is new); `origPath` diffs a rename old→new.
    case git(repoPath: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
    /// Both sides supplied directly.
    case inline(oldText: String, newText: String)
}

/// A request to show a diff in the host's default diff view. A pure value
/// (Invariant 3) that a plugin builds via `tenon.diff.open(...)` and the shell
/// renders as a `.diff` pane. Carries no view or terminal type.
public struct DiffRequest: Equatable, Sendable {
    public var source: DiffSource
    /// The changed file's name, shown in the diff view and used for the tab title.
    public var fileName: String
    /// Tab title (defaults to `fileName` when a plugin omits it).
    public var title: String

    public init(source: DiffSource, fileName: String, title: String) {
        self.source = source
        self.fileName = fileName
        self.title = title
    }
}
