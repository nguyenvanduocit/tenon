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

enum SpatialCanvasCommit: Equatable {
    case move(SpatialLayoutTransaction)
    case swap(SpatialLayoutTransaction)
    case resize(ResizeLayoutTransaction)

    var proposal: [SpatialSlot] {
        switch self {
        case .move(let transaction), .swap(let transaction):
            return transaction.proposal
        case .resize(let transaction):
            return transaction.proposal
        }
    }

    var isValid: Bool {
        switch self {
        case .move(let transaction), .swap(let transaction):
            return transaction.isValid
        case .resize(let transaction):
            return transaction.isValid
        }
    }
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
    private var canvasSize: CGSize
    private var gesture: Gesture?
    private var pointerOrigin = CGPoint.zero
    private var snapshot: [SpatialSlot] = []

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

    func setCanvasSize(_ size: CGSize) {
        guard gesture == nil else { return }
        canvasSize = size
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
    func update(pointer: CGPoint) -> SpatialCanvasCommit? {
        guard let gesture else { return nil }
        let delta = snappedDelta(from: pointerOrigin, to: pointer)

        switch gesture {
        case .move(let slotID):
            if let target = swapTarget(at: pointer, excluding: slotID) {
                preview = .swap(
                    SpatialLayout.swap(
                        snapshot,
                        firstSlotID: slotID,
                        secondSlotID: target
                    )
                )
            } else if let origin = snapshot.first(where: { $0.id == slotID }) {
                preview = .move(
                    SpatialLayout.move(
                        snapshot,
                        slotID: slotID,
                        toColumn: origin.rect.x + delta.columns,
                        row: origin.rect.y + delta.rows
                    )
                )
            }

        case .resize(let slotID, let direction):
            preview = .resize(
                SpatialLayout.resize(
                    snapshot,
                    slotID: slotID,
                    direction: direction,
                    deltaColumns: delta.columns,
                    deltaRows: delta.rows
                )
            )
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
    }

    private func swapTarget(at point: CGPoint, excluding slotID: UUID) -> UUID? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let column = Int(point.x / canvasSize.width * CGFloat(SpatialLayout.columns))
        let row = Int(point.y / canvasSize.height * CGFloat(SpatialLayout.rows))
        guard column >= 0,
              column < SpatialLayout.columns,
              row >= 0,
              row < SpatialLayout.rows
        else { return nil }
        return snapshot.first { slot in
            slot.id != slotID &&
                column >= slot.rect.x &&
                column < slot.rect.x + slot.rect.width &&
                row >= slot.rect.y &&
                row < slot.rect.y + slot.rect.height
        }?.id
    }
}

struct SpatialCanvasView: NSViewRepresentable {
    let tab: TenonCore.Tab
    let workspacePath: URL
    let allLiveSlotIDs: Set<UUID>
    let activeSlotID: UUID?
    let store: WorkspaceStore
    let pool: SurfacePool
    let webPool: PluginWebSurfacePool
    let host: PluginHost
    let pluginSnapshots: [PluginSnapshot]
    let pluginViewSections: [PluginViewSection]
    let webSurfaceTitles: [WebSurfaceKey: String]
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
            webPool: webPool,
            host: host,
            pluginSnapshots: pluginSnapshots,
            pluginViewSections: pluginViewSections,
            webSurfaceTitles: webSurfaceTitles,
            router: router
        )
    }

    static func dismantleNSView(
        _ view: SpatialCanvasNSView,
        coordinator: Coordinator
    ) {
        view.stopMouseMonitoring()
    }
}

final class SpatialCanvasNSView: NSView {
    private let interaction = SpatialCanvasInteractionCoordinator(canvasSize: .zero)
    private var cards: [UUID: SpatialSlotCardView] = [:]
    private var displayedSlots: [SpatialSlot] = []
    private var store: WorkspaceStore?
    private var pool: SurfacePool?
    private var router: DragRouter?
    private var tabID: UUID?
    private var activeSlotID: UUID?
    private var gestureSlotID: UUID?
    private var responderBeforeGesture: NSResponder?
    private var mouseMonitor: Any?

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
            stopMouseMonitoring()
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

