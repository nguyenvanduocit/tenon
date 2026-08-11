import AppKit
import SwiftUI
import XCTest

@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore

/// T-096, the half a headless assertion cannot reach: what the strip *looks like* mid-drag.
///
/// A passing rule test says the caret belongs in gap 3; it says nothing about whether a 2 pt
/// hairline between two 26 pt chips reads as an insertion point, whether the lifted chip is
/// distinguishable from its neighbours, or whether either clips. So this lays the shipped
/// `TabChip` out through the shipped `TabChipExtentReporter`, places the shipped
/// `TabInsertionCaret` at the x the shipped rule answers with, and writes the picture.
///
/// The first version of this test measured chips with `NSHostingView.fittingSize` instead,
/// and the photograph showed the caret sitting on top of a chip's ✕: a close control is an
/// overlay, so a chip's ideal width and its laid-out width differ by exactly that button.
/// The strip has never used that number — but a picture taken with it would have been
/// evidence for a layout the app does not draw.
@MainActor
final class TabStripReorderTests: XCTestCase {
    private let titles = ["tenon", "claude — supervise", "docs", "kanban"]
    private let stripSize = CGSize(width: 620, height: 36)

    /// Collects what the chips report, exactly as `ShellTitleBar`'s own `chipExtents` does.
    @MainActor
    private final class Extents {
        var byID: [UUID: ClosedRange<CGFloat>] = [:]
    }

