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
/// It pins what that investigation established with a measurement: a plainly constructed
/// `NSHostingView` reports `sizingOptions` of `[.minSize, .intrinsicContentSize, .maxSize]`,
/// so every pane was inviting AppKit to ask how tall its content wanted to be — a question
/// `SpatialSlotCardView.layout()` has already answered by setting the frame, and one that
/// costs a full measurement of scrolling content to answer at all.
///
/// T-121 reproduced the loop and named the half a pane host cannot reach. Silencing each
/// pane's own hosting view left the stage above them still asking: the `ZStack` at
/// `WorkspaceStageView.swift:36` carries no infinite frame, so it asks its child for an ideal
/// size, and a representable that declares no `sizeThatFits` sends that question to AppKit —
/// `AppKitPlatformViewHost.fittingSize` → `systemLayoutSizeFittingSize:` → an Auto Layout
/// sweep over every card in the tree. In a `sample` of the hung process that path held
/// **2395 of 3461 main-thread samples**, and the sweep dirtied the `NSTextField`s it walked
/// (`_invalidateEffectiveFont`, `invalidateIntrinsicContentSize`) while it measured them.
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

    // MARK: - T-121: the stage above the panes

    /// The mechanism, measured rather than asserted about: a representable that answers no
    /// size makes the layout ask AppKit instead, and AppKit answers by walking the subtree.
    ///
    /// This is the control for the rule below. If a future SwiftUI stops routing the question
    /// through Auto Layout, this fails and `sizeThatFits` on the canvas becomes redundant —
    /// worth learning from a red test rather than carrying as folklore.
    func testARepresentableThatAnswersNoSizeIsMeasuredThroughAppKit() {
        let probe = SizeQueryProbeView()

        layOut(ZStack { SilentRepresentable(probe: probe) })

        XCTAssertGreaterThan(
            probe.intrinsicSizeQueries,
            0,
            """
            A representable declaring no sizeThatFits was expected to send the stack's \
            size question to AppKit, which answers it by asking the subtree. Nothing asked, \
            so this test can no longer tell the two shapes apart.
            """
        )
    }

    /// The rule: answering the proposal keeps the question out of AppKit entirely.
    func testDeclaringSizeThatFitsKeepsTheMeasurementOutOfAutoLayout() {
        let probe = SizeQueryProbeView()

        layOut(ZStack { SpeakingRepresentable(probe: probe) })

        XCTAssertEqual(
            probe.intrinsicSizeQueries,
            0,
            """
            A representable that answers the proposal was still measured through Auto Layout \
            \(probe.intrinsicSizeQueries) time(s) — the sweep this rule exists to prevent.
            """
        )
    }

    /// Proposing nothing must not mean occupying nothing.
    ///
    /// `ContentView.swift:99` wraps the stage in `.frame(maxWidth: .infinity, maxHeight:
    /// .infinity)` above a 1 pt rule and the status bar, and that frame is the very thing at
    /// the top of the hung stack: it asks its child for an ideal size. A canvas answering
    /// zero to that question is only correct if the infinite frame still hands it every
    /// point the stack has left — which is a measurement, not an inference, and the one that
    /// separates this fix from a canvas that silently disappears.
    func testAnsweringZeroIdealStillFillsTheStage() {
        let probe = SizeQueryProbeView()
        let statusBarHeight: CGFloat = 22

        layOut(
            VStack(spacing: 0) {
                ZStack { SpeakingRepresentable(probe: probe) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().frame(height: 1)
                Color.clear.frame(height: statusBarHeight)
            }
        )

        XCTAssertEqual(
            probe.frame.height,
            layoutSize.height - 1 - statusBarHeight,
            accuracy: 0.5,
            "the canvas must take every point the stack has left, not its own zero ideal"
        )
        XCTAssertEqual(probe.frame.width, layoutSize.width, accuracy: 0.5)
    }

    /// The production shape the rule is for. The canvas fills what it is given and proposes
    /// nothing of its own, so the stage never has a reason to ask AppKit how big it wants
    /// to be — the walk that froze the app for as long as it was left running.
    func testTheSpatialCanvasAnswersTheSizeItIsProposed() throws {
        let source = try String(
            contentsOf: appSourceRoot
                .appendingPathComponent("Canvas/SpatialCanvasRepresentable.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("func sizeThatFits("),
            """
            SpatialCanvasView declares no sizeThatFits, so every measurement of the stage \
            runs an Auto Layout fitting-size sweep over every card, every pane host and \
            every NSTextField beneath it.
            """
        )
    }

    // MARK: - Fixture

    private let layoutSize = CGSize(width: 400, height: 300)

    private func layOut(_ view: some View) {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: layoutSize)
        host.layoutSubtreeIfNeeded()
    }

    private var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TenonApp")
    }
}

/// Counts the questions a fitting-size sweep asks it. Nothing else in a laid-out subtree
/// reads this, so a non-zero count means the sweep ran.
private final class SizeQueryProbeView: NSView {
    private(set) var intrinsicSizeQueries = 0

    override var intrinsicContentSize: NSSize {
        intrinsicSizeQueries += 1
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// The shape `SpatialCanvasView` had while the app hung: no answer of its own.
private struct SilentRepresentable: NSViewRepresentable {
    let probe: SizeQueryProbeView

    func makeNSView(context: Context) -> SizeQueryProbeView { probe }
    func updateNSView(_ nsView: SizeQueryProbeView, context: Context) {}
}

/// The shape it has now: it takes the space it is offered.
private struct SpeakingRepresentable: NSViewRepresentable {
    let probe: SizeQueryProbeView

    func makeNSView(context: Context) -> SizeQueryProbeView { probe }
    func updateNSView(_ nsView: SizeQueryProbeView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SizeQueryProbeView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
