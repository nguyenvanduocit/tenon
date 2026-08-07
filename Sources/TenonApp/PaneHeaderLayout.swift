// @domain: pane-chrome
import AppKit
import TenonCore

/// Header geometry, solved in pure Swift so that hit testing, cursor rects, the drag band and
/// the renderer all read ONE set of rects. This is what turns the card's hardcoded close-button
/// hit-test exemption into data: every hole punched in the pane's drag surface is a solved rect,
/// and the control drawn there is drawn into the same rect.
///
/// Pane-header geometry is exactly the T-055/T-063 defect class — "passes 24 tests and still
/// looks wrong" — so the rule is a pure function asserted without a window. `solve` reads no
/// global, mounts no view, and caches nothing; the same arguments always produce the same
/// `Solution`.
///
/// The vertical band and the two horizontal reservations are *post-conditions*, not hopes.
/// `PaneHeaderLayoutTests` sweeps every width a pane can take and asserts them, because the
/// guarantees the rest of the card stands on — a pane you can always grab, a resize edge you can
/// always reach, a close control nothing can sit under — are all statements about these rects.
enum PaneHeaderLayout {
    /// x < 31 is glyph + attention dot and is NEVER an accessory. A solver post-condition, so
    /// `x ∈ (12, 31)` is provably bare, always-draggable header at every width with any
    /// content — the guarantee the XCUITest press-drag stands on, and the reason a plugin
    /// cannot render its own pane immovable.
    static let accessoryOriginFloor: CGFloat = 31
    /// The bare title band the solver reserves before any accessory is placed. Reserving first
    /// and placing second is what makes the grab surface a layout constraint instead of a
    /// residual.
    static let minimumDragBand: CGFloat = 64
    /// A title stub narrower than this says nothing a reader can use, so once accessories have
    /// taken the room the title is dropped rather than shown as an ellipsis.
    static let minimumTitleWidth: CGFloat = 40
    static let itemSpacing: CGFloat = 6
    /// The floor on the separation between the leading and trailing runs. The drag band only
    /// relaxes to it once nothing is left that could fold; until then `minimumDragBand` holds.
    static let groupGap: CGFloat = 8
    /// Wide enough for the close control's own frame plus the inset it is drawn with, so no
    /// accessory can ever sit under the ✕.
    static let closeButtonReserve: CGFloat = 31
    /// 20 in a 34-point band: 34 − 2 × `verticalInset`. The band is inset top and bottom, so
    /// the height shrinks with the header rather than spilling into the resize edge on a short
    /// card.
    static let accessoryHeight: CGFloat = 20
    static let overflowWidth: CGFloat = 22
    /// A label gives up width down to this before anything folds — the "truncates, never folds"
    /// rule expressed as geometry. Which *end* it gives up is the label's own truncation token,
    /// applied by the renderer, which is the layer that knows how to shorten a path.
    static let minimumLabelWidth: CGFloat = 24
    /// A text field never folds — a menu entry reports one fixed value and cannot accept
    /// typing, so a field has no honest folded form — so it shrinks to this instead.
    static let minimumTextFieldWidth: CGFloat = 48
    /// The share of the card the trailing run may occupy before it starts folding. A run that
    /// eats more than half the header has already eaten the pane's name.
    static let trailingRunShare: CGFloat = 0.55
    /// The north resize edge, mirrored from `SpatialCanvasInteractionCoordinator.hitRegion`:
    /// a point with `y ≤ 6` resizes the pane, whoever else wants it. It is restated here
    /// because the solver has to place *around* it, and asserted against the real function in
    /// `PaneHeaderLayoutTests` so the two cannot drift.
    static let northResizeEdge: CGFloat = 6
    /// The first row of points the resize edge does not claim, applied top and bottom so the
    /// band stays centred. `bandY` is floored from this, so `minY ≥ verticalInset` and
    /// `maxY ≤ headerHeight − verticalInset` follow arithmetically rather than by inspection —
    /// and `minY > northResizeEdge` follows from those, which is the whole point of the
    /// number. At 5 the band began *inside* the edge and a control there ate two of the six
    /// points a user has to grab a pane's top border with.
    static let verticalInset: CGFloat = northResizeEdge + 1
    /// The host's own id for the `…` control. Defined once, on `PaneHeaderItem`, because that
    /// is where the rule refusing it to contributors lives; the solver adds this control
    /// itself, after both runs are settled, so it never passes through `PaneHeader.init` —
    /// which is exactly what lets the id be reserved there without unmaking the host's own.
    static let overflowItemID = PaneHeaderItem.overflowItemID

