// @domain: workspace-model
import Foundation

/// Turns "where a pane's shell currently is" into "what the panels should be anchored to".
///
/// A pane carries two directories, and conflating them is the bug this rule exists to fix.
/// The **cwd** churns constantly — every `cd`, every step into a subdirectory. The
/// **project root** almost never changes: it is the checkout the work belongs to. Files and
/// Git anchor to the project root, so walking around inside one repository re-roots
/// nothing, while an agent stepping into its own `git worktree` moves the panels with it.
///
/// The rule is deliberately the one git itself uses: the nearest ancestor holding a `.git`
/// entry, where `.git` may be a **file** rather than a directory. That file case is not an
/// edge case here — it is precisely the linked worktree and the submodule, which is to say
/// the parallel-agent layout this product targets.
public enum ProjectRoot {
    public struct Resolution: Equatable, Sendable {
        /// `nil` when the cwd sits under no repository at all. The panels then keep their
        /// existing fallback (the workspace path); this rule never guesses `/`.
        public let root: URL?

        public init(root: URL?) {
            self.root = root
        }
    }

    /// Resolves the project root for a pane sitting in `cwd`.
    public static func resolve(cwd: URL) -> Resolution {
        var current = canonical(cwd)
        while true {
            if hasGitEntry(at: current) {
                return Resolution(root: current)
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            // `/` is its own parent; stop there rather than looping forever.
            guard parent.path != current.path else {
                return Resolution(root: nil)
            }
            current = parent
        }
    }

    /// Whether moving between two resolutions should actually repaint the panels.
    ///
    /// This is the no-thrash rule in one place: an ordinary `cd` within a repository
    /// produces two resolutions with the same root, and answers `false`.
    public static func rerootsPanels(from: Resolution, to: Resolution) -> Bool {
        from.root != to.root
    }

    /// Both of a pane's directories as one value, so the two can never be updated out of
    /// step. This is what the pane carries and what the `pane.cwd-changed` fact reports.
    public struct PaneDirectory: Equatable, Sendable {
        public let cwd: URL
        public let projectRoot: URL?

        public init(cwd: URL) {
            let resolution = ProjectRoot.resolve(cwd: cwd)
            self.cwd = ProjectRoot.canonical(cwd)
            self.projectRoot = resolution.root
        }

        public var resolution: Resolution {
            Resolution(root: projectRoot)
        }
    }

    /// One identity per directory, so a repository reached through a symlink is not treated
    /// as a second repository. `/tmp/repo` and `/private/tmp/repo` must re-root nothing.
    fileprivate static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// `.git` as a directory is a plain checkout; `.git` as a file holding a `gitdir:`
    /// pointer is a linked worktree or a submodule. Both root here, which is why this asks
    /// only whether the entry exists. A broken symlink resolves to nothing and does not
    /// root, so the search correctly continues up to the real repository.
    private static func hasGitEntry(at directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path
        )
    }
}
