// @domain: plugin-contributions
import Foundation

enum KanbanBoardFormat {
    static let maximumRowsPerColumn = 12
    static let maximumLabelLength = 160
    static let maximumCriteria = 12
    static let maximumCardTitleLength = 96
    static let maximumCardMetaLength = 24
    static let writePageBytes = 48 * 1024
    static let maximumWritePages = 21
    static let maximumReadPages = 24
    static let maximumReadRestarts = 3
    static let maximumTailLines = 15
    static let maximumTailLineLength = 160

    struct Board: Sendable, Equatable {
        var columns: [Column]
    }

    struct Column: Sendable, Equatable {
        let name: String
        var tasks: [Task]
    }

    struct Task: Sendable, Equatable {
        let id: String
        let path: String
        let title: String
        let meta: String
    }

    struct Detail: Sendable, Equatable {
        var title = ""
        var description = ""
        var priority = ""
        var effort = ""
        var criteria: [Criterion] = []
    }

    struct Criterion: Sendable, Equatable {
        let done: Bool
        let text: String
    }

    enum Relocation: Sendable, Equatable {
        case text(String)
        case unchanged
        case failure(String)
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 0 else { return "" }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    static func parseBoard(_ text: String) -> Board {
        var columns: [Column] = []
        var currentIndex: Int?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let name = columnHeading(in: line) {
                columns.append(Column(name: name, tasks: []))
                currentIndex = columns.index(before: columns.endIndex)
                continue
            }
            guard let currentIndex,
                  let row = taskRow(in: line)
            else { continue }
            columns[currentIndex].tasks.append(
                Task(
                    id: row.id,
                    path: row.path,
                    title: title(of: row.rest),
                    meta: meta(of: row.rest)
                )
            )
        }
        return Board(columns: columns)
    }

