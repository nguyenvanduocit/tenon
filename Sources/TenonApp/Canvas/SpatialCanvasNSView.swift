// @domain: spatial-canvas
/// The canvas surface: hit-testing, cursors, drag session, context menus, and the mounting of
/// pane cards. It owns AppKit state and asks `SpatialCanvasInteractionCoordinator` what a
/// gesture means rather than deciding for itself.
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

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
    private var paneRenamer: PaneRenameCoordinator?
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
    /// Test seam for the clipboard edge. Both the contextual-menu item and the pane's
    /// VoiceOver action enter this one route.
    var copyWorkspaceIdentifier: (UUID) -> Void = {
        WorkspaceIdentifierClipboard.copy($0)
    }

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
        setAccessibilityLabel(Shell.text("Spatial canvas"))
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
        workspaceID: UUID,
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
        /// What each pane is doing to its own name, read off the coordinator by the stage.
        /// A VALUE for the same reason `paneHeaders` is one: the read that invalidates this
        /// canvas has to happen in a SwiftUI body, and `configure` is not one.
        paneRenames: [UUID: PaneRenamePhase] = [:],
        paneRenamer: PaneRenameCoordinator? = nil,
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
        self.paneRenamer = paneRenamer
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
                workspaceID: workspaceID,
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
                renamePhase: paneRenames[slot.id],
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
            slots: displayedSlots,
            sizing: store?.newPaneSizing ?? .unlimited
        ) else { return false }

        return presentEmptyGridLauncher(target)
    }

    private func requestBestEmptyGridLauncher() -> Bool {
        guard let hole = SpatialLayout.bestEmptyRect(
            in: displayedSlots,
            near: store?.catalog.activeSlotID
        ) else { return false }
        // No pointer chose a cell here, so the pane takes the hole's leading edge and the
        // popover follows it rather than the hole's centre.
        let rect = (store?.newPaneSizing ?? .unlimited).fitting(hole)
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
            send: { invocation in
                await EmptyGridLauncherPlacement.invoke(
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
        // The popover owns the key window from here until it closes, so every responder
        // change in between was caused by presenting or dismissing it. None of them is a
        // person choosing a pane, and the launcher is about to create one (T-088).
        pool.isOverlayOwningFocus = true
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover,
              closed === launcherPopover
        else { return }
        launcherPopover = nil
        releaseOverlayFocus(reassertingModelFocus: true)
    }

    /// Hands the responder chain back to whichever pane the workspace now considers active,
    /// then lets ordinary focus reports through again.
    ///
    /// Re-asserting is what settles focus on a pane the launcher just created: AppKit would
    /// otherwise restore the pane the person was leaving. It emits nothing, because a
    /// host-driven focus is not reported back.
    private func releaseOverlayFocus(reassertingModelFocus: Bool) {
        guard let pool else { return }
        if reassertingModelFocus, let activeSlotID = store?.catalog.activeSlotID {
            pool.focusSurface(for: activeSlotID)
        }
        pool.isOverlayOwningFocus = false
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
        card.onCopyID = { [weak self] id in
            self?.copyWorkspaceIdentifier(id)
        }
        card.onRename = { [weak self] id in
            self?.beginManualRename(for: id)
        }
        card.onAIRename = { [weak self] id in
            self?.beginAIRename(for: id)
        }
        card.onRenameCommit = { [weak self] id, text in
            self?.paneRenamer?.commitManual(slotID: id, to: text)
        }
        card.onRenameCancel = { [weak self] id in
            self?.paneRenamer?.cancel(slotID: id)
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

        menu.addItem(SlotMenuItem(title: Shell.text("Rename…"), isEnabled: true) { [weak self] in
            self?.beginManualRename(for: slotID)
        })
        menu.addItem(SlotMenuItem(title: Shell.text("AI Rename…"), isEnabled: true) { [weak self] in
            self?.beginAIRename(for: slotID)
        })

        menu.addItem(.separator())

        menu.addItem(SlotMenuItem(title: "Copy Pane ID", isEnabled: true) { [weak self] in
            self?.copyWorkspaceIdentifier(slotID)
        })

        menu.addItem(.separator())

        menu.addItem(SlotMenuItem(title: "Close", isEnabled: true) { [weak store] in
            store?.closeSlot(slotID)
        })

        return menu
    }

    private func beginManualRename(for slotID: UUID) {
        guard let title = cards[slotID]?.presentedTitle else { return }
        paneRenamer?.beginManual(slotID: slotID, currentTitle: title)
    }

    private func beginAIRename(for slotID: UUID) {
        guard let title = cards[slotID]?.presentedTitle else { return }
        paneRenamer?.beginAI(slotID: slotID, currentTitle: title)
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
        // Leaving the window is not a moment to move focus anywhere; the claim is simply
        // dropped so a canvas going away cannot leave reports muted for the next one.
        releaseOverlayFocus(reassertingModelFocus: false)
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
