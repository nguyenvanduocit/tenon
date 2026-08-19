// @domain: agent-lens
import Foundation

/// The one rule for "a transcript this host is allowed to read".
///
/// It existed in three near-copies before this type did — `AgentSessionRegistry.candidateURL`
/// for a path a hook reports, `AgentLensDiscovery.declared` for one a session states, and
/// `AgentLensDiscovery.validate` for one found by walking a process's open descriptors — and
/// they had already drifted: only two of the three resolved symlinks in the ROOT before
/// comparing, so a home directory that is itself a symlink (which `/tmp` is on macOS, and which
/// every test fixture built under `NSTemporaryDirectory` therefore is) answered the same
/// question two different ways depending on who asked.
///
/// It is pure and takes its roots as an argument, so the rule can be swept headlessly against
/// real symlinks on disk rather than against a description of them.
enum AgentTranscriptPath {
    /// Where the providers keep transcripts, under one home directory.
    ///
    /// Codex first, matching the order both existing callers already used — the list is a set in
    /// meaning, and nothing reads it positionally, but a reordering would still show up in a
    /// diff as a change nobody made on purpose. opencode keeps every session in one SQLite
    /// database, so its data directory is the root and the database itself is the file. The
    /// opencode root defaults to `home`-derived so a test fixture built under a temporary home
    /// stays self-contained.
    static func allowedRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        opencodeDataRoot: URL? = nil
    ) -> [URL] {
        [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            opencodeDataRoot ?? home.appendingPathComponent(
                ".local/share/opencode",
                isDirectory: true
            ),
        ]
    }

    /// The transcript `path` names, or nil when this host may not read it.
    ///
    /// Fails closed on everything it cannot prove: a relative path, a path whose extension is
    /// not one the provider records (`.jsonl` for Codex and Claude Code, `.db` for opencode),
    /// and a path that — after symlinks are followed on BOTH sides — does not sit
    /// under one of `roots`. Following symlinks first is what makes the containment check
    /// meaningful: a link inside an allowed root pointing at `~/.ssh/id_ed25519` is refused
    /// because the resolved path is compared, not the name that was written.
    ///
    /// It deliberately says nothing about whether the file EXISTS. A session states where it
    /// will write before it has written, and refusing that would refuse a real session for
    /// being new. `validatedExisting` is the same question asked when the file must be there.
    static func validated(
        _ path: String,
        roots: [URL],
        fileExtension: String = "jsonl"
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return validated(URL(fileURLWithPath: path), roots: roots, fileExtension: fileExtension)
    }

    static func validated(
        _ candidate: URL,
        roots: [URL],
        fileExtension: String = "jsonl"
    ) -> URL? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == fileExtension else { return nil }
        for root in roots {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            // The trailing separator is what keeps `/a/projects-secret/x.jsonl` out of the root
            // `/a/projects`: a bare prefix test admits any sibling whose name starts the same.
            if resolved.path.hasPrefix(resolvedRoot + "/") { return resolved }
        }
        return nil
    }

    /// The same question asked of a file that must already be on disk.
    static func validatedExisting(
        _ candidate: URL,
        roots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        guard let validated = validated(candidate, roots: roots),
              fileManager.fileExists(atPath: validated.path)
        else { return nil }
        return validated
    }
}
