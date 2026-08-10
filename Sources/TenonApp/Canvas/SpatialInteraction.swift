// @domain: spatial-canvas
/// The canvas as a state machine, with no view in it.
///
/// A press, a drag, a modifier, a drop: every gesture on the canvas resolves here into a
/// decision — move this pane, resize that edge, open this menu, commit nothing — before any
/// AppKit object hears about it. That is what lets the whole interaction be asserted in
/// `SpatialCanvasInteractionTests` without a window, and it is why this file holds no `NSView`.
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

struct GridDelta: Equatable {
    let columns: Int
    let rows: Int
}

struct EmptyGridLauncherTarget: Equatable {
    let anchor: CGPoint
    let rect: GridRect
}

enum SpatialCanvasHitRegion: Equatable {
    case resize(ResizeDirection)
    case header
    case body
}

/// What a press on a pane means once its click count is known.
enum SpatialCanvasPress: Equatable {
    case begin(SpatialCanvasHitRegion)
    case fillWidth
    case cycleExtent(ResizeDirection)
}

/// What a right-click on a pane offers, by region. A border already carries the resize
/// cursor and the resize semantics, so it offers sizes; the header offers the pane's own
/// actions; the body belongs to what it renders, and a terminal keeps its own menu there.
enum SpatialCanvasMenu: Equatable {
    case pane
    case resize(ResizeDirection)
    case surface
}

enum SpatialCanvasCommit: Equatable {
    case move(SpatialLayoutTransaction)
    case resize(ResizeLayoutTransaction)

    var proposal: [SpatialSlot] {
        switch self {
        case .move(let transaction):
            return transaction.proposal
        case .resize(let transaction):
            return transaction.proposal
        }
    }

    var isValid: Bool {
        switch self {
        case .move(let transaction):
            return transaction.isValid
        case .resize(let transaction):
            return transaction.isValid
        }
    }
}

struct SpatialCanvasMoveTarget: Equatable {
    let slotID: UUID
    let edge: SpatialDropEdge
}

enum SpatialCanvasEnd: Equatable {
    case commit(SpatialCanvasCommit)
    case rollback([SpatialSlot])
}

/// Converts pointer gestures into core layout transactions. It owns no views and
/// performs no I/O, so the high-frequency drag path stays deterministic.
final class SpatialCanvasInteractionCoordinator {
    private enum Gesture {
        case move(slotID: UUID)
        case resize(slotID: UUID, direction: ResizeDirection)
    }

    private(set) var preview: SpatialCanvasCommit?
    private(set) var moveTarget: SpatialCanvasMoveTarget?
    private(set) var isCarryingPane = false
    private var canvasSize: CGSize
    private var gesture: Gesture?
    private var pointerOrigin = CGPoint.zero
    private var snapshot: [SpatialSlot] = []

    var isActive: Bool { gesture != nil }

    init(canvasSize: CGSize) {
        self.canvasSize = canvasSize
    }

    static func hitRegion(
        at point: CGPoint,
        in bounds: CGRect
    ) -> SpatialCanvasHitRegion {
        let corner: CGFloat = 12
        let edge: CGFloat = 6
        let header: CGFloat = TenonTheme.slotHeaderHeight
        let north = point.y <= bounds.minY + corner
        let south = point.y >= bounds.maxY - corner
        let west = point.x <= bounds.minX + corner
        let east = point.x >= bounds.maxX - corner

        if north && west { return .resize(.northWest) }
        if north && east { return .resize(.northEast) }
        if south && west { return .resize(.southWest) }
        if south && east { return .resize(.southEast) }
        if point.y <= bounds.minY + edge { return .resize(.north) }
        if point.y >= bounds.maxY - edge { return .resize(.south) }
        if point.x <= bounds.minX + edge { return .resize(.west) }
        if point.x >= bounds.maxX - edge { return .resize(.east) }
        if point.y <= bounds.minY + header { return .header }
        return .body
    }

    /// The launcher belongs only to grid cells no pane owns. Testing the 12 x 12 model
    /// instead of card frames keeps the visual gutter between neighbouring panes from
    /// masquerading as empty workspace.
    static func emptyGridLauncherAnchor(
        at point: CGPoint,
        canvasSize: CGSize,
        slots: [SpatialSlot],
        sizing: NewPaneSizing = .unlimited
    ) -> CGPoint? {
        emptyGridLauncherTarget(
            at: point,
            canvasSize: canvasSize,
            slots: slots,
            sizing: sizing
        )?.anchor
    }

