import AppKit
import SwiftUI
import TenonCore

struct GridDelta: Equatable {
    let columns: Int
    let rows: Int
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
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              point.x >= 0,
              point.y >= 0,
              point.x < canvasSize.width,
              point.y < canvasSize.height
        else { return nil }

        let column = Int(point.x / canvasSize.width * CGFloat(SpatialLayout.columns))
        let row = Int(point.y / canvasSize.height * CGFloat(SpatialLayout.rows))
        let isOccupied = slots.contains { slot in
            column >= slot.rect.x &&
                column < slot.rect.x + slot.rect.width &&
                row >= slot.rect.y &&
                row < slot.rect.y + slot.rect.height
        }
        return isOccupied ? nil : point
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
            guard let hit = slotFrames.first(where: {
                $0.key != slotID && $0.value.contains(pointer)
            }) else {
                preview = nil
                moveTarget = nil
                return nil
            }
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
    let editorStates: EditorPaneStateStore
    let pluginSnapshots: [PluginSnapshot]
    let pluginViewSections: [PluginViewSection]
    let webSurfaceTitles: [WebSurfaceKey: String]
    /// T-029: the per-slot attention projection; the card header shows its state dot.
    let paneAttention: [UUID: PaneActivity]
    let router: DragRouter

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
            editorStates: editorStates,
            pluginSnapshots: pluginSnapshots,
            pluginViewSections: pluginViewSections,
            webSurfaceTitles: webSurfaceTitles,
            paneAttention: paneAttention,
            router: router
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
    private var router: DragRouter?
    private var tabID: UUID?
    private var activeSlotID: UUID?
    private var gestureSlotID: UUID?
    private var responderBeforeGesture: NSResponder?
    private var mouseMonitor: Any?
    private var launcherPopover: NSPopover?
    private(set) var dragThumbnailView: SpatialDragThumbnailView?
    private(set) var dropHighlightView: SpatialDropHighlightView?

    /// Test seam for the AppKit presentation edge. Production leaves it nil and hosts
    /// `LauncherMenu` below; tests replace only the final popover side effect while the
    /// same empty-grid routing still runs.
    var onPresentEmptyGridLauncher: ((NSRect) -> Void)?

