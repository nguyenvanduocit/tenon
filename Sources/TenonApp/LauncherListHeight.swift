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

    /// Which way a launcher's list grows away from the control that opened it.
    enum Opening {
        /// The popover hangs below its anchor, so the room is between the anchor's bottom
        /// edge and the bottom of the screen.
        case below
        /// The popover rises above its anchor, so the room is between the anchor's top edge
        /// and the top of the screen.
        case above
    }

    /// The tallest a list may grow before it must start scrolling: the room actually left on
    /// the screen in the direction the popover opens.
    ///
    /// The direction is a parameter because the anchor is not always near the top of the
    /// window. A tab strip drawn at the foot opens its launcher upward, and so does nothing
    /// else in the shell — measuring downward from the window's top edge there would claim a
    /// whole window's worth of room that is not on the screen at all.
    ///
    /// The floor of 140 is the point below which a list stops being a list: fewer than three
    /// rows and a person is scrolling to read what they asked for.
    static func ceiling(
        anchor: CGRect,
        opening: Opening,
        visibleFrame: CGRect,
        chrome: CGFloat
    ) -> CGFloat {
        let room: CGFloat
        switch opening {
        case .below: room = anchor.minY - visibleFrame.minY
        case .above: room = visibleFrame.maxY - anchor.maxY
        }
        return max(140, room - chrome)
    }

    /// Which way a launcher whose anchor can land anywhere on screen should open: whichever
    /// side actually has more room.
    ///
    /// A tab strip or the title-bar `+` can state its direction outright because its own
    /// position is fixed — always at the window's head or foot. An empty-grid click has no
    /// such fixed position: it can land one row from the top of a tall canvas or one row
    /// from the bottom, and only the click itself knows which. Asking for `.below` there
    /// unconditionally leaves the popover's actual placement (AppKit still flips it to fit
    /// the screen) disagreeing with the room this measures for it — the list gets clamped to
    /// the cramped side's room while the popover has already opened into the roomy one.
    static func opening(for anchor: CGRect, in visibleFrame: CGRect) -> Opening {
        let roomBelow = anchor.minY - visibleFrame.minY
        let roomAbove = visibleFrame.maxY - anchor.maxY
        return roomBelow >= roomAbove ? .below : .above
    }
}
