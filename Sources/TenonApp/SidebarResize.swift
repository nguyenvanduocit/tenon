// @domain: workspace-model
import CoreGraphics

/// Pure geometry for the resizable workspace sidebar.
///
/// The shell drives this from a drag gesture on the divider; the rule — clamp the
/// width within `[minWidth, maxWidth]`, and once the pointer pulls it narrower than
/// `minWidth` collapse the sidebar to its icon rail instead of shrinking further —
/// lives here so it can be asserted in `TenonAppStateTests` without a window.
enum SidebarResize {
    /// The persistent icon rail shown while the full sidebar is collapsed.
    static let collapsedWidth: CGFloat = 48
    /// Width the sidebar opens at, and the width it restores to after a re-open.
    static let defaultWidth: CGFloat = 232
    /// Narrowest the expanded sidebar remains: a workspace row is down to its icon and a
    /// clipped name. Drag below this and the sidebar becomes the icon rail.
    static let minWidth: CGFloat = 110
    static let maxWidth: CGFloat = 480

    enum Outcome: Equatable {
        /// Keep the sidebar open at this clamped width.
        case resize(CGFloat)
        /// The drag went narrower than the expanded rows — show the icon rail.
        case collapse
    }

    /// Width mounted by the shell. Collapsing preserves a useful navigation rail instead
    /// of removing the sidebar and shifting every workspace affordance off-screen.
    static func renderedWidth(isExpanded: Bool, expandedWidth: CGFloat) -> CGFloat {
        isExpanded ? expandedWidth : collapsedWidth
    }

    /// Resolve a proposed drag width into the width to render, or a collapse.
    static func resolve(proposedWidth: CGFloat) -> Outcome {
        if proposedWidth < minWidth {
            return .collapse
        }
        return .resize(min(proposedWidth, maxWidth))
    }
}
