// @domain: spatial-canvas
import AppKit
import Observation
import SwiftUI
import TenonCore

/// Where a pane drag that reached the tab bar would land.
enum TabBarDropTarget: Equatable {
    case none
    case newTab
    case existingTab(UUID)
}

/// Pure geometry: classify a pointer against the tab strip. `band` and every chip
/// frame are in *window* coordinates so they compare directly with
/// `NSEvent.locationInWindow` — no coordinate-space or flip reconciliation. Over a
/// chip → that tab; inside the band but over no chip → a new tab; outside → none.
enum TabBarDropResolver {
    static func resolve(
        point: CGPoint,
        band: CGRect,
        chips: [UUID: CGRect]
    ) -> TabBarDropTarget {
        guard band.contains(point) else { return .none }
        if let hit = chips.first(where: { $0.value.contains(point) }) {
            return .existingTab(hit.key)
        }
        return .newTab
    }
}

/// Where in the revealed tab's body a routed pane drop would land: beside an
/// existing pane on one of its edges, or filling an empty grid region — the same
/// two destinations the in-canvas drag offers, so switching tabs mid-drag never
/// shrinks where a pane may go.
enum RoutedPaneBodyDestination: Equatable {
    case beside(slotID: UUID, edge: SpatialDropEdge)
    case emptyRegion(GridRect)
}

/// The body destination chosen after a pane drag has switched tabs. The router owns
/// this value because the source tab's canvas is no longer the visible interaction
/// owner once the tab bar reveals another tab.
struct RoutedPaneDropTarget: Equatable {
    let tabID: UUID
    let destination: RoutedPaneBodyDestination
}

/// Identity-only state for a pane drag whose lifetime can cross tab-local canvases.
/// Geometry always comes from the currently visible canvas, so switching tabs cannot
/// carry a stale source layout into the destination's hit testing.
struct RoutedPaneDrag: Equatable {
    let slotID: UUID
    let sourceTabID: UUID
    var bodyTarget: RoutedPaneDropTarget?
    /// Body drops route only for a drag that actually visited the tab bar. An
    /// in-canvas gesture whose interaction died another way — an intervening store
    /// mutation staled its baseline — stays dead: releasing it commits nothing.
    var reachedTabBar: Bool = false
}

/// Main-thread geometry bridge between the SwiftUI tab bar and the AppKit spatial
/// canvas. The tab bar writes chip/band frames (window coordinates, non-published so
/// the fast layout path never loops back through SwiftUI); the canvas reads them
/// mid-drag to decide a reparent and publishes the live drop target back so the tab
/// bar can highlight it.
@Observable
@MainActor
final class DragRouter {
    @ObservationIgnored var tabBarBand: CGRect = .zero
    @ObservationIgnored var tabChipFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private(set) var paneDrag: RoutedPaneDrag?
    var activeDropTarget: TabBarDropTarget = .none

    func target(at windowPoint: CGPoint) -> TabBarDropTarget {
        TabBarDropResolver.resolve(
            point: windowPoint,
            band: tabBarBand,
            chips: tabChipFrames
        )
    }

    func beginPaneDrag(slotID: UUID, sourceTabID: UUID) {
        guard paneDrag == nil else { return }
        paneDrag = RoutedPaneDrag(
            slotID: slotID,
            sourceTabID: sourceTabID,
            bodyTarget: nil
        )
    }

    func setBodyTarget(_ target: RoutedPaneDropTarget?) {
        paneDrag?.bodyTarget = target
    }

    func markPaneDragReachedTabBar() {
        paneDrag?.reachedTabBar = true
    }

    func endPaneDrag() {
        paneDrag = nil
        activeDropTarget = .none
    }
}

/// Reports its backing view's frame in *window* coordinates whenever layout changes,
/// so a SwiftUI-laid-out view (a tab chip, the tab strip) can be hit-tested against
/// `NSEvent.locationInWindow` with no coordinate math. Placed as a `.background`.
struct WindowFrameReporter: NSViewRepresentable {
    let report: (CGRect) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.report = report
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        nsView.report = report
        nsView.reportFrame()
    }

    final class ReporterView: NSView {
        var report: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            reportFrame()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        func reportFrame() {
            guard window != nil else { return }
            report?(convert(bounds, to: nil))
        }
    }
}
