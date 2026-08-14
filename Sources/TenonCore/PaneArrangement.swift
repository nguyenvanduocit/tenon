// @domain: spatial-canvas, workspace-model
import Foundation

/// The small, closed set of whole-tab arrangements offered by the native launcher.
///
/// These mirror the useful families shared by terminal multiplexers and IDEs: equal
/// columns, equal rows, a balanced grid, and one focused pane with the remaining panes
/// in the opposite one-third strip. The focused pane is the main pane.
public enum PaneArrangementPreset: String, CaseIterable, Equatable, Sendable {
    case tiled
    case evenColumns
    case evenRows
    case mainLeft
    case mainRight
    case mainTop
    case mainBottom
}

/// Pure whole-canvas geometry. Presentation chooses a preset; this rule decides whether
/// the current pane count can satisfy Tenon's minimum pane size and, if it can, produces
/// one atomic resize transaction for the workspace model to validate and commit.
public enum PaneArrangement {
    public static func availablePresets(
        for slots: [SpatialSlot],
        mainSlotID: UUID?
    ) -> [PaneArrangementPreset] {
        PaneArrangementPreset.allCases.filter {
            transaction(slots, mainSlotID: mainSlotID, preset: $0).isValid
        }
    }

    public static func transaction(
        _ slots: [SpatialSlot],
        mainSlotID: UUID?,
        preset: PaneArrangementPreset
    ) -> ResizeLayoutTransaction {
        guard SpatialLayout.isValid(slots), slots.count >= 2,
              let proposal = proposal(
                for: visuallyOrdered(slots),
                mainSlotID: mainSlotID,
                preset: preset
              ),
              SpatialLayout.isValid(proposal),
              Set(proposal.map(\.id)) == Set(slots.map(\.id))
        else {
            return refused(slots)
        }

        let proposalByID = Dictionary(uniqueKeysWithValues: proposal.map { ($0.id, $0.rect) })
        let affected = slots.compactMap { slot in
            proposalByID[slot.id] == slot.rect ? nil : slot.id
        }
        return ResizeLayoutTransaction(
            isValid: true,
            isDetached: false,
            baseline: slots,
            proposal: proposal,
            affectedSlotIDs: affected
        )
    }

    private static func proposal(
        for slots: [SpatialSlot],
        mainSlotID: UUID?,
        preset: PaneArrangementPreset
    ) -> [SpatialSlot]? {
        switch preset {
        case .tiled:
            return tiled(slots)
        case .evenColumns:
            return banded(slots, axis: .horizontal)
        case .evenRows:
            return banded(slots, axis: .vertical)
        case .mainLeft, .mainRight, .mainTop, .mainBottom:
            guard let mainSlotID else { return nil }
            return mainAndStrip(slots, mainSlotID: mainSlotID, preset: preset)
        }
    }

    /// Fill the canvas with rows whose pane counts differ by at most one. Earlier rows
    /// receive the extra pane, so three panes become two above and one full-width below,
    /// while five become three above and two below.
    private static func tiled(_ slots: [SpatialSlot]) -> [SpatialSlot]? {
        let columnCapacity = SpatialLayout.columns / SpatialLayout.minimumWidth
        let rowCapacity = SpatialLayout.rows / SpatialLayout.minimumHeight
        guard slots.count <= columnCapacity * rowCapacity else { return nil }

        let desiredColumns = min(
            columnCapacity,
            Int(ceil(sqrt(Double(slots.count))))
        )
        let rowCount = Int(ceil(Double(slots.count) / Double(desiredColumns)))
        guard let rowSpans = spans(
            total: SpatialLayout.rows,
            count: rowCount,
            minimum: SpatialLayout.minimumHeight
        ) else { return nil }

        let baseCount = slots.count / rowCount
        let extraRows = slots.count % rowCount
        var slotIndex = 0
        var result: [SpatialSlot] = []
        for row in 0..<rowCount {
            let countInRow = baseCount + (row < extraRows ? 1 : 0)
            guard let columnSpans = spans(
                total: SpatialLayout.columns,
                count: countInRow,
                minimum: SpatialLayout.minimumWidth
            ) else { return nil }
            for column in 0..<countInRow {
                var slot = slots[slotIndex]
                slot.rect = GridRect(
                    x: columnSpans[column].origin,
                    y: rowSpans[row].origin,
                    width: columnSpans[column].length,
                    height: rowSpans[row].length
                )
                result.append(slot)
                slotIndex += 1
            }
        }
        return result
    }

