import AppKit
import SwiftUI
import XCTest
@testable import TenonApp

/// T-127: what one alignment question costs when the answer is a lazy list.
///
/// `Layout.explicitAlignment` has a default implementation that answers by running
/// `placeSubviews` and reading the resulting child geometry. `AgentSessionLayout.placeSubviews`
/// places the account content — a `ScrollView` around a `LazyVStack` — so if a parent asks for
/// an alignment guide, producing that one number can cost a full `LazyStack.measureEstimates`
/// over every row.
///
/// A `sample` of the app hung on 2026-08-11 at 12:38 put 544 of 3400 main-thread samples in
/// exactly that path: `_FlexFrameLayout.placement` → `ViewDimensions.subscript` →
/// `explicitAlignment` → `defaultAlignment` → `childGeometries` →
/// `AgentSessionLayout.placeSubviews` → `ScrollView.sizeThatFits` → `measureEstimates`.
///
/// These tests measure the cost rather than argue about it, because a first attempt at this
/// fixture — two `Color.clear` slots — reported the same count with and without the override
/// and would have justified a change that does nothing.
@MainActor
final class AgentSessionLayoutAlignmentTests: XCTestCase {
    /// How many times every row of a lazy list is asked for its size while the pane is laid
    /// out once. This is the number the hang is made of.
    func testMeasuringTheSessionPaneDoesNotRemeasureEveryRow() {
        let counter = MeasureCounter()

        layOut(sessionPane(rowCounter: counter))

        XCTAssertLessThanOrEqual(
            counter.rowMeasurements,
            rowCount * 2,
            """
            One layout pass measured \(rowCount) rows \(counter.rowMeasurements) times — \
            \(String(format: "%.1f", Double(counter.rowMeasurements) / Double(rowCount))) \
            per row. Each extra sweep is one alignment question answered by placing the \
            scroll view and measuring its whole lazy list.
            """
        )
    }

    /// What an offscreen fixture can and cannot say about the alignment override.
    ///
    /// T-127 filed this as a refuted hypothesis. The refutation was weaker than it read: its
    /// control returned `nil` from both overrides, and `nil` *is* the default, so it compared
    /// the expensive path against itself. With a control that answers in numbers, the override
    /// is verifiably reached — this fixture asks 8 alignment questions and all 8 are answered
    /// without touching `defaultAlignment` — and the row counts still do not move.
    ///
    /// That is a fact about the fixture, not about the app. Offscreen, the default path's
    /// `placeSubviews` hits the size cache, so skipping it saves nothing. In the hung process
    /// T-127 measured 534 of 534 cache lookups missing, and the 15:5x sample puts 1409 of 7457
    /// main-thread samples inside the path this override removes.
    ///
    /// So this test is a tripwire, not a verdict: it records that the offscreen numbers are
    /// equal. If it ever turns red, an offscreen host has started discriminating and the method
    /// note in `docs/design-pane-hosting.md` needs revisiting.
    func testAnsweringAlignmentOffscreenChangesNeitherCount() {
        let byDefault = MeasureCounter()
        let answering = MeasureCounter()

        layOut(sessionPane(rowCounter: byDefault))
        layOut(controlPane(rowCounter: answering))

        XCTAssertGreaterThan(
            answering.alignmentQuestions,
            0,
            """
            The fixture asked for an alignment guide \(answering.alignmentQuestions) time(s), \
            so it exercises none of the path under test.
            """
        )
        XCTAssertEqual(
            answering.rowMeasurements,
            byDefault.rowMeasurements,
            """
            Answering measured the rows \(answering.rowMeasurements) time(s) against \
            \(byDefault.rowMeasurements) for the default — an offscreen difference where this \
            repository has always measured none.
            """
        )
        XCTAssertEqual(
            answering.rowPlacements,
            byDefault.rowPlacements,
            """
            Answering placed the rows \(answering.rowPlacements) time(s) against \
            \(byDefault.rowPlacements) for the default. A difference here means an offscreen \
            host now reproduces what only a live sample could show.
            """
        )
    }