    /// The region a click on empty canvas reserves.
    ///
    /// This is where the person's creation maximum meets a rect, and the only place it can:
    /// the cell they pointed at is known here and nowhere downstream, so the narrowed region
    /// can be held over that cell instead of snapping to the hole's leading edge and opening
    /// a pane away from the pointer. The width the maximum declines stays empty canvas.
    static func emptyGridLauncherTarget(
        at point: CGPoint,
        canvasSize: CGSize,
        slots: [SpatialSlot],
        sizing: NewPaneSizing = .unlimited
    ) -> EmptyGridLauncherTarget? {
        guard let cell = gridCell(at: point, canvasSize: canvasSize) else { return nil }
        guard let rect = SpatialLayout.bestEmptyRect(
            in: slots,
            containingColumn: cell.column,
            row: cell.row
        ) else { return nil }
        return EmptyGridLauncherTarget(
            anchor: point,
            rect: sizing.fitting(rect, keeping: cell.column)
        )
    }

    private static func gridCell(
        at point: CGPoint,
        canvasSize: CGSize
    ) -> (column: Int, row: Int)? {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              point.x >= 0,
              point.y >= 0,
              point.x < canvasSize.width,
              point.y < canvasSize.height
        else { return nil }
        return (
            Int(point.x / canvasSize.width * CGFloat(SpatialLayout.columns)),
            Int(point.y / canvasSize.height * CGFloat(SpatialLayout.rows))
        )
    }

