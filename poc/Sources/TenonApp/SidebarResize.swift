// @domain: workspace-model
import CoreGraphics

/// Pure geometry for the resizable workspace sidebar.
///
/// The shell drives this from a drag gesture on the divider; the rule — clamp the
/// width within `[minWidth, maxWidth]`, and once the pointer pulls it narrower than
/// `minWidth` snap the sidebar shut instead of shrinking further — lives here so it
/// can be asserted in `TenonAppTests` without a window.
enum SidebarResize {
    /// Width the sidebar opens at, and the width it restores to after a re-open.
    static let defaultWidth: CGFloat = 232
    /// Narrowest a sidebar stays open: a workspace row is down to its icon and a
    /// clipped name. Drag below this and the sidebar closes.
    static let minWidth: CGFloat = 110
    static let maxWidth: CGFloat = 480

    enum Outcome: Equatable {
        /// Keep the sidebar open at this clamped width.
        case resize(CGFloat)
        /// The drag went narrower than the icons — close the sidebar.
        case collapse
    }

    /// Resolve a proposed drag width into the width to render, or a collapse.
    static func resolve(proposedWidth: CGFloat) -> Outcome {
        if proposedWidth < minWidth {
            return .collapse
        }
        return .resize(min(proposedWidth, maxWidth))
    }
}
