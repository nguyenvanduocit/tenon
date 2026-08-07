// @domain: editor-and-diff
import Foundation

/// A diff row's identity, derived from the line numbers the row shows rather than
/// from where it sits in the list.
///
/// This exists because the renderer is lazy. A lazy container builds and discards
/// rows as they scroll, and it decides what to reuse from `Identifiable`. Keying on
/// a position (`enumerated().offset`) means every row below a change gets a new
/// identity whenever anything above it moves, so a reload rebuilds the whole list.
/// A line number is a property of the content: an edit elsewhere in the file leaves
/// it alone.
///
/// `old`/`new` are 1-based, `0` meaning "this row has no line on that side".
/// Uniqueness follows from the alignment: `LineDiff` gives every old line at most
/// one row and every new line at most one row, so `(kind, old, new)` cannot repeat
/// within a diff.
public struct DiffRowID: Hashable, Sendable {
    public enum Kind: UInt8, Sendable { case header, context, added, removed, pair }

    public let kind: Kind
    public let old: Int
    public let new: Int

    public init(kind: Kind, old: Int, new: Int) {
        self.kind = kind
        self.old = old
        self.new = new
    }
}

/// One drawable row of a diff: a hunk header, a unified line, or a side-by-side
/// pair. Flattening (hunks × lines) into a single list is what lets the shell hand
/// the whole diff to a lazy container and pay only for the rows on screen.
public struct DiffRow: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// The `@@ -a,b +c,d @@` address line that opens a hunk.
        case header(String)
        /// Unified style: one line, its sign already implied by `kind`.
        case line(DiffLine)
        /// Split style: the two sides of one row. Either side may be absent — that
        /// is the pairing gap left when one side of a change is longer.
        case pair(left: DiffLine?, right: DiffLine?)
    }

    public let id: DiffRowID
    /// Which hunk this row belongs to, so the shell can group without re-deriving it.
    public let hunkIndex: Int
    public let content: Content

    public init(id: DiffRowID, hunkIndex: Int, content: Content) {
        self.id = id
        self.hunkIndex = hunkIndex
        self.content = content
    }

    public var isHeader: Bool {
        if case .header = content { return true }
        return false
    }
}

/// Pure projection from `LineDiff`'s hunks to the flat row list the diff pane
/// scrolls. No AppKit/SwiftUI (Invariant 3): unified order, side-by-side pairing,
/// pairing gaps, row identity, and column sizing are all value transforms, asserted
/// in `DiffRowsTests` without a window.
public enum DiffRows {
    // MARK: - Flattening

