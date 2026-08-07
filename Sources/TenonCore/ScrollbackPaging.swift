// @domain: terminal-surface
import Foundation

/// The paging rule behind `terminal.scrollback.read.v1`, kept as a pure function of
/// (how many rows the pane retains, how many the caller wants, where they left off) so
/// every case is assertable without a terminal, a window, or a run loop.
///
/// Rows are addressed by position from the oldest retained row. The emulator exposes no
/// stable per-row identity — when the buffer evicts from the top, every earlier position
/// shifts underneath a caller who is midway through reading. There is therefore no way to
/// prove a position still means the row it meant, so the cursor carries the row count it
/// was issued against and **any change to that count invalidates it**. Restarting is worse
/// than nothing only if the alternative is correct; silently skipping the middle of a
/// command's output is not.
public enum ScrollbackPaging {
    /// Where the next page starts, and the scrollback size that made that number mean
    /// something. Purely a value: the host keeps nothing when a caller drops one.
    public struct Cursor: Equatable, Sendable {
        public let nextRow: Int
        public let totalRows: Int

        public init(nextRow: Int, totalRows: Int) {
            self.nextRow = nextRow
            self.totalRows = totalRows
        }

        public var encoded: String { "\(nextRow):\(totalRows)" }

        /// Rejects anything this type did not write. A caller cannot widen its own read by
        /// handing back a negative row, a reversed pair, or a third field.
        public static func decode(_ raw: String) -> Cursor? {
            let parts = raw.split(
                separator: ":",
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  let nextRow = Int(parts[0]),
                  let totalRows = Int(parts[1]),
                  nextRow >= 0,
                  totalRows >= 0,
                  nextRow <= totalRows
            else { return nil }
            return Cursor(nextRow: nextRow, totalRows: totalRows)
        }
    }

    public enum Page: Equatable, Sendable {
        /// Rows to read, half-open and oldest first, and the cursor that continues after
        /// them. A `nil` next cursor means the page reached the newest row; an empty range
        /// with a `nil` cursor means there was nothing left to read.
        case rows(Range<Int>, next: Cursor?)

        /// The scrollback changed size since this cursor was issued, so its positions can
        /// no longer be trusted. The caller starts again from the oldest retained row.
        case invalidated
    }

    /// - Parameters:
    ///   - totalRows: rows the pane retains right now, scrollback included.
    ///   - maxLines: the caller's page size; clamped to at least one row.
    ///   - cursor: `nil` starts at the oldest retained row.
    public static func page(
        totalRows: Int,
        maxLines: Int,
        cursor: Cursor?
    ) -> Page {
        let total = max(totalRows, 0)
        let limit = max(maxLines, 1)

        let start: Int
        if let cursor {
            guard cursor.totalRows == total else { return .invalidated }
            start = cursor.nextRow
        } else {
            start = 0
        }

        guard start < total else {
            return .rows(start ..< start, next: nil)
        }
        let end = min(start + limit, total)
        let next = end < total
            ? Cursor(nextRow: end, totalRows: total)
            : nil
        return .rows(start ..< end, next: next)
    }
}
