import Foundation
import SwiftUI

/// One block of agent prose. The parser covers the CommonMark subset CLI agents actually
/// emit — headings, paragraphs, lists (nested, ordered, task), fenced code, blockquotes,
/// pipe tables, thematic breaks — and leaves inline spans as source text for
/// `AgentMarkdownInline` to interpret at render time.
indirect enum AgentMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([AgentMarkdownListItem])
    case code(language: String, source: String)
    case quote([AgentMarkdownBlock])
    case table(AgentMarkdownTable)
    case rule
}

struct AgentMarkdownListItem: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case bullet
        /// The literal ordinal from source — "1." or "2)" — so a list that starts at 3
        /// still reads as 3.
        case ordered(String)
    }

    enum Task: Equatable, Sendable {
        case unchecked
        case checked
    }

    var depth: Int
    var marker: Marker
    var task: Task?
    var text: String
}

struct AgentMarkdownTable: Equatable, Sendable {
    enum Column: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    var header: [String]
    var columns: [Column]
    var rows: [[String]]
}

/// Line-based block parser. Deliberately not a full CommonMark implementation: it reads
/// the shapes agent harnesses emit, and anything it does not recognise degrades to a
/// paragraph whose inline spans still render. An unterminated fence stays a code block so
/// a streaming message never flips its formatting mid-write.
enum AgentMarkdown {
    static func parse(_ source: String) -> [AgentMarkdownBlock] {
        parseBlocks(
            source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
        )
    }

    private static func parseBlocks(_ lines: [String]) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if isBlank(line) {
                index += 1
                continue
            }

            if let fence = fence(line) {
                index += 1
                var body: [String] = []
                while index < lines.count, !closes(lines[index], fence) {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.code(language: fence.language, source: body.joined(separator: "\n")))
                continue
            }

            if isThematicBreak(line) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(line) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isQuote(line) {
                var inner: [String] = []
                while index < lines.count, isQuote(lines[index]) {
                    inner.append(strippingQuote(lines[index]))
                    index += 1
                }
                blocks.append(.quote(parseBlocks(inner)))
                continue
            }

            if tableStarts(lines, at: index) {
                blocks.append(.table(parseTable(lines, &index)))
                continue
            }

            if listItem(line) != nil {
                blocks.append(.list(parseList(lines, &index)))
                continue
            }

            // An indented run keeps its own shape — trees, tables of numbers, and stack
            // traces arrive this way often enough that reflowing them loses the content.
            if indentWidth(line) >= 4, !isList(blocks.last) {
                blocks.append(.code(language: "", source: parseIndentedCode(lines, &index)))
                continue
            }