    /// Unified style: each hunk's header followed by its lines, in diff order.
    public static func unified(_ hunks: [DiffHunk]) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for (index, hunk) in hunks.enumerated() {
            rows.append(headerRow(hunk, hunkIndex: index))
            for line in hunk.lines {
                rows.append(
                    DiffRow(id: id(of: line), hunkIndex: index, content: .line(line))
                )
            }
        }
        return rows
    }

    /// Split style: each hunk's header followed by its paired rows.
    public static func split(_ hunks: [DiffHunk]) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for (index, hunk) in hunks.enumerated() {
            rows.append(headerRow(hunk, hunkIndex: index))
            for pair in paired(hunk.lines) {
                rows.append(
                    DiffRow(
                        id: DiffRowID(
                            kind: .pair,
                            old: pair.left?.oldNumber ?? 0,
                            new: pair.right?.newNumber ?? 0
                        ),
                        hunkIndex: index,
                        content: .pair(left: pair.left, right: pair.right)
                    )
                )
            }
        }
        return rows
    }

    /// Pairs a hunk's lines for side-by-side view: a run of removals aligns with the
    /// run of additions that follows it, context sits on both sides, and the longer
    /// side of an uneven change leaves a gap opposite it.
    public static func paired(_ lines: [DiffLine]) -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(left: DiffLine?, right: DiffLine?)] = []
        var index = 0
        while index < lines.count {
            switch lines[index].kind {
            case .context:
                rows.append((lines[index], lines[index]))
                index += 1
            case .removed:
                var removed: [DiffLine] = []
                while index < lines.count, lines[index].kind == .removed {
                    removed.append(lines[index])
                    index += 1
                }
                var added: [DiffLine] = []
                while index < lines.count, lines[index].kind == .added {
                    added.append(lines[index])
                    index += 1
                }
                for offset in 0..<Swift.max(removed.count, added.count) {
                    rows.append(
                        (
                            offset < removed.count ? removed[offset] : nil,
                            offset < added.count ? added[offset] : nil
                        )
                    )
                }
            case .added:
                while index < lines.count, lines[index].kind == .added {
                    rows.append((nil, lines[index]))
                    index += 1
                }
            }
        }
        return rows
    }

    // MARK: - Column sizing

    /// One text column of the rendered diff.
    public enum Column: Sendable { case unified, left, right }

    /// The `limit` widest lines in a column, widest first.
    ///
    /// A lazy container only measures the rows it actually builds, so it cannot tell
    /// the scroll view how wide the content is — the widest line may be a thousand
    /// rows below the viewport. Core picks the candidates by display width; the shell
    /// measures just these few with the real font and sizes the column from them.
    /// A handful of candidates rather than one because a cell count is an
    /// approximation of what a font finally draws.
    public static func widestTexts(_ rows: [DiffRow], column: Column, limit: Int = 4) -> [String] {
        guard limit > 0 else { return [] }
        var measured: [(text: String, width: Int)] = []
        for row in rows {
            guard let text = text(of: row, column: column) else { continue }
            measured.append((text, displayWidth(text)))
        }
        return measured
            .sorted { $0.width > $1.width }
            .prefix(limit)
            .map(\.text)
    }

    /// Width of a string in monospaced cells: East Asian wide and emoji graphemes
    /// take two, everything else one. Ranking by `count` alone would call eight
    /// ASCII characters wider than five han characters, which is backwards in the
    /// font this pane actually renders with.
    public static func displayWidth(_ text: String) -> Int {
        var width = 0
        for character in text {
            width += isWide(character) ? 2 : 1
        }
        return width
    }

    /// The largest line number any row shows, so the gutter is exactly as wide as it
    /// needs to be. Never below 1: a gutter is at least one digit wide.
    public static func maxLineNumber(_ hunks: [DiffHunk]) -> Int {
        hunks.reduce(1) { running, hunk in
            hunk.lines.reduce(running) {
                Swift.max($0, Swift.max($1.oldNumber ?? 0, $1.newNumber ?? 0))
            }
        }
    }

    // MARK: - Internals

    private static func headerRow(_ hunk: DiffHunk, hunkIndex: Int) -> DiffRow {
        DiffRow(
            id: DiffRowID(kind: .header, old: hunk.oldStart, new: hunk.newStart),
            hunkIndex: hunkIndex,
            content: .header(hunk.header)
        )
    }

    private static func id(of line: DiffLine) -> DiffRowID {
        let kind: DiffRowID.Kind
        switch line.kind {
        case .context: kind = .context
        case .added: kind = .added
        case .removed: kind = .removed
        }
        return DiffRowID(kind: kind, old: line.oldNumber ?? 0, new: line.newNumber ?? 0)
    }

    private static func text(of row: DiffRow, column: Column) -> String? {
        switch (row.content, column) {
        case (.line(let line), .unified): return line.text
        case (.pair(let left, _), .left): return left?.text
        case (.pair(_, let right), .right): return right?.text
        default: return nil
        }
    }

    /// East Asian Wide/Fullwidth blocks plus the emoji planes — the graphemes a
    /// monospaced font draws at double advance.
    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,      // Kana through CJK compatibility
             0x3400...0x4DBF,      // CJK extension A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE10...0xFE19,      // Vertical forms
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // Fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,    // Emoji
             0x1F900...0x1F9FF,
             0x20000...0x3FFFD:    // CJK extension B and beyond
            return true
        default:
            return false
        }
    }
}