    private static func banded(
        _ slots: [SpatialSlot],
        axis: SplitAxis
    ) -> [SpatialSlot]? {
        let total = axis == .horizontal ? SpatialLayout.columns : SpatialLayout.rows
        let minimum = axis == .horizontal
            ? SpatialLayout.minimumWidth
            : SpatialLayout.minimumHeight
        guard let divisions = spans(total: total, count: slots.count, minimum: minimum)
        else { return nil }

        return zip(slots, divisions).map { slot, division in
            var updated = slot
            switch axis {
            case .horizontal:
                updated.rect = GridRect(
                    x: division.origin,
                    y: 0,
                    width: division.length,
                    height: SpatialLayout.rows
                )
            case .vertical:
                updated.rect = GridRect(
                    x: 0,
                    y: division.origin,
                    width: SpatialLayout.columns,
                    height: division.length
                )
            }
            return updated
        }
    }

    private static func mainAndStrip(
        _ slots: [SpatialSlot],
        mainSlotID: UUID,
        preset: PaneArrangementPreset
    ) -> [SpatialSlot]? {
        guard var main = slots.first(where: { $0.id == mainSlotID }) else { return nil }
        let secondary = slots.filter { $0.id != mainSlotID }
        guard !secondary.isEmpty else { return nil }

        let mainExtent = 8
        let stripExtent = 4
        let stripAxis: SplitAxis
        switch preset {
        case .mainLeft:
            main.rect = GridRect(x: 0, y: 0, width: mainExtent, height: SpatialLayout.rows)
            stripAxis = .vertical
        case .mainRight:
            main.rect = GridRect(x: stripExtent, y: 0, width: mainExtent, height: SpatialLayout.rows)
            stripAxis = .vertical
        case .mainTop:
            main.rect = GridRect(x: 0, y: 0, width: SpatialLayout.columns, height: mainExtent)
            stripAxis = .horizontal
        case .mainBottom:
            main.rect = GridRect(x: 0, y: stripExtent, width: SpatialLayout.columns, height: mainExtent)
            stripAxis = .horizontal
        case .tiled, .evenColumns, .evenRows:
            return nil
        }

        let total = stripAxis == .horizontal ? SpatialLayout.columns : SpatialLayout.rows
        let minimum = stripAxis == .horizontal
            ? SpatialLayout.minimumWidth
            : SpatialLayout.minimumHeight
        guard let divisions = spans(
            total: total,
            count: secondary.count,
            minimum: minimum
        ) else { return nil }

        let arrangedSecondary = zip(secondary, divisions).map { slot, division in
            var updated = slot
            switch preset {
            case .mainLeft:
                updated.rect = GridRect(
                    x: mainExtent,
                    y: division.origin,
                    width: stripExtent,
                    height: division.length
                )
            case .mainRight:
                updated.rect = GridRect(
                    x: 0,
                    y: division.origin,
                    width: stripExtent,
                    height: division.length
                )
            case .mainTop:
                updated.rect = GridRect(
                    x: division.origin,
                    y: mainExtent,
                    width: division.length,
                    height: stripExtent
                )
            case .mainBottom:
                updated.rect = GridRect(
                    x: division.origin,
                    y: 0,
                    width: division.length,
                    height: stripExtent
                )
            case .tiled, .evenColumns, .evenRows:
                break
            }
            return updated
        }
        return [main] + arrangedSecondary
    }

    private static func spans(
        total: Int,
        count: Int,
        minimum: Int
    ) -> [(origin: Int, length: Int)]? {
        guard count > 0, total / count >= minimum else { return nil }
        let base = total / count
        let remainder = total % count
        var origin = 0
        return (0..<count).map { index in
            let length = base + (index < remainder ? 1 : 0)
            defer { origin += length }
            return (origin, length)
        }
    }

    private static func visuallyOrdered(_ slots: [SpatialSlot]) -> [SpatialSlot] {
        slots.enumerated().sorted { lhs, rhs in
            if lhs.element.rect.y != rhs.element.rect.y {
                return lhs.element.rect.y < rhs.element.rect.y
            }
            if lhs.element.rect.x != rhs.element.rect.x {
                return lhs.element.rect.x < rhs.element.rect.x
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func refused(_ slots: [SpatialSlot]) -> ResizeLayoutTransaction {
        ResizeLayoutTransaction(
            isValid: false,
            isDetached: false,
            baseline: slots,
            proposal: slots,
            affectedSlotIDs: []
        )
    }
}

public extension WorkspaceStore {
    /// Arrange the tab the person is currently looking at. Callers that begin from a
    /// background tab select that exact tab first, so this mutation never guesses a target.
    func arrangeActiveTab(_ preset: PaneArrangementPreset) {
        guard let tab = catalog.activeTab else { return }
        let transaction = PaneArrangement.transaction(
            tab.spatialSlots,
            mainSlotID: tab.activeSlotID,
            preset: preset
        )
        guard transaction.isValid, !transaction.affectedSlotIDs.isEmpty else { return }
        applyResize(transaction)
    }
}
