import CoreGraphics
import TenonCore
import XCTest
@testable import TenonApp

/// The pane-header solver, asserted without a window.
///
/// Every measurement is injected, so nothing here depends on a font, a screen or an OS version:
/// the stub answers a fixed width per item and the assertions are *relations* between the rects
/// that come back — "left of", "does not overlap", "folded before" — never pixel counts. The one
/// exception is the empty-header case, which is a pixel receipt on purpose: a pane that
/// contributes nothing must solve to exactly the geometry the card drew before this vocabulary
/// existed, and that arithmetic is written out independently here rather than read back from the
/// solver's own constants (the T-043 tautology lesson).
///
/// The sweep in most of these tests runs every width from 120 to 1600. Narrow is the common case
/// in multi-agent supervision, and the guarantees the rest of the card stands on — a pane you can
/// always grab, a resize edge you can always reach, a close control nothing can hide under — are
/// only guarantees if they hold at every width a user can drag a pane to.
final class PaneHeaderLayoutTests: XCTestCase {
    // MARK: - Fixtures

    /// Fixed widths, so a test states only the measurement its relation depends on.
    private struct FixedMetrics: PaneHeaderMetrics {
        var widths: [String: CGFloat] = [:]
        var standard: CGFloat = 30

        func width(of item: PaneHeaderItem) -> CGFloat { widths[item.id] ?? standard }
    }

    private let headerHeight: CGFloat = 34
    private let glyphHeight: CGFloat = 13
    private let titleHeight: CGFloat = 13
    private let titleIdealWidth: CGFloat = 96

    private func solve(
        _ header: PaneHeader,
        width: CGFloat,
        showsDot: Bool = false,
        metrics: FixedMetrics = FixedMetrics()
    ) -> PaneHeaderLayout.Solution {
        PaneHeaderLayout.solve(
            header: header,
            showsDot: showsDot,
            titleIdealWidth: titleIdealWidth,
            glyphSize: CGSize(width: 19, height: glyphHeight),
            titleHeight: titleHeight,
            bounds: CGSize(width: width, height: 200),
            headerHeight: headerHeight,
            metrics: metrics
        )
    }

    private func dot(_ id: String) -> PaneHeaderItem {
        .dot(id: id, tint: .green, tooltip: nil)
    }

    private func label(
        _ id: String,
        _ text: String,
        _ truncation: PaneHeaderTruncation = .tail
    ) -> PaneHeaderItem {
        .label(
            id: id,
            text: text,
            weight: .regular,
            color: .text,
            truncation: truncation,
            tooltip: nil
        )
    }

    private func badge(_ id: String, _ text: String) -> PaneHeaderItem {
        .badge(id: id, text: text, tint: .muted, tooltip: nil)
    }

    private func image(_ id: String) -> PaneHeaderItem {
        .image(id: id, systemName: "circle", tint: .muted, tooltip: nil)
    }

    private func button(_ id: String) -> PaneHeaderItem {
        .iconButton(
            id: id,
            systemName: "circle",
            tint: .default,
            isEnabled: true,
            tooltip: id,
            accessibilityID: nil
        )
    }

    private func toggle(_ id: String) -> PaneHeaderItem {
        .toggle(
            id: id,
            systemName: "eye",
            isOn: true,
            isEnabled: true,
            tooltip: id,
            accessibilityID: nil
        )
    }

    private func segmented(
        _ id: String,
        _ values: [String],
        selection: String
    ) -> PaneHeaderItem {
        .segmented(
            id: id,
            segments: values.compactMap { PaneHeaderSegment(value: $0, label: $0) },
            selection: selection,
            isEnabled: true,
            accessibilityID: nil
        )
    }

    private func menu(_ id: String, _ values: [String]) -> PaneHeaderItem {
        .menu(
            id: id,
            systemName: "ellipsis",
            entries: values.compactMap { PaneHeaderMenuEntry(value: $0, label: $0) },
            isEnabled: true,
            tooltip: nil,
            accessibilityID: nil
        )
    }

