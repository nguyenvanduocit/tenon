// @domain: workspace-model
import Foundation

/// The widest a pane may become through automatic layout, chosen once in Settings and
/// applied by every path that opens one and by close-time absorption. The creation-oriented
/// type name is retained because it is already threaded through every creation API; its
/// value now also governs the one automatic resize that follows an actual close.
///
/// This is not a lock on the pane. The person drags its borders afterwards exactly as
/// before, and changing the preference by itself never moves a pane that already exists.
/// Automatic layout reads the current value when it creates a pane or gives released width
/// to a surviving pane.
///
/// The width vocabulary is the canvas's own `SpatialExtentFraction`: the same three
/// destinations the pane border's contextual menu offers, so Settings and the border name
/// a pane width the same way instead of this feature inventing a second unit. Naming the
/// sizes rather than counting columns is also what keeps an unusable layout out of the
/// preference: every fraction of the canvas is at least `SpatialLayout.minimumWidth` wide,
/// so no stored value describes a pane too narrow to exist, and a value the current build
/// cannot name decodes back to `unlimited`. There is no range to validate at the edge.
public struct NewPaneSizing: Equatable, Sendable {
    /// Automatic layout bounded only by the space it offers — what Tenon does when the
    /// preference is unset, and the default wherever a caller supplies no policy.
    public static let unlimited = NewPaneSizing(maximumWidth: nil)

    public let maximumWidth: SpatialExtentFraction?

    public init(maximumWidth: SpatialExtentFraction?) {
        self.maximumWidth = maximumWidth
    }

    /// The maximum in canvas columns, or nil while automatic layout is unbounded. Floored at
    /// `SpatialLayout.minimumWidth`, so a fraction can only ever ask for a pane the layout
    /// accepts — without the floor a vocabulary or canvas change lands as a `Tab.init`
    /// precondition crash at the moment a pane is created. That the floor never has to
    /// fire is a separate claim, asserted on the fractions themselves by
    /// `testEveryFractionOfTheCanvasIsAtLeastAUsablePaneWide`.
    public var maximumColumns: Int? {
        maximumWidth.map {
            max(SpatialLayout.minimumWidth, $0.extent(of: SpatialLayout.columns))
        }
    }

    /// `candidate` narrowed to the maximum.
    ///
    /// The layout has already decided how much room a new pane may have; this only takes
    /// width back off that answer, so the result respects the space available *and* the
    /// person's maximum, and a candidate that is already narrow enough is returned
    /// untouched.
    ///
    /// `keeping` names the cell someone pointed at on empty canvas. That cell designates
    /// its own region, so the narrowed pane *begins* there and slides left only far enough
    /// to stay inside the region it came from — never snapping to the region's leading edge
    /// and opening away from the pointer. Without a cell the result keeps the candidate's
    /// leading edge. Either way the width given up stays empty canvas.
    public func fitting(_ candidate: GridRect, keeping column: Int? = nil) -> GridRect {
        guard let maximum = maximumColumns, candidate.width > maximum else { return candidate }

        var x = candidate.x
        if let column, column >= candidate.x, column < candidate.x + candidate.width {
            x = min(column, candidate.x + candidate.width - maximum)
        }

        return GridRect(
            x: x,
            y: candidate.y,
            width: maximum,
            height: candidate.height
        )
    }
}