    /// VoiceOver exposes one action per distinct fillable region. Each action uses the
    /// same hit-testing rule as a pointer click, with its anchor at the region's center.
    static func emptyGridLauncherTargets(
        canvasSize: CGSize,
        slots: [SpatialSlot]
    ) -> [EmptyGridLauncherTarget] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        var rects: [GridRect] = []
        for row in 0..<SpatialLayout.rows {
            for column in 0..<SpatialLayout.columns {
                if rects.contains(where: { rect in
                    column >= rect.x && column < rect.x + rect.width &&
                        row >= rect.y && row < rect.y + rect.height
                }) {
                    continue
                }
                guard let rect = SpatialLayout.bestEmptyRect(
                    in: slots,
                    containingColumn: column,
                    row: row
                ), !rects.contains(rect)
                else { continue }
                rects.append(rect)
            }
        }
        return rects.map { rect in
            EmptyGridLauncherTarget(
                anchor: CGPoint(
                    x: CGFloat(rect.x * 2 + rect.width) * canvasSize.width /
                        CGFloat(SpatialLayout.columns * 2),
                    y: CGFloat(rect.y * 2 + rect.height) * canvasSize.height /
                        CGFloat(SpatialLayout.rows * 2)
                ),
                rect: rect
            )
        }
    }

    /// The target is divided by its diagonals, matching the directional pane-drop
    /// affordance used by Kero, Ghostty, and VS Code.
    static func dropEdge(at point: CGPoint, in frame: CGRect) -> SpatialDropEdge {
        let dx = (point.x - frame.midX) / max(frame.width, 1)
        let dy = (point.y - frame.midY) / max(frame.height, 1)
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .top : .bottom
    }

    /// A second click means a size, from every region that owns one. The header answers
    /// the way a window title bar does — it grows the pane into the space beside it — and
    /// a border steps through the same sizes its contextual menu lists. The body owns no
    /// size, so it keeps its drag whatever the click count.
    static func press(
        region: SpatialCanvasHitRegion,
        clickCount: Int
    ) -> SpatialCanvasPress {
        guard clickCount >= 2 else { return .begin(region) }
        switch region {
        case .header: return .fillWidth
        case .resize(let direction): return .cycleExtent(direction)
        case .body: return .begin(region)
        }
    }

    /// A right-click resolves to the menu the region it landed on owns. The edge is
    /// carried through so the border's menu resizes the same edge a drag there would.
    static func menu(for region: SpatialCanvasHitRegion) -> SpatialCanvasMenu {
        switch region {
        case .header: return .pane
        case .resize(let direction): return .resize(direction)
        case .body: return .surface
        }
    }

    func setCanvasSize(_ size: CGSize) {
        guard gesture == nil else { return }
        canvasSize = size
    }

    /// A representable may be refreshed for unrelated shell state while a gesture is
    /// live. Its preview remains authoritative only while the layout it started from
    /// is still the model's current layout.
    func isBased(on slots: [SpatialSlot]) -> Bool {
        gesture != nil && snapshot == slots
    }

    func snappedDelta(from start: CGPoint, to end: CGPoint) -> GridDelta {
        let cellWidth = max(canvasSize.width / CGFloat(SpatialLayout.columns), 1)
        let cellHeight = max(canvasSize.height / CGFloat(SpatialLayout.rows), 1)
        return GridDelta(
            columns: Int(((end.x - start.x) / cellWidth).rounded()),
            rows: Int(((end.y - start.y) / cellHeight).rounded())
        )
    }

    func beginMove(
        slotID: UUID,
        slots: [SpatialSlot],
        pointer: CGPoint
    ) {
        guard SpatialLayout.isValid(slots),
              slots.contains(where: { $0.id == slotID })
        else { return }
        snapshot = slots
        pointerOrigin = pointer
        gesture = .move(slotID: slotID)
        preview = nil
        moveTarget = nil
        isCarryingPane = false
    }

    func beginResize(
        slotID: UUID,
        direction: ResizeDirection,
        slots: [SpatialSlot],
        pointer: CGPoint
    ) {
        guard SpatialLayout.isValid(slots),
              slots.contains(where: { $0.id == slotID })
        else { return }
        snapshot = slots
        pointerOrigin = pointer
        gesture = .resize(slotID: slotID, direction: direction)
        preview = nil
    }

    @discardableResult
    func update(
        pointer: CGPoint,
        slotFrames: [UUID: CGRect] = [:]
    ) -> SpatialCanvasCommit? {
        guard let gesture else { return nil }
        let delta = snappedDelta(from: pointerOrigin, to: pointer)

        let candidate: SpatialCanvasCommit?
        switch gesture {
        case .move(let slotID):
            let distance = hypot(pointer.x - pointerOrigin.x, pointer.y - pointerOrigin.y)
            guard distance >= 4 else {
                preview = nil
                moveTarget = nil
                return nil
            }
            isCarryingPane = true
            if let hit = slotFrames.first(where: {
                $0.key != slotID && $0.value.contains(pointer)
            }) {
                let edge = Self.dropEdge(at: pointer, in: hit.value)
                let transaction = SpatialLayout.moveBeside(
                    snapshot,
                    slotID: slotID,
                    targetID: hit.key,
                    edge: edge
                )
                guard transaction.isValid else {
                    preview = nil
                    moveTarget = nil
                    return nil
                }
                moveTarget = SpatialCanvasMoveTarget(slotID: hit.key, edge: edge)
                candidate = .move(transaction)
            } else {
                moveTarget = nil
                guard let cell = Self.gridCell(at: pointer, canvasSize: canvasSize),
                      !snapshot.contains(where: { slot in
                          cell.column >= slot.rect.x &&
                              cell.column < slot.rect.x + slot.rect.width &&
                              cell.row >= slot.rect.y &&
                              cell.row < slot.rect.y + slot.rect.height
                      }),
                      let origin = snapshot.first(where: { $0.id == slotID })
                else {
                    preview = nil
                    return nil
                }
                let transaction = SpatialLayout.move(
                    snapshot,
                    slotID: slotID,
                    toColumn: origin.rect.x + delta.columns,
                    row: origin.rect.y + delta.rows
                )
                guard transaction.isValid else {
                    preview = nil
                    return nil
                }
                candidate = .move(transaction)
            }

        case .resize(let slotID, let direction):
            candidate = .resize(
                SpatialLayout.resize(
                    snapshot,
                    slotID: slotID,
                    direction: direction,
                    deltaColumns: delta.columns,
                    deltaRows: delta.rows
                )
            )
        }
        // A resize never previews a position it cannot commit: an invalid candidate
        // keeps the last valid edge. Pane moves clear their target above because the
        // floating thumbnail may cross gaps and its own source without a destination.
        if let candidate, candidate.isValid {
            preview = candidate
        }
        return preview
    }

    func cancel() -> [SpatialSlot]? {
        guard gesture != nil else { return nil }
        let result = snapshot
        clear()
        return result
    }

    func finish() -> SpatialCanvasEnd? {
        guard gesture != nil else { return nil }
        let baseline = snapshot
        let result: SpatialCanvasEnd
        if let preview,
           preview.isValid,
           preview.proposal != baseline {
            result = .commit(preview)
        } else {
            result = .rollback(baseline)
        }
        clear()
        return result
    }

    private func clear() {
        gesture = nil
        snapshot = []
        preview = nil
        moveTarget = nil
        isCarryingPane = false
    }
}
