// @domain: pane-chrome
import Foundation

/// The optional name a person pins to a pane.
///
/// Pane identity remains its UUID; this value only replaces the content-derived label in
/// chrome. Returning `nil` for blank input is intentional: clearing Rename restores the
/// automatic terminal/file/plugin title instead of persisting an empty label.
public enum PaneTitle {
    public static let maximumLength = 60

    public static func sanitized(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}
