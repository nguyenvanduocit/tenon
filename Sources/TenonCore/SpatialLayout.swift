// @domain: workspace-model, spatial-canvas
import Foundation

public struct GridRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var right: Int { x + width }
    var bottom: Int { y + height }

    func overlaps(_ other: GridRect) -> Bool {
        x < other.right &&
            right > other.x &&
            y < other.bottom &&
            bottom > other.y
    }
}

public struct SpatialSlot: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var rect: GridRect

    public init(id: UUID, rect: GridRect) {
        self.id = id
        self.rect = rect
    }
}

public enum SplitAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

/// Which half of a target pane receives a pane carried by a header drag.
public enum SpatialDropEdge: Equatable, Sendable {
    case left
    case right
    case top
    case bottom
}

public enum ResizeDirection: Equatable, Sendable {
    case north
    case east
    case south
    case west
    case northEast
    case northWest
    case southEast
    case southWest

    public var includesNorth: Bool {
        self == .north || self == .northEast || self == .northWest
    }

    public var includesEast: Bool {
        self == .east || self == .northEast || self == .southEast
    }

    public var includesSouth: Bool {
        self == .south || self == .southEast || self == .southWest
    }

    public var includesWest: Bool {
        self == .west || self == .northWest || self == .southWest
    }
}

/// The sizes a pane border offers when it is asked to resize by name rather than by
/// drag. A fraction is of the whole canvas, never of the pane's current size, so "1/2"
/// means the same width wherever the pane sits.
public enum SpatialExtentFraction: Equatable, Sendable, CaseIterable {
    case oneThird
    case oneHalf
    case full

    func extent(of total: Int) -> Int {
        switch self {
        case .oneThird: return total / 3
        case .oneHalf: return total / 2
        case .full: return total
        }
    }
}

public enum CloseAbsorptionDirection: Equatable, Sendable {
    case left
    case top
    case right
    case bottom
}

public enum SpatialLayoutTransactionKind: Equatable, Sendable {
    case split
    case move
    case swap
}

public struct SpatialLayoutTransaction: Equatable, Sendable {
    public let kind: SpatialLayoutTransactionKind
    public let isValid: Bool
    public let baseline: [SpatialSlot]
    public let proposal: [SpatialSlot]
    public let affectedSlotIDs: [UUID]

    init(
        kind: SpatialLayoutTransactionKind,
        isValid: Bool,
        baseline: [SpatialSlot],
        proposal: [SpatialSlot],
        affectedSlotIDs: [UUID]
    ) {
        self.kind = kind
        self.isValid = isValid
        self.baseline = baseline
        self.proposal = proposal
        self.affectedSlotIDs = affectedSlotIDs
    }
}

public struct CloseLayoutTransaction: Equatable, Sendable {
    public let proposal: [SpatialSlot]
    public let absorbedSlotIDs: [UUID]
    public let direction: CloseAbsorptionDirection?

    init(
        proposal: [SpatialSlot],
        absorbedSlotIDs: [UUID],
        direction: CloseAbsorptionDirection?
    ) {
        self.proposal = proposal
        self.absorbedSlotIDs = absorbedSlotIDs
        self.direction = direction
    }
}

public struct ResizeLayoutTransaction: Equatable, Sendable {
    public let isValid: Bool
    public let isDetached: Bool
    public let baseline: [SpatialSlot]
    public let proposal: [SpatialSlot]
    public let affectedSlotIDs: [UUID]

    init(
        isValid: Bool,
        isDetached: Bool,
        baseline: [SpatialSlot],
        proposal: [SpatialSlot],
        affectedSlotIDs: [UUID]
    ) {
        self.isValid = isValid
        self.isDetached = isDetached
        self.baseline = baseline
        self.proposal = proposal
        self.affectedSlotIDs = affectedSlotIDs
    }
}

public enum SpatialLayout {
    public static let columns = 12
    public static let rows = 12
    public static let minimumWidth = 3
    public static let minimumHeight = 3

