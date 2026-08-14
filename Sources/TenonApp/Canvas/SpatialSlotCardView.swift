// @domain: spatial-canvas, pane-chrome
/// One pane, as the canvas draws it: the card, its chrome header hosts, its attention dot,
/// its close control and its context menu. The header vocabulary and layout belong to
/// `pane-chrome`; what is here is the card that mounts a solved header and a pane's content.
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

final class SpatialSlotCardView: NSView, NSTextFieldDelegate {
    let slotID: UUID
    var onClose: ((UUID) -> Void)?
    var onBegin: ((UUID, SpatialCanvasHitRegion, CGPoint) -> Void)?
    var onDrag: ((_ canvasPoint: CGPoint, _ windowPoint: CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onFillWidth: ((UUID) -> Void)?
    var onCycleExtent: ((UUID, ResizeDirection) -> Void)?
    var onRequestMenu: ((UUID) -> NSMenu?)?
    var onRequestResizeMenu: ((UUID, ResizeDirection) -> NSMenu?)?
    var onCopyID: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onAIRename: ((UUID) -> Void)?
    /// The inline rename's two endings. The card owns the text field and nothing else: what
    /// a committed name means is `PaneRenameCoordinator`'s to say, exactly as `onClose` sends
    /// pane lifecycle back out rather than deciding it here.
    var onRenameCommit: ((UUID, String) -> Void)?
    var onRenameCancel: ((UUID) -> Void)?
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
    /// The rect the spoken position and the identifier were last written from.
    private var appliedAccessibilityRect: GridRect?
    /// What the mounted content view tree IS, as a value. `configure` rebuilds that tree
    /// exactly when this changes, so it is also the only honest observable for the rule
    /// that keeps a live PTY alive: header state, attention state and focus state are
    /// pane state and must never appear in this key. The `NSHostingView` itself is reused
    /// across a rebuild, so its identity cannot answer that question and this can.
    private(set) var contentKey = ""
    /// The pane's own name, always — never what the header is temporarily SAYING. The rename
    /// menu items pass this back as the starting point, so a pane whose title currently reads
    /// `Naming…` still offers its real name to the next rename.
    private(set) var presentedTitle = ""
    /// What this pane is doing to its name, as handed down by the coordinator.
    private(set) var renamePhase: PaneRenamePhase?
    /// What the header is currently SAYING, which during a rename is not the pane's name:
    /// `Naming…` while a Companion works, `Rename failed` for as long as that lasts.
    var displayedTitle: String { title.stringValue }
    /// Whether the pane's name is being typed on the title itself.
    var isRenamingInline: Bool { title.isEditable }
    /// The pane's content kind, kept so the glyph the rename borrows can be handed back.
    private var presentedContent: SlotContent = .empty
    /// Set while `commitRename`/`cancelRename` are unwinding AppKit's own end-of-editing
    /// notification, so one Return key does not commit the same name twice.
    private var isSettlingRename = false
    /// The colour the rename state claims for the title and glyph, or `nil` while the pane's
    /// own focus rule owns them.
    private var renameEmphasisColor: NSColor?
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
        setAccessibilityLabel(Shell.text("Pane"))

        glyph.font = TenonTheme.utilityNSFont(size: 9, weight: .semibold)
        glyph.textColor = TenonTheme.amberNS
        title.font = TenonTheme.interfaceNSFont(size: 10, weight: .medium)
        title.textColor = TenonTheme.textNS
        title.lineBreakMode = .byTruncatingMiddle

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: Shell.text("Close pane")
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

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(
                name: Shell.text("Rename Pane")
            ) { [weak self] in
                guard let self else { return false }
                self.onRename?(self.slotID)
                return self.onRename != nil
            },
            NSAccessibilityCustomAction(
                name: Shell.text("AI Rename Pane")
            ) { [weak self] in
                guard let self else { return false }
                self.onAIRename?(self.slotID)
                return self.onAIRename != nil
            },
            NSAccessibilityCustomAction(
                name: Shell.text("Copy Pane ID")
            ) { [weak self] in
                guard let self else { return false }
                self.onCopyID?(self.slotID)
                return self.onCopyID != nil
            },
        ]
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
        if renamePhase?.isEditing == true {
            // Typing needs a field, and the solver's answer for a *label* can be `.zero` —
            // a flexible accessory took the gap, or the strip is too narrow to read a name
            // in. Editing takes the band between the glyph and the close control outright,
            // because a rename the operator cannot see is worse than an accessory that is
            // briefly covered by the thing they explicitly asked for.
            title.isHidden = false
            title.frame = editingTitleRect(headerHeight: headerHeight)
        } else {
            title.frame = headerSolution.titleRect
            // A flexible field owns the gap, or the accessories left too little of it to
            // read; either way the pane's name is not drawn as a two-character stub.
            title.isHidden = headerSolution.titleRect == .zero
        }

        // The glyph and title use different fonts (monospaced vs interface), so
        // centering each field on its own line-box leaves their baselines apart
        // — the prompt drops below the name. The solver centres the title band; the
        // join onto one baseline stays here because it needs `firstBaselineOffsetFromTop`
        // from two live NSTextFields, a font fact no value type can carry. A suppressed
        // title still supplies the band the glyph sits on.
        let titleTop = title.isHidden
            ? ((headerHeight - titleHeight) / 2).rounded()
            : title.frame.origin.y
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
        // An open rename field is a control, and the same rule every other header control
        // gets applies to it: its rect is not pane-drag surface. Without this the click that
        // places a caret picks the pane up instead.
        if renamePhase?.isEditing == true, title.frame.contains(local) {
            return title
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
        // The open rename field keeps AppKit's own editing menu, exactly as a header text
        // field does — popping Split/Stack/Close over a caret would be the wrong vocabulary.
        if renamePhase?.isEditing == true, title.frame.contains(local) {
            return nil
        }
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
        if renamePhase?.isEditing == true, title.frame.contains(local) {
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
        workspaceID: UUID,
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
        /// What this pane is doing to its own name, if anything. A VALUE like the header and
        /// the attention state, and deliberately not part of `contentKey`: a pane being
        /// renamed must not have its live PTY or web surface torn down and rebuilt.
        renamePhase: PaneRenamePhase?,
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
        presentedContent = slot.content
        presentedTitle = newTitle
        self.showsFocusRing = showsFocusRing
        setState(isActive: isActive)
        applyRenameChrome(phase: renamePhase, contentTitle: newTitle)
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
                workspaceID: workspaceID,
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
            let contentHost = PaneContentHost.make(root)
            contentHost.layer?.backgroundColor = TenonTheme.inkNS.cgColor
            addSubview(contentHost, positioned: .below, relativeTo: glyph)
            self.contentHost = contentHost
        }
        needsLayout = true
    }

    /// Called by the canvas when the set of live plugin generations changes.
    func invalidatePluginContent(
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

    // MARK: - Renaming, on the pane's own title  @domain: pane-chrome

    /// The band an inline rename gets: everything between the pane's glyph and its close
    /// control. Pure geometry over the card's own bounds — the close control's rect is
    /// recomputed rather than read, because `layout()` places the title before it.
    func editingTitleRect(headerHeight: CGFloat) -> CGRect {
        let fieldHeight = min(22, max(headerHeight - 6, 1))
        let leading = max(headerSolution.glyphRect.maxX + 6, 8)
        let trailing = max(bounds.width - 27, leading + 1)
        return CGRect(
            x: leading,
            y: ((headerHeight - fieldHeight) / 2).rounded(),
            width: max(trailing - leading - 4, 1),
            height: fieldHeight
        )
    }

    /// Draw whatever this pane is doing to its name.
    ///
    /// Which words appear is `PaneRenameChrome`'s decision — a pure function this method only
    /// paints — so what the title says in each phase is asserted without a window. What lives
    /// here is the part no value can carry: an `NSTextField` that becomes editable, takes the
    /// keyboard, and gives it back.
    private func applyRenameChrome(phase: PaneRenamePhase?, contentTitle: String) {
        let wasEditing = renamePhase?.isEditing ?? false
        renamePhase = phase
        let chrome = PaneRenameChrome.make(
            phase: phase,
            contentTitle: contentTitle,
            contentGlyph: SlotPresentation.glyph(for: presentedContent)
        )
        glyph.stringValue = chrome.glyph
        title.toolTip = chrome.tooltip
        renameEmphasisColor = chrome.emphasis.map(Self.emphasisColor)
        // A field mid-edit owns its own text. Rewriting `stringValue` on every reconfigure —
        // and the canvas reconfigures on every catalog mutation — would delete what the
        // operator is typing, one keystroke behind.
        if !(chrome.isEditable && wasEditing) {
            title.stringValue = chrome.title
        }
        setRenameEditing(chrome.isEditable, seed: chrome.title, wasEditing: wasEditing)
        applyTitleColor()
    }

    private func setRenameEditing(_ isEditing: Bool, seed: String, wasEditing: Bool) {
        guard isEditing != wasEditing else { return }
        if isEditing {
            title.isEditable = true
            title.isSelectable = true
            title.isBezeled = true
            title.bezelStyle = .roundedBezel
            title.drawsBackground = true
            title.backgroundColor = TenonTheme.panelNS
            title.focusRingType = .default
            title.lineBreakMode = .byTruncatingTail
            title.delegate = self
            title.stringValue = seed
            needsLayout = true
            layoutSubtreeIfNeeded()
            window?.makeFirstResponder(title)
            title.currentEditor()?.selectAll(nil)
        } else {
            let heldFocus = title.currentEditor() != nil
            title.isEditable = false
            title.isSelectable = false
            title.isBezeled = false
            title.drawsBackground = false
            title.focusRingType = .none
            title.lineBreakMode = .byTruncatingMiddle
            title.delegate = nil
            if heldFocus {
                // Hand the keyboard back to the pane rather than to whatever AppKit picks:
                // a terminal that lost focus to a rename has to be typeable again after it.
                window?.makeFirstResponder(contentHost ?? self)
            }
            needsLayout = true
        }
    }

    private func applyTitleColor() {
        if let renameEmphasisColor {
            title.textColor = renameEmphasisColor
            glyph.textColor = renameEmphasisColor
        } else {
            title.textColor = headerIsActive ? TenonTheme.textNS : TenonTheme.mutedNS
            glyph.textColor = headerIsActive ? TenonTheme.amberNS : TenonTheme.mutedNS
        }
    }

    private static func emphasisColor(_ token: ColorToken) -> NSColor {
        switch token {
        case .red: return NSColor(hex: 0xED6A5E)
        case .green: return NSColor(hex: 0x61C28B)
        case .amber: return TenonTheme.amberNS
        case .muted, .default: return TenonTheme.mutedNS
        case .text: return TenonTheme.textNS
        }
    }

    /// Put text in the open rename field. The card owns that field, so this is the only door
    /// for a caller that is not the keyboard — a test, or a future paste-a-name path.
    func setRenameText(_ text: String) {
        guard renamePhase?.isEditing == true else { return }
        title.stringValue = text
    }

    func commitRename() {
        guard renamePhase?.isEditing == true, !isSettlingRename else { return }
        isSettlingRename = true
        defer { isSettlingRename = false }
        onRenameCommit?(slotID, title.stringValue)
    }

    func cancelRename() {
        guard renamePhase?.isEditing == true, !isSettlingRename else { return }
        isSettlingRename = true
        defer { isSettlingRename = false }
        onRenameCancel?(slotID)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRename()
            return true
        default:
            return false
        }
    }

    /// Clicking away commits, the way renaming a file in Finder does — the operator typed a
    /// name, so losing the field is not a reason to throw it away. Escape is the discard.
    func controlTextDidEndEditing(_ notification: Notification) {
        commitRename()
    }

    /// T-029: project the pane's attention state onto the header dot — the same one
    /// machine the tab chip, sidebar and title bar read; nothing recomputed here.
    func setAttention(_ state: PaneActivityState?) {
        if let state {
            stateDot.isHidden = false
            stateDot.layer?.backgroundColor =
                PaneAttentionProjection.dotColor(for: state).cgColor
            // The dot is the pane's whole attention signal, and a colour is not readable by
            // everyone or by anything. The state travels as a shape when the system asks for
            // one, and as words to the accessibility tree either way.
            if PaneAttentionProjection.differentiatesWithoutColor {
                let symbol = NSImage(
                    systemSymbolName: PaneAttentionProjection.symbolName(for: state),
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(
                        pointSize: 8,
                        weight: .semibold
                    )
                    .applying(
                        .init(paletteColors: [PaneAttentionProjection.dotColor(for: state)])
                    )
                )
                stateDot.layer?.contents = symbol
                stateDot.layer?.contentsGravity = .resizeAspect
                stateDot.layer?.backgroundColor = NSColor.clear.cgColor
            } else {
                stateDot.layer?.contents = nil
            }
            stateDot.setAccessibilityElement(true)
            stateDot.setAccessibilityRole(.staticText)
            stateDot.setAccessibilityLabel(Shell.text("Activity"))
            stateDot.setAccessibilityValue(PaneAttentionProjection.spokenState(for: state))
        } else {
            stateDot.isHidden = true
            stateDot.setAccessibilityElement(false)
        }
        needsLayout = true
    }

    func setState(isActive: Bool) {
        let wasActive = headerIsActive
        headerIsActive = isActive
        // Focus decides the title's and glyph's colour unless the pane is reporting a rename
        // state on them; `applyTitleColor` owns that precedence in one place, so a reconfigure
        // during a rename cannot repaint the state away.
        applyTitleColor()
        // Header accessories dim with their pane for the same reason the glyph and title
        // do: a fully-lit row of controls on an unfocused pane reads as the focused one.
        //
        // Both guards earn their place. `refreshCardActivity()` restates this on every
        // card after every gesture and every reconfigure, so an unconditional invalidation
        // would re-solve and re-mount every header run each time — the exact full pass
        // that method exists to avoid. And the glyph and the title recolour themselves
        // above without any layout, so a pane with nothing in its chrome has nothing left
        // whose appearance depends on focus.
        if wasActive != isActive {
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

    /// Two audiences, two channels.
    ///
    /// What VoiceOver speaks is where the pane is, in the words a person would use — the value
    /// is the one place a screen reader reports a group's state, and it used to hold a UUID and
    /// four raw grid numbers. The stable identity and exact rect a UI test needs ride the
    /// accessibility *identifier*, which is never spoken.
    /// Both strings are pure functions of the rect, so an unchanged rect has nothing new to
    /// say. `applyFrames` calls this for every displayed card on every layout pass and on every
    /// `.leftMouseDragged`, and unlike the `card.frame` assignment beside it — which AppKit
    /// short-circuits when the rect is unchanged — writing here means a UUID interpolation and
    /// one or two `String(localized:)` lookups each time.
    ///
    /// Returns whether it wrote, so the saving is assertable rather than merely intended.
    @discardableResult
    func updateAccessibilityValue(for slot: SpatialSlot) -> Bool {
        guard appliedAccessibilityRect != slot.rect else { return false }
        appliedAccessibilityRect = slot.rect
        setAccessibilityIdentifier(
            "tenon.slot#\(slot.id.uuidString)@\(slot.rect.x),\(slot.rect.y),\(slot.rect.width),\(slot.rect.height)"
        )
        setAccessibilityValue(Self.spokenPosition(of: slot.rect))
        return true
    }

    /// "Column 2, row 1, 2 by 1 cells" — the grid is one-based when spoken, because a person
    /// counting columns starts at one.
    static func spokenPosition(of rect: GridRect) -> String {
        let place = Shell.text(
            "Column \(rect.x + 1), row \(rect.y + 1)",
            comment: "A pane's position on the grid, spoken by VoiceOver"
        )
        guard rect.width > 1 || rect.height > 1 else { return place }
        return Shell.text(
            "\(place), \(rect.width) by \(rect.height) cells",
            comment: "A pane's position and the number of grid cells it spans"
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
            accessibilityDescription: Shell.text("Resize diagonally")
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
