// @domain: agent-control, companion
import Foundation

/// Installs `AgentHarnessText` into the files an agent already reads on this machine.
///
/// These are the person's own files, not Tenon's, and that shapes every rule here. The
/// briefing goes between two markers and nothing outside them is ever read back out or
/// rewritten; installing again replaces what is between the markers and stacks nothing;
/// removing takes the block and leaves the file. A skill file is different in kind — Tenon
/// owns the whole file, so it is written and deleted whole.
///
/// Every path is derived from an injected home directory so the whole contract is provable
/// in a temp dir, without a window and without touching the running person's configuration.
struct AgentHarnessInstaller {
    enum Target: CaseIterable {
        /// Claude Code's global instructions.
        case claudeInstructions
        /// Codex's global instructions. Tenon already installs lifecycle hooks for both
        /// providers, so a harness that reached only one would leave the other blind.
        case codexInstructions
        /// A Claude Code skill Tenon owns end to end.
        case claudeSkill

        var relativePath: String {
            switch self {
            case .claudeInstructions: ".claude/CLAUDE.md"
            case .codexInstructions: ".codex/AGENTS.md"
            case .claudeSkill: ".claude/skills/tenon/SKILL.md"
            }
        }

        /// True when Tenon owns the whole file rather than one block inside it.
        var isExclusivelyOwned: Bool { self == .claudeSkill }

        var body: String {
            isExclusivelyOwned ? AgentHarnessText.skill : AgentHarnessText.instructions
        }

        func url(relativeTo home: URL) -> URL {
            home.appendingPathComponent(relativePath)
        }
    }

    enum State: Equatable {
        /// No target carries Tenon's briefing.
        case absent
        /// Every target carries this build's briefing, byte for byte.
        case current
        /// At least one target carries a briefing, and it is not this one.
        case outdated
    }

    struct Status: Equatable {
        var state: State = .absent
        /// The paths that carry this build's briefing right now, for the settings page to
        /// name rather than describe.
        var currentPaths: [String] = []
    }

    struct Outcome: Equatable {
        enum Status: Equatable {
            case installed
            case alreadyCurrent
        }

        var status: Status
        var paths: [String]
    }

    let homeDirectory: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func status() -> Status {
        var current: [String] = []
        var anyBriefing = false
        for target in Target.allCases {
            let url = target.url(relativeTo: homeDirectory)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            if target.isExclusivelyOwned {
                guard contents.contains("# Working inside Tenon") else { continue }
                anyBriefing = true
                if contents == target.body { current.append(url.path) }
            } else {
                guard managedRange(in: contents) != nil else { continue }
                anyBriefing = true
                if contents == merged(target.body, into: contents) {
                    current.append(url.path)
                }
            }
        }
        guard anyBriefing else { return Status() }
        return Status(
            state: current.count == Target.allCases.count ? .current : .outdated,
            currentPaths: current
        )
    }

    @discardableResult
    func install() throws -> Outcome {
        var changed = false
        var paths: [String] = []
        for target in Target.allCases {
            let url = target.url(relativeTo: homeDirectory)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = target.isExclusivelyOwned
                ? target.body
                : merged(target.body, into: existing)
            paths.append(url.path)
            guard updated != existing else { continue }
            try write(updated, to: url)
            changed = true
        }
        return Outcome(status: changed ? .installed : .alreadyCurrent, paths: paths)
    }

    func remove() throws {
        for target in Target.allCases {
            let url = target.url(relativeTo: homeDirectory)
            guard target.isExclusivelyOwned == false else {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard let existing = try? String(contentsOf: url, encoding: .utf8),
                  let range = managedRange(in: existing)
            else { continue }
            var remaining = existing
            remaining.removeSubrange(range)
            try write(remaining, to: url)
        }
    }
}

private extension AgentHarnessInstaller {
    /// The block including its markers and the blank line that separates it from whatever a
    /// person wrote above it — so removing it leaves no drifting blank lines behind, and
    /// reinstalling reproduces the same bytes.
    func managedRange(in contents: String) -> Range<String.Index>? {
        guard let begin = contents.range(of: AgentHarnessText.beginMarker),
              let end = contents.range(of: AgentHarnessText.endMarker),
              begin.upperBound <= end.lowerBound
        else { return nil }
        var lower = begin.lowerBound
        while lower > contents.startIndex {
            let previous = contents.index(before: lower)
            guard contents[previous] == "\n" else { break }
            lower = previous
        }
        var upper = end.upperBound
        if upper < contents.endIndex, contents[upper] == "\n" {
            upper = contents.index(after: upper)
        }
        return lower ..< upper
    }

    func block(_ body: String) -> String {
        """
        \(AgentHarnessText.beginMarker)
        <!-- Tenon writes this block. Edits inside it are replaced when it is reinstalled; \
        everything outside it is left alone. -->

        \(body)
        \(AgentHarnessText.endMarker)
        """
    }

    /// Replaces the existing block in place, or appends one — always separated from the
    /// person's own text by exactly one blank line, and always ending in a newline.
    func merged(_ body: String, into existing: String) -> String {
        if let range = managedRange(in: existing) {
            let before = String(existing[existing.startIndex ..< range.lowerBound])
            let after = String(existing[range.upperBound...])
            let separator = before.isEmpty ? "" : "\n\n"
            return before + separator + block(body) + "\n" + after
        }
        let trimmed = existing.isEmpty
            ? ""
            : String(existing.reversed().drop { $0 == "\n" }.reversed())
        let separator = trimmed.isEmpty ? "" : "\n\n"
        return trimmed + separator + block(body) + "\n"
    }

    func write(_ contents: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
