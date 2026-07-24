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

public enum ResizeDirection: Equatable, Sendable {
    case north
    case east
    case south
    case west
    case northEast
    case northWest
    case southEast
    case southWest

    var includesNorth: Bool {
        self == .north || self == .northEast || self == .northWest
    }

    var includesEast: Bool {
        self == .east || self == .northEast || self == .southEast
    }

    var includesSouth: Bool {
        self == .south || self == .southEast || self == .southWest
    }

    var includesWest: Bool {
        self == .west || self == .northWest || self == .southWest
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