    /// The chrome the card has always drawn, reproduced here verbatim so an empty header solves
    /// to exactly today's geometry. The glyph column is a fixed width: a longer prompt clips
    /// rather than pushing the attention dot, which is what the card does today.
    private static let glyphOriginX: CGFloat = 9
    private static let glyphColumnWidth: CGFloat = 19
    private static let dotSize: CGFloat = 7
    private static let dotGap: CGFloat = 5

    /// Which of the two AppKit hosts draws a placement. Two hosts with a bare band between them
    /// is what makes the pane's drag surface one contiguous rectangle by construction instead of
    /// a rect subtraction.
    enum Run: Sendable, Equatable {
        case leading, trailing
    }

    struct Placement: Equatable {
        let run: Run
        let item: PaneHeaderItem
        let rect: CGRect
    }

    /// One item the width forced out of its run, together with the entries it contributed to the
    /// overflow menu.
    ///
    /// The pair is the point. Overflow entries speak the *source item's* value space, not the
    /// menu's — a folded `segmented` yields entries valued "tree"/"flat", never "layout" — so a
    /// pick has to be attributed back to the item that folded before it can be reported. Folding
    /// item by item and keeping this association is what makes that possible.
    struct FoldedItem: Equatable {
        let item: PaneHeaderItem
        let entries: [PaneHeaderMenuEntry]

        /// The action a pick of `value` in the overflow menu stands for, or `nil` when the entry
        /// is a read-only line — a folded label or badge is the pane's news, not a control.
        func action(forEntryValue value: String) -> PaneHeaderAction? {
            guard entries.contains(where: { $0.value == value }) else { return nil }
            switch item {
            case .dot, .image, .spinner, .textfield, .label, .badge:
                return nil
            case .iconButton, .toggle:
                return PaneHeaderAction(itemID: item.id)
            case .segmented, .menu:
                return PaneHeaderAction(itemID: item.id, value: value)
            }
        }
    }

    struct Solution: Equatable {
        static let empty = Solution(
            glyphRect: .zero,
            dotRect: nil,
            titleRect: .zero,
            dragBandRect: .zero,
            leadingHostRect: nil,
            trailingHostRect: nil,
            placements: [],
            folded: [],
            overflow: nil
        )

        let glyphRect: CGRect
        let dotRect: CGRect?
        /// `.zero` when a flexible textfield owns the gap, or when accessories left too little
        /// of it to read.
        let titleRect: CGRect
        /// Contiguous, ≥ `minimumDragBand` unless every foldable item is already folded.
        let dragBandRect: CGRect
        let leadingHostRect: CGRect?
        let trailingHostRect: CGRect?
        /// Card-space rects, one per placed item, leading run then trailing run, each in visual
        /// left-to-right order.
        let placements: [Placement]
        /// What folded, in fold order, with the entries each folded item contributed.
        let folded: [FoldedItem]
        /// The `…` control, present only when something with a folded form actually folded.
        let overflow: PaneHeaderItem?

        var interactiveRects: [CGRect] {
            placements.filter { $0.item.isInteractive }.map(\.rect)
        }

