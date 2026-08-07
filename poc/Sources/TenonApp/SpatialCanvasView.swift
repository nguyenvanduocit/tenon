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
        slots: [SpatialSlot]
    ) -> CGPoint? {
        emptyGridLauncherTarget(
            at: point,
            canvasSize: canvasSize,
            slots: slots
        )?.anchor
    }

    static func emptyGridLauncherTarget(
        at point: CGPoint,
        canvasSize: CGSize,
        slots: [SpatialSlot]
    ) -> EmptyGridLauncherTarget? {
        guard let cell = gridCell(at: point, canvasSize: canvasSize) else { return nil }
        guard let rect = SpatialLayout.bestEmptyRect(
            in: slots,
            containingColumn: cell.column,
            row: cell.row
        ) else { return nil }
        return EmptyGridLauncherTarget(anchor: point, rect: rect)
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

struct SpatialCanvasView: NSViewRepresentable {
    let tab: TenonCore.Tab
    let workspacePath: URL
    let allLiveSlotIDs: Set<UUID>
    let activeSlotID: UUID?
    let store: WorkspaceStore
    let pool: SurfacePool
    let agentLens: AgentLensPool
    let webPool: PluginWebSurfacePool
    let host: PluginHost
    let intentRuntime: AppIntentRuntime
    let palette: CommandPaletteState
    let agentSuggestions: [AgentLaunchSuggestion]
    let editorStates: EditorPaneStateStore
    let pluginSnapshots: [PluginSnapshot]
    let pluginViewSections: [PluginViewSection]
    let webSurfaceTitles: [WebSurfaceKey: String]
    /// T-029: the per-slot attention projection; the card header shows its state dot.
    let paneAttention: [UUID: PaneActivity]
    /// The host-native panes' header contributions, passed as a VALUE exactly like
    /// `paneAttention`. `WorkspaceStageView.body` reads them off `PaneHeaderStore`, and
    /// that read is what invalidates this representable when one changes.
    let paneHeaders: [UUID: PaneHeader]
    /// The same store, for the command route back down. Held apart from the dictionary
    /// because routing a click is not something a re-render should depend on.
    let paneHeaderStore: PaneHeaderStore
    let router: DragRouter
    let automation: AutomationScheduler
    let automationSchedulesEnabled: Bool
    let automationActions: AutomationPaneActions

    func makeNSView(context: Context) -> SpatialCanvasNSView {
        SpatialCanvasNSView()
    }

    func updateNSView(_ view: SpatialCanvasNSView, context: Context) {
        view.configure(
            tab: tab,
            workspacePath: workspacePath,
            allLiveSlotIDs: allLiveSlotIDs,
            activeSlotID: activeSlotID,
            store: store,
            pool: pool,
            agentLens: agentLens,
            webPool: webPool,
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
            agentSuggestions: agentSuggestions,
            editorStates: editorStates,
            pluginSnapshots: pluginSnapshots,
            pluginViewSections: pluginViewSections,
            webSurfaceTitles: webSurfaceTitles,
            paneAttention: paneAttention,
            paneHeaders: paneHeaders,
            paneHeaderStore: paneHeaderStore,
            router: router,
            automation: automation,
            automationSchedulesEnabled: automationSchedulesEnabled,
            automationActions: automationActions
        )
    }

    static func dismantleNSView(
        _ view: SpatialCanvasNSView,
        coordinator: Coordinator
    ) {
        view.prepareForRemoval()
    }
}

final class SpatialCanvasNSView: NSView, NSPopoverDelegate {
    private let interaction = SpatialCanvasInteractionCoordinator(canvasSize: .zero)
    private var cards: [UUID: SpatialSlotCardView] = [:]
    private var displayedSlots: [SpatialSlot] = []
    private var store: WorkspaceStore?
    private var pool: SurfacePool?
    private var host: PluginHost?
    private var intentRuntime: AppIntentRuntime?
    private var palette: CommandPaletteState?
    private var paneHeaderStore: PaneHeaderStore?
    /// The live contribution list, kept because a header click on a plugin pane has to find
    /// the section it came from — the pane's own instance, and its `instanceID` — at the
    /// moment of the click rather than at the moment the card was built.
    private var pluginViewSections: [PluginViewSection] = []
    private var agentSuggestions: [AgentLaunchSuggestion] = []
    private var router: DragRouter?
    private var tabID: UUID?
    private var activeSlotID: UUID?
    private var gestureSlotID: UUID?
    private var responderBeforeGesture: NSResponder?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var launcherPopover: NSPopover?
    private(set) var dragThumbnailView: SpatialDragThumbnailView?
    private(set) var dropHighlightView: SpatialDropHighlightView?

    /// Test seam for the AppKit presentation edge. Production leaves it nil and hosts
    /// `LauncherMenu` below; tests replace only the final popover side effect while the
    /// same empty-grid routing still runs.
    var onPresentEmptyGridLauncher: ((NSRect, GridRect) -> Void)?

    private var gestureIsMove = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = TenonTheme.panelNS.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("tenon.canvas")
        setAccessibilityLabel("Spatial canvas")
        setAccessibilityHelp(
            "Press Option-Return or use a Fill Empty Region action to open content in free space."
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMouseMonitorIfNeeded()
            installKeyMonitorIfNeeded()
        } else {
            prepareForRemoval()
        }
    }

    override func layout() {
        super.layout()
        interaction.setCanvasSize(bounds.size)
        applyFrames(displayedSlots)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        TenonTheme.lineNS.withAlphaComponent(0.18).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        for column in 1..<SpatialLayout.columns {
            let x = CGFloat(column) * bounds.width / CGFloat(SpatialLayout.columns)
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
        }
        for row in 1..<SpatialLayout.rows {
            let y = CGFloat(row) * bounds.height / CGFloat(SpatialLayout.rows)
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: bounds.width, y: y))
        }
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        if handleEmptyGridShortcut(event) {
            return
        }
        if event.keyCode == 53, cancelGesture() {
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let targets = SpatialCanvasInteractionCoordinator.emptyGridLauncherTargets(
            canvasSize: bounds.size,
            slots: displayedSlots
        )
        guard !targets.isEmpty else { return nil }
        return targets.map { target in
            NSAccessibilityCustomAction(
                name: Self.accessibilityFillName(for: target.rect)
            ) { [weak self] in
                self?.requestEmptyGridLauncher(at: target.anchor) == true
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard requestEmptyGridLauncher(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard requestEmptyGridLauncher(at: point) else {
            super.mouseDown(with: event)
            return
        }
    }

    func configure(
        tab: TenonCore.Tab,
        workspacePath: URL,
        allLiveSlotIDs: Set<UUID>,
        activeSlotID: UUID?,
        store: WorkspaceStore,
        pool: SurfacePool,
        agentLens: AgentLensPool,
        webPool: PluginWebSurfacePool,
        host: PluginHost,
        intentRuntime: AppIntentRuntime,
        palette: CommandPaletteState,
        agentSuggestions: [AgentLaunchSuggestion],
        editorStates: EditorPaneStateStore,
        pluginSnapshots: [PluginSnapshot],
        pluginViewSections: [PluginViewSection],
        webSurfaceTitles: [WebSurfaceKey: String],
        paneAttention: [UUID: PaneActivity],
        paneHeaders: [UUID: PaneHeader],
        paneHeaderStore: PaneHeaderStore,
        router: DragRouter,
        automation: AutomationScheduler,
        automationSchedulesEnabled: Bool,
        automationActions: AutomationPaneActions
    ) {
        if let bodyTarget = router.paneDrag?.bodyTarget,
           bodyTarget.tabID != tab.id {
            router.setBodyTarget(nil)
            dropHighlightView?.removeFromSuperview()
            dropHighlightView = nil
        }
        if case .existingTab(let highlightedTabID) = router.activeDropTarget,
           highlightedTabID != tab.id {
            router.activeDropTarget = .none
        }
        let authoritativeSlots = tab.spatialSlots
        let preservesGesturePreview = self.tabID == tab.id &&
            interaction.isBased(on: authoritativeSlots)
        if interaction.isActive && !preservesGesturePreview {
            let routedSlotID = router.paneDrag?.slotID
            let continuesRoutedPaneDrag = gestureIsMove &&
                routedSlotID == gestureSlotID &&
                routedSlotID.flatMap { store.catalog.slot(id: $0) } != nil
            if continuesRoutedPaneDrag {
                // The source canvas hands off identity only. Its geometry snapshot is
                // discarded; the newly visible tab will provide fresh hit-test frames.
                _ = interaction.cancel()
            } else {
                // A real layout change unrelated to the routed pane drag makes the
                // pointer snapshot stale and cancels the gesture atomically.
                _ = cancelGesture()
            }
        }

        self.store = store
        self.pool = pool
        self.host = host
        self.intentRuntime = intentRuntime
        self.palette = palette
        self.agentSuggestions = agentSuggestions
        self.paneHeaderStore = paneHeaderStore
        self.pluginViewSections = pluginViewSections
        self.router = router
        self.tabID = tab.id
        self.activeSlotID = activeSlotID
        interaction.setCanvasSize(bounds.size)
        // Backstop for a content view torn down without `onDisappear`. The store defers the
        // write it implies: this method is reached only from `updateNSView`, and dropping a
        // stale entry here would mutate the very observable the stage read to get here.
        paneHeaderStore.scheduleSweep(retaining: allLiveSlotIDs)

        for id in Array(cards.keys) where !allLiveSlotIDs.contains(id) {
            cards[id]?.removeFromSuperview()
            cards.removeValue(forKey: id)
        }

        let activePluginRenderIdentities = Set(
            pluginSnapshots.compactMap {
                plugin -> PluginRenderIdentity? in
                guard plugin.isEnabled,
                      plugin.isLoaded,
                      let installationID = plugin.installationID
                else {
                    return nil
                }
                return PluginRenderIdentity(
                    installation: PluginInstallationKey(
                        pluginID: plugin.id,
                        installationID: installationID
                    ),
                    allowsWebView: plugin.permissions.contains("web.view")
                )
            }
        )
        for card in cards.values {
            card.invalidatePluginContent(
                unlessActiveIn: activePluginRenderIdentities
            )
        }

        for slot in tab.slots {
            let card = cards[slot.id] ?? makeCard(slotID: slot.id)
            if card.superview == nil {
                addSubview(card)
            }
            card.configure(
                slot: slot,
                workspacePath: workspacePath,
                title: SlotPresentation.title(
                    for: slot,
                    workspacePath: workspacePath,
                    pool: pool,
                    webPool: webPool,
                    pluginSnapshots: pluginSnapshots,
                    pluginViewSections: pluginViewSections,
                    webSurfaceTitles: webSurfaceTitles
                ),
                header: PaneHeaderProjection.header(
                    for: slot,
                    published: paneHeaders[slot.id],
                    pluginViewSections: pluginViewSections
                ),
                headerStore: paneHeaderStore,
                isActive: slot.id == activeSlotID,
                showsFocusRing: tab.slots.count > 1,
                store: store,
                pool: pool,
                agentLens: agentLens,
                webPool: webPool,
                editorStates: editorStates,
                pluginSnapshots: pluginSnapshots,
                agentSuggestions: agentSuggestions,
                host: host,
                automation: automation,
                automationSchedulesEnabled: automationSchedulesEnabled,
                automationActions: automationActions
            )
            card.setAttention(paneAttention[slot.id]?.state)
        }

        let visibleIDs = Set(tab.slots.map(\.id))
        for id in Array(cards.keys) where !visibleIDs.contains(id) {
            cards[id]?.removeFromSuperview()
        }
        webPool.reconcile(catalog: store.catalog, host: host)

        if !preservesGesturePreview {
            displayedSlots = authoritativeSlots
        }
        applyFrames(displayedSlots)
        refreshCardActivity()
    }

    /// Opens the shared launcher at a right-/control-click that belongs to no pane.
    /// Returning whether the click was consumed keeps the responder fallback explicit.
    @discardableResult
    func requestEmptyGridLauncher(at point: CGPoint) -> Bool {
        guard let target = SpatialCanvasInteractionCoordinator.emptyGridLauncherTarget(
            at: point,
            canvasSize: bounds.size,
            slots: displayedSlots
        ) else { return false }

        return presentEmptyGridLauncher(target)
    }

    private func requestBestEmptyGridLauncher() -> Bool {
        guard let rect = SpatialLayout.bestEmptyRect(
            in: displayedSlots,
            near: store?.catalog.activeSlotID
        ) else { return false }
        let target = EmptyGridLauncherTarget(
            anchor: CGPoint(
                x: CGFloat(rect.x * 2 + rect.width) * bounds.width /
                    CGFloat(SpatialLayout.columns * 2),
                y: CGFloat(rect.y * 2 + rect.height) * bounds.height /
                    CGFloat(SpatialLayout.rows * 2)
            ),
            rect: rect
        )
        return presentEmptyGridLauncher(target)
    }

    private func presentEmptyGridLauncher(_ target: EmptyGridLauncherTarget) -> Bool {
        let anchor = NSRect(x: target.anchor.x, y: target.anchor.y, width: 1, height: 1)
        if let onPresentEmptyGridLauncher {
            onPresentEmptyGridLauncher(anchor, target.rect)
        } else {
            presentEmptyGridLauncher(relativeTo: anchor, targetRect: target.rect)
        }
        return true
    }

    private static func accessibilityFillName(for rect: GridRect) -> String {
        "Fill empty region, columns \(rect.x + 1) through \(rect.x + rect.width), " +
            "rows \(rect.y + 1) through \(rect.y + rect.height)"
    }

    /// Hosts the exact search-first launcher used by the title-bar `+` and tab-chip
    /// right-click. Membership, ranking, grouping, icons, invocation, failure display,
    /// and frecency therefore remain one implementation in `LauncherMenu`.
    private func presentEmptyGridLauncher(relativeTo anchor: NSRect, targetRect: GridRect) {
        guard let store, let pool, let host, let intentRuntime, let palette, window != nil
        else { return }

        launcherPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: LauncherMenu(
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
            agentSuggestions: agentSuggestions,
            launchAgent: { suggestion in
                AgentLaunchExecutor.run(
                    suggestion,
                    placement: .emptyGrid(targetRect),
                    workspaceStore: store,
                    terminalPool: pool
                )
            },
            send: { commandID in
                guard let invocation = PaletteIntentInvoker.prepare(
                    commandID: commandID,
                    host: host
                ) else { return .unavailable }
                return await EmptyGridLauncherPlacement.invoke(
                    in: store,
                    targetRect: targetRect,
                    userGestureID: invocation.userGestureID
                ) { scope in
                    await PaletteIntentInvoker.send(
                        invocation,
                        scope: scope,
                        runtime: intentRuntime
                    )
                }
            },
            purpose: .fillEmptyGrid,
            dismiss: { [weak self, weak popover] in
                popover?.performClose(nil)
                if self?.launcherPopover === popover {
                    self?.launcherPopover = nil
                }
            }
        ))
        launcherPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover,
              closed === launcherPopover
        else { return }
        launcherPopover = nil
    }

    private func makeCard(slotID: UUID) -> SpatialSlotCardView {
        let card = SpatialSlotCardView(slotID: slotID)
        card.onClose = { [weak self] id in
            self?.store?.closeSlot(id)
        }
        card.onBegin = { [weak self] id, region, point in
            self?.begin(slotID: id, region: region, pointer: point)
        }
        card.onDrag = { [weak self] canvasPoint, windowPoint in
            self?.drag(to: canvasPoint, window: windowPoint)
        }
        card.onEnd = { [weak self] in
            self?.end()
        }
        card.onFillWidth = { [weak self] id in
            self?.store?.fillSlotWidth(id)
        }
        card.onRequestMenu = { [weak self] id in
            self?.slotContextMenu(for: id)
        }
        card.onCycleExtent = { [weak self] id, direction in
            self?.store?.cycleSlotExtent(id, direction: direction)
        }
        card.onRequestResizeMenu = { [weak self] id, direction in
            self?.resizeContextMenu(for: id, direction: direction)
        }
        // A header control focuses its pane before it acts. The ✕ stays the documented
        // exception: everything else here hands the pane's own state a change, and a
        // change made to a pane AppKit does not consider focused leaves `activeSlotID`
        // pointing somewhere else — ⌘W would then close the wrong pane.
        card.onHeaderAction = { [weak self] id, action in
            guard let self, let slot = self.store?.catalog.slot(id: id) else { return }
            self.store?.focusSlot(id)
            guard case let .pluginView(pluginID, viewID) = slot.content else {
                // A built-in pane's controls resolve through the typed enum and nothing
                // else, so no free-form string ever routes between two parts of the one
                // host semantic owner.
                guard let command = PaneHeaderCommand(rawValue: action.itemID) else { return }
                self.paneHeaderStore?.perform(command, value: action.value, for: id)
                return
            }
            self.routePluginHeaderAction(
                action,
                pluginID: pluginID,
                viewID: viewID,
                slotID: id
            )
        }
        cards[slotID] = card
        return card
    }

    /// A click on a plugin pane's header, delivered back to that plugin.
    ///
    /// It is the same EVENT fact a row click and a body button click already are, so it takes
    /// the same two routes back into the view — no third callback, and nothing new on `tenon`.
    /// WHICH of the two is a property of the item's KIND rather than of the click: a
    /// `textfield` commits through `onSubmit`, and every other control selects. The question is
    /// asked of the header the plugin actually published, read from the section this slot
    /// matched, so the answer is the plugin's own declaration and never a guess about ids.
    ///
    /// A pane whose plugin has since retired resolves to no section and the click is dropped —
    /// which is the same answer its chrome gives, because both read the live contribution list.
    private func routePluginHeaderAction(
        _ action: PaneHeaderAction,
        pluginID: PluginID,
        viewID: String,
        slotID: UUID
    ) {
        guard let host,
              let section = PaneHeaderProjection.section(
                  pluginID: pluginID,
                  viewID: viewID,
                  slotID: slotID,
                  in: pluginViewSections
              )
        else { return }
        let instanceID = section.instanceID
        let itemID = action.itemID
        if case .textfield = section.header.item(id: itemID) {
            let text = action.value ?? ""
            Task { @MainActor in
                _ = await host.invokeViewSubmit(
                    pluginID: pluginID,
                    viewID: viewID,
                    instanceID: instanceID,
                    itemID: itemID,
                    text: text
                )
            }
        } else {
            let value = action.value
            Task { @MainActor in
                _ = await host.invokeViewSelect(
                    pluginID: pluginID,
                    viewID: viewID,
                    instanceID: instanceID,
                    itemID: itemID,
                    value: value.map(IntentValue.string)
                )
            }
        }
    }

    /// Builds the pane header's contextual menu. It lives here, not on the card,
    /// because the actions are just projections of existing `WorkspaceStore`
    /// operations — the card stays a dumb view with no store reference. "Split"
    /// and "Stack" reuse the shell toolbar's exact vocabulary (right / down), and
    /// "Duplicate" is `WorkspaceStore.duplicateSlot` — a second pane showing what
    /// this one shows, wherever the layout has room for it.
    func slotContextMenu(for slotID: UUID) -> NSMenu? {
        guard let store,
              let slot = store.catalog.slot(id: slotID)
        else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(SlotMenuItem(
            title: "Split",
            keyEquivalent: "d",
            modifiers: .command,
            isEnabled: slot.rect.width >= SpatialLayout.minimumWidth * 2
        ) { [weak store] in
            store?.splitSlot(slotID, .horizontal)
        })
        menu.addItem(SlotMenuItem(
            title: "Stack",
            keyEquivalent: "d",
            modifiers: [.command, .shift],
            isEnabled: slot.rect.height >= SpatialLayout.minimumHeight * 2
        ) { [weak store] in
            store?.splitSlot(slotID, .vertical)
        })

        menu.addItem(SlotMenuItem(
            title: "Duplicate",
            isEnabled: store.catalog.canDuplicateSlot(slotID)
        ) { [weak store] in
            store?.duplicateSlot(slotID)
        })

        menu.addItem(.separator())

        menu.addItem(SlotMenuItem(title: "Close", isEnabled: true) { [weak store] in
            store?.closeSlot(slotID)
        })

        return menu
    }

    /// The border's contextual menu: the drag that border performs, offered as three
    /// destinations. The clicked edge decides what changes and stays fixed at the
    /// opposite side, so the menu is the drag without the pixel accuracy. A destination
    /// the layout would refuse — a size that would swallow a neighbour, or the size the
    /// pane already has — is shown disabled rather than hidden, so the border's
    /// vocabulary reads the same everywhere it appears.
    func resizeContextMenu(for slotID: UUID, direction: ResizeDirection) -> NSMenu? {
        guard let store, store.catalog.slot(id: slotID) != nil else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledInfoItem(SpatialCanvasNSView.resizeMenuHeading(direction)))

        for (title, fraction) in [
            ("1/3", SpatialExtentFraction.oneThird),
            ("1/2", .oneHalf),
            ("Full", .full),
        ] {
            menu.addItem(SlotMenuItem(
                title: title,
                isEnabled: SpatialLayout.resize(
                    displayedSlots,
                    slotID: slotID,
                    direction: direction,
                    fraction: fraction
                ).isValid
            ) { [weak store] in
                store?.resizeSlot(slotID, direction: direction, fraction: fraction)
            })
        }

        return menu
    }

    /// Names the axes the clicked edge moves, so the fractions below it are unambiguous.
    private static func resizeMenuHeading(_ direction: ResizeDirection) -> String {
        let width = direction.includesEast || direction.includesWest
        let height = direction.includesNorth || direction.includesSouth
        if width && height { return "Set Width & Height" }
        return width ? "Set Width" : "Set Height"
    }

    /// A non-actionable label. `menu.autoenablesItems` is already false, so a plain
    /// disabled item stays readable rather than being culled.
    private func disabledInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func begin(
        slotID: UUID,
        region: SpatialCanvasHitRegion,
        pointer: CGPoint
    ) {
        switch region {
        case .header:
            interaction.beginMove(
                slotID: slotID,
                slots: displayedSlots,
                pointer: pointer
            )
            gestureIsMove = true
        case .resize(let direction):
            interaction.beginResize(
                slotID: slotID,
                direction: direction,
                slots: displayedSlots,
                pointer: pointer
            )
            gestureIsMove = false
        case .body:
            return
        }
        gestureSlotID = slotID
        responderBeforeGesture = window?.firstResponder
        window?.makeFirstResponder(self)
    }

    func drag(to point: CGPoint, window windowPoint: CGPoint? = nil) {
        // Cards from other tabs remain cached to keep their live surfaces mounted,
        // but only the active tab's attached cards may participate in drop routing.
        let slotFrames: [UUID: CGRect] = Dictionary(
            uniqueKeysWithValues: displayedSlots.compactMap { slot -> (UUID, CGRect)? in
                guard let card = cards[slot.id], card.superview === self else { return nil }
                return (slot.id, card.frame)
            }
        )
        let preview = interaction.update(pointer: point, slotFrames: slotFrames)
        if interaction.isCarryingPane,
           let gestureSlotID,
           let tabID {
            router?.beginPaneDrag(slotID: gestureSlotID, sourceTabID: tabID)
        }

        // A header drag that reaches the tab bar switches to reparent mode: the
        // in-canvas layout freezes, the tab bar highlights the target, and an
        // existing target tab becomes the visible body immediately. Releasing on
        // the chip still uses the original reparent operation.
        if gestureIsMove,
           router?.paneDrag != nil,
           let router,
           let windowPoint {
            let target = router.target(at: windowPoint)
            if target != .none {
                router.setBodyTarget(nil)
                router.activeDropTarget = target
                updateMovePresentation(at: point, acceptsExternalDrop: true)
                if case .existingTab(let targetTabID) = target,
                   store?.catalog.activeTab?.id != targetTabID {
                    store?.selectTab(targetTabID)
                }
                return
            }
        }
        if router?.activeDropTarget != TabBarDropTarget.none {
            router?.activeDropTarget = .none
        }

        // Once another tab has been revealed, its own card frames decide the body
        // destination. The router carries only pane identity and the chosen target;
        // no geometry from the source tab survives the handoff.
        if gestureIsMove {
            if !interaction.isActive,
               let routed = router?.paneDrag,
               let tabID {
                let hit = slotFrames.first { frame in
                    frame.key != routed.slotID && frame.value.contains(point)
                }
                if let hit {
                    let edge = SpatialCanvasInteractionCoordinator.dropEdge(
                        at: point,
                        in: hit.value
                    )
                    let valid: Bool
                    if tabID == routed.sourceTabID {
                        valid = SpatialLayout.moveBeside(
                            displayedSlots,
                            slotID: routed.slotID,
                            targetID: hit.key,
                            edge: edge
                        ).isValid
                    } else {
                        valid = SpatialLayout.insertBeside(
                            displayedSlots,
                            newSlotID: routed.slotID,
                            targetID: hit.key,
                            edge: edge
                        ) != nil
                    }
                    if valid {
                        let target = RoutedPaneDropTarget(
                            tabID: tabID,
                            slotID: hit.key,
                            edge: edge
                        )
                        router?.setBodyTarget(target)
                        updateMovePresentation(
                            at: point,
                            routedTarget: SpatialCanvasMoveTarget(
                                slotID: hit.key,
                                edge: edge
                            )
                        )
                        return
                    }
                }
                router?.setBodyTarget(nil)
                updateMovePresentation(at: point)
                return
            }
            router?.setBodyTarget(nil)
            updateMovePresentation(at: point)
            return
        }
        guard let preview else { return }
        displayedSlots = preview.proposal
        applyFrames(displayedSlots)
    }

    func end() {
        // Released over the tab bar: reparent instead of committing an in-canvas
        // move. The slot keeps its identity, so its terminal surface survives the
        // hop; `retainOnly` never sees the id leave the catalog.
        if let tabTarget = router?.activeDropTarget,
           tabTarget != .none {
            let slotID = router?.paneDrag?.slotID ?? gestureSlotID
            _ = interaction.cancel()
            clearMovePresentation()
            switch tabTarget {
            case .newTab:
                if let slotID { store?.moveSlotToNewTab(slotID) }
            case .existingTab(let targetTabID):
                if let slotID { store?.moveSlot(slotID, toTab: targetTabID) }
            case .none:
                break
            }
            router?.endPaneDrag()
            synchronizeWithStore(fallback: displayedSlots)
            refreshCardActivity()
            finishGestureFocus(cancelled: false)
            return
        }

        // Released in the body shown by a hover-selected tab. Recompute the final
        // transaction from that tab's authoritative layout; the router never stores
        // source-tab geometry.
        if let routed = router?.paneDrag,
           let target = routed.bodyTarget {
            _ = interaction.cancel()
            clearMovePresentation()
            if target.tabID == tabID,
               let activeTab = store?.catalog.activeTab,
               activeTab.id == target.tabID {
                if target.tabID == routed.sourceTabID {
                    let transaction = SpatialLayout.moveBeside(
                        activeTab.spatialSlots,
                        slotID: routed.slotID,
                        targetID: target.slotID,
                        edge: target.edge
                    )
                    if transaction.isValid {
                        store?.applyMove(transaction)
                    }
                } else {
                    store?.moveSlot(
                        routed.slotID,
                        toTab: target.tabID,
                        beside: target.slotID,
                        edge: target.edge
                    )
                }
            }
            router?.endPaneDrag()
            synchronizeWithStore(fallback: displayedSlots)
            refreshCardActivity()
            finishGestureFocus(cancelled: false)
            return
        }

        if router?.paneDrag != nil,
           !interaction.isActive {
            _ = cancelGesture()
            return
        }

        guard let result = interaction.finish() else { return }
        clearMovePresentation()
        switch result {
        case .rollback(let snapshot):
            synchronizeWithStore(fallback: snapshot)
        case .commit(let commit):
            switch commit {
            case .move(let transaction):
                store?.applyMove(transaction)
            case .resize(let transaction):
                store?.applyResize(transaction)
            }
            synchronizeWithStore(fallback: commit.proposal)
        }
        if let gestureSlotID,
           store?.catalog.slot(id: gestureSlotID) != nil {
            store?.focusSlot(gestureSlotID)
        }
        synchronizeWithStore(fallback: displayedSlots)
        refreshCardActivity()
        router?.endPaneDrag()
        finishGestureFocus(cancelled: false)
    }

    @discardableResult
    func cancelGesture() -> Bool {
        let snapshot = interaction.cancel()
        guard snapshot != nil || router?.paneDrag != nil else { return false }
        clearMovePresentation()
        router?.endPaneDrag()
        synchronizeWithStore(fallback: snapshot ?? displayedSlots)
        refreshCardActivity()
        finishGestureFocus(cancelled: true)
        return true
    }

    /// Kero-style pickup: the source remains mounted and dimmed, while one bitmap
    /// snapshot follows the pointer and a separate overlay describes the drop.
    private func updateMovePresentation(
        at point: CGPoint,
        acceptsExternalDrop: Bool = false,
        routedTarget: SpatialCanvasMoveTarget? = nil
    ) {
        guard interaction.isCarryingPane || router?.paneDrag != nil,
              let sourceID = gestureSlotID,
              let sourceCard = cards[sourceID]
        else { return }

        let thumbnail: SpatialDragThumbnailView
        if let dragThumbnailView {
            thumbnail = dragThumbnailView
        } else {
            let size = Self.thumbnailSize(for: sourceCard.frame.size)
            thumbnail = SpatialDragThumbnailView(image: sourceCard.paneSnapshot())
            thumbnail.frame.size = size
            addSubview(thumbnail, positioned: .above, relativeTo: nil)
            dragThumbnailView = thumbnail
        }
        sourceCard.alphaValue = 0.55
        thumbnail.frame.origin = CGPoint(
            x: point.x - thumbnail.frame.width / 2,
            y: point.y - thumbnail.frame.height / 2
        )

        let targetFrame: CGRect?
        if let target = routedTarget ?? interaction.moveTarget,
           let targetCard = cards[target.slotID] {
            targetFrame = Self.highlightFrame(for: target.edge, in: targetCard.frame)
        } else if case .move(let transaction) = interaction.preview,
                  let rect = transaction.proposal.first(where: { $0.id == sourceID })?.rect {
            targetFrame = cardFrame(for: rect)
        } else {
            targetFrame = nil
        }

        if !acceptsExternalDrop, let targetFrame {
            let highlight = dropHighlightView ?? SpatialDropHighlightView()
            highlight.frame = targetFrame
            if highlight.superview == nil {
                addSubview(highlight, positioned: .above, relativeTo: nil)
                addSubview(thumbnail, positioned: .above, relativeTo: highlight)
            }
            dropHighlightView = highlight
            NSCursor.closedHand.set()
        } else {
            dropHighlightView?.removeFromSuperview()
            dropHighlightView = nil
            (acceptsExternalDrop ? NSCursor.closedHand : NSCursor.operationNotAllowed).set()
        }
    }

    private func clearMovePresentation() {
        if let gestureSlotID {
            cards[gestureSlotID]?.alphaValue = 1
        }
        dragThumbnailView?.removeFromSuperview()
        dragThumbnailView = nil
        dropHighlightView?.removeFromSuperview()
        dropHighlightView = nil
        NSCursor.arrow.set()
    }

    private static func thumbnailSize(for source: CGSize) -> CGSize {
        let maximum = CGSize(width: 220, height: 160)
        guard source.width > 0, source.height > 0 else { return maximum }
        let scale = min(maximum.width / source.width, maximum.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private static func highlightFrame(
        for edge: SpatialDropEdge,
        in target: CGRect
    ) -> CGRect {
        switch edge {
        case .left:
            return CGRect(
                x: target.minX,
                y: target.minY,
                width: target.width / 2,
                height: target.height
            )
        case .right:
            return CGRect(
                x: target.midX,
                y: target.minY,
                width: target.width / 2,
                height: target.height
            )
        case .top:
            return CGRect(
                x: target.minX,
                y: target.minY,
                width: target.width,
                height: target.height / 2
            )
        case .bottom:
            return CGRect(
                x: target.minX,
                y: target.midY,
                width: target.width,
                height: target.height / 2
            )
        }
    }

    private func applyFrames(_ slots: [SpatialSlot]) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        for slot in slots {
            guard let card = cards[slot.id] else { continue }
            card.frame = cardFrame(for: slot.rect)
            card.updateAccessibilityValue(for: slot)
        }
    }

    private func cardFrame(for rect: GridRect) -> CGRect {
        let cellWidth = bounds.width / CGFloat(SpatialLayout.columns)
        let cellHeight = bounds.height / CGFloat(SpatialLayout.rows)
        let cell = CGRect(
            x: CGFloat(rect.x) * cellWidth,
            y: CGFloat(rect.y) * cellHeight,
            width: max(CGFloat(rect.width) * cellWidth, 1),
            height: max(CGFloat(rect.height) * cellHeight, 1)
        )
        // The drop preview uses the same inset geometry as a committed pane, so the
        // highlight cannot promise pixels the card will not occupy after mouse-up.
        let inset = TenonTheme.slotGutter / 2
        return CGRect(
            x: cell.minX + inset,
            y: cell.minY + inset,
            width: max(cell.width - TenonTheme.slotGutter, 1),
            height: max(cell.height - TenonTheme.slotGutter, 1)
        )
    }

    /// Re-applies each card's active border after the authoritative geometry (and
    /// with it `activeSlotID`) may have changed without a full reconfigure.
    private func refreshCardActivity() {
        for (id, card) in cards {
            card.setState(isActive: id == activeSlotID)
        }
    }

    private func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  event.window === self.window
            else { return event }
            switch event.type {
            case .leftMouseDown:
                let point = self.convert(event.locationInWindow, from: nil)
                self.handleLocalLeftMouseDown(at: point)
                return event
            case .leftMouseDragged:
                guard self.gestureSlotID != nil || self.router?.paneDrag != nil else {
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                self.drag(to: point, window: event.locationInWindow)
                return nil
            case .leftMouseUp:
                guard self.gestureSlotID != nil || self.router?.paneDrag != nil else {
                    return event
                }
                self.end()
                return nil
            default:
                return event
            }
        }
    }

    /// The terminal normally owns the responder chain, so a canvas-only `keyDown` cannot
    /// make its empty-region shortcut reachable during ordinary work. This monitor is
    /// scoped to the canvas's own window and consumes Option-Return only when it actually
    /// opens a valid empty region.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.launcherPopover?.isShown != true,
                  self.handleEmptyGridShortcut(event)
            else { return event }
            return nil
        }
    }

    private func handleEmptyGridShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        return !event.isARepeat &&
            event.keyCode == 36 &&
            modifiers == .option &&
            requestBestEmptyGridLauncher()
    }

    func stopEventMonitoring() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        launcherPopover?.performClose(nil)
        launcherPopover = nil
    }

    /// Ends all gesture-owned state before the canvas leaves its window. AppKit can
    /// dismantle or detach the representable without delivering mouse-up/Escape.
    func prepareForRemoval() {
        stopEventMonitoring()
        let ownedGestureState = interaction.isActive ||
            gestureSlotID != nil ||
            dragThumbnailView != nil ||
            dropHighlightView != nil ||
            router?.paneDrag != nil
        guard ownedGestureState else { return }
        if let snapshot = interaction.cancel() {
            synchronizeWithStore(fallback: snapshot)
        }
        clearMovePresentation()
        router?.endPaneDrag()
        finishGestureFocus(cancelled: true)
    }

    /// The local monitor only bridges body clicks that the hosted terminal or
    /// built-in content consumes. Header, resize, and close interactions own
    /// their selection semantics and must never pre-focus a slot.
    func handleLocalLeftMouseDown(at point: CGPoint) {
        guard let slot = displayedSlots.first(where: {
            cards[$0.id]?.frame.contains(point) == true
        }), let card = cards[slot.id]
        else { return }
        let local = card.convert(point, from: self)
        guard SpatialCanvasInteractionCoordinator.hitRegion(
            at: local,
            in: card.bounds
        ) == .body else { return }
        store?.focusSlot(slot.id)
    }

    private func synchronizeWithStore(fallback: [SpatialSlot]) {
        guard let tab = authoritativeTab else {
            displayedSlots = fallback
            applyFrames(fallback)
            return
        }
        displayedSlots = tab.spatialSlots
        activeSlotID = tab.activeSlotID
        applyFrames(displayedSlots)
    }

    private var authoritativeTab: TenonCore.Tab? {
        guard let store, let tabID else { return nil }
        for workspace in store.catalog.workspaces {
            if let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                return tab
            }
        }
        return nil
    }

    private func finishGestureFocus(cancelled: Bool) {
        let slotID = gestureSlotID
        let previous = responderBeforeGesture
        gestureSlotID = nil
        responderBeforeGesture = nil
        gestureIsMove = false

        let restoredPrevious: Bool
        if let previous,
           previous !== self {
            restoredPrevious = window?.makeFirstResponder(previous) == true
        } else {
            restoredPrevious = false
        }

        let focusSlotID = cancelled && !restoredPrevious
            ? store?.catalog.activeSlotID
            : slotID
        guard (!cancelled || !restoredPrevious),
              let focusSlotID,
              store?.catalog.slot(id: focusSlotID)?.content == .terminal
        else { return }
        DispatchQueue.main.async { [weak pool] in
            pool?.focusSurface(for: focusSlotID)
        }
    }
}