            blocks.append(.paragraph(parseParagraph(lines, &index)))
        }

        return blocks
    }

    // MARK: - Paragraphs

    private static func parseParagraph(_ lines: [String], _ index: inout Int) -> String {
        var text: [String] = []
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                break
            }
            if !text.isEmpty, startsBlock(lines, at: index) {
                break
            }
            text.append(trimmingTrailingWhitespace(line))
            index += 1
        }
        return text.joined(separator: "\n")
    }

    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        return fence(line) != nil
            || isThematicBreak(line)
            || heading(line) != nil
            || isQuote(line)
            || listItem(line) != nil
            || tableStarts(lines, at: index)
    }

    // MARK: - Code

    private struct Fence {
        var marker: Character
        var length: Int
        var language: String
    }

    private static func fence(_ line: String) -> Fence? {
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3, let marker = body.first, marker == "`" || marker == "~" else {
            return nil
        }
        let run = body.prefix(while: { $0 == marker })
        guard run.count >= 3 else { return nil }
        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string cannot itself contain a backtick, which is what
        // keeps ```` ``inline`` ```` out of the block path.
        if marker == "`", info.contains("`") { return nil }
        return Fence(
            marker: marker,
            length: run.count,
            language: info.split(separator: " ").first.map(String.init) ?? ""
        )
    }

    private static func closes(_ line: String, _ fence: Fence) -> Bool {
        let body = line.drop(while: { $0 == " " })
        let run = body.prefix(while: { $0 == fence.marker })
        guard run.count >= fence.length else { return false }
        return body.dropFirst(run.count).allSatisfy { $0 == " " }
    }

    private static func parseIndentedCode(_ lines: [String], _ index: inout Int) -> String {
        var body: [String] = []
        var lookahead = index
        while lookahead < lines.count, isBlank(lines[lookahead]) || indentWidth(lines[lookahead]) >= 4 {
            body.append(expandingTabs(lines[lookahead]))
            lookahead += 1
        }
        while let last = body.last, isBlank(last) {
            body.removeLast()
        }
        index += body.count
        return body.map { String($0.dropFirst(4)) }.joined(separator: "\n")
    }

    // MARK: - Headings, rules, quotes

    private static func heading(_ line: String) -> AgentMarkdownBlock? {
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3 else { return nil }
        let hashes = body.prefix(while: { $0 == "#" })
        guard (1 ... 6).contains(hashes.count) else { return nil }
        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let body = line.trimmingCharacters(in: .whitespaces)
        guard let marker = body.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        guard body.allSatisfy({ $0 == marker || $0 == " " }) else { return false }
        return body.filter { $0 == marker }.count >= 3
    }

    private static func isQuote(_ line: String) -> Bool {
        let body = line.drop(while: { $0 == " " })
        return line.count - body.count <= 3 && body.first == ">"
    }

    private static func strippingQuote(_ line: String) -> String {
        var body = line.drop(while: { $0 == " " }).dropFirst()
        if body.first == " " {
            body = body.dropFirst()
        }
        return String(body)
    }

    // MARK: - Lists

    private struct RawListItem {
        var indent: Int
        var marker: AgentMarkdownListItem.Marker
        var text: String
    }

    private static func listItem(_ line: String) -> RawListItem? {
        let expanded = expandingTabs(line)
        let indent = expanded.prefix(while: { $0 == " " }).count
        let body = expanded.dropFirst(indent)
        guard let first = body.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            // `**bold**` opens a paragraph, not a bullet — a marker needs a space after it.
            guard rest.isEmpty || rest.first == " " else { return nil }
            return RawListItem(
                indent: indent,
                marker: .bullet,
                text: String(rest.drop(while: { $0 == " " }))
            )
        }

        let digits = body.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return RawListItem(
            indent: indent,
            marker: .ordered(String(digits) + String(delimiter)),
            text: String(rest.drop(while: { $0 == " " }))
        )
    }

    private static func parseList(_ lines: [String], _ index: inout Int) -> [AgentMarkdownListItem] {
        var items: [AgentMarkdownListItem] = []
        // Indentation columns seen so far; the stack's depth is the item's nesting level,
        // so a list indented by 2, 3, or 4 spaces nests the same way.
        var indents: [Int] = []

        while index < lines.count {
            let line = lines[index]

            if isBlank(line) {
                let next = lines[(index + 1)...].first { !isBlank($0) }
                guard let next, listItem(next) != nil else { break }
                index += 1
                continue
            }

            if isThematicBreak(line) || fence(line) != nil || heading(line) != nil {
                break
            }

            guard let raw = listItem(line) else {
                // A wrapped continuation line belongs to the item above it.
                guard let last = items.indices.last, indentWidth(line) >= 2 else { break }
                items[last].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                index += 1
                continue
            }

            while let last = indents.last, raw.indent < last {
                indents.removeLast()
            }
            if indents.last.map({ raw.indent > $0 }) ?? true {
                indents.append(raw.indent)
            }

            let (task, text) = checkbox(raw.text)
            items.append(
                AgentMarkdownListItem(
                    depth: max(0, indents.count - 1),
                    marker: raw.marker,
                    task: task,
                    text: text
                )
            )
            index += 1
        }

        return items
    }

    private static func checkbox(_ text: String) -> (AgentMarkdownListItem.Task?, String) {
        let marks: [(String, AgentMarkdownListItem.Task)] = [
            ("[ ]", .unchecked),
            ("[x]", .checked),
            ("[X]", .checked),
        ]
        for (mark, task) in marks where text.hasPrefix(mark) {
            let rest = text.dropFirst(mark.count)
            guard rest.isEmpty || rest.first == " " else { continue }
            return (task, String(rest.drop(while: { $0 == " " })))
        }
        return (nil, text)
    }

    // MARK: - Tables

    private static func tableStarts(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        return columns(delimiter: lines[index + 1]) != nil
    }

    private static func parseTable(_ lines: [String], _ index: inout Int) -> AgentMarkdownTable {
        let header = cells(lines[index])
        var columns = self.columns(delimiter: lines[index + 1]) ?? []
        if columns.count < header.count {
            columns += Array(repeating: .leading, count: header.count - columns.count)
        }
        columns = Array(columns.prefix(max(header.count, 1)))
        index += 2

        var rows: [[String]] = []
        while index < lines.count, !isBlank(lines[index]), lines[index].contains("|") {
            var row = cells(lines[index])
            if row.count < header.count {
                row += Array(repeating: "", count: header.count - row.count)
            }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }

        return AgentMarkdownTable(header: header, columns: columns, rows: rows)
    }

    private static func columns(delimiter line: String) -> [AgentMarkdownTable.Column]? {
        let cells = cells(line)
        guard !cells.isEmpty else { return nil }
        var columns: [AgentMarkdownTable.Column] = []
        for cell in cells {
            let leading = cell.hasPrefix(":")
            let trailing = cell.count > 1 && cell.hasSuffix(":")
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            columns.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return columns
    }

    private static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") {
            body.removeFirst()
        }
        if body.hasSuffix("|") {
            body.removeLast()
        }
        guard !body.isEmpty else { return [] }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Line helpers

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isList(_ block: AgentMarkdownBlock?) -> Bool {
        if case .list = block { return true }
        return false
    }

    private static func indentWidth(_ line: String) -> Int {
        expandingTabs(line).prefix(while: { $0 == " " }).count
    }

    private static func expandingTabs(_ line: String) -> String {
        line.contains("\t") ? line.replacingOccurrences(of: "\t", with: "    ") : line
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var body = Substring(line)
        while let last = body.last, last == " " || last == "\t" {
            body = body.dropLast()
        }
        return String(body)
    }
}