        /// The action a pick in the overflow menu stands for. The first folded item claiming the
        /// value wins, which is the same "ids are unique per view" rule the rest of the view
        /// vocabulary already asks of its contributors.
        func overflowAction(forEntryValue value: String) -> PaneHeaderAction? {
            for candidate in folded {
                if let action = candidate.action(forEntryValue: value) { return action }
            }
            return nil
        }
    }

    /// Deterministic. `metrics` is injected so tests solve against fixed widths and the shell
    /// solves against real font metrics — functional core, imperative shell.
    ///
    /// `glyphSize` is consumed for its height only; the glyph column's width is fixed so the
    /// attention dot never moves. The glyph's `y` is left where the card's own `layout()` puts
    /// it before pinning, because the join that lands the glyph and the title on one baseline
    /// needs `firstBaselineOffsetFromTop` from two live `NSTextField`s — a font fact, not a
    /// value the solver can be handed.
    static func solve(
        header: PaneHeader,
        showsDot: Bool,
        titleIdealWidth: CGFloat,
        glyphSize: CGSize,
        titleHeight: CGFloat,
        bounds: CGSize,
        headerHeight: CGFloat,
        metrics: some PaneHeaderMetrics
    ) -> Solution {
        let glyphRect = CGRect(
            x: glyphOriginX,
            y: 0,
            width: glyphColumnWidth,
            height: glyphSize.height
        )
        let dotRect = showsDot
            ? CGRect(
                x: accessoryOriginFloor,
                y: ((headerHeight - dotSize) / 2).rounded(),
                width: dotSize,
                height: dotSize
            )
            : nil
        // The runs start where the title starts today: after the dot when there is one.
        let runOrigin = showsDot
            ? accessoryOriginFloor + dotSize + dotGap
            : accessoryOriginFloor
        let trailingLimit = bounds.width - closeButtonReserve
        let span = trailingLimit - runOrigin
        let titleTop = ((headerHeight - titleHeight) / 2).rounded()
        let bandHeight = min(accessoryHeight, headerHeight - verticalInset * 2)

        /// Today's chrome, unchanged: the title owns the whole span. A pane that contributed
        /// nothing must be pixel-identical to the one that shipped before this vocabulary
        /// existed, at every width — that identity is the migration's receipt.
        func bare() -> Solution {
            Solution(
                glyphRect: glyphRect,
                dotRect: dotRect,
                titleRect: CGRect(
                    x: runOrigin,
                    y: titleTop,
                    width: max(span, 1),
                    height: titleHeight
                ),
                dragBandRect: CGRect(
                    x: runOrigin,
                    y: 0,
                    width: max(span, 0),
                    height: headerHeight
                ),
                leadingHostRect: nil,
                trailingHostRect: nil,
                placements: [],
                folded: [],
                overflow: nil
            )
        }

        // A band too short to draw a single point of control, or a span that cannot hold even
        // the `…` and its minimum separation, is a pane being resized rather than read.
        guard !header.isEmpty, bandHeight >= 1, span >= overflowWidth + groupGap else {
            return bare()
        }

        var leading = header.leading.map { sized($0, metrics: metrics) }
        var trailing = header.trailing.map { sized($0, metrics: metrics) }
        var folded: [FoldedItem] = []
        let trailingCap = bounds.width * trailingRunShare

        // A fold with no folded form (a spinner, a dot) costs nothing extra, so the `…` appears
        // only once something that can be read or picked has left a run.
        func overflowIsPresent() -> Bool { folded.contains { !$0.entries.isEmpty } }
        func leadingFloorWidth() -> CGFloat { runWidth(leading.map(\.floor)) }
        func trailingFloorWidth() -> CGFloat {
            runWidth((overflowIsPresent() ? [overflowWidth] : []) + trailing.map(\.floor))
        }
        // Measured at the floors: folding starts only when even the shrunk widths do not fit.
        func fitsWithBand() -> Bool {
            leadingFloorWidth() + trailingFloorWidth() + minimumDragBand <= span
        }

        // Steps 2 and 3 of the folding rules, re-evaluated in that order every pass because
        // folding a leading item introduces the `…` into the trailing run and can push it back
        // over its share. Each pass removes exactly one item, so the loop is bounded by the
        // item caps the header value type already enforces.
        while true {
            if trailingFloorWidth() > trailingCap,
               let index = foldIndex(in: trailing, fromEnd: false) {
                folded.append(foldedItem(trailing.remove(at: index)))
                continue
            }
            if !fitsWithBand(), let victim = foldVictim(leading: leading, trailing: trailing) {
                switch victim {
                case let .leading(index): folded.append(foldedItem(leading.remove(at: index)))
                case let .trailing(index): folded.append(foldedItem(trailing.remove(at: index)))
                }
                continue
            }
            break
        }

        // Once nothing is left that could fold, the band gives up its reservation rather than
        // clipping a control that has nowhere to go. Everything unfoldable is a text field, and
        // a field shrinks instead.
        let stillFoldable = foldVictim(leading: leading, trailing: trailing) != nil
        let requiredGap = stillFoldable ? minimumDragBand : groupGap
        let overflowItem = overflowIsPresent() ? overflowMenu(folded) : nil

        let survivors = leading + trailing
        let naturals = survivors.map(\.natural)
        var widths = survivors.map(\.floor)
        // Compare against the header's own answer, never against `wantsFlex`: the header
        // resolves leading-then-trailing and grants slack to the first claimant only, so a
        // later item can still report `wantsFlex` without being the flexible one.
        let flexIndex = header.flexibleItemID.flatMap { id in
            survivors.firstIndex { $0.item.id == id }
        }
        let overflowSlot: [CGFloat] = overflowItem == nil ? [] : [overflowWidth]
        let floorContent = runWidth(Array(widths.prefix(leading.count)))
            + runWidth(overflowSlot + Array(widths.suffix(trailing.count)))
        let slack = span - requiredGap - floorContent

        if slack > 0 {
            // Elastic items share what is left equally, and an item that reaches its natural
            // width hands its remainder back to the others, so two labels narrow together
            // instead of the first one hoarding the row.
            var pool = slack
            var elastic = widths.indices.filter { index in
                index != flexIndex && widths[index] < naturals[index] - 0.5
            }
            while pool > 0.5, !elastic.isEmpty {
                let share = pool / CGFloat(elastic.count)
                var consumed: CGFloat = 0
                var next: [Int] = []
                for index in elastic {
                    let take = min(naturals[index] - widths[index], share)
                    widths[index] += take
                    consumed += take
                    if naturals[index] - widths[index] > 0.5 { next.append(index) }
                }
                guard consumed > 0.5 else { break }
                pool -= consumed
                elastic = next
            }
            // Whatever survives the labels goes to the flexible field: it takes the gap minus
            // the band the drag reservation already kept.
            if let flexIndex { widths[flexIndex] += pool }
        } else if slack < 0 {
            // Only text fields can reach here — everything else folds, and folding stops only
            // when nothing foldable is left — so this is the field-shrinks-past-its-floor path.
            var deficit = -slack
            var shrinkable = widths.indices.filter { survivors[$0].isTextField && widths[$0] > 0 }
            while deficit > 0.5, !shrinkable.isEmpty {
                let share = deficit / CGFloat(shrinkable.count)
                var released: CGFloat = 0
                var next: [Int] = []
                for index in shrinkable {
                    let give = min(widths[index], share)
                    widths[index] -= give
                    released += give
                    if widths[index] > 0.5 { next.append(index) }
                }
                guard released > 0.5 else { break }
                deficit -= released
                shrinkable = next
            }
        }

        let bandY = ((headerHeight - bandHeight) / 2).rounded(.down)
        var leadingPlacements: [Placement] = []
        var cursor = runOrigin
        for index in leading.indices where widths[index] >= 1 {
            leadingPlacements.append(
                Placement(
                    run: .leading,
                    item: leading[index].item,
                    rect: CGRect(x: cursor, y: bandY, width: widths[index], height: bandHeight)
                )
            )
            cursor += widths[index] + itemSpacing
        }

        // The `…` takes the trailing run's tail — its leftmost slot — so the controls anchored
        // to the close button keep their positions as their neighbours fold away. Muscle memory
        // finds the rightmost control; folding must not move it.
        var trailingItems: [(item: PaneHeaderItem, width: CGFloat)] = []
        if let overflowItem { trailingItems.append((overflowItem, overflowWidth)) }
        for index in trailing.indices where widths[leading.count + index] >= 1 {
            trailingItems.append((trailing[index].item, widths[leading.count + index]))
        }
        var packed: [Placement] = []
        cursor = trailingLimit
        for entry in trailingItems.reversed() {
            cursor -= entry.width
            packed.append(
                Placement(
                    run: .trailing,
                    item: entry.item,
                    rect: CGRect(x: cursor, y: bandY, width: entry.width, height: bandHeight)
                )
            )
            cursor -= itemSpacing
        }
        let trailingPlacements = Array(packed.reversed())

        let gapStart = leadingPlacements.last?.rect.maxX ?? runOrigin
        let gapEnd = trailingPlacements.first?.rect.minX ?? trailingLimit
        let gapWidth = max(gapEnd - gapStart, 0)
        let placements = leadingPlacements + trailingPlacements

        // A flexible field IS the pane's address line; showing it and the pane's name in one
        // 34-point strip is the two-headers problem this vocabulary exists to end.
        let flexIsPlaced = flexIndex.map { widths[$0] >= 1 } ?? false
        let titleThreshold = max(min(titleIdealWidth, minimumTitleWidth), 1)
        let titleRect: CGRect
        if flexIsPlaced || (!placements.isEmpty && gapWidth < titleThreshold) {
            titleRect = .zero
        } else {
            titleRect = CGRect(
                x: gapStart,
                y: titleTop,
                width: max(gapWidth, 1),
                height: titleHeight
            )
        }

        return Solution(
            glyphRect: glyphRect,
            dotRect: dotRect,
            titleRect: titleRect,
            dragBandRect: CGRect(x: gapStart, y: 0, width: gapWidth, height: headerHeight),
            leadingHostRect: hostRect(over: leadingPlacements, y: bandY, height: bandHeight),
            trailingHostRect: hostRect(over: trailingPlacements, y: bandY, height: bandHeight),
            placements: placements,
            folded: folded,
            overflow: overflowItem
        )
    }