    public static func isValid(_ slots: [SpatialSlot]) -> Bool {
        guard Set(slots.map(\.id)).count == slots.count else { return false }

        for slot in slots {
            let rect = slot.rect
            let isInsideGrid =
                rect.width >= minimumWidth &&
                rect.height >= minimumHeight &&
                rect.x >= 0 &&
                rect.y >= 0 &&
                rect.width <= columns &&
                rect.height <= rows &&
                rect.x <= columns - rect.width &&
                rect.y <= rows - rect.height

            guard isInsideGrid else { return false }
        }

        for (index, slot) in slots.enumerated() {
            let rect = slot.rect
            for other in slots.dropFirst(index + 1) where rect.overlaps(other.rect) {
                return false
            }
        }

        return true
    }

    public static func bestEmptyRect(
        in slots: [SpatialSlot],
        near activeSlotID: UUID?
    ) -> GridRect? {
        bestEmptyRect(in: slots, near: activeSlotID, containing: nil)
    }

    /// The largest valid empty rectangle that contains the grid cell the user chose.
    /// This is distinct from `bestEmptyRect(in:near:)`: an empty-grid click designates
    /// its own region and must never jump to a larger hole elsewhere on the canvas.
    public static func bestEmptyRect(
        in slots: [SpatialSlot],
        containingColumn column: Int,
        row: Int
    ) -> GridRect? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return bestEmptyRect(in: slots, near: nil, containing: (column, row))
    }

    private static func bestEmptyRect(
        in slots: [SpatialSlot],
        near activeSlotID: UUID?,
        containing requiredCell: (column: Int, row: Int)?
    ) -> GridRect? {
        guard isValid(slots) else { return nil }

        let active = slots.first { $0.id == activeSlotID }?.rect
        let activeCenterX = active.map { $0.x * 2 + $0.width } ?? 0
        let activeCenterY = active.map { $0.y * 2 + $0.height } ?? 0
        var best: EmptyRectCandidate?

        for y in 0...(rows - minimumHeight) {
            for x in 0...(columns - minimumWidth) {
                for height in minimumHeight...(rows - y) {
                    for width in minimumWidth...(columns - x) {
                        let rect = GridRect(x: x, y: y, width: width, height: height)
                        if let requiredCell,
                           !(requiredCell.column >= rect.x &&
                             requiredCell.column < rect.x + rect.width &&
                             requiredCell.row >= rect.y &&
                             requiredCell.row < rect.y + rect.height)
                        {
                            continue
                        }
                        guard !slots.contains(where: { rect.overlaps($0.rect) }) else { continue }

                        let centerDeltaX = active == nil ? 0 : x * 2 + width - activeCenterX
                        let centerDeltaY = active == nil ? 0 : y * 2 + height - activeCenterY
                        let candidate = EmptyRectCandidate(
                            rect: rect,
                            area: width * height,
                            distance: centerDeltaX * centerDeltaX + centerDeltaY * centerDeltaY,
                            shortSide: min(width, height)
                        )

                        if best == nil || candidate.isBetter(than: best!) {
                            best = candidate
                        }
                    }
                }
            }
        }

        return best?.rect
    }

    public static func split(
        _ slots: [SpatialSlot],
        slotID: UUID,
        newSlotID: UUID,
        axis: SplitAxis
    ) -> SpatialLayoutTransaction? {
        guard isValid(slots),
              let index = slots.firstIndex(where: { $0.id == slotID }),
              !slots.contains(where: { $0.id == newSlotID })
        else { return nil }

        let original = slots[index].rect
        let available = axis == .horizontal ? original.width : original.height
        let minimum = axis == .horizontal ? minimumWidth : minimumHeight
        guard available >= minimum * 2 else { return nil }

        let firstSize = (available + 1) / 2
        let secondSize = available - firstSize
        var proposal = slots
        var firstRect = original
        let secondRect: GridRect

        switch axis {
        case .horizontal:
            firstRect.width = firstSize
            secondRect = GridRect(
                x: original.x + firstSize,
                y: original.y,
                width: secondSize,
                height: original.height
            )
        case .vertical:
            firstRect.height = firstSize
            secondRect = GridRect(
                x: original.x,
                y: original.y + firstSize,
                width: original.width,
                height: secondSize
            )
        }

        proposal[index].rect = firstRect
        proposal.append(SpatialSlot(id: newSlotID, rect: secondRect))
        guard isValid(proposal) else { return nil }

        return SpatialLayoutTransaction(
            kind: .split,
            isValid: true,
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: [slotID, newSlotID]
        )
    }

    public static func close(
        _ slots: [SpatialSlot],
        slotID: UUID
    ) -> CloseLayoutTransaction? {
        guard isValid(slots),
              let deleted = slots.first(where: { $0.id == slotID })
        else { return nil }
        let remaining = slots.filter { $0.id != slotID }

        for direction in [
            CloseAbsorptionDirection.left,
            .top,
            .right,
            .bottom,
        ] {
            let verticalEdge = direction == .left || direction == .right
            let neighbors = remaining.filter { neighbor in
                switch direction {
                case .left:
                    return neighbor.rect.right == deleted.rect.x &&
                        neighbor.rect.y >= deleted.rect.y &&
                        neighbor.rect.bottom <= deleted.rect.bottom
                case .top:
                    return neighbor.rect.bottom == deleted.rect.y &&
                        neighbor.rect.x >= deleted.rect.x &&
                        neighbor.rect.right <= deleted.rect.right
                case .right:
                    return neighbor.rect.x == deleted.rect.right &&
                        neighbor.rect.y >= deleted.rect.y &&
                        neighbor.rect.bottom <= deleted.rect.bottom
                case .bottom:
                    return neighbor.rect.y == deleted.rect.bottom &&
                        neighbor.rect.x >= deleted.rect.x &&
                        neighbor.rect.right <= deleted.rect.right
                }
            }

            let rangeStart = verticalEdge ? deleted.rect.y : deleted.rect.x
            let rangeEnd = verticalEdge ? deleted.rect.bottom : deleted.rect.right
            var intervals: [Interval] = []
            for neighbor in neighbors {
                if verticalEdge {
                    intervals.append(Interval(start: neighbor.rect.y, end: neighbor.rect.bottom))
                } else {
                    intervals.append(Interval(start: neighbor.rect.x, end: neighbor.rect.right))
                }
            }
            intervals.sort {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }

            guard intervalsTile(intervals, from: rangeStart, to: rangeEnd) else { continue }

            let absorbedSlotIDs = neighbors.map(\.id)
            let absorbed = Set(absorbedSlotIDs)
            let proposal = remaining.map { slot -> SpatialSlot in
                guard absorbed.contains(slot.id) else { return slot }
                var expanded = slot

                switch direction {
                case .left:
                    expanded.rect.width += deleted.rect.width
                case .top:
                    expanded.rect.height += deleted.rect.height
                case .right:
                    expanded.rect.x = deleted.rect.x
                    expanded.rect.width += deleted.rect.width
                case .bottom:
                    expanded.rect.y = deleted.rect.y
                    expanded.rect.height += deleted.rect.height
                }

                return expanded
            }

            if isValid(proposal) {
                return CloseLayoutTransaction(
                    proposal: proposal,
                    absorbedSlotIDs: absorbedSlotIDs,
                    direction: direction
                )
            }
        }

        return CloseLayoutTransaction(
            proposal: remaining,
            absorbedSlotIDs: [],
            direction: nil
        )
    }

    public static func resize(
        _ slots: [SpatialSlot],
        slotID: UUID,
        direction: ResizeDirection,
        deltaColumns: Int,
        deltaRows: Int
    ) -> ResizeLayoutTransaction {
        guard isValid(slots),
              let moving = slots.first(where: { $0.id == slotID })
        else {
            return ResizeLayoutTransaction(
                isValid: false,
                isDetached: false,
                baseline: slots,
                proposal: slots,
                affectedSlotIDs: []
            )
        }

        let safeDeltaColumns = min(max(deltaColumns, -columns), columns)
        let safeDeltaRows = min(max(deltaRows, -rows), rows)
        let movingCandidate = resizedRect(
            moving.rect,
            direction: direction,
            deltaColumns: safeDeltaColumns,
            deltaRows: safeDeltaRows
        )
        let activeOnlyProposal = replacingRect(in: slots, slotID: slotID, with: movingCandidate)
        var coupledRects = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.rect) })
        coupledRects[slotID] = movingCandidate
        var affectedSlotIDs = [slotID]

        let horizontalDelta: Int
        if direction.includesEast {
            horizontalDelta = movingCandidate.right - moving.rect.right
        } else if direction.includesWest {
            horizontalDelta = movingCandidate.x - moving.rect.x
        } else {
            horizontalDelta = 0
        }

        let verticalDelta: Int
        if direction.includesSouth {
            verticalDelta = movingCandidate.bottom - moving.rect.bottom
        } else if direction.includesNorth {
            verticalDelta = movingCandidate.y - moving.rect.y
        } else {
            verticalDelta = 0
        }

        for neighbor in slots where neighbor.id != slotID {
            var rect = coupledRects[neighbor.id]!
            var changed = false

            if direction.includesEast &&
                horizontalDelta != 0 &&
                neighbor.rect.x == moving.rect.right &&
                spansOverlap(
                    moving.rect.y,
                    moving.rect.height,
                    neighbor.rect.y,
                    neighbor.rect.height
                ) {
                rect.x = neighbor.rect.x + horizontalDelta
                rect.width = neighbor.rect.width - horizontalDelta
                changed = true
            }

            if direction.includesWest &&
                horizontalDelta != 0 &&
                neighbor.rect.right == moving.rect.x &&
                spansOverlap(
                    moving.rect.y,
                    moving.rect.height,
                    neighbor.rect.y,
                    neighbor.rect.height
                ) {
                rect.width = neighbor.rect.width + horizontalDelta
                changed = true
            }

            if direction.includesSouth &&
                verticalDelta != 0 &&
                neighbor.rect.y == moving.rect.bottom &&
                spansOverlap(
                    moving.rect.x,
                    moving.rect.width,
                    neighbor.rect.x,
                    neighbor.rect.width
                ) {
                rect.y = neighbor.rect.y + verticalDelta
                rect.height = neighbor.rect.height - verticalDelta
                changed = true
            }

            if direction.includesNorth &&
                verticalDelta != 0 &&
                neighbor.rect.bottom == moving.rect.y &&
                spansOverlap(
                    moving.rect.x,
                    moving.rect.width,
                    neighbor.rect.x,
                    neighbor.rect.width
                ) {
                rect.height = neighbor.rect.height + verticalDelta
                changed = true
            }

            if changed {
                coupledRects[neighbor.id] = rect
                affectedSlotIDs.append(neighbor.id)
            }
        }

        let coupledProposal = slots.map { slot in
            SpatialSlot(id: slot.id, rect: coupledRects[slot.id]!)
        }
        if isValid(coupledProposal) {
            return ResizeLayoutTransaction(
                isValid: true,
                isDetached: false,
                baseline: slots,
                proposal: coupledProposal,
                affectedSlotIDs: affectedSlotIDs
            )
        }

        if isValid(activeOnlyProposal) {
            return ResizeLayoutTransaction(
                isValid: true,
                isDetached: true,
                baseline: slots,
                proposal: activeOnlyProposal,
                affectedSlotIDs: [slotID]
            )
        }

        return ResizeLayoutTransaction(
            isValid: false,
            isDetached: false,
            baseline: slots,
            proposal: activeOnlyProposal,
            affectedSlotIDs: [slotID]
        )
    }

    /// The same resize, named by destination instead of by delta: the edge given by
    /// `direction` lands at `fraction` of the canvas while the opposite edge stays
    /// fixed — the anchor a drag on that edge already uses. A corner names both axes.
    ///
    /// The fraction is converted to the delta that reaches it and handed to the
    /// delta-based `resize`, so neighbour coupling, detachment, clamping, and validity
    /// are the drag's, not a second set of rules. A destination that changes nothing
    /// yields an invalid transaction, so a caller can tell "already that size" from a
    /// real change without diffing rects itself.
    public static func resize(
        _ slots: [SpatialSlot],
        slotID: UUID,
        direction: ResizeDirection,
        fraction: SpatialExtentFraction
    ) -> ResizeLayoutTransaction {
        let refused = ResizeLayoutTransaction(
            isValid: false,
            isDetached: false,
            baseline: slots,
            proposal: slots,
            affectedSlotIDs: []
        )
        guard isValid(slots),
              let target = slots.first(where: { $0.id == slotID })
        else { return refused }

        let horizontal = direction.includesEast || direction.includesWest
        let vertical = direction.includesNorth || direction.includesSouth
        let widthDelta = horizontal
            ? fraction.extent(of: columns) - target.rect.width
            : 0
        let heightDelta = vertical
            ? fraction.extent(of: rows) - target.rect.height
            : 0

        // West and north edges grow toward smaller coordinates, so the delta that
        // moves such an edge is the negation of the size change it produces.
        let transaction = resize(
            slots,
            slotID: slotID,
            direction: direction,
            deltaColumns: direction.includesWest ? -widthDelta : widthDelta,
            deltaRows: direction.includesNorth ? -heightDelta : heightDelta
        )
        guard transaction.proposal != slots else { return refused }
        return transaction
    }

    /// Steps one edge to the next size in the border's own cycle — Full, then 1/2, then
    /// 1/3, then Full again — starting from whichever of the three the pane currently
    /// sits on. A pane sitting on none of them goes Full, so the first double-click on a
    /// border always means "fill this direction".
    ///
    /// A size the layout would refuse is skipped for the next one, so the cycle never
    /// answers with nothing while some size was still reachable. The sizes themselves are
    /// `resize(…, fraction:)`, which is what the border's contextual menu lists: one
    /// vocabulary, reached either by naming a size or by stepping to it.
    public static func cycleExtent(
        _ slots: [SpatialSlot],
        slotID: UUID,
        direction: ResizeDirection
    ) -> ResizeLayoutTransaction {
        let refused = ResizeLayoutTransaction(
            isValid: false,
            isDetached: false,
            baseline: slots,
            proposal: slots,
            affectedSlotIDs: []
        )
        guard isValid(slots),
              let target = slots.first(where: { $0.id == slotID })
        else { return refused }

        let cycle: [SpatialExtentFraction] = [.full, .oneHalf, .oneThird]
        let current = cycle.firstIndex {
            occupies(target.rect, direction: direction, fraction: $0)
        }
        // On a known size, the walk starts at the one after it; on none, at the head of
        // the cycle, which is Full.
        let candidates = current.map { start in
            (1...cycle.count).map { cycle[(start + $0) % cycle.count] }
        } ?? cycle

        for fraction in candidates {
            let transaction = resize(
                slots,
                slotID: slotID,
                direction: direction,
                fraction: fraction
            )
            if transaction.isValid { return transaction }
        }
        return refused
    }

    /// Whether a pane already sits on one of the cycle's sizes, measured on the axes the
    /// edge moves. A corner sits on a size only when both of its axes do.
    private static func occupies(
        _ rect: GridRect,
        direction: ResizeDirection,
        fraction: SpatialExtentFraction
    ) -> Bool {
        let horizontal = direction.includesEast || direction.includesWest
        let vertical = direction.includesNorth || direction.includesSouth
        let widthMatches = !horizontal || rect.width == fraction.extent(of: columns)
        let heightMatches = !vertical || rect.height == fraction.extent(of: rows)
        return widthMatches && heightMatches
    }

    /// Grows one slot sideways until it meets the slots that share its rows, or the
    /// canvas edge where none do. Nothing else moves: a neighbour is a stop, never
    /// something to shrink, so filling never rearranges the rest of the layout. A slot
    /// that already spans its band yields an invalid transaction, so a caller can tell
    /// "nothing to fill" from a change without diffing rects itself.
    public static func fillWidth(
        _ slots: [SpatialSlot],
        slotID: UUID
    ) -> ResizeLayoutTransaction {
        guard isValid(slots),
              let target = slots.first(where: { $0.id == slotID })
        else {
            return ResizeLayoutTransaction(
                isValid: false,
                isDetached: false,
                baseline: slots,
                proposal: slots,
                affectedSlotIDs: []
            )
        }

        // Slots overlap the target's rows or they do not; a non-overlapping layout
        // leaves those that do entirely to one side of it, so their near edges are
        // exactly the two stops.
        let sharingRows = slots.filter { other in
            other.id != slotID && spansOverlap(
                target.rect.y,
                target.rect.height,
                other.rect.y,
                other.rect.height
            )
        }
        let left = sharingRows
            .filter { $0.rect.right <= target.rect.x }
            .map(\.rect.right)
            .max() ?? 0
        let right = sharingRows
            .filter { $0.rect.x >= target.rect.right }
            .map(\.rect.x)
            .min() ?? columns
        let filled = GridRect(
            x: left,
            y: target.rect.y,
            width: right - left,
            height: target.rect.height
        )
        let proposal = replacingRect(in: slots, slotID: slotID, with: filled)

        guard filled != target.rect, isValid(proposal) else {
            return ResizeLayoutTransaction(
                isValid: false,
                isDetached: false,
                baseline: slots,
                proposal: slots,
                affectedSlotIDs: []
            )
        }

        return ResizeLayoutTransaction(
            isValid: true,
            isDetached: false,
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: [slotID]
        )
    }

    public static func move(
        _ slots: [SpatialSlot],
        slotID: UUID,
        toColumn column: Int,
        row: Int
    ) -> SpatialLayoutTransaction {
        guard isValid(slots),
              let moving = slots.first(where: { $0.id == slotID })
        else {
            return SpatialLayoutTransaction(
                kind: .move,
                isValid: false,
                baseline: slots,
                proposal: slots,
                affectedSlotIDs: []
            )
        }

        let maximumX = max(0, columns - moving.rect.width)
        let maximumY = max(0, rows - moving.rect.height)
        let candidate = GridRect(
            x: min(max(0, column), maximumX),
            y: min(max(0, row), maximumY),
            width: moving.rect.width,
            height: moving.rect.height
        )
        let proposal = replacingRect(in: slots, slotID: slotID, with: candidate)

        return SpatialLayoutTransaction(
            kind: .move,
            isValid: isValid(proposal),
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: [slotID]
        )
    }

    /// Collapses the carried pane's old footprint, then divides the target in half
    /// and places the carried pane on the requested edge. The operation mirrors a
    /// structural pane move while preserving the spatial model's stable slot order.
    public static func moveBeside(
        _ slots: [SpatialSlot],
        slotID: UUID,
        targetID: UUID,
        edge: SpatialDropEdge
    ) -> SpatialLayoutTransaction {
        func invalid() -> SpatialLayoutTransaction {
            SpatialLayoutTransaction(
                kind: .move,
                isValid: false,
                baseline: slots,
                proposal: slots,
                affectedSlotIDs: []
            )
        }

        guard isValid(slots),
              slotID != targetID,
              slots.contains(where: { $0.id == slotID }),
              slots.contains(where: { $0.id == targetID }),
              let closed = close(slots, slotID: slotID)
        else { return invalid() }

        let axis: SplitAxis = edge == .left || edge == .right
            ? .horizontal
            : .vertical
        guard let split = split(
            closed.proposal,
            slotID: targetID,
            newSlotID: slotID,
            axis: axis
        ) else { return invalid() }

        var rects = Dictionary(
            uniqueKeysWithValues: split.proposal.map { ($0.id, $0.rect) }
        )
        if edge == .left || edge == .top {
            let sourceRect = rects[slotID]
            rects[slotID] = rects[targetID]
            rects[targetID] = sourceRect
        }
        let proposal = slots.map { slot in
            SpatialSlot(id: slot.id, rect: rects[slot.id] ?? slot.rect)
        }
        let affectedSlotIDs = slots.compactMap { slot in
            rects[slot.id] == slot.rect ? nil : slot.id
        }
        guard isValid(proposal), !affectedSlotIDs.isEmpty else { return invalid() }

        return SpatialLayoutTransaction(
            kind: .move,
            isValid: true,
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: affectedSlotIDs
        )
    }

    /// Inserts a pane that does not yet belong to this layout beside the named target.
    /// This is the cross-tab counterpart to `moveBeside`: the destination canvas owns
    /// the split geometry, while the workspace transaction owns detaching and reparenting
    /// the pane itself.
    public static func insertBeside(
        _ slots: [SpatialSlot],
        newSlotID: UUID,
        targetID: UUID,
        edge: SpatialDropEdge
    ) -> SpatialLayoutTransaction? {
        guard isValid(slots),
              !slots.contains(where: { $0.id == newSlotID }),
              slots.contains(where: { $0.id == targetID })
        else { return nil }

        let axis: SplitAxis = edge == .left || edge == .right
            ? .horizontal
            : .vertical
        guard let split = split(
            slots,
            slotID: targetID,
            newSlotID: newSlotID,
            axis: axis
        ) else { return nil }

        var rects = Dictionary(
            uniqueKeysWithValues: split.proposal.map { ($0.id, $0.rect) }
        )
        if edge == .left || edge == .top {
            let insertedRect = rects[newSlotID]
            rects[newSlotID] = rects[targetID]
            rects[targetID] = insertedRect
        }
        let proposal = split.proposal.map { slot in
            SpatialSlot(id: slot.id, rect: rects[slot.id] ?? slot.rect)
        }
        let affectedSlotIDs = proposal.compactMap { slot -> UUID? in
            guard slot.id != newSlotID else { return slot.id }
            return slots.first(where: { $0.id == slot.id })?.rect == slot.rect
                ? nil
                : slot.id
        }
        guard isValid(proposal) else { return nil }

        return SpatialLayoutTransaction(
            kind: .split,
            isValid: true,
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: affectedSlotIDs
        )
    }

    public static func swap(
        _ slots: [SpatialSlot],
        firstSlotID: UUID,
        secondSlotID: UUID
    ) -> SpatialLayoutTransaction {
        guard isValid(slots),
              firstSlotID != secondSlotID,
              let first = slots.first(where: { $0.id == firstSlotID }),
              let second = slots.first(where: { $0.id == secondSlotID })
        else {
            return SpatialLayoutTransaction(
                kind: .swap,
                isValid: false,
                baseline: slots,
                proposal: slots,
                affectedSlotIDs: []
            )
        }

        let proposal = slots.map { slot -> SpatialSlot in
            if slot.id == firstSlotID {
                return SpatialSlot(id: slot.id, rect: second.rect)
            }
            if slot.id == secondSlotID {
                return SpatialSlot(id: slot.id, rect: first.rect)
            }
            return slot
        }

        return SpatialLayoutTransaction(
            kind: .swap,
            isValid: isValid(proposal),
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: [firstSlotID, secondSlotID]
        )
    }

    private static func replacingRect(
        in slots: [SpatialSlot],
        slotID: UUID,
        with rect: GridRect
    ) -> [SpatialSlot] {
        slots.map { slot in
            slot.id == slotID ? SpatialSlot(id: slot.id, rect: rect) : slot
        }
    }

    private static func resizedRect(
        _ origin: GridRect,
        direction: ResizeDirection,
        deltaColumns: Int,
        deltaRows: Int
    ) -> GridRect {
        var left = origin.x
        var right = origin.right
        var top = origin.y
        var bottom = origin.bottom

        if direction.includesWest {
            left = max(0, min(right - minimumWidth, origin.x + deltaColumns))
        }
        if direction.includesEast {
            right = max(left + minimumWidth, min(columns, origin.right + deltaColumns))
        }
        if direction.includesNorth {
            top = max(0, min(bottom - minimumHeight, origin.y + deltaRows))
        }
        if direction.includesSouth {
            bottom = max(top + minimumHeight, min(rows, origin.bottom + deltaRows))
        }

        return GridRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        )
    }

    private static func spansOverlap(
        _ firstStart: Int,
        _ firstSize: Int,
        _ secondStart: Int,
        _ secondSize: Int
    ) -> Bool {
        firstStart < secondStart + secondSize &&
            firstStart + firstSize > secondStart
    }

    private static func intervalsTile(
        _ intervals: [Interval],
        from rangeStart: Int,
        to rangeEnd: Int
    ) -> Bool {
        guard !intervals.isEmpty else { return false }
        var cursor = rangeStart

        for interval in intervals {
            guard interval.start == cursor, interval.end > interval.start else { return false }
            cursor = interval.end
        }

        return cursor == rangeEnd
    }
}

private struct EmptyRectCandidate {
    let rect: GridRect
    let area: Int
    let distance: Int
    let shortSide: Int

    func isBetter(than other: EmptyRectCandidate) -> Bool {
        if area != other.area { return area > other.area }
        if distance != other.distance { return distance < other.distance }
        if shortSide != other.shortSide { return shortSide > other.shortSide }
        if rect.y != other.rect.y { return rect.y < other.rect.y }
        if rect.x != other.rect.x { return rect.x < other.rect.x }
        if rect.width != other.rect.width { return rect.width > other.rect.width }
        return rect.height > other.rect.height
    }
}

private struct Interval {
    let start: Int
    let end: Int
}