    private func textfield(_ id: String, flex: Bool) -> PaneHeaderItem {
        .textfield(
            id: id,
            value: "",
            placeholder: "Search or enter website",
            flex: flex,
            isEnabled: true,
            accessibilityID: nil
        )
    }

    /// One header per pane the migration produces, plus the two extremes: no contribution at
    /// all, and both slots saturated to their caps.
    private func corpus() -> [PaneHeader] {
        [
            PaneHeader(),
            // Agent Lens: identity and status leading, presentation and inspector trailing.
            PaneHeader(
                leading: [dot("state"), label("provider", "Claude"), label("status", "Working")],
                trailing: [
                    segmented("mode", ["session", "terminal", "split"], selection: "session"),
                    toggle("inspector"),
                ]
            ),
            // Diff: stats leading, style trailing.
            PaneHeader(
                leading: [badge("added", "+12"), badge("removed", "-3")],
                trailing: [segmented("style", ["unified", "split"], selection: "unified")]
            ),
            // Changes: branch leading, layout and refresh trailing.
            PaneHeader(
                leading: [image("branch"), label("branch-name", "main"), badge("total", "7")],
                trailing: [
                    segmented("layout", ["tree", "flat"], selection: "tree"),
                    button("refresh"),
                ]
            ),
            // Browser: navigation leading, a flexible address field trailing.
            PaneHeader(
                leading: [button("back"), button("forward"), button("reload")],
                trailing: [textfield("go", flex: true)]
            ),
            // Docs: nothing but progress.
            PaneHeader(trailing: [spinner("loading")]),
            // Both slots at their caps, every kind represented.
            PaneHeader(
                leading: [
                    dot("d"), label("l", "status"), badge("b", "9"), image("i"), spinner("s"),
                ],
                trailing: [
                    segmented("seg", ["one", "two"], selection: "one"),
                    toggle("tog"),
                    button("btn1"),
                    button("btn2"),
                    menu("mnu", ["m1", "m2"]),
                    badge("b2", "3"),
                    label("l2", "tail"),
                    textfield("tf", flex: false),
                ]
            ),
        ]
    }

    private func spinner(_ id: String) -> PaneHeaderItem { .spinner(id: id) }

    /// Every width a pane can be dragged to, in both attention-dot states, over every header the
    /// migration produces.
    private func sweep(
        _ body: (PaneHeader, CGFloat, Bool, PaneHeaderLayout.Solution) -> Void
    ) {
        for header in corpus() {
            for width in stride(from: CGFloat(120), through: 1600, by: 20) {
                for showsDot in [false, true] {
                    body(header, width, showsDot, solve(header, width: width, showsDot: showsDot))
                }
            }
        }
    }

    // MARK: - 15

    /// The no-contribution receipt. A pane that publishes nothing must land on the card's own
    /// pre-existing geometry, so step 1 of the migration changes no pixel except the header's
    /// height. The arithmetic is spelled out rather than derived from the solver's constants.
    func testAnEmptyHeaderSolvesToTodaysGlyphTitleAndCloseGeometry() {
        // ((34 - 13) / 2).rounded() == 11 for the title, ((34 - 7) / 2).rounded() == 14 for
        // the dot: the card's own centring, to the point.
        let bare = solve(PaneHeader(), width: 400)
        XCTAssertEqual(bare.glyphRect, CGRect(x: 9, y: 0, width: 19, height: 13))
        XCTAssertNil(bare.dotRect)
        XCTAssertEqual(bare.titleRect, CGRect(x: 31, y: 11, width: 400 - 31 - 31, height: 13))
        XCTAssertEqual(bare.dragBandRect, CGRect(x: 31, y: 0, width: 400 - 31 - 31, height: 34))
        XCTAssertTrue(bare.placements.isEmpty)
        XCTAssertTrue(bare.folded.isEmpty)
        XCTAssertNil(bare.overflow)
        XCTAssertNil(bare.leadingHostRect)
        XCTAssertNil(bare.trailingHostRect)
        // The title stops exactly where the close control's reservation begins, which is what
        // keeps the ✕ clear without either side knowing the other's frame.
        XCTAssertEqual(bare.titleRect.maxX, 400 - PaneHeaderLayout.closeButtonReserve)

        let withDot = solve(PaneHeader(), width: 400, showsDot: true)
        XCTAssertEqual(withDot.dotRect, CGRect(x: 31, y: 14, width: 7, height: 7))
        XCTAssertEqual(withDot.titleRect, CGRect(x: 43, y: 11, width: 400 - 43 - 31, height: 13))

        // Today's `max(width - titleX - 31, 1)` floor, at a width no pane should reach.
        let pinched = solve(PaneHeader(), width: 40)
        XCTAssertEqual(pinched.titleRect.width, 1)
    }