    // MARK: - Measurement and folding  @domain: pane-chrome

    /// An item with the width it wants and the width it will accept. Only labels and text
    /// fields have room between the two; every other control is rigid and either fits or folds.
    private struct Sized {
        let item: PaneHeaderItem
        let natural: CGFloat
        let floor: CGFloat

        var isTextField: Bool {
            if case .textfield = item { return true }
            return false
        }

        var isLabel: Bool {
            if case .label = item { return true }
            return false
        }
    }

    private enum FoldTier {
        case control, label
    }

    private enum FoldVictim {
        case leading(Int), trailing(Int)
    }

    private static func sized(
        _ item: PaneHeaderItem,
        metrics: some PaneHeaderMetrics
    ) -> Sized {
        let natural = max(metrics.width(of: item), 0)
        switch item {
        case .label:
            return Sized(item: item, natural: natural, floor: min(natural, minimumLabelWidth))
        case .textfield:
            return Sized(
                item: item,
                natural: natural,
                floor: min(natural, minimumTextFieldWidth)
            )
        case .dot, .badge, .image, .spinner, .iconButton, .toggle, .segmented, .menu:
            return Sized(item: item, natural: natural, floor: natural)
        }
    }

    private static func runWidth(_ widths: [CGFloat]) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + itemSpacing * CGFloat(widths.count - 1)
    }

    private static func foldedItem(_ sized: Sized) -> FoldedItem {
        FoldedItem(item: sized.item, entries: sized.item.overflowEntries())
    }

    private static func index(in run: [Sized], tier: FoldTier, fromEnd: Bool) -> Int? {
        let order = fromEnd ? Array(run.indices.reversed()) : Array(run.indices)
        return order.first { position in
            let candidate = run[position]
            guard !candidate.isTextField else { return false }
            return tier == .label ? candidate.isLabel : !candidate.isLabel
        }
    }

    /// The leftmost item a trailing run over its share gives up. Controls and decoration go
    /// before labels, because a label still says something once it has folded into the menu and
    /// a picker does not.
    private static func foldIndex(in run: [Sized], fromEnd: Bool) -> Int? {
        index(in: run, tier: .control, fromEnd: fromEnd)
            ?? index(in: run, tier: .label, fromEnd: fromEnd)
    }

    /// Trailing packs right-to-left and folds its leftmost inward; leading packs left-to-right
    /// and folds its last item backwards. Leading gives way first because the trailing run's
    /// own share is already enforced before this runs, and labels everywhere go last so a
    /// header stops being a picker before it stops being a sentence.
    private static func foldVictim(leading: [Sized], trailing: [Sized]) -> FoldVictim? {
        for tier in [FoldTier.control, .label] {
            if let position = index(in: leading, tier: tier, fromEnd: true) {
                return .leading(position)
            }
            if let position = index(in: trailing, tier: tier, fromEnd: false) {
                return .trailing(position)
            }
        }
        return nil
    }

    /// The one `…` control, built host-side from what folded.
    ///
    /// It is deliberately not run through `PaneHeaderItem.bounded()`, for two reasons that
    /// point the same way. `bounded()` refuses `PaneHeaderItem.reservedIDs`, and this control
    /// wears exactly one of them — the reservation is what stops a contributor minting a second
    /// `…`, and the solver composes this one after both runs are settled, so it never goes
    /// through the header's door. And the entry cap bounds what one *contributor* may publish
    /// in one menu, while this menu is host-composed from items each of which was already
    /// bounded on its way in.
    ///
    /// Its size is still bounded by construction, just not by that cap: at most
    /// `PaneHeader.maximumLeadingItems + PaneHeader.maximumTrailingItems` = 13 items can fold,
    /// and the most any single one contributes is a `menu`'s
    /// `PaneHeaderMenuEntry.maximumEntries` = 12 (a `segmented` yields at most 5, everything
    /// else 1 or 0) — so the ceiling is 13 × 12 = 156 already-bounded entries. That is a long
    /// menu, and it is reachable only on a pane too narrow to draw thirteen controls, which is
    /// a pane mid-resize. Truncating there would delete the very controls folding exists to
    /// preserve, so the ceiling is accepted rather than clamped.
    private static func overflowMenu(_ folded: [FoldedItem]) -> PaneHeaderItem? {
        var entries: [PaneHeaderMenuEntry] = []
        for candidate in folded where !candidate.entries.isEmpty {
            for (position, entry) in candidate.entries.enumerated() {
                let opensGroup = position == 0 && !entries.isEmpty
                if opensGroup,
                   let separated = PaneHeaderMenuEntry(
                       value: entry.value,
                       label: entry.label,
                       systemName: entry.systemName,
                       isOn: entry.isOn,
                       separatorBefore: true
                   ) {
                    entries.append(separated)
                } else {
                    entries.append(entry)
                }
            }
        }
        guard !entries.isEmpty else { return nil }
        return .menu(
            id: overflowItemID,
            systemName: "ellipsis",
            entries: entries,
            isEnabled: true,
            tooltip: "More",
            accessibilityID: overflowItemID
        )
    }

    private static func hostRect(
        over placements: [Placement],
        y: CGFloat,
        height: CGFloat
    ) -> CGRect? {
        guard let first = placements.first, let last = placements.last else { return nil }
        return CGRect(
            x: first.rect.minX,
            y: y,
            width: last.rect.maxX - first.rect.minX,
            height: height
        )
    }
}

