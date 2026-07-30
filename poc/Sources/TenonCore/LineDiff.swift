import Foundation

/// A single aligned line in a diff. `.context` lines exist on both sides (both
/// numbers set); `.added` lines exist only on the new side (`oldNumber == nil`);
/// `.removed` lines exist only on the old side (`newNumber == nil`). 1-based.
public enum DiffLineKind: Equatable, Sendable { case context, added, removed }

public struct DiffLine: Equatable, Sendable {
    public let kind: DiffLineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(kind: DiffLineKind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

/// A contiguous run of change plus its surrounding context, addressed like a
/// unified-diff `@@` header. The renderer draws one of these per gap-separated
/// region so an unchanged 10k-line file with a two-line edit paints two hunks,
/// not ten thousand rows.
public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

/// Pure line-level diff via Myers' O(ND) shortest-edit-script algorithm — the same
/// core git and most diff tools use. No AppKit/SwiftUI (Invariant 3): the whole
/// rule is a value transform, asserted in `LineDiffTests` without a window.
public enum LineDiff {
    /// The full aligned line sequence in unified order.
    public static func lines(old: String, new: String) -> [DiffLine] {
        myers(splitLines(old), splitLines(new))
    }

    /// Added/removed line counts (the `+N -M` summary), ignoring context. Summarises
    /// a diff already in hand: every changed line lands in exactly one hunk, so the
    /// counts are the same as over the full alignment — without paying for a second
    /// pass through the edit-script search.
    public static func stat(_ hunks: [DiffHunk]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in hunks.lazy.flatMap(\.lines) {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .context: break
            }
        }
        return (added, removed)
    }

    /// Groups the aligned lines into hunks with `context` unchanged lines around
    /// each change; runs of unchanged lines longer than that collapse away, and
    /// changes closer than `2 * context` merge into one hunk.
    public static func hunks(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        let all = lines(old: old, new: new)
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        var ranges: [(lo: Int, hi: Int)] = []
        for i in changed {
            let lo = Swift.max(0, i - context)
            let hi = Swift.min(all.count - 1, i + context)
            if let last = ranges.last, lo <= last.hi + 1 {
                ranges[ranges.count - 1].hi = Swift.max(last.hi, hi)
            } else {
                ranges.append((lo, hi))
            }
        }

        return ranges.map { range in
            let slice = Array(all[range.lo...range.hi])
            let oldNums = slice.compactMap(\.oldNumber)
            let newNums = slice.compactMap(\.newNumber)
            return DiffHunk(
                oldStart: oldNums.first ?? 0,
                oldCount: oldNums.count,
                newStart: newNums.first ?? 0,
                newCount: newNums.count,
                lines: slice
            )
        }
    }

    // MARK: - Internals

    /// Splits into display lines, treating a single trailing newline as a line
    /// terminator (not a spurious empty final line) while preserving genuine
    /// interior/leading blank lines.
    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func myers(_ a: [String], _ b: [String]) -> [DiffLine] {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return [] }
        let maxD = n + m
        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        var trace: [[Int]] = []

        forward: for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]        // move down = insertion from b
                } else {
                    x = v[offset + k - 1] + 1    // move right = deletion from a
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { break forward }
            }
        }

        // Backtrack the recorded traces into an edit list (built in reverse).
        var edits: [DiffLine] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[offset + prevK]
            let prevY = prevX - prevK

            while x > prevX && y > prevY {
                edits.append(DiffLine(kind: .context, text: a[x - 1], oldNumber: x, newNumber: y))
                x -= 1; y -= 1
            }
            if d > 0 {
                if x == prevX {
                    edits.append(DiffLine(kind: .added, text: b[y - 1], oldNumber: nil, newNumber: y))
                } else {
                    edits.append(DiffLine(kind: .removed, text: a[x - 1], oldNumber: x, newNumber: nil))
                }
                x = prevX; y = prevY
            }
        }
        return edits.reversed()
    }
}