final class SpatialDragThumbnailView: NSView {
    private let imageView = NSImageView()

    init(image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0.9
        layer?.backgroundColor = TenonTheme.inkNS.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.5
        layer?.borderColor = TenonTheme.amberNS.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class SpatialDropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = TenonTheme.amberNS.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 2
        layer?.borderColor = TenonTheme.amberNS.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct PluginRenderIdentity: Hashable {
    let installation: PluginInstallationKey
    let allowsWebView: Bool
}

final class SpatialSlotCardView: NSView {
    let slotID: UUID
    var onClose: ((UUID) -> Void)?
    var onBegin: ((UUID, SpatialCanvasHitRegion, CGPoint) -> Void)?
    var onDrag: ((_ canvasPoint: CGPoint, _ windowPoint: CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onFillWidth: ((UUID) -> Void)?
    var onCycleExtent: ((UUID, ResizeDirection) -> Void)?
    var onRequestMenu: ((UUID) -> NSMenu?)?
    var onRequestResizeMenu: ((UUID, ResizeDirection) -> NSMenu?)?
    /// A header control's click, already attributed to the item that owns it. The card
    /// stays a dumb view with no store reference — the same split `onRequestMenu` uses.
    var onHeaderAction: ((UUID, PaneHeaderAction) -> Void)?

    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    /// T-029: the pane's attention state, colored by the one shared dot vocabulary.
    /// Hidden while the pane never materialised — no surface, no invented state.
    private let stateDot = NSView()
    private let closeButton = SlotCloseButton()
    /// Two hosts with a bare AppKit band between them, so the pane's drag surface is one
    /// contiguous rectangle by construction rather than a rect subtraction, and the drag
    /// path never crosses SwiftUI's hit-test propagation.
    private let leadingHost = PaneHeaderHostView()
    private let trailingHost = PaneHeaderHostView()
    /// What this pane's owner contributed, and the geometry the solver made of it. The
    /// solution is the single source every consumer reads: `layout()` draws it,
    /// `hitTest` exempts it, `menu(for:)` defers to it and `resetCursorRects` cuts its
    /// cursors from it, so what the user sees and what the pointer does cannot drift.
    private var header = PaneHeader.empty
    private(set) var headerSolution = PaneHeaderLayout.Solution.empty
    private var headerIsActive = false
    /// The focus state the mounted runs were last built with, so a pane going active
    /// re-dims its accessories even when the geometry did not move.
    private var appliedHeaderIsActive: Bool?
    private var contentHost: NSHostingView<AnyView>?
    /// What the mounted content view tree IS, as a value. `configure` rebuilds that tree
    /// exactly when this changes, so it is also the only honest observable for the rule
    /// that keeps a live PTY alive: header state, attention state and focus state are
    /// pane state and must never appear in this key. The `NSHostingView` itself is reused
    /// across a rebuild, so its identity cannot answer that question and this can.
    private(set) var contentKey = ""
    private var pluginRenderIdentity: PluginRenderIdentity?
    /// Kero keeps a single pane full-bleed and only introduces focus chrome once
    /// multiple panes make the focused owner ambiguous.
    private var showsFocusRing = false

    private static let northwestSoutheastCursor = diagonalResizeCursor(
        symbol: "arrow.up.left.and.arrow.down.right"
    )
    private static let northeastSouthwestCursor = diagonalResizeCursor(
        symbol: "arrow.up.right.and.arrow.down.left"
    )

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(slotID: UUID) {
        self.slotID = slotID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = TenonTheme.inkNS.cgColor
        layer?.cornerRadius = TenonTheme.slotCornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = TenonTheme.lineNS.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("tenon.slot")
        setAccessibilityLabel("Slot")

        glyph.font = TenonTheme.utilityNSFont(size: 9, weight: .semibold)
        glyph.textColor = TenonTheme.amberNS
        title.font = TenonTheme.interfaceNSFont(size: 10, weight: .medium)
        title.textColor = TenonTheme.textNS
        title.lineBreakMode = .byTruncatingMiddle

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close slot"
        )
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = TenonTheme.mutedNS
        closeButton.onPress = { [weak self] in
            guard let self else { return }
            self.onClose?(self.slotID)
        }
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3.5
        stateDot.isHidden = true
        addSubview(glyph)
        addSubview(stateDot)
        addSubview(title)
        addSubview(closeButton)
        addSubview(leadingHost, positioned: .above, relativeTo: title)
        addSubview(trailingHost, positioned: .above, relativeTo: title)
        setState(isActive: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let headerHeight = min(TenonTheme.slotHeaderHeight, bounds.height)
        let titleHeight = title.intrinsicContentSize.height
        let solved = PaneHeaderLayout.solve(
            header: header,
            showsDot: !stateDot.isHidden,
            titleIdealWidth: title.intrinsicContentSize.width,
            glyphSize: glyph.intrinsicContentSize,
            titleHeight: titleHeight,
            bounds: bounds.size,
            headerHeight: headerHeight,
            metrics: .live
        )
        let solutionChanged = solved != headerSolution
        if solutionChanged {
            headerSolution = solved
        }
        if solutionChanged || appliedHeaderIsActive != headerIsActive {
            appliedHeaderIsActive = headerIsActive
            leadingHost.apply(
                headerSolution,
                run: .leading,
                isActive: headerIsActive,
                perform: { [weak self] in self?.routeHeaderAction($0) }
            )
            trailingHost.apply(
                headerSolution,
                run: .trailing,
                isActive: headerIsActive,
                perform: { [weak self] in self?.routeHeaderAction($0) }
            )
        }
        if solutionChanged {
            // Unlike every other rect on this card, the cursor rects now depend on the
            // header's CONTENT, so a solution that changed at an unchanged size still has
            // to invalidate them.
            window?.invalidateCursorRects(for: self)
        }

        glyph.frame = headerSolution.glyphRect
        stateDot.frame = headerSolution.dotRect ?? .zero
        title.frame = headerSolution.titleRect
        // A flexible field owns the gap, or the accessories left too little of it to
        // read; either way the pane's name is not drawn as a two-character stub.
        title.isHidden = headerSolution.titleRect == .zero

        // The glyph and title use different fonts (monospaced vs interface), so
        // centering each field on its own line-box leaves their baselines apart
        // — the prompt drops below the name. The solver centres the title band; the
        // join onto one baseline stays here because it needs `firstBaselineOffsetFromTop`
        // from two live NSTextFields, a font fact no value type can carry. A suppressed
        // title still supplies the band the glyph sits on.
        let titleTop = title.isHidden
            ? ((headerHeight - titleHeight) / 2).rounded()
            : headerSolution.titleRect.origin.y
        let baseline = titleTop + title.firstBaselineOffsetFromTop
        glyph.frame.origin.y = (baseline - glyph.firstBaselineOffsetFromTop).rounded()

        closeButton.frame = CGRect(
            x: max(bounds.width - 27, 0),
            y: 3,
            width: 23,
            height: max(headerHeight - 6, 1)
        )
        leadingHost.frame = headerSolution.leadingHostRect ?? .zero
        trailingHost.frame = headerSolution.trailingHostRect ?? .zero
        leadingHost.isHidden = headerSolution.leadingHostRect == nil
        trailingHost.isHidden = headerSolution.trailingHostRect == nil
        contentHost?.frame = CGRect(
            x: 0,
            y: headerHeight,
            width: max(bounds.width, 1),
            height: max(bounds.height - headerHeight, 1)
        )
    }

    /// The card owns the solution, so it is the one place that can attribute a pick in
    /// the host-composed `…` menu back to the item that folded. Those entries speak the
    /// folded items' value spaces — a folded `segmented` yields "tree"/"flat", not
    /// "layout" — so reporting them under the overflow's own id would name a control that
    /// no owner published.
    private func routeHeaderAction(_ action: PaneHeaderAction) {
        guard action.itemID == PaneHeaderLayout.overflowItemID else {
            onHeaderAction?(slotID, action)
            return
        }
        guard let value = action.value,
              let resolved = headerSolution.overflowAction(forEntryValue: value)
        else { return }
        onHeaderAction?(slotID, resolved)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        TenonTheme.chromeRaisedNS.setFill()
        NSBezierPath(
            rect: CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: min(TenonTheme.slotHeaderHeight, bounds.height)
            )
        ).fill()
        TenonTheme.lineNS.withAlphaComponent(0.72).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 0, y: TenonTheme.slotHeaderHeight))
        line.line(to: CGPoint(x: bounds.width, y: TenonTheme.slotHeaderHeight))
        line.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Pane lifecycle is host authority: the close control wins over everything, and
        // the solver keeps every accessory left of `closeButtonReserve` so the two are
        // disjoint rather than merely ordered.
        if closeButton.frame.contains(local) {
            return closeButton
        }
        if let placement = headerSolution.placements.first(where: {
            $0.item.isInteractive && $0.rect.contains(local)
        }) {
            // The run is read from the placement, never inferred from x. Falling back to
            // the host rather than to `self` keeps the exemption a property of the
            // solution: a control's rect is never pane-drag surface, whatever SwiftUI's
            // internal view tree happens to answer for that point.
            let host = placement.run == .leading ? leadingHost : trailingHost
            return host.hitTest(local) ?? host
        }
        switch SpatialCanvasInteractionCoordinator.hitRegion(
            at: local,
            in: bounds
        ) {
        case .header, .resize:
            return self
        case .body:
            return super.hitTest(point)
        }
    }

    /// Right-click / control-click routes here through AppKit's contextual-menu
    /// machinery. Which menu appears is the region's answer: the header offers the
    /// pane's actions, a border offers the sizes that border can be dragged to, and
    /// the body yields nothing so the terminal keeps its own.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        // A control with no contextual menu of its own would otherwise let AppKit walk up
        // to the card and pop Split/Stack/Duplicate/Close over a segmented picker. Ceding
        // the point lets a text field keep AppKit's own editing menu, and matches how the
        // ✕ already behaves.
        if headerSolution.interactiveRects.contains(where: { $0.contains(local) }) {
            return nil
        }
        switch SpatialCanvasInteractionCoordinator.menu(
            for: SpatialCanvasInteractionCoordinator.hitRegion(at: local, in: bounds)
        ) {
        case .pane:
            return onRequestMenu?(slotID)
        case .resize(let direction):
            return onRequestResizeMenu?(slotID, direction)
        case .surface:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Declining a control's own rect here is the other half of the `hitTest`
        // exemption, and it is not redundant with it. AppKit sends `mouseDown:` to the
        // view `hitTest` chose, and a view that does not consume it passes it to its next
        // responder — which for either header host IS this card. Without this the clicks
        // SwiftUI declines (a disabled button, the slack inside a menu's frame) would
        // arrive here as a pane pickup, while the pointer was showing a pointing hand.
        // Same rule, same solution, same rects as `hitTest` and `menu(for:)`.
        if headerSolution.interactiveRects.contains(where: { $0.contains(local) }) {
            return
        }
        let canvasPoint = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        let region = SpatialCanvasInteractionCoordinator.hitRegion(
            at: local,
            in: bounds
        )
        switch SpatialCanvasInteractionCoordinator.press(
            region: region,
            clickCount: event.clickCount
        ) {
        case .begin(let region):
            onBegin?(slotID, region, canvasPoint)
        case .fillWidth:
            onFillWidth?(slotID)
        case .cycleExtent(let direction):
            onCycleExtent?(slotID, direction)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let canvasPoint = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        onDrag?(canvasPoint, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let corner: CGFloat = 12
        let edge: CGFloat = 6
        addCursorRect(
            CGRect(
                x: corner,
                y: 0,
                width: max(bounds.width - corner * 2, 0),
                height: edge
            ),
            cursor: .resizeUpDown
        )
        addCursorRect(
            CGRect(
                x: corner,
                y: max(bounds.height - edge, 0),
                width: max(bounds.width - corner * 2, 0),
                height: edge
            ),
            cursor: .resizeUpDown
        )
        addCursorRect(
            CGRect(
                x: 0,
                y: corner,
                width: edge,
                height: max(bounds.height - corner * 2, 0)
            ),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            CGRect(
                x: max(bounds.width - edge, 0),
                y: corner,
                width: edge,
                height: max(bounds.height - corner * 2, 0)
            ),
            cursor: .resizeLeftRight
        )
        for entry in headerCursorRects() {
            addCursorRect(entry.rect, cursor: entry.cursor)
        }
        addCursorRect(
            CGRect(x: 0, y: 0, width: corner, height: corner),
            cursor: Self.northwestSoutheastCursor
        )
        addCursorRect(
            CGRect(
                x: max(bounds.width - corner, 0),
                y: 0,
                width: corner,
                height: corner
            ),
            cursor: Self.northeastSouthwestCursor
        )
        addCursorRect(
            CGRect(
                x: 0,
                y: max(bounds.height - corner, 0),
                width: corner,
                height: corner
            ),
            cursor: Self.northeastSouthwestCursor
        )
        addCursorRect(
            CGRect(
                x: max(bounds.width - corner, 0),
                y: max(bounds.height - corner, 0),
                width: corner,
                height: corner
            ),
            cursor: Self.northwestSoutheastCursor
        )
    }

    /// One cursor and the rect that owns it.
    struct HeaderCursorRect {
        let rect: CGRect
        let cursor: NSCursor
    }

    /// The header's cursors, as a value.
    ///
    /// A pure function of the solution and the card's bounds, so the rule can be asserted
    /// against `hitTest` point by point without a window — `addCursorRect` writes into
    /// AppKit and answers no questions afterwards, which is exactly how a cursor pass
    /// drifts away from the hit testing it is supposed to describe.
    ///
    /// The cut is **two-dimensional, because hit testing is**. An accessory occupies one
    /// 20-point band inside a 34-point strip, so a pass that claimed the whole column over
    /// a control would show a pointing hand across the row above it and the seven points
    /// below it — where the click actually picks the pane up. Cursor and click answer from
    /// the same rects or the affordance is a lie.
    ///
    /// The open hand starts from `dragBandRect`: the contiguous band the solver RESERVES
    /// before it places anything. That band is the one region provably free of controls at
    /// every `y`, so it is drawn once at full height and the sections either side of it are
    /// the only ones that have to be cut row by row. Reading it here is what turns the
    /// reservation from a solver post-condition into a guarantee the pointer ships.
    ///
    /// Stops before the close button so hovering the ✕ shows the pointing hand
    /// `SlotCloseButton` adds rather than the open hand that means "grab to move".
    func headerCursorRects() -> [HeaderCursorRect] {
        let edge: CGFloat = 6
        let region = CGRect(
            x: edge,
            y: edge,
            width: max(max(closeButton.frame.minX, edge) - edge, 0),
            height: max(TenonTheme.slotHeaderHeight - edge, 0)
        )
        guard region.width > 0, region.height > 0 else { return [] }

        let controls = headerSolution.interactiveRects
            .compactMap { clip($0, to: region) }
            .sorted { $0.minX < $1.minX }

        guard let band = clip(headerSolution.dragBandRect, to: region) else {
            return headerCursorRects(in: region, controls: controls)
        }
        return [HeaderCursorRect(rect: band, cursor: .openHand)]
            + [
                CGRect(
                    x: region.minX,
                    y: region.minY,
                    width: band.minX - region.minX,
                    height: region.height
                ),
                CGRect(
                    x: band.maxX,
                    y: region.minY,
                    width: region.maxX - band.maxX,
                    height: region.height
                ),
            ]
            .filter { $0.width > 0 }
            .flatMap { headerCursorRects(in: $0, controls: controls) }
    }

    /// One control-bearing section, cut into rows. The rows above and below the accessory
    /// band stay grab-to-move all the way across; inside the band a pointing hand covers
    /// exactly each control and an open hand covers the gaps, including the 6-point
    /// spacing between two neighbours. The pass runs left to right and each rect starts
    /// where the last one ended, because AppKit does not promise which of two OVERLAPPING
    /// cursor rects wins.
    private func headerCursorRects(
        in section: CGRect,
        controls: [CGRect]
    ) -> [HeaderCursorRect] {
        let inside = controls.compactMap { clip($0, to: section) }
        // Every placement is solved into the same band, so one row bounds them all.
        guard let top = inside.map(\.minY).min(),
              let bottom = inside.map(\.maxY).max()
        else {
            return [HeaderCursorRect(rect: section, cursor: .openHand)]
        }

        var rects: [HeaderCursorRect] = []
        if top > section.minY {
            rects.append(HeaderCursorRect(
                rect: CGRect(
                    x: section.minX,
                    y: section.minY,
                    width: section.width,
                    height: top - section.minY
                ),
                cursor: .openHand
            ))
        }
        var cursorX = section.minX
        for control in inside {
            let start = max(control.minX, cursorX)
            if start > cursorX {
                rects.append(HeaderCursorRect(
                    rect: CGRect(
                        x: cursorX,
                        y: top,
                        width: start - cursorX,
                        height: bottom - top
                    ),
                    cursor: .openHand
                ))
            }
            let end = max(control.maxX, start)
            if end > start {
                rects.append(HeaderCursorRect(
                    rect: CGRect(x: start, y: top, width: end - start, height: bottom - top),
                    cursor: .pointingHand
                ))
            }
            cursorX = end
        }
        if section.maxX > cursorX {
            rects.append(HeaderCursorRect(
                rect: CGRect(
                    x: cursorX,
                    y: top,
                    width: section.maxX - cursorX,
                    height: bottom - top
                ),
                cursor: .openHand
            ))
        }
        if section.maxY > bottom {
            rects.append(HeaderCursorRect(
                rect: CGRect(
                    x: section.minX,
                    y: bottom,
                    width: section.width,
                    height: section.maxY - bottom
                ),
                cursor: .openHand
            ))
        }
        return rects
    }

    /// `CGRect.intersection` answers `.null` for a miss and a zero-width rect for a touch;
    /// neither is a cursor rect, and both would seed a row sandwich around nothing.
    private func clip(_ rect: CGRect, to region: CGRect) -> CGRect? {
        let clipped = rect.intersection(region)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return clipped
    }

    func configure(
        slot: WorkspaceSlot,
        workspacePath: URL,
        title newTitle: String,
        // The header travels in BOTH directions, over two channels that are not
        // interchangeable. `newHeader` is the already-projected VALUE coming DOWN, the one
        // this card measures, folds and draws. `headerStore` is what the content view mounted
        // inside this card writes UP into when its own model changes, and it has to be handed
        // through because the card builds that view. Collapsing them is impossible in either
        // direction: the card cannot read a content model, and a plugin pane's header never
        // passes through the store at all (`PaneHeaderProjection`).
        header newHeader: PaneHeader,
        headerStore: PaneHeaderStore,
        isActive: Bool,
        showsFocusRing: Bool,
        store: WorkspaceStore?,
        pool: SurfacePool,
        agentLens: AgentLensPool,
        webPool: PluginWebSurfacePool,
        editorStates: EditorPaneStateStore,
        pluginSnapshots: [PluginSnapshot],
        agentSuggestions: [AgentLaunchSuggestion],
        host: PluginHost,
        automation: AutomationScheduler,
        automationSchedulesEnabled: Bool,
        automationActions: AutomationPaneActions
    ) {
        glyph.stringValue = SlotPresentation.glyph(for: slot.content)
        title.stringValue = newTitle
        self.showsFocusRing = showsFocusRing
        setState(isActive: isActive)
        // Deliberately ABOVE the cache guard, and deliberately NOT part of `contentKey`.
        // A header is pane state, not content identity: folding it into the key would
        // tear down and rebuild the NSHostingView owning this pane's live Ghostty PTY or
        // WKWebView on every agent-status tick.
        if header != newHeader {
            header = newHeader
            needsLayout = true
        }

        // An empty slot rebinds the return key when it becomes the active pane,
        // so fold active state into the cache key for empties only — other
        // content ignores it and keeps its live surface across focus changes.
        let activeSuffix = slot.content == .empty ? "|active=\(isActive)" : ""
        let agentSuffix = slot.content == .empty
            ? "|agents=" + agentSuggestions.map {
                $0.agent.rawValue + ":" + $0.arguments.joined(separator: ",")
            }.joined(separator: ";")
            : ""
        let nextPluginRenderIdentity: PluginRenderIdentity?
        if case let .pluginView(pluginID, _) = slot.content,
           let plugin = pluginSnapshots.first(where: {
               $0.id == pluginID && $0.isEnabled && $0.isLoaded
           }),
           let installationID = plugin.installationID {
            nextPluginRenderIdentity = PluginRenderIdentity(
                installation: PluginInstallationKey(
                    pluginID: pluginID,
                    installationID: installationID
                ),
                allowsWebView: plugin.permissions.contains("web.view")
            )
        } else {
            nextPluginRenderIdentity = nil
        }
        let installationSuffix: String
        if let nextPluginRenderIdentity {
            let installationID = nextPluginRenderIdentity.installation
                .installationID.uuidString.lowercased()
            installationSuffix =
                "|installation=\(installationID)"
                + "|web.view=\(nextPluginRenderIdentity.allowsWebView)"
        } else if case .pluginView = slot.content {
            installationSuffix = "|installation=inactive"
        } else {
            installationSuffix = ""
        }
        // A cached pane root normally stays untouched across focus and shell refreshes.
        // Automation's enablement is a value rather than an observable owner, so include
        // only that pane's flag in its key to ensure Settings changes reach the mounted view.
        let automationSuffix = slot.content == .automation
            ? "|scheduled=\(automationSchedulesEnabled)"
            : ""
        let key = "\(slot.content.busValue)|\(workspacePath.standardizedFileURL.path)"
            + activeSuffix + agentSuffix + installationSuffix + automationSuffix
        guard key != contentKey else { return }
        contentKey = key
        pluginRenderIdentity = nextPluginRenderIdentity
        let root = AnyView(
            BuiltInSlotContentView(
                slot: slot,
                workspacePath: workspacePath,
                host: host,
                pool: pool,
                agentLens: agentLens,
                webPool: webPool,
                agentSuggestions: agentSuggestions,
                editorStates: editorStates,
                headerStore: headerStore,
                store: store,
                isActive: isActive,
                automation: automation,
                automationSchedulesEnabled: automationSchedulesEnabled,
                automationActions: automationActions
            )
            .preferredColorScheme(.dark)
        )
        if let contentHost {
            contentHost.rootView = root
        } else {
            let contentHost = NSHostingView(rootView: root)
            contentHost.wantsLayer = true
            contentHost.layer?.backgroundColor = TenonTheme.inkNS.cgColor
            addSubview(contentHost, positioned: .below, relativeTo: glyph)
            self.contentHost = contentHost
        }
        needsLayout = true
    }

    fileprivate func invalidatePluginContent(
        unlessActiveIn activeIdentities: Set<PluginRenderIdentity>
    ) {
        guard let pluginRenderIdentity,
              !activeIdentities.contains(pluginRenderIdentity)
        else {
            return
        }
        contentHost?.removeFromSuperview()
        contentHost = nil
        contentKey = ""
        self.pluginRenderIdentity = nil
        // The contribution that drew this header went with the generation, so the chrome
        // it named goes too rather than outliving the pane it described.
        header = .empty
        needsLayout = true
    }

    /// T-029: project the pane's attention state onto the header dot — the same one
    /// machine the tab chip, sidebar and title bar read; nothing recomputed here.
    func setAttention(_ state: PaneActivityState?) {
        if let state {
            stateDot.isHidden = false
            stateDot.layer?.backgroundColor =
                PaneAttentionProjection.dotColor(for: state).cgColor
        } else {
            stateDot.isHidden = true
        }
        needsLayout = true
    }

    func setState(isActive: Bool) {
        glyph.textColor = isActive ? TenonTheme.amberNS : TenonTheme.mutedNS
        title.textColor = isActive ? TenonTheme.textNS : TenonTheme.mutedNS
        // Header accessories dim with their pane for the same reason the glyph and title
        // do: a fully-lit row of controls on an unfocused pane reads as the focused one.
        //
        // Both guards earn their place. `refreshCardActivity()` restates this on every
        // card after every gesture and every reconfigure, so an unconditional invalidation
        // would re-solve and re-mount every header run each time — the exact full pass
        // that method exists to avoid. And the glyph and the title recolour themselves
        // above without any layout, so a pane with nothing in its chrome has nothing left
        // whose appearance depends on focus.
        if headerIsActive != isActive {
            headerIsActive = isActive
            if !header.isEmpty {
                needsLayout = true
            }
        }
        if isActive && showsFocusRing {
            layer?.borderColor = TenonTheme.amberNS.withAlphaComponent(0.85).cgColor
            layer?.borderWidth = 1.5
        } else {
            layer?.borderColor = TenonTheme.lineNS.cgColor
            layer?.borderWidth = 1
        }
    }

    func updateAccessibilityValue(for slot: SpatialSlot) {
        setAccessibilityValue(
            "slot=\(slot.id.uuidString);rect=\(slot.rect.x),\(slot.rect.y),\(slot.rect.width),\(slot.rect.height)"
        )
    }

    /// Captures the mounted pane once at pickup. The live AppKit/SwiftUI surface stays
    /// in place for the rest of the drag, avoiding terminal/WebView reparent churn.
    ///
    /// The whole card, not just its content: now that the chrome header carries the
    /// pane's controls and identity, a drag ghost that omitted it would be showing the
    /// user something other than the thing they picked up.
    func paneSnapshot() -> NSImage? {
        guard bounds.width > 0,
              bounds.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private static func diagonalResizeCursor(symbol: String) -> NSCursor {
        guard let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Resize diagonally"
        ) else {
            return .crosshair
        }
        return NSCursor(
            image: image,
            hotSpot: CGPoint(
                x: image.size.width / 2,
                y: image.size.height / 2
            )
        )
    }
}

private final class SlotCloseButton: NSButton {
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(performPress)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(performPress)
    }

    @objc private func performPress() {
        onPress?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A closure-backed menu item so the pane header menu can be declared inline
/// without a fan-out of `@objc` selectors and `representedObject` plumbing.
final class SlotMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        title: String,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
        keyEquivalentModifierMask = modifiers
        self.isEnabled = isEnabled
    }

    required init(coder: NSCoder) {
        fatalError("SlotMenuItem is built in code, never decoded from a nib")
    }

    /// Invoked by AppKit when the item is chosen, and directly by tests.
    func invoke() {
        handler()
    }

    @objc private func fire() {
        invoke()
    }
}
