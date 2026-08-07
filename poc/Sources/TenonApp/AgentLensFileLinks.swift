import Foundation

/// A file an agent named in its prose: the path exactly as it was written, plus the line
/// it pointed at when it wrote one. Recovering this is a pure rule, so what counts as a
/// file reference is asserted without a window.
struct AgentFileReference: Equatable, Sendable {
    let path: String
    let line: Int?
}

enum AgentFileReferenceRule {
    /// The file named by one inline span, or nil when the span is a command, a flag, a URL,
    /// or ordinary prose. Agents write all four in the same backticks, so the rule is
    /// deliberately narrow: a file is written as a path or written with an extension.
    static func reference(in span: String) -> AgentFileReference? {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024 else { return nil }
        // A command is a span with arguments; a flag is a span that starts with its dash.
        guard !trimmed.contains(where: \.isWhitespace), !trimmed.hasPrefix("-") else {
            return nil
        }
        // A URL addresses somebody else's namespace, not this workspace.
        guard !trimmed.contains("://"), !trimmed.contains("@") else { return nil }

        // `AgentLensView.swift:1023` and `:1023:9` point into a file. The file is what
        // opens, so strip the suffixes right to left and keep the leftmost number, which
        // is the line rather than the column.
        var path = trimmed
        var line: Int?
        while let colon = path.lastIndex(of: ":"), colon != path.startIndex {
            let suffix = path[path.index(after: colon)...]
            guard !suffix.isEmpty,
                  suffix.allSatisfy(\.isNumber),
                  let value = Int(suffix)
            else { break }
            line = value
            path = String(path[..<colon])
        }

        // A trailing separator names a directory, which has no file pane to open.
        guard !path.isEmpty, !path.hasSuffix("/"), !path.contains(":") else { return nil }
        guard path.contains("/") || hasExtension(path) else { return nil }
        return AgentFileReference(path: path, line: line)
    }

    private static func hasExtension(_ path: String) -> Bool {
        let component = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else {
            // A dotfile is its own extension: `.gitignore` names a file, `.` does not.
            return component.hasPrefix(".") &&
                component.dropFirst().allSatisfy { $0.isLetter || $0.isNumber }
        }
        let suffix = component[component.index(after: dot)...]
        return (1...16).contains(suffix.count) &&
            suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

/// Turns a written span into the absolute path of a file that is really there. Agents
/// write paths they believe in, so only a path that resolves earns a link: a click in
/// Agent Lens always lands on evidence rather than on a missing file.
struct AgentFileLinks: Sendable {
    private let resolvePath: @Sendable (String) -> String?

    /// No span resolves. The default for prose rendered outside a workspace.
    static let none = AgentFileLinks { _ in nil }

    init(resolve: @escaping @Sendable (String) -> String?) {
        resolvePath = resolve
    }

    /// Resolution against the workspace the agent is running in. `isFile` is injected so
    /// the containment and candidate rules are asserted without touching disk.
    init(
        root: URL,
        isFile: @escaping @Sendable (String) -> Bool = { AgentFileLinks.isReadableFile($0) }
    ) {
        self.init { span in
            guard let reference = AgentFileReferenceRule.reference(in: span) else { return nil }
            return Self.candidates(for: reference.path, root: root).first(where: isFile)
        }
    }

    /// The absolute path `span` names, or nil when it names no file that exists.
    func path(for span: String) -> String? {
        resolvePath(span)
    }

    /// The file URL a rendered span links to. A `file:` URL is what the click handler
    /// recognises, so remote links keep their ordinary system behaviour.
    func url(for span: String) -> URL? {
        resolvePath(span).map { URL(fileURLWithPath: $0) }
    }

    /// Where a written path could be. A relative path is read against the workspace root
    /// and must stay inside it, so prose can never walk a click out of the workspace.
    /// An absolute or `~` path is what the agent explicitly named and resolves as written.
    static func candidates(for path: String, root: URL) -> [String] {
        if path.hasPrefix("/") {
            return [URL(fileURLWithPath: path).standardizedFileURL.path]
        }
        if path.hasPrefix("~") {
            return [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL.path]
        }
        let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let resolved = root.appendingPathComponent(relative).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard resolved.path == base || resolved.path.hasPrefix(base + "/") else { return [] }
        return [resolved.path]
    }

    static func isReadableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