    func configure(
        tab: TenonCore.Tab,
        workspacePath: URL,
        allLiveSlotIDs: Set<UUID>,
        activeSlotID: UUID?,
        store: WorkspaceStore,
        pool: SurfacePool,
        webPool: PluginWebSurfacePool,
        host: PluginHost,
        pluginSnapshots: [PluginSnapshot],
        pluginViewSections: [PluginViewSection],
        webSurfaceTitles: [WebSurfaceKey: String],
        router: DragRouter
    ) {
        self.store = store
        self.pool = pool
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
                store: store,
                pool: pool,
                webPool: webPool,
                pluginSnapshots: pluginSnapshots,
                host: host
            )
        }

        let visibleIDs = Set(tab.slots.map(\.id))
        for id in Array(cards.keys) where !visibleIDs.contains(id) {
            cards[id]?.removeFromSuperview()
        }
        webPool.reconcile(catalog: store.catalog, host: host)

        displayedSlots = tab.spatialSlots
        applyFrames(displayedSlots)
        setPreviewValidity(nil)
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
        card.onRequestMenu = { [weak self] id in
            self?.slotContextMenu(for: id)
        }
        cards[slotID] = card
        return card
    }

    /// Builds the pane header's contextual menu. It lives here, not on the card,
    /// because the actions are just projections of existing `WorkspaceStore`
    /// operations — the card stays a dumb view with no store reference. "Split"
    /// and "Stack" reuse the shell toolbar's exact vocabulary (right / down).
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

        menu.addItem(.separator())

        let changeType = NSMenuItem(title: "Change Type", action: nil, keyEquivalent: "")
        let typeMenu = NSMenu()
        typeMenu.autoenablesItems = false
        for option in SlotTypeOption.allCases {
            let item = SlotMenuItem(title: option.title, isEnabled: true) { [weak store] in
                store?.setSlotContent(slotID, option.content)
            }
            item.state = slot.content == option.content ? .on : .off
            typeMenu.addItem(item)
        }
        changeType.submenu = typeMenu
        menu.addItem(changeType)

        menu.addItem(.separator())

        menu.addItem(SlotMenuItem(title: "Close", isEnabled: true) { [weak store] in
            store?.closeSlot(slotID)
        })

        return menu
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
                setPreviewValidity(nil)
                return
            }
        }
        if pendingReparent != .none {
            pendingReparent = .none
            router?.activeDropTarget = .none
        }

        guard let preview = interaction.update(pointer: point) else { return }
        displayedSlots = preview.proposal
        applyFrames(displayedSlots)
        setPreviewValidity(preview.isValid)
    }

    func end() {
        // Released over the tab bar: reparent instead of committing an in-canvas
        // move. The slot keeps its identity, so its terminal surface survives the
        // hop; `retainOnly` never sees the id leave the catalog.
        if pendingReparent != .none {
            let slotID = gestureSlotID
            _ = interaction.cancel()
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
            setPreviewValidity(nil)
            finishGestureFocus(cancelled: false)
            return
        }

        guard let result = interaction.finish() else { return }
        switch result {
        case .rollback(let snapshot):
            synchronizeWithStore(fallback: snapshot)
        case .commit(let commit):
            switch commit {
            case .move(let transaction):
                store?.applyMove(transaction)
            case .swap(let transaction):
                store?.applySwap(transaction)
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
        setPreviewValidity(nil)
        finishGestureFocus(cancelled: false)
    }

    @discardableResult
    func cancelGesture() -> Bool {
        guard let snapshot = interaction.cancel() else { return false }
        pendingReparent = .none
        router?.activeDropTarget = .none
        synchronizeWithStore(fallback: snapshot)
        setPreviewValidity(nil)
        finishGestureFocus(cancelled: true)
        return true
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

    private func setPreviewValidity(_ isValid: Bool?) {
        for (id, card) in cards {
            card.setState(
                isActive: id == activeSlotID,
                previewIsValid: isValid
            )
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
        guard let mouseMonitor else { return }
        NSEvent.removeMonitor(mouseMonitor)
        self.mouseMonitor = nil
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
    var onRequestMenu: ((UUID) -> NSMenu?)?

    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let closeButton = SlotCloseButton()
    private var contentHost: NSHostingView<AnyView>?
    private var contentKey = ""
    private var pluginRenderIdentity: PluginRenderIdentity?

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
        addSubview(glyph)
        addSubview(title)
        addSubview(closeButton)
        setState(isActive: false, previewIsValid: nil)
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
        title.frame = CGRect(
            x: 31,
            y: 0,
            width: max(bounds.width - 62, 1),
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
    /// machinery. The menu is a title-bar affordance only, so a click that lands
    /// on the body or a resize edge yields no menu and the terminal keeps its own.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard SpatialCanvasInteractionCoordinator.hitRegion(
            at: local,
            in: bounds
        ) == .header else { return nil }
        return onRequestMenu?(slotID)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let canvasPoint = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        let region = SpatialCanvasInteractionCoordinator.hitRegion(
            at: local,
            in: bounds
        )
        onBegin?(slotID, region, canvasPoint)
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
        store: WorkspaceStore?,
        pool: SurfacePool,
        webPool: PluginWebSurfacePool,
        pluginSnapshots: [PluginSnapshot],
        host: PluginHost
    ) {
        glyph.stringValue = SlotPresentation.glyph(for: slot.content)
        title.stringValue = newTitle
        setState(isActive: isActive, previewIsValid: nil)

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
                webPool: webPool,
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

    func setState(isActive: Bool, previewIsValid: Bool?) {
        glyph.textColor = isActive ? TenonTheme.amberNS : TenonTheme.mutedNS
        title.textColor = isActive ? TenonTheme.textNS : TenonTheme.mutedNS
        if previewIsValid == false {
            layer?.borderColor = NSColor.systemRed.cgColor
            layer?.borderWidth = 1.5
        } else if isActive {
            layer?.borderColor = TenonTheme.amberNS.withAlphaComponent(0.45).cgColor
            layer?.borderWidth = 1
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

/// The slot content types offered by the header's "Change Type" submenu — the
/// same set the tab bar's "Add slot" menu exposes.
enum SlotTypeOption: CaseIterable {
    case terminal
    case files
    case changes
    case docs

    var title: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .files:
            return "Files"
        case .changes:
            return "Diff"
        case .docs:
            return "Docs"
        }
    }

    var content: SlotContent {
        switch self {
        case .terminal:
            return .terminal
        case .files:
            // Files is the bundled file-explorer plugin's tree, not a host content type.
            return .pluginView(
                pluginID: "dev.tenon.file-explorer",
                viewID: "tree"
            )
        case .changes:
            return .changes
        case .docs:
            return .docs
        }
    }
}