    /// T-129: the question T-127's counter could not ask — how many times is the list *placed*?
    ///
    /// A row's size is cached, so `rowMeasurements` can sit still while the pane walks the whole
    /// `ForEach` again. A placement cannot be cached away: it runs `applyNodes` down the list,
    /// which is where the hung sample's second hot branch sits. One layout pass should place a
    /// visible row once.
    func testOneLayoutPassPlacesEachRowOnce() {
        let counter = MeasureCounter()

        layOut(sessionPane(rowCounter: counter))

        XCTAssertLessThanOrEqual(
            counter.rowPlacements,
            rowCount,
            """
            One layout pass placed \(rowCount) rows \(counter.rowPlacements) times — \
            \(String(format: "%.1f", Double(counter.rowPlacements) / Double(rowCount))) per \
            row. Each extra sweep is one alignment question answered by placing the scroll \
            view and walking its whole lazy list.
            """
        )
    }

    /// Every standard guide is answered from the box, so the default is never reached for one.
    ///
    /// The unit that is actually provable without a window. `nil` sends the caller back through
    /// `defaultAlignment` → `childGeometries` → `placeSubviews`, so a guide left unanswered is a
    /// guide that still costs a placement of the whole transcript. The six box guides are facts
    /// about `bounds`; a baseline is a fact about the content and is left to the default on
    /// purpose, because guessing it would misalign the pane to buy speed.
    func testEveryBoxGuideIsAnsweredFromTheBoundsAlone() {
        XCTAssertEqual(AgentSessionLayout.guidePosition(of: .leading, across: 500), 0)
        XCTAssertEqual(AgentSessionLayout.guidePosition(of: HorizontalAlignment.center, across: 500), 250)
        XCTAssertEqual(AgentSessionLayout.guidePosition(of: .trailing, across: 500), 500)
        XCTAssertEqual(AgentSessionLayout.guidePosition(of: .top, across: 400), 0)
        XCTAssertEqual(AgentSessionLayout.guidePosition(of: VerticalAlignment.center, across: 400), 200)
        XCTAssertEqual(AgentSessionLayout.guidePosition(of: .bottom, across: 400), 400)

        XCTAssertNil(
            AgentSessionLayout.guidePosition(of: .firstTextBaseline, across: 400),
            "a baseline is a fact about the content — answering it from the box would misalign"
        )
        XCTAssertNil(
            AgentSessionLayout.guidePosition(of: .lastTextBaseline, across: 400),
            "a baseline is a fact about the content — answering it from the box would misalign"
        )
    }

    /// Does the cost of one layout pass stay proportional to the rows on screen?
    ///
    /// A lazy list is supposed to measure what is visible. If the count grows with the list
    /// instead of with the viewport, the pane pays for history nobody is looking at — which is
    /// the shape a 22-item pane taking 60 s would need.
    func testLayoutCostFollowsTheViewportRatherThanTheList() {
        var measured: [(rows: Int, measurements: Int)] = []

        for rows in [20, 40, 80, 160] {
            let counter = MeasureCounter()
            layOut(uniformPane(rows: rows, counter: counter))
            measured.append((rows, counter.rowMeasurements))
        }

        let smallest = measured.first!.measurements
        let largest = measured.last!.measurements
        XCTAssertLessThanOrEqual(
            largest,
            smallest * 2,
            """
            Eight times the rows cost \(largest) measurements against \(smallest) — \
            \(measured.map { "\($0.rows):\($0.measurements)" }.joined(separator: " ")). \
            The pane is measuring the list rather than the viewport.
            """
        )
    }