/// Width measurement, injectable so the solver stays a pure function the tests can sweep.
///
/// One method, because width is the only measurement the header needs: its height is the band's,
/// and its position is the solver's answer.
protocol PaneHeaderMetrics: Sendable {
    func width(of item: PaneHeaderItem) -> CGFloat
}

/// The shell's measurement: real text through `NSAttributedString.size()`.
///
/// No throwaway `NSHostingView` and no cache. `layout()` runs on the pane-drag path, where a
/// hosting view per measurement would cost a view tree per frame and a cache would grow with
/// every distinct label a plugin ever published — while the strings here are a pane title's
/// worth of text, which Core Text measures in microseconds.
struct LivePaneHeaderMetrics: PaneHeaderMetrics {
    /// Header scale: the same 10 points the pane title is drawn at, so a header label and the
    /// pane's name read as one row.
    private static let textSize: CGFloat = 10
    private static let badgeTextSize: CGFloat = 9
    /// The attention dot's diameter, matching the card's own state dot.
    private static let dotWidth: CGFloat = 7
    private static let spinnerWidth: CGFloat = 14
    private static let symbolWidth: CGFloat = 16
    /// An SF Symbol control at `.controlSize(.small)`.
    private static let controlWidth: CGFloat = 22
    private static let menuWidth: CGFloat = 30
    private static let badgePadding: CGFloat = 12
    private static let segmentPadding: CGFloat = 20
    private static let segmentSymbolWidth: CGFloat = 26
    private static let segmentedBorder: CGFloat = 2
    private static let textFieldPadding: CGFloat = 16
    /// What a field asks for before the flexible one is handed the gap. Wide enough for a URL's
    /// meaningful head, narrow enough that a non-flexible field does not eat the pane's name.
    private static let preferredTextFieldWidth: CGFloat = 220

