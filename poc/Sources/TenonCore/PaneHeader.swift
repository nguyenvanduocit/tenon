// @domain: pane-chrome, plugin-contributions
import Foundation

/// What one pane contributes into the ONE chrome header the card draws.
///
/// TWO slots, not three. `leading` and `trailing` earn their names from genuinely different
/// layout rules — opposite pack direction, opposite drop order, and only one of them may hold
/// the flexible item. A third `actions` slot would render identically to the tail of
/// `trailing` and carry no distinct layout, drop-order, or hit-test rule; two names for one
/// operation is exactly the shape invariant 6 forbids. Order inside `trailing` — status first,
/// verbs last — IS the "actions zone", expressed as position instead of as a second name.
///
/// There is deliberately no `title` slot. The pane's name is host chrome and content may not
/// replace it; restating the title is precisely what the panes that drew their own second
/// header row were doing. Deleting the slot deletes a whole class of precedence rules before
/// anyone has to write them.
///
/// The header is presentation the host owns end to end: its owner declares which items exist
/// and what they say, and the host decides how they are measured, folded, drawn, hit-tested
/// and cursored. That division is what lets one value serve a built-in pane writing typed
/// Swift and a plugin publishing JSON without either becoming a second protocol.
///
/// It is also the whole reason a contributor never needs a chrome bar of its own. A browser's
/// back/forward/reload buttons and its address field are the vocabulary below — three
/// `iconButton`s and a `textfield` — so the host paints Safari-grade chrome from a published
/// value, while every control routes back through the view's own `onSelect`/`onSubmit` and the
/// plugin keeps all of its navigation logic and URL resolution. No plugin sees a native type
/// (invariant 2), and there is one way to draw a pane's chrome rather than one per kind of
/// pane (invariant 6).
///
/// This initialiser is where the vocabulary's bounds are actually applied — see
/// `PaneHeaderItem.bounded()`. Both producers reach their header through it, so a built-in
/// Swift pane cannot publish a 400-character label that a plugin would have been clamped out
/// of (invariant 10).
public struct PaneHeader: Sendable, Hashable {
    public static let maximumLeadingItems = 5
    public static let maximumTrailingItems = 8
    public static let empty = PaneHeader()

    /// Packs left-to-right from the title origin: identity and state.
    public let leading: [PaneHeaderItem]
    /// Packs right-to-left from the close button: measurements and controls.
    public let trailing: [PaneHeaderItem]

    /// The header a producer gets, and every item it wrote that is not in it.
    ///
    /// Admission exists as a value because a decoder has to be able to SAY what happened. A
    /// contributor is promised one sentence per control the host will not draw, and two of the
    /// three ways an item loses its place — an id already spoken for, and a full slot — are
    /// decided here rather than at the JSON boundary. Returning them keeps that rule stated
    /// once, in the place that enforces it, instead of restated in a second copy the decoder
    /// would have to keep in step (invariant 6).
    public struct Admission: Sendable, Hashable {
        public let header: PaneHeader
        /// In the order the producer wrote them. Empty is the ordinary case.
        public let refused: [RefusedItem]
    }

    public enum Slot: String, Sendable, Hashable {
        case leading
        case trailing

        /// How many items this slot holds — the number a refusal sentence has to quote.
        public var capacity: Int {
            switch self {
            case .leading: PaneHeader.maximumLeadingItems
            case .trailing: PaneHeader.maximumTrailingItems
            }
        }
    }

    public struct RefusedItem: Sendable, Hashable {
        public let slot: Slot
        public let id: String
        public let reason: Refusal
    }

    /// Why an item its producer wrote is not in the header it published.
    ///
    /// A malformed item — one `PaneHeaderItem.bounded()` refuses outright — is not here: it
    /// never reaches admission, and the boundary that decoded it has already explained it in
    /// the vocabulary of the field the author got wrong.
    public enum Refusal: Sendable, Hashable {
        /// An item admitted before it, in either slot, is already using that id.
        case duplicateID
        /// Its slot was already holding as many items as a header slot may hold.
        case slotIsFull
    }

    /// Bounds each item first, then the slot. Doing it in that order means an item refused for
    /// being malformed never consumes one of the five or eight places a usable item could have
    /// taken.
    ///
    /// Identity is settled here too, across BOTH slots at once, because both ends of the
    /// contract key on the id alone: the renderer draws a run with one
    /// `ForEach(id: \.item.id)`, and a click comes back carrying nothing but an `itemID`. A
    /// second item under an id already spoken for could not be told apart from the first at
    /// either end, so it loses its place — the same answer this vocabulary already gives an
    /// over-long segment value, for the same reason.
    public static func admitting(
        leading: [PaneHeaderItem] = [],
        trailing: [PaneHeaderItem] = []
    ) -> Admission {
        var taken: Set<String> = []
        var refused: [RefusedItem] = []

        func admitted(_ items: [PaneHeaderItem], into slot: Slot) -> [PaneHeaderItem] {
            var kept: [PaneHeaderItem] = []
            for item in items {
                guard let bounded = item.bounded() else { continue }
                guard kept.count < slot.capacity else {
                    refused.append(
                        RefusedItem(slot: slot, id: bounded.id, reason: .slotIsFull)
                    )
                    continue
                }
                guard taken.insert(bounded.id).inserted else {
                    refused.append(
                        RefusedItem(slot: slot, id: bounded.id, reason: .duplicateID)
                    )
                    continue
                }
                kept.append(bounded)
            }
            return kept
        }

        // Leading first, so "already spoken for" always names the earlier of the two slots the
        // way a reader scans the strip.
        let admittedLeading = admitted(leading, into: .leading)
        let admittedTrailing = admitted(trailing, into: .trailing)
        return Admission(
            header: PaneHeader(admitted: admittedLeading, and: admittedTrailing),
            refused: refused
        )
    }

    /// The ordinary way to build one. Everything it drops, it drops for a reason `admitting`
    /// can name — call that instead when there is somewhere to say it.
    public init(leading: [PaneHeaderItem] = [], trailing: [PaneHeaderItem] = []) {
        self = Self.admitting(leading: leading, trailing: trailing).header
    }

    /// The one storing initialiser, reachable only from `admitting`, so no future caller can
    /// put items into a header without passing the rules that admission applies.
    private init(admitted leading: [PaneHeaderItem], and trailing: [PaneHeaderItem]) {
        self.leading = leading
        self.trailing = trailing
    }

    public var isEmpty: Bool { leading.isEmpty && trailing.isEmpty }

    /// The item published under `id`, in whichever slot holds it — `nil` when nothing does.
    ///
    /// The renderer never asks: it is handed placements. A ROUTER does, and that is the whole
    /// reason this exists. A `PaneHeaderAction` carries an `itemID` and nothing else, while
    /// which contract the click travels back on — a selection or a commit — is a property of
    /// the item's KIND. Asking the header what kind it published is how the router answers that
    /// without the action having to carry a second discriminator that every producer would then
    /// have to set correctly.
    public func item(id: String) -> PaneHeaderItem? {
        leading.first { $0.id == id } ?? trailing.first { $0.id == id }
    }

    /// At most one item absorbs slack. It takes the title gap minus the reserved drag band and
    /// suppresses the title. Two address bars in one 34-point strip is not a layout, so the
    /// first claimant wins and every later one is laid out at its natural width.
    public var flexibleItemID: String? {
        (leading + trailing).first(where: \.wantsFlex)?.id
    }
}