    /// Set while the pointer is over the tab bar during a header drag: releasing
    /// there reparents the dragged slot instead of committing an in-canvas move.
    /// Only header (move) drags can reparent — a resize edge dragged up is ignored.
    private var pendingReparent: TabBarDropTarget = .none
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMouseMonitorIfNeeded()
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
        if event.keyCode == 53, cancelGesture() {
            return
        }
        super.keyDown(with: event)
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
        editorStates: EditorPaneStateStore,
        pluginSnapshots: [PluginSnapshot],
        pluginViewSections: [PluginViewSection],
        webSurfaceTitles: [WebSurfaceKey: String],
        paneAttention: [UUID: PaneActivity],
        router: DragRouter
    ) {
        let authoritativeSlots = tab.spatialSlots
        let preservesGesturePreview = self.tabID == tab.id &&
            interaction.isBased(on: authoritativeSlots)
        if interaction.isActive && !preservesGesturePreview {
            // A real tab/layout change makes the pointer snapshot stale. Cancel it once
            // here so later drag events cannot reintroduce the old geometry.
            _ = cancelGesture()
        }

        self.store = store
        self.pool = pool
        self.host = host
        self.intentRuntime = intentRuntime
        self.palette = palette
        self.router = router
        self.tabID = tab.id
        self.activeSlotID = activeSlotID
        interaction.setCanvasSize(bounds.size)

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
                isActive: slot.id == activeSlotID,
                showsFocusRing: tab.slots.count > 1,
                store: store,
                pool: pool,
                agentLens: agentLens,
                webPool: webPool,
                editorStates: editorStates,
                pluginSnapshots: pluginSnapshots,
                host: host
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
        guard let point = SpatialCanvasInteractionCoordinator.emptyGridLauncherAnchor(
            at: point,
            canvasSize: bounds.size,
            slots: displayedSlots
        ) else { return false }

        let anchor = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        if let onPresentEmptyGridLauncher {
            onPresentEmptyGridLauncher(anchor)
        } else {
            presentEmptyGridLauncher(relativeTo: anchor)
        }
        return true
    }

    /// Hosts the exact search-first launcher used by the title-bar `+` and tab-chip
    /// right-click. Membership, ranking, grouping, icons, invocation, failure display,
    /// and frecency therefore remain one implementation in `LauncherMenu`.
    private func presentEmptyGridLauncher(relativeTo anchor: NSRect) {
        guard let host, let intentRuntime, let palette, window != nil else { return }

        launcherPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: LauncherMenu(
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
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
        cards[slotID] = card
        return card
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

        // A header drag that reaches the tab bar switches to reparent mode: the
        // in-canvas layout freezes and the tab bar highlights the target. Any
        // other region (resize) or a nil window point keeps the in-canvas path.
        if gestureIsMove,
           gestureSlotID != nil,
           let router,
           let windowPoint {
            let target = router.target(at: windowPoint)
            if target != .none {
                pendingReparent = target
                router.activeDropTarget = target
                updateMovePresentation(at: point, acceptsExternalDrop: true)
                return
            }
        }
        if pendingReparent != .none {
            pendingReparent = .none
            router?.activeDropTarget = .none
        }

        // Pane moves carry a bitmap and highlight a destination while the live
        // surfaces stay mounted. Only resize previews alter card frames in flight.
        if gestureIsMove {
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
        if pendingReparent != .none {
            let slotID = gestureSlotID
            _ = interaction.cancel()
            clearMovePresentation()
            switch pendingReparent {
            case .newTab:
                if let slotID { store?.moveSlotToNewTab(slotID) }
            case .existingTab(let targetTabID):
                if let slotID { store?.moveSlot(slotID, toTab: targetTabID) }
            case .none:
                break
            }
            pendingReparent = .none
            router?.activeDropTarget = .none
            synchronizeWithStore(fallback: displayedSlots)
            refreshCardActivity()
            finishGestureFocus(cancelled: false)
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
        finishGestureFocus(cancelled: false)
    }

    @discardableResult
    func cancelGesture() -> Bool {
        guard let snapshot = interaction.cancel() else { return false }
        clearMovePresentation()
        pendingReparent = .none
        router?.activeDropTarget = .none
        synchronizeWithStore(fallback: snapshot)
        refreshCardActivity()
        finishGestureFocus(cancelled: true)
        return true
    }

    /// Kero-style pickup: the source remains mounted and dimmed, while one bitmap
    /// snapshot follows the pointer and a separate overlay describes the drop.
    private func updateMovePresentation(
        at point: CGPoint,
        acceptsExternalDrop: Bool = false
    ) {
        guard interaction.isCarryingPane,
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

        if !acceptsExternalDrop,
           let target = interaction.moveTarget,
           let targetCard = cards[target.slotID] {
            let highlight = dropHighlightView ?? SpatialDropHighlightView()
            highlight.frame = Self.highlightFrame(
                for: target.edge,
                in: targetCard.frame
            )
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
        let cellWidth = bounds.width / CGFloat(SpatialLayout.columns)
        let cellHeight = bounds.height / CGFloat(SpatialLayout.rows)
        // Each card is inset by half a gutter on every side, so the panel
        // background shows through as an even gap between neighbours (a full
        // gutter) and a half-gutter margin against the canvas edge. The gap is
        // also a dead zone that keeps adjacent resize edges from overlapping.
        let inset = TenonTheme.slotGutter / 2
        for slot in slots {
            guard let card = cards[slot.id] else { continue }
            let cell = CGRect(
                x: CGFloat(slot.rect.x) * cellWidth,
                y: CGFloat(slot.rect.y) * cellHeight,
                width: max(CGFloat(slot.rect.width) * cellWidth, 1),
                height: max(CGFloat(slot.rect.height) * cellHeight, 1)
            )
            card.frame = CGRect(
                x: cell.minX + inset,
                y: cell.minY + inset,
                width: max(cell.width - TenonTheme.slotGutter, 1),
                height: max(cell.height - TenonTheme.slotGutter, 1)
            )
            card.updateAccessibilityValue(for: slot)
        }
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
            matching: [.leftMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window === self.window
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            self.handleLocalLeftMouseDown(at: point)
            return event
        }
    }

    func stopMouseMonitoring() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        launcherPopover?.performClose(nil)
        launcherPopover = nil
    }

    /// Ends all gesture-owned state before the canvas leaves its window. AppKit can
    /// dismantle or detach the representable without delivering mouse-up/Escape.
    func prepareForRemoval() {
        stopMouseMonitoring()
        let ownedGestureState = interaction.isActive ||
            gestureSlotID != nil ||
            dragThumbnailView != nil ||
            dropHighlightView != nil ||
            pendingReparent != .none
        guard ownedGestureState else { return }
        if let snapshot = interaction.cancel() {
            synchronizeWithStore(fallback: snapshot)
        }
        clearMovePresentation()
        pendingReparent = .none
        router?.activeDropTarget = .none
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

        if let previous,
           previous !== self {
            window?.makeFirstResponder(previous)
        }

        guard !cancelled,
              let slotID,
              store?.catalog.slot(id: slotID)?.content == .terminal
        else { return }
        DispatchQueue.main.async { [weak pool] in
            pool?.focusSurface(for: slotID)
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

    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    /// T-029: the pane's attention state, colored by the one shared dot vocabulary.
    /// Hidden while the pane never materialised — no surface, no invented state.
    private let stateDot = NSView()
    private let closeButton = SlotCloseButton()
    private var contentHost: NSHostingView<AnyView>?
    private var contentKey = ""
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
        setState(isActive: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let header = min(TenonTheme.slotHeaderHeight, bounds.height)

        // The glyph and title use different fonts (monospaced vs interface), so
        // centering each field on its own line-box leaves their baselines apart
        // — the prompt drops below the name. Size both to a single line, center
        // the title in the header, then pin the glyph onto the title's baseline
        // so ">_" and the name sit on one line.
        let glyphHeight = glyph.intrinsicContentSize.height
        let titleHeight = title.intrinsicContentSize.height
        glyph.frame = CGRect(x: 9, y: 0, width: 19, height: glyphHeight)
        let dotSize: CGFloat = 7
        stateDot.frame = CGRect(
            x: 31,
            y: ((header - dotSize) / 2).rounded(),
            width: dotSize,
            height: dotSize
        )
        let titleX: CGFloat = stateDot.isHidden ? 31 : 43
        title.frame = CGRect(
            x: titleX,
            y: 0,
            width: max(bounds.width - titleX - 31, 1),
            height: titleHeight
        )
        let titleTop = ((header - titleHeight) / 2).rounded()
        let baseline = titleTop + title.firstBaselineOffsetFromTop
        title.frame.origin.y = titleTop
        glyph.frame.origin.y = (baseline - glyph.firstBaselineOffsetFromTop).rounded()

        closeButton.frame = CGRect(
            x: max(bounds.width - 27, 0),
            y: 3,
            width: 23,
            height: max(header - 6, 1)
        )
        contentHost?.frame = CGRect(
            x: 0,
            y: header,
            width: max(bounds.width, 1),
            height: max(bounds.height - header, 1)
        )
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
        if closeButton.frame.contains(local) {
            return closeButton
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
        // Stop the drag cursor before the close button so hovering the ✕
        // shows a pointing hand (added by SlotCloseButton) rather than the
        // open hand that means "grab to move the pane".
        addCursorRect(
            CGRect(
                x: edge,
                y: edge,
                width: max(closeButton.frame.minX - edge, 0),
                height: max(TenonTheme.slotHeaderHeight - edge, 0)
            ),
            cursor: .openHand
        )
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

    func configure(
        slot: WorkspaceSlot,
        workspacePath: URL,
        title newTitle: String,
        isActive: Bool,
        showsFocusRing: Bool,
        store: WorkspaceStore?,
        pool: SurfacePool,
        agentLens: AgentLensPool,
        webPool: PluginWebSurfacePool,
        editorStates: EditorPaneStateStore,
        pluginSnapshots: [PluginSnapshot],
        host: PluginHost
    ) {
        glyph.stringValue = SlotPresentation.glyph(for: slot.content)
        title.stringValue = newTitle
        self.showsFocusRing = showsFocusRing
        setState(isActive: isActive)

        // An empty slot rebinds the return key when it becomes the active pane,
        // so fold active state into the cache key for empties only — other
        // content ignores it and keeps its live surface across focus changes.
        let activeSuffix = slot.content == .empty ? "|active=\(isActive)" : ""
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
        let key = "\(slot.content.busValue)|\(workspacePath.standardizedFileURL.path)\(activeSuffix)\(installationSuffix)"
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
                editorStates: editorStates,
                store: store,
                isActive: isActive
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
    func paneSnapshot() -> NSImage? {
        let source = contentHost ?? self
        guard source.bounds.width > 0,
              source.bounds.height > 0,
              let representation = source.bitmapImageRepForCachingDisplay(in: source.bounds)
        else { return nil }
        source.cacheDisplay(in: source.bounds, to: representation)
        let image = NSImage(size: source.bounds.size)
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