    // MARK: - 16

    /// The guarantee the XCUITest press-drag stands on: whatever a pane contributes, the strip
    /// between the glyph and the accessory floor is bare, always-draggable header.
    func testNoAccessoryIsEverPlacedLeftOfTheAccessoryOriginFloor() {
        XCTAssertEqual(
            corpus().reduce(0) { $0 + $1.leading.count + $1.trailing.count },
            31,
            "the corpus lost an item to PaneHeader's own bounds — fix the fixture, not the rule"
        )
        // The bare column the drag test grabs: x from 12 (past the corner square) to the floor.
        let grabColumn = CGRect(x: 12, y: 0, width: PaneHeaderLayout.accessoryOriginFloor - 12,
                                height: headerHeight)
        sweep { _, width, showsDot, solution in
            for placement in solution.placements {
                XCTAssertGreaterThanOrEqual(
                    placement.rect.minX,
                    PaneHeaderLayout.accessoryOriginFloor,
                    "\(placement.item.id) at width \(width), dot \(showsDot)"
                )
                XCTAssertFalse(
                    placement.rect.intersects(grabColumn),
                    "\(placement.item.id) reached the grab column at width \(width)"
                )
            }
        }
    }

    // MARK: - 17

    /// Clearance, read from the card's OWN rule instead of from the solver's constants.
    ///
    /// `SpatialCanvasInteractionCoordinator.hitRegion` is the function that decides whether a
    /// point resizes a pane or belongs to its header, and the card consults it for every point
    /// no control claimed. So every corner of every placement is put to that function and must
    /// come back `.header`: a control whose top edge lands in the 6-point north edge eats the
    /// strip the user grabs to resize, and one that reaches a 12×12 corner square eats a
    /// diagonal. Asserting the solver's `verticalInset` against itself could never say either —
    /// that is the tautology this test used to be, and the T-055/T-063 defect class in one line.
    func testEveryPlacementStaysBelowTheNorthResizeEdgeAndInsideTheCornerSquares() {
        sweep { _, width, showsDot, solution in
            let cardBounds = CGRect(x: 0, y: 0, width: width, height: 200)
            for placement in solution.placements {
                let rect = placement.rect
                for corner in [
                    CGPoint(x: rect.minX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY),
                    CGPoint(x: rect.maxX, y: rect.maxY),
                ] {
                    XCTAssertEqual(
                        SpatialCanvasInteractionCoordinator.hitRegion(at: corner, in: cardBounds),
                        .header,
                        """
                        \(placement.item.id) puts \(corner) outside the header \
                        at width \(width), dot \(showsDot)
                        """
                    )
                }
            }
        }
    }

