// @domain: repository-read
import Foundation

struct GitChangeEntry: Sendable, Equatable {
    let path: String
    let staged: String
    let unstaged: String
    let conflict: Bool
    let origPath: String?
}

struct GitRecentCommit: Sendable, Equatable {
    let hash: String
    let subject: String
}

struct GitStatusModel: Sendable, Equatable {
    var isRepo: Bool
    var branch: String
    var ahead: Int
    var behind: Int
    var upstream: String?
    var hasHead: Bool
    var staged: [GitChangeEntry]
    var changed: [GitChangeEntry]
    var merge: [GitChangeEntry]
    var recent: [GitRecentCommit]

    static var empty: GitStatusModel {
        GitStatusModel(
            isRepo: false,
            branch: "?",
            ahead: 0,
            behind: 0,
            upstream: nil,
            hasHead: true,
            staged: [],
            changed: [],
            merge: [],
            recent: []
        )
    }
}

enum GitStatusParser {
    static let logSeparator = "\u{1f}"

    static func parseStatus(_ output: String) -> GitStatusModel {
        let records = output.split(
            separator: "\u{0}",
            omittingEmptySubsequences: false
        ).map(String.init)
        var model = GitStatusModel.empty
        model.isRepo = true
        var entries: [GitChangeEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            defer { index += 1 }
            guard !record.isEmpty else { continue }
            if parseBranchRecord(record, into: &model) { continue }
            guard let parsed = parseEntryRecord(
                record,
                next: index + 1 < records.count ? records[index + 1] : nil
            ) else { continue }
            entries.append(parsed.entry)
            index += parsed.consumed - 1
        }
        classify(entries, into: &model)
        return model
    }

    static func parseLog(_ output: String) -> [GitRecentCommit] {
        output.split(separator: "\n").map { line in
            let fields = line.split(
                separator: Character(logSeparator),
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            return GitRecentCommit(
                hash: fields.first.map(String.init) ?? "",
                subject: fields.dropFirst().first.map(String.init) ?? ""
            )
        }.filter { !$0.hash.isEmpty }
    }

    private static func parseBranchRecord(
        _ record: String,
        into model: inout GitStatusModel
    ) -> Bool {
        if record.hasPrefix("# branch.oid ") {
            model.hasHead = String(record.dropFirst(13)) != "(initial)"
            return true
        }
        if record.hasPrefix("# branch.head ") {
            let head = String(record.dropFirst(14))
            model.branch = head == "(detached)" ? "detached HEAD" : head
            return true
        }
        if record.hasPrefix("# branch.upstream ") {
            model.upstream = String(record.dropFirst(18))
            return true
        }
        if record.hasPrefix("# branch.ab ") {
            let parts = record.dropFirst(12).split(separator: " ")
            for part in parts {
                if part.hasPrefix("+") {
                    model.ahead = Int(part.dropFirst()) ?? 0
                }
                if part.hasPrefix("-") {
                    model.behind = Int(part.dropFirst()) ?? 0
                }
            }
            return true
        }
        return false
    }

    private struct ParsedEntry {
        let entry: GitChangeEntry
        let consumed: Int
    }

    private static func parseEntryRecord(
        _ record: String,
        next: String?
    ) -> ParsedEntry? {
        guard record.count > 1,
              record[record.index(after: record.startIndex)] == " "
        else { return nil }

        switch record.first {
        case "1":
            return ParsedEntry(
                entry: GitChangeEntry(
                    path: pathAfter(record, spaces: 8),
                    staged: character(at: 2, in: record),
                    unstaged: character(at: 3, in: record),
                    conflict: false,
                    origPath: nil
                ),
                consumed: 1
            )
        case "2":
            return ParsedEntry(
                entry: GitChangeEntry(
                    path: pathAfter(record, spaces: 9),
                    staged: character(at: 2, in: record),
                    unstaged: character(at: 3, in: record),
                    conflict: false,
                    origPath: next
                ),
                consumed: 2
            )
        case "u":
            return ParsedEntry(
                entry: GitChangeEntry(
                    path: pathAfter(record, spaces: 10),
                    staged: character(at: 2, in: record),
                    unstaged: character(at: 3, in: record),
                    conflict: true,
                    origPath: nil
                ),
                consumed: 1
            )
        case "?":
            return ParsedEntry(
                entry: GitChangeEntry(
                    path: String(record.dropFirst(2)),
                    staged: "?",
                    unstaged: "?",
                    conflict: false,
                    origPath: nil
                ),
                consumed: 1
            )
        default:
            return nil
        }
    }

    private static func classify(
        _ entries: [GitChangeEntry],
        into model: inout GitStatusModel
    ) {
        model.merge = entries.filter(\.conflict)
        model.staged = entries.filter {
            !$0.conflict && $0.staged != "." && $0.staged != "?"
        }
        model.changed = entries.filter { !$0.conflict && $0.unstaged != "." }
    }

    private static func pathAfter(_ record: String, spaces target: Int) -> String {
        var count = 0
        for index in record.indices where record[index] == " " {
            count += 1
            if count == target {
                return String(record[record.index(after: index)...])
            }
        }
        return ""
    }

    private static func character(at offset: Int, in record: String) -> String {
        guard offset >= 0,
              let index = record.index(
                record.startIndex,
                offsetBy: offset,
                limitedBy: record.endIndex
              ),
              index < record.endIndex
        else { return "" }
        return String(record[index])
    }
}