    /// The reading column as production actually writes it: two paddings and two frames
    /// carrying non-default alignments, wrapped around the lazy list.
    ///
    /// This is the shape the hung sample names — `_FlexFrameLayout` over `_FlexFrameLayout`
    /// over `_PaddingLayout` over `_PaddingLayout` over `LazyLayoutComputer` — and an
    /// alignment is a question about where the child's content sits, which a lazy list can
    /// only answer by measuring.
    func testTheReadingColumnCostsNoMoreThanThePlainList() {
        let plain = MeasureCounter()
        let column = MeasureCounter()

        layOut(uniformPane(rows: 80, counter: plain))
        layOut(columnPane(rows: 80, counter: column))

        XCTAssertLessThanOrEqual(
            column.rowMeasurements,
            plain.rowMeasurements * 3,
            """
            The reading column measured the rows \(column.rowMeasurements) time(s) against \
            \(plain.rowMeasurements) for the same list with no column modifiers. The wrapping \
            frames and their alignments are charging for rows nobody is looking at.
            """
        )
    }

    /// The same question where the rows do not all agree on their height, which is what a
    /// transcript actually looks like: every row is wrapped text of a different length, so no
    /// estimate serves for the next one.
    func testRaggedRowsDoNotCostMoreThanUniformOnes() {
        let uniform = MeasureCounter()
        let ragged = MeasureCounter()

        layOut(uniformPane(rows: 80, counter: uniform))
        layOut(raggedPane(rows: 80, counter: ragged))

        XCTAssertLessThanOrEqual(
            ragged.rowMeasurements,
            uniform.rowMeasurements * 3,
            """
            Rows of differing heights cost \(ragged.rowMeasurements) measurements against \
            \(uniform.rowMeasurements) for uniform rows — the lazy list is re-measuring to \
            find a height it cannot estimate.
            """
        )
    }

    /// A footer that drifts by a fraction of a point must not cost a re-measurement of the list.
    ///
    /// `placeSubviews` derives `contentHeight = bounds.height - footerHeight` and places the
    /// scroll view at it, so that derived value is the `ViewSizeCache` key. The key is a
    /// `CGFloat`. In the hung sample **534 of 534 lookups were inside `makeValue`** — every
    /// single one a miss — and a miss runs the full `LazyStack.measureEstimates` descent, which
    /// writes lazy cache positions while answering a size question.
    ///
    /// The footer is not a static bar: it holds a live `TextField` whose backing `NSTextField`
    /// has its intrinsic size invalidated in the same pass, so sub-point drift is realistic.
    func testAJitteringFooterDoesNotRemeasureEveryRow() {
        let stable = MeasureCounter()
        let jittering = MeasureCounter()

        layOutTwice(jitterPane(rows: 80, counter: stable, jitters: false))
        layOutTwice(jitterPane(rows: 80, counter: jittering, jitters: true))

        // The fixture has to actually jitter, or this test is vacuously green: the drift is
        // applied on every second footer measurement, so fewer than two measurements means no
        // height ever changed and nothing was tested.
        XCTAssertGreaterThan(
            jittering.footerMeasurements,
            1,
            "the footer was measured \(jittering.footerMeasurements) time(s), so it never drifted"
        )

        XCTAssertEqual(
            jittering.rowMeasurements,
            stable.rowMeasurements,
            """
            A footer drifting by 0.4 pt cost \(jittering.rowMeasurements) row measurements \
            against \(stable.rowMeasurements) for a steady one. The derived content height is \
            the scroll view's size-cache key, so drift misses the cache and re-measures the \
            whole lazy list.
            """
        )
    }

