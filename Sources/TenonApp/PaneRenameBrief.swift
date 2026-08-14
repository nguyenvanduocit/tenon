// @domain: pane-chrome
import Foundation
import TenonCore

struct PaneRenameBrief: Equatable, Sendable {
    static let maximumExcerptBytes = 12 << 10

    let currentTitle: String
    let kind: String
    let location: String
    let excerpt: String

    @concurrent
    static func make(
        slot: WorkspaceSlot,
        currentTitle: String,
        workspacePath: URL,
        terminalExcerpt: String?
    ) async -> Self {
        let kind: String
        let location: String
        let rawExcerpt: String

        switch slot.content {
        case .terminal:
            kind = "terminal"
            location = workspacePath.path
            rawExcerpt = terminalExcerpt ?? "No terminal scrollback is available."
        case .file(let path):
            kind = "file"
            let url = resolved(path: path, relativeTo: workspacePath)
            location = url.path
            rawExcerpt = readPrefix(of: url) ?? "The file could not be read."
        case .changes:
            kind = "working-tree changes"
            location = workspacePath.path
            rawExcerpt = "A host-native view of the workspace's changed files."
        case .automation:
            kind = "automation"
            location = workspacePath.path
            rawExcerpt = "A host-native view of schedules, runs, and delivery evidence."
        case let .pluginView(pluginID, viewID):
            kind = "plugin view"
            location = workspacePath.path
            rawExcerpt = "Plugin: \(pluginID.rawValue)\nView: \(viewID)"
        case .diff(let request):
            kind = "diff"
            location = workspacePath.path
            switch request.source {
            case let .git(repoPath, path, staged, untracked, originalPath):
                rawExcerpt = """
                File: \(request.fileName)
                Repository: \(repoPath)
                Path: \(path)
                Staged: \(staged)
                Untracked: \(untracked)
                Original path: \(originalPath ?? "none")
                """
            case let .inline(oldText, newText):
                rawExcerpt = """
                File: \(request.fileName)
                Before:
                \(bounded(oldText, maximumBytes: maximumExcerptBytes / 2))
                After:
                \(bounded(newText, maximumBytes: maximumExcerptBytes / 2))
                """
            }
        case .agentSession(let ref):
            kind = "recorded agent session"
            location = ref.transcriptPath
            rawExcerpt = readTail(of: URL(fileURLWithPath: ref.transcriptPath))
                ?? "Session \(ref.provider.rawValue) \(ref.sessionID)"
        case .empty:
            kind = "empty pane"
            location = workspacePath.path
            rawExcerpt = "The pane has no content yet."
        }

        return Self(
            currentTitle: currentTitle,
            kind: kind,
            location: location,
            excerpt: bounded(rawExcerpt, maximumBytes: maximumExcerptBytes)
        )
    }

    private static func resolved(path: String, relativeTo workspacePath: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return workspacePath.appendingPathComponent(path).standardizedFileURL
    }

    private static func readPrefix(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumExcerptBytes),
              !data.isEmpty
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maximumExcerptBytes)
            ? end - UInt64(maximumExcerptBytes)
            : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: maximumExcerptBytes),
                  !data.isEmpty
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    static func bounded(_ text: String, maximumBytes: Int) -> String {
        let bytes = Data(text.utf8)
        guard bytes.count > maximumBytes else { return text }
        return String(decoding: bytes.suffix(maximumBytes), as: UTF8.self)
    }
}
