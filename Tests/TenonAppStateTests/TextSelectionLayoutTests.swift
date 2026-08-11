import AppKit
import SwiftUI
import XCTest
@testable import TenonApp

/// T-127 / A1: does `.textSelection(.enabled)` leave a layout pending after a settled update?
///
/// On macOS, SwiftUI backs `.textSelection(.enabled)` with `SelectionOverlay`, an
/// `NSViewRepresentable` over an `NSTextField`. In the 2026-08-11 sample its `updateNSView`
/// reaches `NSControl.setFont:` → `NSTextFieldCell._invalidateEffectiveFont` →
/// `_effectiveFontDidChangeTo:` → `NSTextField.invalidateIntrinsicContentSize`, with a second
/// route through `setLineBreakMode:` → `_setTextAttributeParaStyleNeedsRecalc`.
///
/// Invalidating an intrinsic size is a **request for another layout, issued from inside an
/// update**. If that is what happens, a pane full of selectable prose can re-arm the pass that
/// is drawing it, and the count scales with the amount of text rather than with the number of
/// rows — which is how 22 timeline rows could occupy one layout pass for over a minute.
///
/// Agent Lens carries nine `.textSelection(.enabled)` sites, two of them per-list-line and
/// per-table-cell. Removing them costs a real product affordance, so this measurement runs
/// first and decides whether any of them is touched.
@MainActor
final class TextSelectionLayoutTests: XCTestCase {
    /// The fixture check this whole file rests on: `.textSelection(.enabled)` must actually
    /// mount its AppKit backing here, or every comparison below is between two identical trees.
    func testSelectableProseMountsAnAppKitTextBacking() {
        let plain = settledHost(for: prose(selectable: false))
        let selectable = settledHost(for: prose(selectable: true))

        XCTAssertGreaterThan(
            textBackingCount(in: selectable),
            textBackingCount(in: plain),
            """
            Selectable prose mounted \(textBackingCount(in: selectable)) NSTextField(s) against \
            \(textBackingCount(in: plain)) for plain prose. With no difference in the view tree \
            there is no SelectionOverlay here, and nothing in this file measures the production \
            mechanism.
            """
        )
    }

    /// The decisive comparison: identical prose, with and without selection enabled.
    func testSelectableProseLeavesNoLayoutPendingAfterTheUpdateSettles() {
        let plain = settledHost(for: prose(selectable: false))
        let selectable = settledHost(for: prose(selectable: true))

        XCTAssertFalse(
            plain.needsLayout,
            "baseline: plain prose already leaves a layout pending, so this comparison cannot "
                + "attribute one to selection"
        )

        XCTAssertEqual(
            selectable.needsLayout,
            plain.needsLayout,
            """
            After a settled update, selectable prose reports needsLayout=\
            \(selectable.needsLayout) against \(plain.needsLayout) for the same text without \
            selection. A layout still pending once everything has settled is a mutation \
            performed inside the update — the shape that re-arms a pass from within itself.
            """
        )
    }

    /// The same question asked of many rows rather than one, because the claim is that the cost
    /// scales with the quantity of selectable text.
    func testManySelectableRowsLeaveNoMoreLayoutPendingThanOne() {
        let single = settledHost(for: prose(selectable: true))
        let many = settledHost(
            for: VStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< 40, id: \.self) { index in
                    Text("Evidence line \(index): the reading returns to the transcript it came from.")
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }
            }
        )

        XCTAssertEqual(
            many.needsLayout,
            single.needsLayout,
            """
            Forty selectable rows report needsLayout=\(many.needsLayout) against \
            \(single.needsLayout) for one. If quantity changes the answer, the invalidation is \
            per element and scales with the transcript.
            """
        )
    }

    // MARK: - Fixture

    private func prose(selectable: Bool) -> some View {
        Group {
            if selectable {
                Text(Self.sentence).textSelection(.enabled)
            } else {
                Text(Self.sentence)
            }
        }
        .padding(12)
    }

    private static let sentence =
        "Every material claim carries source, freshness, and a direct return path to the "
            + "transcript, diff, command result, or test receipt it represents."

    /// Every `NSTextField` under the host — SwiftUI's `SelectionOverlay` is one.
    private func textBackingCount(in view: NSView) -> Int {
        var found = view is NSTextField ? 1 : 0
        for subview in view.subviews { found += textBackingCount(in: subview) }
        return found
    }

    /// Mount, lay out, and let SwiftUI's update drain before asking whether anything is still
    /// pending. Without the drain this asks about a half-finished transaction and answers
    /// nothing.
    private func settledHost(for view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return host
    }
}