    /// Repeated placements at identical bounds must not re-measure the scroll view.
    ///
    /// `AgentSessionLayout.placeSubviews` places the account with `place(at:anchor:proposal:)`,
    /// and resolving an anchor calls `LayoutProxy.dimensions(in:)` — even for `.topLeading`,
    /// whose unit point is (0,0). So the lazy content *is* asked for a size on every placement,
    /// which falsifies the conclusion in the comment at `AgentLensView.swift:479-482`. What
    /// makes it survivable is a cache hit; what would make it fatal is a miss on every pass.
    func testRepeatedPlacementsAtTheSameBoundsMeasureTheContentOnce() {
        let once = MeasureCounter()
        let fourTimes = MeasureCounter()

        layOut(uniformPane(rows: 80, counter: once), passes: 1)
        layOut(uniformPane(rows: 80, counter: fourTimes), passes: 4)

        XCTAssertEqual(
            fourTimes.rowMeasurements,
            once.rowMeasurements,
            """
            Four placements at identical bounds cost \(fourTimes.rowMeasurements) row \
            measurements against \(once.rowMeasurements) for one. Each placement is re-measuring \
            the lazy content instead of reading a cached size.
            """
        )
    }

    /// T-143: a Chat row must draw inside the box it hands its parent.
    ///
    /// A `LazyVStack` puts the next row at the bottom edge the previous row reported. So a row
    /// whose content is drawn below that edge is not a cosmetic misalignment — it is written over
    /// its neighbour, which is what the operator photographed on 2026-08-13: whole messages
    /// stacked on top of each other in a pane whose rows all still claimed the right heights.
    ///
    /// The shape that does it is one line of `AgentSpineChrome`. Its rail holds no text and is
    /// `maxHeight: .infinity`; a view with no text resolves `firstTextBaseline` to its bottom
    /// edge, and a greedy view's bottom edge is the row height the `HStack` has not finished
    /// computing. The guide then depends on the alignment that reads it, and SwiftUI settles that
    /// by sizing against the proposal and placing against the final height.
    ///
    /// Measured rather than argued: on the shipped alignment the content lands 33 pt below the
    /// row's own bounds, and the control — the same fixture reading `.top` — puts it 5 pt inside
    /// them. A fixture that could not tell those apart would make this test vacuously green.
    func testAChatRowDrawsInsideTheBoundsItReports() {
        for width in [320.0, 860.0] {
            let geometry = RowGeometry()

            layOut(spineRow(recordingInto: geometry), size: CGSize(width: width, height: 600))

            XCTAssertGreaterThan(
                geometry.content.height,
                0,
                "the fixture never placed any content at \(width) pt wide, so it tested nothing"
            )
            XCTAssertLessThanOrEqual(
                geometry.content.maxY,
                geometry.row.maxY,
                """
                At \(width) pt wide the row reported a box ending at \(geometry.row.maxY) and drew \
                its content down to \(geometry.content.maxY) — \
                \(String(format: "%.1f", geometry.content.maxY - geometry.row.maxY)) pt of a \
                message written over whatever the lazy list places next.
                """
            )
        }
    }

    /// The tick stays on the row's first line of text, which is the thing the rail is *for*.
    ///
    /// Without this, the row above passes trivially by pushing the rail down instead of the
    /// content — the same defect wearing the other sign, and one a reader would notice just as
    /// fast. One 18 pt tick against a 9.5 pt label is close enough that a whole line of drift is
    /// the only failure worth naming.
    func testTheTickSitsOnTheRowsFirstLineOfText() {
        let geometry = RowGeometry()

        layOut(spineRow(recordingInto: geometry), size: CGSize(width: 860, height: 600))

        XCTAssertEqual(
            geometry.content.minY,
            geometry.row.minY,
            accuracy: 6,
            """
            The row's content starts \(geometry.content.minY - geometry.row.minY) pt below the row \
            itself, so the tick no longer marks the line it points at.
            """
        )
    }

    // MARK: - Fixture

    private let rowCount = 60
    private let layoutSize = CGSize(width: 500, height: 400)