    /// `PaneHeaderLayout.northResizeEdge` restates a constant that lives in
    /// `SpatialCanvasInteractionCoordinator`, and the solver's doc comment claims the two cannot
    /// drift. The corner sweep above only catches drift in ONE direction — an edge that grows —
    /// and only through whichever placements the corpus happens to produce. This asserts the
    /// restatement directly and in both directions, which is what that comment promises: the
    /// last row the edge claims is `northResizeEdge`, and the first row it does not is the next
    /// one up. An edge that shrinks would leave the solver reserving space nobody needs; one
    /// that grows would put a control back inside the resize strip.
    func testTheSolversNorthResizeEdgeIsTheOneTheInteractionCoordinatorEnforces() {
        // x is held at the middle so the 12×12 corner squares cannot answer instead — this is
        // a question about the north edge alone.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let middle = bounds.midX

        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: middle, y: PaneHeaderLayout.northResizeEdge),
                in: bounds
            ),
            .resize(.north),
            "the solver reserves \(PaneHeaderLayout.northResizeEdge) points the coordinator "
                + "does not actually claim"
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.hitRegion(
                at: CGPoint(x: middle, y: PaneHeaderLayout.northResizeEdge + 1),
                in: bounds
            ),
            .header,
            "the coordinator claims further north than the solver reserves, so an accessory "
                + "placed at `verticalInset` sits inside the resize strip"
        )
    }

    /// The `…` is the one identity a contributor and the host could both mint, and identity is
    /// what the renderer and the router each key on alone — `ForEach(id: \\.item.id)` in
    /// `PaneHeaderBar`, `action.itemID` in the card. Two placements answering one id is a
    /// duplicate SwiftUI identity plus a click resolved against the wrong owner.
    ///
    /// Nothing in the renderer can catch that, because by then both rows exist. The refusal
    /// happens at the header's door, and this is the proof that the door actually closes the
    /// hole: the colliding item is constructed, and the sweep that would have shown the two
    /// rows together finds one id per placement at every width.
    func testTheHostsOverflowControlCannotShareItsIdentityWithAContributedItem() {
        let collider = PaneHeader(
            leading: [button("b1"), button("b2"), button("b3")],
            trailing: [
                button("t1"),
                button("t2"),
                menu(PaneHeaderLayout.overflowItemID, ["mine"]),
            ]
        )
        XCTAssertFalse(
            (collider.leading + collider.trailing)
                .contains { $0.id == PaneHeaderLayout.overflowItemID },
            "the host's reserved id reached a header"
        )

        // Tracked per header, not pooled. Pooling lets a corpus header's fold satisfy the
        // guard while the COLLIDER — the one header built to provoke the clash — never folds
        // at any swept width, so its `…` never enters a `ForEach` and the duplicate-identity
        // half of this test sweeps only headers that could not have collided anyway.
        var sawHostOverflow: [Bool] = []
        for header in corpus() + [collider] {
            var folded = false
            for width in stride(from: CGFloat(120), through: 1600, by: 20) {
                let solution = solve(header, width: width)
                let ids = solution.placements.map(\.item.id)
                XCTAssertEqual(
                    Set(ids).count,
                    ids.count,
                    "two placements share one ForEach identity at width \(width): \(ids)"
                )
                // The `…` is itself a placement (`PaneHeaderLayout.swift:359` appends it to the
                // trailing run), so its identity is already inside the uniqueness check above —
                // a contributed item carrying the reserved id would surface there as two
                // placements answering one id. All this flag records is that the sweep reached
                // a width where the `…` existed at all.
                if solution.overflow != nil { folded = true }
            }
            sawHostOverflow.append(folded)
        }
        XCTAssertTrue(
            sawHostOverflow.last == true,
            "the collider never folded at any swept width, so its `…` was never in play and "
                + "this test proved nothing about the case it was written for"
        )
        XCTAssertTrue(
            sawHostOverflow.contains(true),
            "nothing ever folded, so the `…` was never in play"
        )
    }

    // MARK: - 18

    /// Disjointness is the whole hit-test contract: one point resolves to at most one control,
    /// the close button owns its reserve alone, and the drag band is bare.
    func testPlacementsNeverOverlapEachOtherTheCloseButtonOrTheDragBand() {
        sweep { _, width, showsDot, solution in
            for (index, placement) in solution.placements.enumerated() {
                XCTAssertLessThanOrEqual(
                    placement.rect.maxX,
                    width - PaneHeaderLayout.closeButtonReserve,
                    "\(placement.item.id) reached the close reserve at width \(width)"
                )
                XCTAssertFalse(
                    placement.rect.intersects(solution.dragBandRect),
                    "\(placement.item.id) ate the drag band at width \(width), dot \(showsDot)"
                )
                for other in solution.placements.dropFirst(index + 1) {
                    XCTAssertFalse(
                        placement.rect.intersects(other.rect),
                        "\(placement.item.id) overlaps \(other.item.id) at width \(width)"
                    )
                }
            }
        }
    }

    // MARK: - 19

    /// Reserve first, place second. While any item could still fold, the band keeps its full
    /// width; only once nothing foldable is left — everything remaining is a text field, which
    /// shrinks instead of folding — may it relax.
    func testTheDragBandNeverFallsBelowItsMinimumWhileAnythingIsStillFoldable() {
        sweep { _, width, showsDot, solution in
            let stillFoldable = solution.placements.contains { placement in
                guard placement.item.id != PaneHeaderLayout.overflowItemID else { return false }
                if case .textfield = placement.item { return false }
                return true
            }
            XCTAssertGreaterThanOrEqual(
                solution.dragBandRect.width,
                0,
                "the band inverted at width \(width), dot \(showsDot)"
            )
            guard stillFoldable else { return }
            XCTAssertGreaterThanOrEqual(
                solution.dragBandRect.width,
                PaneHeaderLayout.minimumDragBand,
                "the band gave way while something could still fold at width \(width)"
            )
        }
    }

    // MARK: - 20

    /// Drop order. The trailing run's rightmost controls are what the eye and the muscle memory
    /// find first, so it gives up its leftmost inward; the leading run reads as a sentence, so it
    /// gives up its tail backwards.
    func testTrailingFoldsItsLeftmostControlFirstAndLeadingFoldsItsLastItemFirst() {
        let header = PaneHeader(
            leading: [button("b1"), button("b2"), button("b3")],
            trailing: [button("t1"), button("t2"), button("t3")]
        )
        XCTAssertEqual(header.leading.count + header.trailing.count, 6)

        // The widest width at which an item has already been squeezed out: an item that folds
        // earlier survives fewer widths, so its number is larger.
        var widestAbsence: [String: CGFloat] = [:]
        for width in stride(from: CGFloat(400), through: 120, by: -2) {
            let placed = Set(solve(header, width: width).placements.map(\.item.id))
            for id in ["b1", "b2", "b3", "t1", "t2", "t3"] where !placed.contains(id) {
                widestAbsence[id] = max(widestAbsence[id] ?? 0, width)
            }
        }
        for id in ["b1", "b2", "b3", "t1", "t2", "t3"] {
            XCTAssertNotNil(widestAbsence[id], "\(id) never folded across the sweep")
        }

        XCTAssertGreaterThan(widestAbsence["b3"] ?? 0, widestAbsence["b2"] ?? 0)
        XCTAssertGreaterThan(widestAbsence["b2"] ?? 0, widestAbsence["b1"] ?? 0)
        XCTAssertGreaterThan(widestAbsence["t1"] ?? 0, widestAbsence["t2"] ?? 0)
        XCTAssertGreaterThan(widestAbsence["t2"] ?? 0, widestAbsence["t3"] ?? 0)
        // Leading gives way before trailing: the trailing run's own share is enforced first,
        // and once that holds the pane's controls outrank its status.
        XCTAssertGreaterThan(widestAbsence["b1"] ?? 0, widestAbsence["t1"] ?? 0)
    }

    // MARK: - 21

    /// Nothing folds silently. Everything that left a run is reachable in the `…` menu, reporting
    /// as the item that folded rather than as the menu, and only decoration — a dot, a spinner —
    /// is allowed to simply disappear.
    func testEverythingFoldedIsReachableInTheOverflowMenu() {
        let header = PaneHeader(
            leading: [dot("d"), label("l", "Working"), badge("b", "7")],
            trailing: [
                segmented("layout", ["tree", "flat"], selection: "tree"),
                toggle("hidden"),
                button("refresh"),
                spinner("s"),
            ]
        )
        XCTAssertEqual(header.leading.count + header.trailing.count, 7)
        let all = header.leading + header.trailing

        var sawFoldedPicker = false
        var sawFoldedToggle = false
        for width in stride(from: CGFloat(120), through: 1600, by: 20) {
            let solution = solve(header, width: width)
            let placed = Set(solution.placements.map(\.item.id))
            let overflowEntries = Set(entries(of: solution.overflow).map(\.value))

            for item in all where !placed.contains(item.id) {
                XCTAssertTrue(
                    solution.folded.contains { $0.item.id == item.id },
                    "\(item.id) vanished without folding at width \(width)"
                )
                let expected = item.overflowEntries()
                guard !expected.isEmpty else { continue }
                for entry in expected {
                    XCTAssertTrue(
                        overflowEntries.contains(entry.value),
                        "\(item.id)'s \(entry.value) is unreachable at width \(width)"
                    )
                }
            }

            if !placed.contains("layout") {
                sawFoldedPicker = true
                // The pick speaks the picker's value space, and is attributed back to it.
                XCTAssertEqual(
                    solution.overflowAction(forEntryValue: "flat"),
                    PaneHeaderAction(itemID: "layout", value: "flat")
                )
                // A folded picker still reads its own state.
                XCTAssertTrue(
                    entries(of: solution.overflow).contains { $0.value == "tree" && $0.isOn }
                )
            }
            if !placed.contains("hidden") {
                sawFoldedToggle = true
                XCTAssertEqual(
                    solution.overflowAction(forEntryValue: "hidden"),
                    PaneHeaderAction(itemID: "hidden", value: nil)
                )
            }
            // A folded status line is news, not a control: it reads, it does not route.
            if !placed.contains("l") {
                XCTAssertNil(solution.overflowAction(forEntryValue: "l"))
            }
        }
        XCTAssertTrue(sawFoldedPicker, "the sweep never narrowed enough to fold the picker")
        XCTAssertTrue(sawFoldedToggle, "the sweep never narrowed enough to fold the toggle")
    }

    // MARK: - 22

    /// A label gives up width, not its place. Controls fold around it, and the truncation token
    /// rides into the placement so the renderer — the layer that knows how to shorten a path —
    /// decides which end goes.
    func testALabelTruncatesInsteadOfFoldingAndKeepsItsSideBasedOnItsTruncationToken() {
        let header = PaneHeader(
            leading: [label("path", "/a/very/long/project/path", .head), label("name", "name")],
            trailing: [button("go")]
        )
        let metrics = FixedMetrics(widths: ["path": 300, "name": 120, "go": 30])

        let roomy = solve(header, width: 800, metrics: metrics)
        XCTAssertEqual(Set(roomy.placements.map(\.item.id)), ["path", "name", "go"])
        XCTAssertEqual(width(of: "path", in: roomy), 300)
        XCTAssertEqual(width(of: "name", in: roomy), 120)

        // 204 points: too narrow for the button, wide enough for both labels at their floor.
        let tight = solve(header, width: 204, metrics: metrics)
        XCTAssertEqual(
            Set(tight.placements.map(\.item.id)),
            ["path", "name", PaneHeaderLayout.overflowItemID]
        )
        XCTAssertTrue(tight.folded.contains { $0.item.id == "go" })
        XCTAssertLessThan(width(of: "path", in: tight) ?? .infinity, 300)
        XCTAssertLessThan(width(of: "name", in: tight) ?? .infinity, 120)
        XCTAssertGreaterThanOrEqual(width(of: "path", in: tight) ?? 0, 1)
        XCTAssertGreaterThanOrEqual(width(of: "name", in: tight) ?? 0, 1)

        // Each label carries its own side into the renderer; the solver rewrites no text.
        XCTAssertEqual(truncation(of: "path", in: tight), .head)
        XCTAssertEqual(truncation(of: "name", in: tight), .tail)
    }

    // MARK: - 23

    /// The one item that may absorb slack takes the gap the title would have had, and the title
    /// steps aside: an address line and a pane name in one 34-point strip is the two-header
    /// problem this vocabulary exists to end.
    func testAFlexibleTextfieldTakesTheGapAndSuppressesTheTitle() {
        let metrics = FixedMetrics(widths: ["go": 200])
        let flexible = PaneHeader(
            leading: [button("back"), button("forward"), button("reload")],
            trailing: [textfield("go", flex: true)]
        )
        let solution = solve(flexible, width: 1000, metrics: metrics)
        XCTAssertEqual(solution.titleRect, .zero)
        XCTAssertGreaterThan(width(of: "go", in: solution) ?? 0, 200)
        // The reserved band survives the field: it takes the gap MINUS the drag reservation.
        XCTAssertEqual(solution.dragBandRect.width, PaneHeaderLayout.minimumDragBand)
        XCTAssertEqual(
            solution.placements.last?.rect.maxX,
            1000 - PaneHeaderLayout.closeButtonReserve
        )

        // The same field without `flex` asks for its natural width and leaves the name alone.
        let fixed = PaneHeader(
            leading: [button("back"), button("forward"), button("reload")],
            trailing: [textfield("go", flex: false)]
        )
        let unclaimed = solve(fixed, width: 1000, metrics: metrics)
        XCTAssertEqual(width(of: "go", in: unclaimed), 200)
        XCTAssertGreaterThan(unclaimed.titleRect.width, PaneHeaderLayout.minimumTitleWidth)
        XCTAssertEqual(unclaimed.titleRect.height, titleHeight)
    }

    // MARK: - 24

    /// The set of holes punched in the pane's drag surface is exactly the set of items that take
    /// the mouse. Status stays draggable, which is why a header of pure state costs the pane
    /// nothing.
    func testInteractiveRectsExcludeDotsLabelsBadgesImagesAndSpinners() {
        let header = PaneHeader(
            leading: [dot("d"), label("l", "Working"), badge("b", "7"), image("i"), spinner("s")],
            trailing: [button("btn"), toggle("tog"), segmented("seg", ["a", "b2"], selection: "a")]
        )
        let solution = solve(header, width: 1600)
        XCTAssertEqual(solution.placements.count, 8, "the sweep width was too narrow to place all")

        let interactive = solution.interactiveRects
        let interactiveIDs = Set(
            solution.placements.filter { interactive.contains($0.rect) }.map(\.item.id)
        )
        XCTAssertEqual(interactiveIDs, ["btn", "tog", "seg"])
        XCTAssertEqual(solution.interactiveRects.count, 3)
    }

    // MARK: - Reading a solution

    private func width(of id: String, in solution: PaneHeaderLayout.Solution) -> CGFloat? {
        solution.placements.first { $0.item.id == id }?.rect.width
    }

    private func truncation(
        of id: String,
        in solution: PaneHeaderLayout.Solution
    ) -> PaneHeaderTruncation? {
        guard let placement = solution.placements.first(where: { $0.item.id == id }),
              case let .label(_, _, _, _, truncation, _) = placement.item
        else { return nil }
        return truncation
    }

    private func entries(of item: PaneHeaderItem?) -> [PaneHeaderMenuEntry] {
        guard case let .menu(_, _, entries, _, _, _) = item else { return [] }
        return entries
    }
}