    static func parseTask(_ text: String) -> Detail {
        var detail = Detail()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let heading = taskHeading(in: line), detail.title.isEmpty {
                detail.title = clip(heading, to: maximumLabelLength)
                continue
            }
            if let quote = descriptionLine(in: line), detail.description.isEmpty {
                detail.description = clip(quote, to: maximumLabelLength)
                continue
            }
            if let field = taskField(in: line) {
                if field.key == "priority" {
                    detail.priority = clip(field.value, to: 32)
                } else {
                    detail.effort = clip(field.value, to: 32)
                }
                continue
            }
            if let criterion = criterionLine(in: line), detail.criteria.count < maximumCriteria {
                detail.criteria.append(
                    Criterion(
                        done: criterion.marker != " ",
                        text: clip(criterion.text, to: maximumLabelLength)
                    )
                )
            }
        }
        return detail
    }

    static func relocateTaskLine(_ text: String, id: String, delta: Int) -> Relocation {
        relocate(text, id: id) { $0 + delta }
    }

    static func relocateTaskLineToColumn(_ text: String, id: String, column: Int) -> Relocation {
        relocate(text, id: id) { _ in column }
    }

    static func splitWritePages(_ text: String) -> [String] {
        var pages: [String] = []
        var page = ""
        var pageBytes = 0

        for character in text {
            let unit = String(character)
            let bytes = unit.utf8.count
            if pageBytes + bytes > writePageBytes {
                pages.append(page)
                page = ""
                pageBytes = 0
            }
            page += unit
            pageBytes += bytes
        }
        pages.append(page)
        return pages
    }

    static func tail(of text: String) -> String {
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed()
            where kept.count < maximumTailLines
        {
            let trimmed = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            guard !trimmed.isEmpty else { continue }
            kept.insert(clip(trimmed, to: maximumTailLineLength), at: 0)
        }
        return kept.joined(separator: "\n")
    }

    static func relocate(
        _ text: String,
        id: String,
        targetFor: (Int) -> Int
    ) -> Relocation {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headings: [Int] = []
        var lastTaskLine: [Int] = []
        var taskLine = -1
        var taskColumn = -1

        for index in lines.indices {
            if columnHeading(in: lines[index]) != nil {
                headings.append(index)
                lastTaskLine.append(-1)
                continue
            }
            guard !headings.isEmpty,
                  let row = taskRow(in: lines[index])
            else { continue }
            lastTaskLine[lastTaskLine.index(before: lastTaskLine.endIndex)] = index
            if taskLine < 0, row.id == id {
                taskLine = index
                taskColumn = headings.count - 1
            }
        }

        guard taskLine >= 0 else { return .failure("task-not-found") }
        let target = targetFor(taskColumn)
        guard headings.indices.contains(target) else {
            return .failure("no-adjacent-column")
        }
        guard target != taskColumn else { return .unchanged }

        let moved = lines[taskLine]
        var insertAfter = lastTaskLine[target] >= 0 ? lastTaskLine[target] : headings[target]
        lines.remove(at: taskLine)
        if insertAfter > taskLine { insertAfter -= 1 }
        lines.insert(moved, at: insertAfter + 1)
        return .text(lines.joined(separator: "\n"))
    }

    private static func columnHeading(in line: String) -> String? {
        guard line.hasPrefix("##") else { return nil }
        let suffix = line.dropFirst(2)
        guard suffix.first?.isWhitespace == true else { return nil }
        let name = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name)
    }

    private struct TaskRow {
        let id: String
        let path: String
        let rest: String
    }

    private static func taskRow(in line: String) -> TaskRow? {
        guard line.hasPrefix("-") else { return nil }
        var index = line.index(after: line.startIndex)
        guard index < line.endIndex, line[index].isWhitespace else { return nil }
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        guard line[index...].hasPrefix("[") else { return nil }
        guard let close = line[index...].firstIndex(of: "]"),
              line.index(after: close) < line.endIndex,
              line[line.index(after: close)] == "("
        else { return nil }
        let id = String(line[line.index(after: index) ..< close])
        guard id.hasPrefix("T-"), id.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        let pathStart = line.index(after: close)
        guard let pathEnd = line[pathStart...].firstIndex(of: ")") else { return nil }
        let path = String(line[line.index(after: pathStart) ..< pathEnd])
        guard !path.isEmpty else { return nil }
        let afterPath = line.index(after: pathEnd)
        let rest = String(line[afterPath...]).trimmingCharacters(in: .whitespaces)
        return TaskRow(id: id, path: path, rest: rest)
    }

    private static func splitOnFirstDash(_ rest: String) -> (String, String) {
        guard let range = rest.range(of: " — ") else { return (rest, "") }
        return (
            String(rest[..<range.lowerBound]),
            String(rest[range.upperBound...])
        )
    }

    private static func title(of rest: String) -> String {
        clip(splitOnFirstDash(rest).0.trimmingCharacters(in: .whitespaces), to: maximumLabelLength)
    }

    private static func meta(of rest: String) -> String {
        let tail = splitOnFirstDash(rest).1
        guard !tail.isEmpty else { return "" }
        return clip(
            splitOnFirstDash(tail).0.trimmingCharacters(in: .whitespaces),
            to: maximumLabelLength
        )
    }

    private static func taskHeading(in line: String) -> String? {
        guard line.hasPrefix("# ") else { return nil }
        let value = String(line.dropFirst(2))
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let id = value[..<colon].trimmingCharacters(in: .whitespaces)
        guard id.hasPrefix("T-"), id.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func descriptionLine(in line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func taskField(in line: String) -> (key: String, value: String)? {
        let prefix = "- **"
        guard line.hasPrefix(prefix) else { return nil }
        let keyStart = line.index(line.startIndex, offsetBy: prefix.count)
        guard
              let end = line.range(of: "**:", range: keyStart ..< line.endIndex)
        else { return nil }
        let key = String(line[keyStart ..< end.lowerBound])
        guard key == "priority" || key == "effort" else { return nil }
        return (
            key,
            String(line[end.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func criterionLine(in line: String) -> (marker: Character, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ["),
              trimmed.count >= 6,
              let marker = trimmed.dropFirst(3).first,
              [" ", "x", "X"].contains(marker),
              trimmed.dropFirst(4).first == "]"
        else { return nil }
        return (
            marker,
            String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
