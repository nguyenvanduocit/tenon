// @domain: command-surface
import CoreGraphics

/// The height the launcher's result list actually needs, stated rather than offered.
///
/// A `ScrollView` handed `.frame(maxHeight:)` inside a popover is greedy: offered a
/// screen's worth of height it takes all of it, floating ten rows in a screen-tall
/// sheet of chrome. So the list's height is computed here — rows, separators, padding —
/// and clamped by the ceiling; scrolling begins only when the rows genuinely outgrow
/// the screen. `LauncherMenu` draws with these same constants, so the rule and the
/// pixels cannot drift apart.
enum LauncherListHeight {
    /// One compact row, exactly as `PaletteRowChrome` draws it — ranked, appended, or
    /// the fixed Copy Tab ID utility, since all three are drawn by that one chrome.
    static let row: CGFloat = PaletteRowChrome.Density.compact.height
    /// The 1-pt rule between sections.
    static let separatorRule: CGFloat = 1
    /// The rule's top and bottom padding.
    static let separatorPadding: CGFloat = 4
    /// The list's own top and bottom padding.
    static let listPadding: CGFloat = 5

    static func height(rows: Int, sections: Int, ceiling: CGFloat) -> CGFloat {
        let content = CGFloat(rows) * row
            + CGFloat(max(0, sections - 1)) * (separatorRule + separatorPadding * 2)
            + listPadding * 2
        return min(content, ceiling)
    }
}