    func width(of item: PaneHeaderItem) -> CGFloat {
        switch item {
        case .dot:
            return Self.dotWidth
        case let .label(_, text, weight, _, _, _):
            return Self.textWidth(text, size: Self.textSize, weight: Self.fontWeight(weight))
        case let .badge(_, text, _, _):
            return Self.textWidth(text, size: Self.badgeTextSize, weight: .semibold)
                + Self.badgePadding
        case .image:
            return Self.symbolWidth
        case .spinner:
            return Self.spinnerWidth
        case .iconButton, .toggle:
            return Self.controlWidth
        case let .segmented(_, segments, _, _, _):
            return segments.reduce(Self.segmentedBorder) { total, segment in
                guard segment.systemName == nil else { return total + Self.segmentSymbolWidth }
                let text = segment.label ?? segment.accessibilityLabel ?? segment.value
                return total
                    + Self.textWidth(text, size: Self.textSize, weight: .medium)
                    + Self.segmentPadding
            }
        case .menu:
            return Self.menuWidth
        case let .textfield(_, value, placeholder, _, _, _):
            let text = value.isEmpty ? placeholder : value
            let asked = Self.textWidth(text, size: Self.textSize, weight: .regular)
                + Self.textFieldPadding
            return min(
                max(asked, PaneHeaderLayout.minimumTextFieldWidth),
                Self.preferredTextFieldWidth
            )
        }
    }

    private static func textWidth(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let measured = NSAttributedString(
            string: text,
            attributes: [.font: TenonTheme.interfaceNSFont(size: size, weight: weight)]
        )
        return measured.size().width.rounded(.up)
    }

    private static func fontWeight(_ weight: FontWeight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }
}

extension PaneHeaderMetrics where Self == LivePaneHeaderMetrics {
    static var live: LivePaneHeaderMetrics { LivePaneHeaderMetrics() }
}
