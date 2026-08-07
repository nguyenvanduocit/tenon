import AppKit
import SwiftUI
import XCTest
@testable import TenonApp

/// T-091: a pane is sized by the canvas, never by what it contains.
///
/// The app hung for hours at 100% CPU inside a single SwiftUI update: `dispatchActions`
/// was ~100% `LazyLayoutViewCache.signalPrefetch()`, which re-armed the update it was
/// running under, so the runloop never completed a turn and never drained its autorelease
/// pool — 11 GB resident, 10.4 GB swapped, one leaked `NSTimer` per turn.
///
/// This test does not claim to prevent that loop; the reproduction is still open. It pins
/// the one thing the investigation did establish with a measurement: a plainly constructed
/// `NSHostingView` reports `sizingOptions` of `[.minSize, .intrinsicContentSize, .maxSize]`,
/// so every pane was inviting AppKit to ask how tall its content wanted to be — a question
/// `SpatialSlotCardView.layout()` has already answered by setting the frame, and one that
/// costs a full measurement of scrolling content to answer at all.
@MainActor
final class PaneHostingSizingTests: XCTestCase {
    /// The rule: no pane host derives size from its content.
    func testPaneContentHostPublishesNoSizeConstraints() {
        let host = PaneContentHost.make(AnyView(Text("pane")))

        XCTAssertTrue(
            host.sizingOptions.isEmpty,
            """
            A pane host must publish no sizing options. It carried \
            \(host.sizingOptions.rawValue), which lets AppKit derive the pane's size from \
            its content — measuring a scrolling pane in full to answer a question \
            SpatialSlotCardView.layout() already answers by setting the frame.
            """
        )
    }

    /// The measurement the rule is answering, kept as an executable statement rather than
    /// a comment: this is what a hosting view does when nobody tells it otherwise. If a
    /// future macOS changes the default to nothing, this fails and the rule above becomes
    /// redundant — which is worth knowing rather than silently carrying.
    func testPlainHostingViewWouldDeriveSizeFromContent() {
        let plain = NSHostingView(rootView: AnyView(Text("pane")))

        XCTAssertFalse(
            plain.sizingOptions.isEmpty,
            "A plainly constructed NSHostingView no longer derives size from content; "
                + "PaneContentHost.make's sizing declaration may now be redundant."
        )
    }

    /// The host is still the thing the card frames and draws into, so the properties
    /// `configure` relied on before the factory existed have to survive it.
    func testPaneContentHostIsLayerBackedForTheCardToTint() {
        let host = PaneContentHost.make(AnyView(Text("pane")))

        XCTAssertTrue(host.wantsLayer, "The card sets a background colour on the host's layer.")
    }
}
