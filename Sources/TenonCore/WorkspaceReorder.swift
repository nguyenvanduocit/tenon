// @domain: workspace-model
import Foundation

/// One workspace row's vertical extent in the sidebar coordinate space.
///
/// Reordering reads only the axis the rows occupy. Keeping the rule independent of SwiftUI
/// geometry makes every insertion boundary and refusal testable without mounting a window.
public struct WorkspaceRowExtent: Equatable, Sendable {
    public let id: UUID
    public let minY: Double
    public let maxY: Double

    public init(id: UUID, minY: Double, maxY: Double) {
        self.id = id
        self.minY = minY
        self.maxY = maxY
    }

    public var midY: Double { (minY + maxY) / 2 }
}

/// Pure rules for moving one workspace through the sidebar's ordered row list.
///
/// The pointer drag stays inside the host view and carries no pasteboard payload. The dragged
/// workspace is always named by stable UUID, while insertion boundaries are translated into
/// array indices only at the typed catalog mutation edge.
public enum WorkspaceReorder {
    /// Horizontal room for an imprecise pointer before the drag is treated as cancelled.
    public static let dropSlack: Double = 44

    /// Whether the pointer is still aimed at the sidebar row band.
    public static func admitsDrop(pointerX: Double, minX: Double, maxX: Double) -> Bool {
        pointerX >= minX - dropSlack && pointerX <= maxX + dropSlack
    }

    /// The vertical gap named by the pointer: before the first row, after the last row, or
    /// the number of row midpoints it has passed.
    public static func insertionIndex(at pointerY: Double, rows: [WorkspaceRowExtent]) -> Int {
        rows.count { $0.midY < pointerY }
    }

    /// The array index `id` would land on, or `nil` when the move is invalid or a no-op.
    public static func destination(
        forWorkspace id: UUID,
        insertingAt insertion: Int,
        rows: [WorkspaceRowExtent]
    ) -> Int? {
        guard let source = rows.firstIndex(where: { $0.id == id }) else { return nil }
        guard insertion >= 0, insertion <= rows.count else { return nil }
        guard insertion != source, insertion != source + 1 else { return nil }
        return insertion > source ? insertion - 1 : insertion
    }

    public static func announcement(name: String, movedTo index: Int, of count: Int) -> String {
        "Moved \(name) to workspace \(index + 1) of \(count)"
    }

    public static func spokenPosition(_ index: Int, of count: Int, isActive: Bool) -> String {
        let place = "workspace \(index + 1) of \(count)"
        return isActive ? "\(place), active" : place
    }
}
