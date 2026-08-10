// @domain: workspace-model
import Foundation

/// One tab chip's horizontal extent, in whatever coordinate space the strip reports its
/// chips and its pointer in. Only the axis the strip runs along matters, so the vertical
/// half of the chip's frame never reaches this rule.
public struct TabChipExtent: Equatable, Sendable {
    public let id: UUID
    public let minX: Double
    public let maxX: Double

    public init(id: UUID, minX: Double, maxX: Double) {
        self.id = id
        self.minX = minX
        self.maxX = maxX
    }

    public var midX: Double { (minX + maxX) / 2 }
}

/// What a click on the strip means: the chip it landed on, and whether it landed on that
/// chip's close control rather than its body.
public enum TabPress: Equatable, Sendable {
    case select(UUID)
    case close(UUID)
}

/// Where a tab dragged along the strip would land.
///
/// The rule is deliberately whole-value: it takes the chips as they are displayed and a
/// pointer position, and answers with an *insertion boundary* first and an array index
/// second. Those are different numbers — inserting at boundary 3 in a five-tab strip moves
/// the dragged tab to index 2 when it came from the left of that boundary and index 3 when
/// it came from the right — and conflating them is how a reorder lands one place off.
///
/// Nothing here knows about SwiftUI, AppKit, or the pasteboard. The gesture that feeds it is
/// an ordinary pointer drag inside one window's tab strip: the tab never travels on a
/// pasteboard, never leaves the strip that started it, and therefore has no path into
/// another workspace, another window, or another application to refuse.
public enum TabReorder {
    /// How far outside the strip a pointer may stray and still mean a reorder.
    ///
    /// Vertical distance is the only cancel a pointer drag can express, because horizontally
    /// the strip owns every x — a tab dragged past either end means that end. Past this
    /// band the gesture was aimed somewhere else: a tab pulled down into the canvas is a
    /// person changing their mind, not a request to move it to the far end.
    public static let dropSlack: Double = 44

    /// Which tab a press at `pointerX` picked up, or `nil` when it landed on no chip — the
    /// `+` button, or the empty stretch past the last tab.
    public static func tab(at pointerX: Double, chips: [TabChipExtent]) -> UUID? {
        chips.first { pointerX >= $0.minX && pointerX <= $0.maxX }?.id
    }

    /// What a press that never travelled far enough to be a reorder asked for.
    ///
    /// The strip owns its whole primary-button stream — a press it hands to the window
    /// server would move the window instead of the tab — so the click a chip's button used
    /// to answer is resolved here, from the same laid-out geometry the drag reads.
    public static func press(
        at pointerX: Double,
        chips: [TabChipExtent],
        closeControls: [UUID: ClosedRange<Double>]
    ) -> TabPress? {
        guard let id = tab(at: pointerX, chips: chips) else { return nil }
        if let control = closeControls[id], control.contains(pointerX) { return .close(id) }
        return .select(id)
    }

    /// Whether a release at `pointerY` — measured in the strip's own space, where `0` is its
    /// top edge — still means the strip.
    public static func admitsDrop(pointerY: Double, stripHeight: Double) -> Bool {
        pointerY >= -dropSlack && pointerY <= stripHeight + dropSlack
    }

    /// The gap a drop at `pointerX` means: `0` before the first chip, `chips.count` after
    /// the last, and otherwise the number of chips whose midpoint the pointer has passed.
    ///
    /// Counting midpoints rather than measuring the space between chips is what makes the
    /// preview feel continuous: every point on the strip belongs to exactly one gap, so the
    /// caret never blanks out while the pointer is over a chip — which is most of the strip.
    public static func insertionIndex(at pointerX: Double, chips: [TabChipExtent]) -> Int {
        chips.count { $0.midX < pointerX }
    }

    /// The array index `id` lands on, or `nil` when the drop changes nothing.
    ///
    /// `nil` covers all three refusals the strip must make, with one answer: a tab this
    /// strip is not showing, an insertion boundary outside the strip, and a drop that means
    /// the position the tab is already in — dropping on either side of itself.
    public static func destination(
        forTab id: UUID,
        insertingAt insertion: Int,
        chips: [TabChipExtent]
    ) -> Int? {
        guard let source = chips.firstIndex(where: { $0.id == id }) else { return nil }
        guard insertion >= 0, insertion <= chips.count else { return nil }
        guard insertion != source, insertion != source + 1 else { return nil }
        return insertion > source ? insertion - 1 : insertion
    }

    /// Where the strip draws the one insertion caret: the midpoint of the gap, and the strip
    /// edge itself at either end so the caret never floats in the padding.
    public static func caretX(forInsertion insertion: Int, chips: [TabChipExtent]) -> Double? {
        guard insertion >= 0, insertion <= chips.count, let first = chips.first,
              let last = chips.last
        else { return nil }
        if insertion == 0 { return first.minX }
        if insertion == chips.count { return last.maxX }
        return (chips[insertion - 1].maxX + chips[insertion].minX) / 2
    }

    /// What VoiceOver says after a tab moved. Written here rather than at the call site so
    /// the sentence is asserted without a window, and so the drag and the custom action
    /// announce the same move in the same words.
    public static func announcement(title: String, movedTo index: Int, of count: Int) -> String {
        "Moved \(title) to tab \(index + 1) of \(count)"
    }

    /// What VoiceOver reads as a chip's value, so a tab's place in the strip is audible
    /// before and after a move rather than only inferable from reading order.
    public static func spokenPosition(_ index: Int, of count: Int, isActive: Bool) -> String {
        let place = "tab \(index + 1) of \(count)"
        return isActive ? "\(place), active" : place
    }
}