/// Inline spans — emphasis, inline code, links, strikethrough — as attributes rather than
/// punctuation. Source the parser could not read comes back as its own characters, so a
/// half-written stream is never blanked out.
enum AgentMarkdownInline {
    static func attributed(
        _ source: String,
        codeStyle: Font.TextStyle = .body,
        fileLinks: AgentFileLinks = .none
    ) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        // A written link to a path stays a link only while the path resolves. A dead
        // link is worse than plain text: it offers a return path to evidence that is
        // not there.
        let written = attributed.runs.compactMap { run in
            run.link.map { (run.range, $0) }
        }
        for (range, url) in written where !isRemote(url) {
            let path = url.scheme == nil ? url.absoluteString : url.path
            attributed[range].link = fileLinks.url(for: path)
        }

        let code = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in code {
            attributed[range].font = .system(codeStyle, design: .monospaced)
            guard attributed[range].link == nil else { continue }
            let span = String(attributed[range].characters)
            // The path an agent typed in backticks is how it cites a file. Linking the
            // span that already resolves is the return path from a claim to its source.
            // An address gets the same treatment: backticks are punctuation, not a reason
            // for the same URL to be live in one sentence and dead in the next.
            attributed[range].link = fileLinks.url(for: span) ?? webAddress(span)
        }
        return attributed
    }

    /// The absolute web address a span names, or nil when it names anything else. Only a
    /// scheme this app is willing to hand to the system counts, so a code span is never
    /// linked on the strength of looking vaguely like a location.
    private static func webAddress(_ span: String) -> URL? {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func isRemote(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "file"
    }
}