    func testRightClickObserverNeverTakesTheLeftMouseHitNeededByReorder() {
        let catcher = RightClickCatcher.CatcherView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 26)
        )

        XCTAssertNil(
            catcher.hitTest(NSPoint(x: 80, y: 13)),
            "the secondary-click seam must never become the target of a tab drag"
        )
    }

    /// T-101, the whole reason a tab drag reorders a tab instead of moving the window.
    ///
    /// The strip is drawn inside the window's title-bar band. AppKit builds a drag region for
    /// that band and uploads it to the window server, which then moves the window itself; a
    /// view leaves the region by answering `mouseDownCanMoveWindow` with `false`, which is
    /// read when the region is built and never at press time.
    func testStripSurfaceNeverHandsThePressToTheWindowServer() {
        let surface = TabStripSurface.SurfaceView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 26)
        )

        XCTAssertFalse(
            surface.mouseDownCanMoveWindow,
            "a press the window server takes is a window move, not a reorder"
        )
    }

    /// Clicking a tab must leave the keyboard where it was — and this asks the window, not
    /// the class.
    ///
    /// The property version of this test (`acceptsFirstResponder == false`) is what broke the
    /// feature: the drag-region builder carves out a control that accepts first responder and
    /// leaves one that refuses inside the region, so satisfying that assertion handed every
    /// chip back to the window server while the suite stayed green. The premise under it was
    /// never true — AppKit focuses no view on a press by itself — so the consequence is what
    /// gets asserted, and the mechanism is free to be whatever keeps it true.
    func testStripSurfaceNeverTakesKeyboardFocusFromTheTerminal() throws {
        let bar = try titleBar()
        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }

        // Stands in for the terminal below the bar: something that wants the keyboard.
        let terminal = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        window.contentView?.addSubview(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal), "the stand-in must take the keyboard")

        let surface = try XCTUnwrap(
            Self.findSurface(in: try XCTUnwrap(window.contentView?.superview))
        )
        let point = surface.convert(
            NSPoint(x: surface.bounds.midX, y: surface.bounds.midY),
            to: nil
        )
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseUp, at: point, in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertIdentical(
            window.firstResponder as AnyObject?,
            terminal,
            "a click on a tab took the keyboard away from the terminal the tab is showing"
        )

        // And no Tab key ever lands here either. This one is safe to assert as a property
        // because its interaction with the drag region was measured rather than assumed:
        // refusing the key view loop leaves the view outside the region, where refusing first
        // responder puts it back in. If anyone reaches for the other lever again, the region
        // test above is what goes red.
        XCTAssertFalse(
            surface.canBecomeKeyView,
            "the strip must stay out of the key view loop"
        )
    }

    /// The terminal's one relevant property, and nothing else.
    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The claim is unconditional, and that is the point.
    ///
    /// Staying out of the drag region only means the app *may* have the press; it still has to
    /// arrive, and it arrives at whichever view answers the hit test. A surface that answers
    /// only while a primary-button event happens to be dispatching is not that view at every
    /// other moment — the first fix for T-101 was written that way.
    func testStripSurfaceClaimsEveryPointInsideItself() {
        let surface = TabStripSurface.SurfaceView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 26)
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
        host.addSubview(surface)

        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 240, y: 13), NSPoint(x: 479, y: 25)] {
            XCTAssertIdentical(
                surface.hitTest(point) as AnyObject?,
                surface,
                "the strip must own \(point) with no event in flight"
            )
        }
        XCTAssertNil(
            surface.hitTest(NSPoint(x: 600, y: 13)),
            "and must claim nothing outside itself"
        )
    }

    /// Taking the pointer must not take the accessibility tree: the chips keep publishing
    /// their labels, spoken position, and move actions.
    func testStripSurfaceIsInvisibleToAssistiveTechnology() {
        let surface = TabStripSurface.SurfaceView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 26)
        )

        XCTAssertFalse(surface.isAccessibilityElement())
        XCTAssertNil(surface.accessibilityHitTest(NSPoint(x: 80, y: 13)))
    }

    /// The composition, not the class: the shipped chips laid out the shipped way, with the
    /// shipped surface over them, inside a real hidden-titlebar window. What a chip's centre
    /// hit-tests to here is what receives the press once the region has let the app keep it.
    ///
    /// This is the assertion the first fix would have failed.
    func testAChipCentreHitTestsToTheStripSurfaceInsideARealTitleBarWindow() throws {
        let ids = titles.indices.map { _ in UUID() }
        let measured = Extents()
        let bar = row(ids: ids, dragging: -1, caretX: nil, extents: measured)
            .overlay(
                TabStripSurface(
                    began: { _ in },
                    changed: { _ in },
                    ended: { _ in },
                    cancelled: {},
                    pressed: { _ in },
                    hovered: { _ in }
                )
            )

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: stripSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: AnyView(bar))
        // As far out of the way as a titled window's constrained origin allows: laid out and
        // hit-testable wherever it lands.
        window.setFrameOrigin(NSPoint(x: -8_000, y: -8_000))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        window.contentView?.layoutSubtreeIfNeeded()

        let frameView = try XCTUnwrap(window.contentView?.superview)
        let surface = try XCTUnwrap(
            Self.findSurface(in: frameView),
            "the strip's surface never reached the view hierarchy"
        )

        // The surface must actually stand over the chips — a degenerate frame would let the
        // hit-test assertion below pass while covering nothing.
        let chip = try XCTUnwrap(measured.byID[ids[0]], "a chip never reported its extent")
        let surfaceInStrip = surface.convert(surface.bounds, to: surface.superview)
        XCTAssertLessThanOrEqual(
            surfaceInStrip.minX,
            chip.lowerBound,
            "the surface starts after the first chip does"
        )
        XCTAssertGreaterThanOrEqual(
            surfaceInStrip.maxX,
            chip.upperBound,
            "the surface ends before the first chip does"
        )

        // Now ask the question macOS asks when a person presses a tab: at the centre of the
        // strip, which view answers — and does it refuse the window drag?
        let centre = surface.convert(
            NSPoint(x: surface.bounds.midX, y: surface.bounds.midY),
            to: nil
        )
        let hit = frameView.hitTest(centre)
        XCTAssertIdentical(
            hit as AnyObject?,
            surface,
            """
            a chip resolved to \(hit.map { String(describing: type(of: $0)) } ?? "nil") \
            — anything but the strip's own surface hands the drag to the window server
            """
        )
        XCTAssertFalse(
            surface.mouseDownCanMoveWindow,
            "the view the window server asks must refuse"
        )
        window.orderOut(nil)
    }

    /// The shipped bar with three tabs behind it, and the store that answers for them.
    private struct MountedBar {
        let view: AnyView
        let store: WorkspaceStore
    }

    private func titleBar() throws -> MountedBar {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-strip-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let stateRoot = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        let store = WorkspaceStore()
        while (store.catalog.activeWorkspace?.tabs.count ?? 0) < 3 {
            store.newTab()
        }
        if let first = store.catalog.activeWorkspace?.tabs.first?.id {
            store.selectTab(first)
        }

        let pool = SurfacePool(backendName: "Tab strip") { _, _ in StubTerminalSurface() }
        let userInterface = PluginUIState()
        let runtime = try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: PluginWebSurfacePool(),
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: runtime.kernel,
            authorization: .bundledInventory
        )

        let bar = ShellTitleBar(
            host: host,
            store: store,
            pool: pool,
            intentRuntime: runtime,
            router: DragRouter(),
            palette: CommandPaletteState(
                storeURL: stateRoot.appendingPathComponent("frecency.json")
            ),
            quickCommands: QuickCommandStore(
                defaults: UserDefaults(suiteName: "tab-strip-\(UUID().uuidString)")!,
                storageKey: "quick"
            ),
            agentSuggestions: [],
            sidebarVisible: false,
            sidebarWidth: 0,
            onToggleSidebar: {}
        )
        return MountedBar(view: AnyView(bar), store: store)
    }

    /// The whole gesture, on the shipped bar, driven by the events AppKit itself dispatches.
    ///
    /// Every earlier assertion here stops one step short of the thing that kept failing in a
    /// person's hands: the hit test is right, the rule is right, and a tab still did not move.
    /// This drives a real `NSEvent` press-drag-release through `ShellTitleBar` itself — routed
    /// by the window's own hit test, as `send` describes — and asks the workspace whether the
    /// tab ended up somewhere else. An earlier reading of this seam concluded synthetic events
    /// never reach a view; that reading was wrong, and it cost two failed fixes.
    func testARealPressAndDragOnTheStripMovesTheTabItStartedOn() throws {
        let bar = try titleBar()
        let store = bar.store
        let ids = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.map(\.id))
        XCTAssertEqual(ids.count, 3, "the strip needs three chips to have somewhere to move")

        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }

        let frameView = try XCTUnwrap(window.contentView?.superview)
        let surface = try XCTUnwrap(
            Self.findSurface(in: frameView),
            "the strip's surface never reached the view hierarchy"
        )
        XCTAssertGreaterThan(surface.bounds.width, 60, "the surface never took a real width")

        // A press just inside the first chip, travelling to the far end of the strip: past
        // every chip's midpoint, so the drop means "after the last one".
        let start = surface.convert(
            NSPoint(x: surface.bounds.minX + 12, y: surface.bounds.midY),
            to: nil
        )
        let end = surface.convert(
            NSPoint(x: surface.bounds.maxX - 4, y: surface.bounds.midY),
            to: nil
        )
        send(.leftMouseDown, at: start, in: window)
        for step in stride(from: 0.1, through: 1.0, by: 0.15) {
            send(
                .leftMouseDragged,
                at: NSPoint(x: start.x + (end.x - start.x) * step, y: start.y),
                in: window
            )
        }
        send(.leftMouseUp, at: end, in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.map(\.id),
            [ids[1], ids[2], ids[0]],
            "a drag from the first chip to the end of the strip must land the tab last"
        )
    }

    /// The short drag: one chip past its neighbour, which is what a person reaching for
    /// "swap these two" actually does.
    ///
    /// The long drag to the end of the strip was the only gesture asserted, and it clears
    /// every midpoint at once — so it could not tell a working commit apart from one that
    /// only ever lands at the far end. This crosses exactly one midpoint.
    func testAShortDragPastOneNeighbourSwapsThatPair() throws {
        let bar = try titleBar()
        let store = bar.store
        let ids = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.map(\.id))

        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }
        let surface = try XCTUnwrap(
            Self.findSurface(in: try XCTUnwrap(window.contentView?.superview))
        )

        // Three chips share the strip evenly, so the second one's midpoint is at 1/2 and
        // landing just past it is the smallest travel that means anything at all.
        let width = surface.bounds.width
        let start = surface.convert(NSPoint(x: 12, y: surface.bounds.midY), to: nil)
        let end = surface.convert(NSPoint(x: width * 0.55, y: surface.bounds.midY), to: nil)

        send(.leftMouseDown, at: start, in: window)
        for step in stride(from: 0.2, through: 1.0, by: 0.2) {
            send(
                .leftMouseDragged,
                at: NSPoint(x: start.x + (end.x - start.x) * step, y: start.y),
                in: window
            )
        }
        send(.leftMouseUp, at: end, in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.map(\.id),
            [ids[1], ids[0], ids[2]],
            "dragging the first chip past its neighbour's midpoint must swap that pair"
        )
    }

    /// A drag that ends where the caret was standing must move the tab there.
    ///
    /// The caret is drawn from `insertionIndex` alone while the commit runs that index
    /// through `destination`, which refuses `source` and `source + 1`. Those two rules can
    /// disagree, and when they do the strip promises a move it will not make — which is
    /// indistinguishable, to the person holding the mouse, from a drag that is simply broken.
    func testEveryGapTheCaretCanStandInEitherMovesTheTabOrIsNotDrawn() throws {
        let bar = try titleBar()
        let ids = try XCTUnwrap(bar.store.catalog.activeWorkspace?.tabs.map(\.id))
        let chips = ids.enumerated().map { index, id in
            TabChipExtent(id: id, minX: Double(index) * 100, maxX: Double(index) * 100 + 90)
        }

        for source in ids.indices {
            for insertion in 0 ... chips.count {
                let moves = TabReorder.destination(
                    forTab: ids[source],
                    insertingAt: insertion,
                    chips: chips
                ) != nil
                let drawn = TabReorder.caretX(forInsertion: insertion, chips: chips) != nil
                guard drawn, !moves else { continue }
                XCTAssertTrue(
                    insertion == source || insertion == source + 1,
                    """
                    the caret stands in gap \(insertion) while dragging tab \(source), and \
                    releasing there moves nothing — a caret may only be a no-op in the two \
                    gaps that touch the tab being dragged
                    """
                )
            }
        }
    }

    /// The assertion every other test in this file was blind to.
    ///
    /// Three fixes shipped and a human drag kept moving the window while hit-testing, event
    /// delivery and the reorder rules were all provably correct — because none of them is what
    /// decides. AppKit computes a **drag region** for the window and uploads it to the window
    /// server, which starts the move itself, before the app is consulted at all. A view leaves
    /// that region by answering `mouseDownCanMoveWindow` with `false` *and* being an
    /// `NSControl` descendant; the region builder ignores a plain `NSView` saying it.
    ///
    /// So this reads the region back and checks the chips are outside it. The empty chrome is
    /// the other half of the oracle: it must stay *inside*, or the window has merely stopped
    /// being draggable everywhere — which is what `window.isMovable = false` did, and why that
    /// lever was rejected.
    func testTheChipsAreOutsideTheDragRegionTheWindowServerMovesTheWindowFrom() throws {
        let bar = try titleBar()
        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }

        let describe = NSSelectorFromString("_lastDragRegionDataDescription")
        try XCTSkipUnless(
            window.responds(to: describe),
            "this macOS no longer exposes the drag region; the rule it guards still holds"
        )
        let description = (window.perform(describe)?.takeUnretainedValue() as? NSString) as String?
        let region = Self.rects(in: description ?? "")

        // Oracle: the empty chrome past the strip must still hand its drag to the server.
        let bandY = window.frame.height - 16
        let chrome = NSPoint(x: window.frame.width - 60, y: bandY)
        XCTAssertTrue(
            region.contains { $0.contains(chrome) },
            """
            the empty title bar is no longer draggable — the region is \(region), and a fix \
            that empties it has taken the window's own drag with it
            """
        )

        // And the strip's own half of it, measured on the shipped surface rather than
        // inferred from its superclass. A class check answers "is the lever set", never
        // "did the lever work here" — and the difference is a moving window.
        let surface = try XCTUnwrap(
            Self.findSurface(in: try XCTUnwrap(window.contentView?.superview)),
            "the shipped bar draws no TabStripSurface, so nothing takes the chips' pointer"
        )
        let chips = surface.convert(surface.bounds, to: nil)

        // Third oracle, and the one this test spent two reports without: a strip below the
        // band is outside the region for a reason that has nothing to do with the fix, so
        // "not covered" would mean nothing. The band is the top 32pt of the window.
        let bandBottom = window.frame.height - 32
        XCTAssertTrue(
            chips.maxY > bandBottom,
            """
            the harness put the strip at \(chips), below the band that ends at \(bandBottom) — \
            it is measuring empty content, not the title bar
            """
        )

        XCTAssertFalse(
            region.contains { $0.intersects(chips) },
            """
            the window server still moves the window from the chips: the strip occupies \
            \(chips) and the region is \(region)
            """
        )

        // The rule behind this is re-measurable outside the suite at
        // `swift scripts/drag-region-probe.swift`, which puts both superclasses across a real
        // band and shows the region covering one and skipping the other.
    }

    private static func rects(in description: String) -> [NSRect] {
        let pattern = #"\{\{\s*([-\d.]+),\s*([-\d.]+)\s*\},\s*\{\s*([-\d.]+),\s*([-\d.]+)\s*\}\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = description as NSString
        return expression
            .matches(in: description, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let numbers = (1 ... 4).compactMap { Double(text.substring(with: match.range(at: $0))) }
                guard numbers.count == 4 else { return nil }
                return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
    }

    /// Taking the pointer means owing what was taken. A press that never travels used to be
    /// answered by the chip's own button; now the surface is in front of it, so this is the
    /// only thing left that can select a tab.
    func testAPressThatDoesNotTravelSelectsTheChipUnderIt() throws {
        let bar = try titleBar()
        let store = bar.store
        let ids = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.map(\.id))
        XCTAssertEqual(store.catalog.activeWorkspace?.activeTabID, ids.first)

        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }
        let surface = try XCTUnwrap(
            Self.findSurface(in: try XCTUnwrap(window.contentView?.superview))
        )

        // Body of the last chip: past its neighbours, and clear of its own close control,
        // which is a 24pt overlay on the trailing edge.
        let body = surface.convert(
            NSPoint(x: surface.bounds.maxX - 40, y: surface.bounds.midY),
            to: nil
        )
        send(.leftMouseDown, at: body, in: window)
        send(.leftMouseUp, at: body, in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(
            store.catalog.activeWorkspace?.activeTabID,
            ids.last,
            "a click on a chip must still select its tab"
        )
    }

    /// The other half of that debt: the ✕ is drawn by the chip but pressed through the
    /// surface, which resolves it against the extent the control itself reported.
    func testAPressOnTheCloseControlClosesThatTab() throws {
        let bar = try titleBar()
        let store = bar.store
        let ids = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.map(\.id))

        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }
        let surface = try XCTUnwrap(
            Self.findSurface(in: try XCTUnwrap(window.contentView?.superview))
        )

        let close = surface.convert(
            NSPoint(x: surface.bounds.maxX - 10, y: surface.bounds.midY),
            to: nil
        )
        send(.leftMouseDown, at: close, in: window)
        send(.leftMouseUp, at: close, in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.map(\.id),
            Array(ids.dropLast()),
            "a click on the ✕ must close that tab and leave the others alone"
        )
    }

    /// A chip inside the band cannot notice a pointer that never reaches it, so the surface
    /// reports the hover — and reports its end, or a chip stays lit behind a pointer that has
    /// gone.
    func testTheSurfaceReportsTheEndOfAHover() {
        let surface = TabStripSurface.SurfaceView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 26)
        )
        var reported: [CGPoint?] = []
        surface.hovered = { reported.append($0) }

        surface.mouseExited(with: NSEvent())

        XCTAssertEqual(reported.count, 1)
        XCTAssertNil(reported[0] ?? nil, "leaving the strip must clear the lit chip")
    }

    /// The crash this file found: SwiftUI calls `dismantleNSView` from inside its own graph
    /// teardown, and writing `@State` there is a fatal exclusivity violation rather than a
    /// late update. The release therefore has to land on a later turn of the run loop — this
    /// asserts *when*, not merely *that*.
    func testDismantlingTheSurfaceDefersItsReleaseOutOfSwiftUIsTeardown() {
        let surface = TabStripSurface.SurfaceView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 26)
        )
        var hovers = 0
        surface.hovered = { _ in hovers += 1 }

        TabStripSurface.dismantleNSView(surface, coordinator: ())
        XCTAssertEqual(hovers, 0, "dismantle must not touch SwiftUI state synchronously")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(hovers, 1, "and must still clear the hover, one turn later")
    }

    /// The `+` sits outside the surface, so it keeps its own click. Under the first version
    /// of the surface it was inside, and pressing it did nothing at all.
    func testTheNewTabButtonIsNotCoveredByTheStripSurface() throws {
        let bar = try titleBar()
        let window = mount(bar.view, size: CGSize(width: 900, height: 300))
        defer { window.orderOut(nil) }

        let frameView = try XCTUnwrap(window.contentView?.superview)
        let surface = try XCTUnwrap(Self.findSurface(in: frameView))

        // The `+` sits one gap past the last chip. Press there and the surface must not be
        // what answers — otherwise the button never hears the click at all.
        let plus = surface.convert(
            NSPoint(
                x: surface.bounds.maxX + TabStripSpace.spacing + 8,
                y: surface.bounds.midY
            ),
            to: nil
        )
        let hit = frameView.hitTest(plus)
        XCTAssertNotIdentical(
            hit as AnyObject?,
            surface,
            "the strip's surface covers the + button, and swallows every press on it"
        )
    }

    /// The view holding the pointer for the length of one press. AppKit hands every drag and
    /// the release to whichever view took the `mouseDown`, wherever the pointer has travelled
    /// to since, so the gesture below is delivered the same way.
    private var pressTarget: NSView?

    /// One event of a real gesture, routed the way the window routes one: the frame view
    /// hit-tests the press, whatever answers receives it, and that view keeps the rest of the
    /// press. Both halves are the shipped ones — the shipped view tree answers the hit test,
    /// and the shipped `mouseDown/mouseDragged/mouseUp` overrides do the work — so the
    /// question these tests ask about the title-bar band is unchanged.
    ///
    /// `NSWindow.sendEvent` is not what drives it, because that method dispatches only for a
    /// window the window server carries on its on-screen list, and a machine running the
    /// suite without a display session never puts one there. Measured on a window held off
    /// that list: `windowNumber` is assigned, `event.window` resolves, and the frame view
    /// hit-tests the press to the strip's own surface — while `mouseDown:` is never called at
    /// all. Every assertion that needs a press to *do* something then fails as "the tab order
    /// did not change", which is a sentence about reordering describing a window that was
    /// never on screen. `testAPressLandsOnTheChipInAWindowTheServerNeverPutOnScreen` holds
    /// this seam in place; the window server's own half of the routing is asserted by
    /// `testTheChipsAreOutsideTheDragRegionTheWindowServerMovesTheWindowFrom`.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            return XCTFail("could not build a \(type) event")
        }

        switch type {
        case .leftMouseDown:
            guard let frameView = window.contentView?.superview else {
                return XCTFail("the window has no frame view for a press to resolve against")
            }
            // Asserted here rather than in each caller because a press that resolves to
            // nothing fails these tests as "the tab order did not change", which reads like a
            // reorder bug and is not one.
            guard let target = frameView.hitTest(point) else {
                return XCTFail("no view in the window claims \(point), so the press lands nowhere")
            }
            pressTarget = target
            target.mouseDown(with: event)
        case .leftMouseDragged:
            guard let target = pressTarget else {
                return XCTFail("a drag arrived with no press holding the pointer")
            }
            target.mouseDragged(with: event)
        case .leftMouseUp:
            guard let target = pressTarget else {
                return XCTFail("a release arrived with no press holding the pointer")
            }
            pressTarget = nil
            target.mouseUp(with: event)
        default:
            XCTFail("\(type) is not part of a primary-button gesture")
        }
    }

    /// The condition every other gesture test in this file is silently mounted on, asserted
    /// once on its own: a press reaches the chip in a window the window server never listed.
    ///
    /// That is the state a runner with no display session leaves every window in, and it is
    /// where four of these tests spent five CI runs red while hit-testing, the drag region,
    /// the reorder rules and the strip's own measurements were all provably intact. Pressing
    /// a chip here fails the moment delivery goes back through `NSWindow.sendEvent`.
    func testAPressLandsOnTheChipInAWindowTheServerNeverPutOnScreen() throws {
        let bar = try titleBar()
        let store = bar.store
        let ids = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.map(\.id))

        let window = mount(bar.view, size: CGSize(width: 900, height: 300), onScreen: false)
        defer { window.orderOut(nil) }
        XCTAssertFalse(
            NSWindow.windowNumbers(options: [])?
                .contains(NSNumber(value: window.windowNumber)) ?? false,
            "this window has to be off the on-screen list for the test to be asking anything"
        )

        let surface = try XCTUnwrap(
            Self.findSurface(in: try XCTUnwrap(window.contentView?.superview))
        )
        let body = surface.convert(
            NSPoint(x: surface.bounds.maxX - 40, y: surface.bounds.midY),
            to: nil
        )
        send(.leftMouseDown, at: body, in: window)
        send(.leftMouseUp, at: body, in: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(
            store.catalog.activeWorkspace?.activeTabID,
            ids.last,
            "a press must reach the chip in a window no display ever showed"
        )
    }

    /// A real hidden-titlebar window carrying the title-bar band the whole bug lives in, put
    /// as far out of the way as AppKit allows — a titled window's origin is constrained back
    /// onto whatever screen exists, so on a desktop this lands in a corner rather than
    /// nowhere. `onScreen: false` leaves it unordered, which is the state a machine with no
    /// display session leaves every window in.
    private func mount(_ view: some View, size: CGSize, onScreen: Bool = true) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Composed the way `ContentView` composes it, and for the reason the drag region
        // exists: the bar has to sit *in* the title-bar band. Hosted without
        // `.ignoresSafeArea` the safe area pushes it 28pt below the band — measured, the
        // chips landed 62pt from the top while the region ends at 32 — and every question
        // about the band then measures nothing at all.
        // Pinned to the top of the window in AppKit, at the height `ContentView` gives it.
        //
        // `.ignoresSafeArea(.container, edges: .top)` was supposed to do this and does not:
        // measured through the surface's own frame, the strip landed 62pt from the top while
        // the drag region ends at 32 — so every question this file asked about the title-bar
        // band was answered about empty content below it, and the region test could not fail
        // for two consecutive reports. Placing the row explicitly removes the safe area from
        // the question; the band oracle in the region test refuses to let it drift back.
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(
            x: 0,
            y: size.height - TenonTheme.titleBarHeight,
            width: size.width,
            height: TenonTheme.titleBarHeight
        )
        hosting.autoresizingMask = [.width, .minYMargin]
        content.addSubview(hosting)
        window.contentView = content
        window.setFrameOrigin(NSPoint(x: -8_000, y: -8_000))
        if onScreen { window.makeKeyAndOrderFront(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private static func findView(
        in view: NSView,
        where matches: (NSView) -> Bool
    ) -> NSView? {
        if matches(view) { return view }
        for sub in view.subviews {
            if let found = findView(in: sub, where: matches) { return found }
        }
        return nil
    }

    private static func findSurface(in view: NSView) -> TabStripSurface.SurfaceView? {
        if let surface = view as? TabStripSurface.SurfaceView { return surface }
        for sub in view.subviews {
            if let found = findSurface(in: sub) { return found }
        }
        return nil
    }

    private func chip(_ index: Int, ids: [UUID], dragging: Int) -> some View {
        TabChip(
            title: titles[index],
            isActive: index == 0,
            position: index,
            tabCount: titles.count,
            isDragging: index == dragging,
            move: { _ in },
            canClose: true,
            select: {},
            close: {},
            openLauncher: {}
        )
    }

    /// The strip's chip row, composed the way `ShellTitleBar` composes it: one spacing
    /// constant, one coordinate space, one extent reporter per chip.
    private func row(
        ids: [UUID],
        dragging: Int,
        caretX: CGFloat?,
        extents: Extents?
    ) -> some View {
        HStack(spacing: TabStripSpace.spacing) {
            ForEach(titles.indices, id: \.self) { index in
                self.chip(index, ids: ids, dragging: dragging)
                    .background(
                        TabChipExtentReporter { extents?.byID[ids[index]] = $0 }
                    )
            }
        }
        .overlay(alignment: .leading) {
            if let caretX { TabInsertionCaret(x: caretX) }
        }
        .coordinateSpace(name: TabStripSpace.name)
        .padding(.horizontal, 8)
        .frame(width: stripSize.width, height: stripSize.height, alignment: .leading)
        .background(TenonTheme.chrome)
    }

    func testTheCaretLandsInTheGapBesideTheChipNotOnItsCloseControl() throws {
        let ids = titles.indices.map { _ in UUID() }
        let dragging = 1

        let measured = Extents()
        let laidOut = host(row(ids: ids, dragging: dragging, caretX: nil, extents: measured))
        laidOut.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        laidOut.layoutSubtreeIfNeeded()

        let chips: [TabChipExtent] = ids.compactMap { id in
            measured.byID[id].map {
                TabChipExtent(id: id, minX: Double($0.lowerBound), maxX: Double($0.upperBound))
            }
        }
        XCTAssertEqual(chips.count, titles.count, "a chip never reported where it landed")

        // Pointer past the third chip's midpoint: gap 3, between "docs" and "kanban".
        let insertion = TabReorder.insertionIndex(at: chips[2].midX + 12, chips: chips)
        XCTAssertEqual(insertion, 3)
        let caretX = try XCTUnwrap(TabReorder.caretX(forInsertion: insertion, chips: chips))
        XCTAssertGreaterThanOrEqual(
            caretX,
            chips[2].maxX,
            "the caret is drawn inside the chip before the gap — on its close control"
        )
        XCTAssertLessThanOrEqual(
            caretX,
            chips[3].minX,
            "the caret is drawn inside the chip after the gap"
        )
        XCTAssertEqual(
            TabReorder.destination(forTab: ids[dragging], insertingAt: insertion, chips: chips),
            2,
            "releasing here must land the dragged tab where the caret is drawn"
        )

        guard let path = ProcessInfo.processInfo.environment["TENON_TAB_STRIP_SNAPSHOT"] else {
            return
        }
        try write(
            row(ids: ids, dragging: dragging, caretX: CGFloat(caretX), extents: nil),
            to: path
        )
    }

    // MARK: - Offscreen capture

    private func host(_ view: some View) -> NSHostingView<AnyView> {
        // `NSApp` is nil until something asks for the shared application, and it is an
        // implicitly unwrapped optional — so reading it first traps rather than returning
        // nil. `PaneViewSnapshotWriter` opens the same way.
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: stripSize)
        return hosting
    }

    private func write(_ view: some View, to path: String) throws {
        let hosting = host(view)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