    /// The production shape: `AgentSessionLayout` holding lazy content and a footer, under the
    /// `.background` and infinite frame that `AgentLensView` wraps it in.
    private func sessionPane(rowCounter: MeasureCounter) -> some View {
        AgentSessionLayout {
            lazyContent(counter: rowCounter)
            footer
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The same shape with one difference: it says how it aligns.
    private func controlPane(rowCounter: MeasureCounter) -> some View {
        AlignmentAnsweringLayout(questions: rowCounter) {
            lazyContent(counter: rowCounter)
            footer
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lazyContent(counter: MeasureCounter) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< rowCount, id: \.self) { _ in
                    CountingRow(counter: counter) { Color.clear }
                }
            }
        }
    }

    /// Rows that all agree on their height — the cheapest thing a lazy list can hold.
    private func uniformPane(rows: Int, counter: MeasureCounter) -> some View {
        AgentSessionLayout {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { _ in
                        CountingRow(counter: counter) { Color.clear }
                    }
                }
            }
            footer
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The production reading column, modifier for modifier: `AgentLensView.swift:525-528`
    /// wraps the lazy list in two paddings and two frames, and both frames carry a
    /// non-default alignment. An alignment is a question about the child's geometry, so each
    /// one is a reason to ask the lazy list where its content sits.
    private func columnPane(rows: Int, counter: MeasureCounter) -> some View {
        AgentSessionLayout {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { index in
                        CountingRow(counter: counter, height: 18 + CGFloat((index * 37) % 11) * 9) {
                            Color.clear
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            footer
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Rows of differing heights, which is what a transcript is: no measured row predicts the
    /// next, so an estimate bought from one row buys nothing for its neighbour.
    private func raggedPane(rows: Int, counter: MeasureCounter) -> some View {
        AgentSessionLayout {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { index in
                        CountingRow(counter: counter, height: 18 + CGFloat((index * 37) % 11) * 9) {
                            Color.clear
                        }
                    }
                }
            }
            footer
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The real footer holds the composer, and a SwiftUI `TextField` on macOS is an
    /// `NSTextField`. Measuring one runs `_invalidateEffectiveFont`, which is a *mutation*
    /// performed while answering a *measurement* — the shape that can re-arm the pass that
    /// asked. A `Color.clear` footer cannot reproduce any of that.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            TextField("Message", text: .constant(""))
                .textFieldStyle(.plain)
                .padding(8)
        }
    }

    /// The pane with a footer whose measured height either repeats or drifts by 0.4 pt.
    private func jitterPane(rows: Int, counter: MeasureCounter, jitters: Bool) -> some View {
        AgentSessionLayout {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { _ in
                        CountingRow(counter: counter) { Color.clear }
                    }
                }
            }
            DriftingFooter(counter: counter, jitters: jitters) { Color.clear }
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One shipping Chat row, with a recorder around the row and another around its content, so
    /// the two boxes are read off the same layout pass in the same coordinate space.
    ///
    /// The content is a header line over wrapped prose because that is what a message is, and
    /// because the defect needs the two to disagree about where the first baseline sits. A
    /// single-line fixture hides it.
    private func spineRow(recordingInto geometry: RowGeometry) -> some View {
        RecordingLayout(geometry: geometry, records: .row) {
            AgentSpineChrome(
                evidence: .terminalInference("test fixture"),
                tint: .cyan,
                active: false,
                inspect: {}
            ) {
                RecordingLayout(geometry: geometry, records: .content) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ASSISTANT").font(.system(size: 9.5, weight: .semibold))
                        Text(String(repeating: "Body prose that wraps across the pane. ", count: 4))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func layOut(_ view: some View) {
        layOut(view, size: layoutSize)
    }

    private func layOut(_ view: some View, size: CGSize) {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
    }

    /// Repeated settled layout passes over one host, which is what a live pane does every time
    /// a snapshot arrives.
    private func layOut(_ view: some View, passes: Int) {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: layoutSize)
        for _ in 0 ..< passes {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
    }

    private func layOutTwice(_ view: some View) {
        layOut(view, passes: 2)
    }
}

/// Where a row was placed, and where the content inside it was placed.
@MainActor
private final class RowGeometry {
    var row = CGRect.zero
    var content = CGRect.zero
}

/// Reads a box off a real layout pass, without changing the box it reads.
///
/// A `GeometryReader` is greedy and would rewrite the very geometry under test; a preference
/// needs a window to deliver. A single-child `Layout` reports its child's own size upward and
/// records the bounds it is handed, so the fixture measures the shipping composition rather than
/// a shape bent to be measurable.
private struct RecordingLayout: Layout {
    enum Slot { case row, content }

    let geometry: RowGeometry
    let records: Slot

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        MainActor.assumeIsolated {
            switch records {
            case .row: geometry.row = bounds
            case .content: geometry.content = bounds
            }
        }
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

/// Counts how often the lazy rows are asked for a size.
@MainActor
private final class MeasureCounter {
    var rowMeasurements = 0
    var rowPlacements = 0
    var alignmentQuestions = 0
    var footerMeasurements = 0
}

/// A footer whose measured height either repeats exactly or drifts by a fraction of a point.
///
/// The drift is deliberately smaller than a pixel: the claim under test is that the derived
/// content height is a cache key, and a cache key does not care how small the difference is.
private struct DriftingFooter: Layout {
    let counter: MeasureCounter
    let jitters: Bool

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let drift = MainActor.assumeIsolated { () -> CGFloat in
            counter.footerMeasurements += 1
            guard jitters else { return 0 }
            return counter.footerMeasurements.isMultiple(of: 2) ? 0.4 : 0
        }
        return CGSize(width: proposal.width ?? 0, height: 40 + drift)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// One row that reports every time it is measured, and every time it is placed.
///
/// Both verbs, because they answer different questions and T-127 only asked the first one. A
/// size is cached, so measurements can stay flat while the list is walked again and again; a
/// placement runs `applyNodes` down the whole `ForEach`, which is where the hung sample's
/// second hot branch sits.
private struct CountingRow: Layout {
    let counter: MeasureCounter
    var height: CGFloat = 24

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        MainActor.assumeIsolated { counter.rowMeasurements += 1 }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        MainActor.assumeIsolated { counter.rowPlacements += 1 }
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// `AgentSessionLayout`'s placement rule, plus the alignment answer it leaves to the default.
/// Kept beside the production type rather than inside it so the comparison is a measurement
/// of one difference, not of two shapes.
private struct AlignmentAnsweringLayout: Layout {
    /// Counts the alignment questions this fixture actually receives.
    ///
    /// Without it the comparison is unfalsifiable: two layouts that are never asked for a guide
    /// place their rows the same number of times whatever their override returns, and the test
    /// reads as "the override does nothing" when the truth is "the fixture asks nothing".
    let questions: MeasureCounter

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let footer = subviews.count > 1
            ? subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            : .zero
        return CGSize(
            width: proposal.width ?? footer.width,
            height: proposal.height ?? footer.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        guard subviews.count > 1 else {
            content.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
            return
        }

        let footer = subviews[1]
        let measured = footer.sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        ).height
        let footerHeight = min(max(measured.isFinite ? measured : 0, 0), bounds.height)

        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: max(bounds.height - footerHeight, 0)
            )
        )
        footer.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - footerHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: footerHeight)
        )
    }

    /// Answers with a number rather than with `nil`.
    ///
    /// This is the difference T-127's control did not carry. `nil` is the protocol's way of
    /// saying "I have no explicit guide, use the default", so a `nil` override and no override
    /// at all take the same route — through `defaultAlignment` → `childGeometries` →
    /// `placeSubviews`. Only a value short-circuits it.
    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        MainActor.assumeIsolated { questions.alignmentQuestions += 1 }
        return AgentSessionLayout.guidePosition(of: guide, across: bounds.width)
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        MainActor.assumeIsolated { questions.alignmentQuestions += 1 }
        return AgentSessionLayout.guidePosition(of: guide, across: bounds.height)
    }
}
