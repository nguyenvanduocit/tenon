import AppKit
@testable import TenonApp
import SwiftUI
import XCTest

/// T-091. A pane's update loop has to settle, and this is the measurement that says so.
///
/// The hang was not slowness: the main thread never returned from one runloop-observer call,
/// because each update turn scheduled the next one. What that looks like from inside the
/// process is a body-evaluation count that keeps climbing while nothing changes — so that is
/// what this counts, on the same host boundary a pane uses: an `NSHostingView` framed by hand
/// (as `SpatialSlotCardView.layout()` frames it) around a `ScrollView` over a `LazyVStack`.
///
/// It is a bound, not a benchmark. Convergence is the claim; the exact number is not.
@MainActor
final class PaneUpdateTurnBoundTests: XCTestCase {
    func testAgentBottomScrollGateCoalescesUntilTheScheduledTurnCompletes() {
        var gate = AgentScrollTurnGate()

        XCTAssertTrue(gate.claim())
        for _ in 0 ..< 32 {
            XCTAssertFalse(gate.claim(), "a revision enqueued an obsolete bottom scroll")
        }

        gate.release()
        XCTAssertTrue(gate.claim(), "the next settled turn could not schedule a fresh scroll")
    }

    func testProductionShapedAgentSessionSettlesAfterRowsAndComposerStopChanging() async {
        let model = LiveAgentSessionProbeModel()
        let counter = EvaluationCounter()
        let host = PaneContentHost.make(
            AnyView(LiveAgentSessionProbe(model: model, counter: counter))
        )
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        await drain(host, turns: 4)
        let beforeChurn = counter.count
        for revision in 1 ... 32 {
            model.rows.append("live row \(revision)")
            model.draft = Array(repeating: "composer line", count: 1 + revision % 6)
                .joined(separator: "\n")
            model.renderRevision = revision
            await drain(host, turns: 2)
        }

        await drain(host, turns: 24)
        let settled = counter.count
        await drain(host, turns: 24)

        XCTAssertGreaterThan(
            settled,
            beforeChurn,
            "row/revision/footer churn never reached the production-shaped view"
        )
        XCTAssertEqual(
            counter.count,
            settled,
            "Agent Session kept evaluating after row, scroll and multiline-footer churn stopped"
        )
    }

    func testAgentSessionContentReceivesOnlyAnExactFiniteViewport() throws {
        let proposals = ProposalLedger()
        let host = PaneContentHost.make(
            AnyView(
                AgentSessionLayout {
                    ProposalRecordingLayout(ledger: proposals) {
                        Color.clear
                    }
                    Color.clear.frame(height: 48)
                }
            )
        )
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        host.updateConstraintsForSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        let received = proposals.values
        XCTAssertFalse(received.isEmpty, "the account content was never laid out")
        XCTAssertTrue(
            received.allSatisfy { proposal in
                guard let width = proposal.width, let height = proposal.height else {
                    return false
                }
                return width.isFinite && height.isFinite && width > 0 && height > 0
            },
            "Agent Session asked its live lazy content for an ideal or unbounded size: \(received)"
        )
    }

    func testAPaneHostedLazyListStopsEvaluatingItsBody() throws {
        let counter = EvaluationCounter()
        let host = PaneContentHost.make(
            AnyView(PaneProbe(counter: counter, rows: 400))
        )
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        // A hosting view only renders inside a window, so the probe gets one. It is never
        // ordered on screen and never closed: ordering a window in hands it to the window
        // server's animation machinery, and closing it releases objects that the next test's
        // autorelease pool pops — which is a crash in whichever test happens to be running,
        // not in this one. Detaching the content view is the whole teardown this needs.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        pump(seconds: 1.0)

        let settled = counter.count
        pump(seconds: 1.0)

        XCTAssertEqual(
            counter.count,
            settled,
            """
            the pane kept re-evaluating its body with nothing changing — \(settled) turns in \
            the first second, \(counter.count) by the second. That is the T-091 shape: each \
            update schedules the next, and the runloop never finishes a turn.
            """
        )
        XCTAssertGreaterThan(settled, 0, "the probe never rendered, so this proves nothing")
    }

    /// The arrangement that makes the bound hold, pinned separately so a regression in it is
    /// reported as itself rather than as a mysterious count.
    func testThePaneHostPublishesNoSizingOptions() {
        let host = PaneContentHost.make(AnyView(Text("pane")))

        XCTAssertTrue(
            host.sizingOptions.isEmpty,
            """
            a pane's size is the canvas's answer. A host that publishes sizing options asks \
            its content how big it wants to be, and asking that of a lazy list measures rows \
            the pane never displays.
            """
        )
    }

    // MARK: - Fixture

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func drain(_ host: NSView, turns: Int) async {
        for _ in 0 ..< turns {
            host.updateConstraintsForSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private final class ProposalLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProposedViewSize] = []

    var values: [ProposedViewSize] { lock.withLock { storage } }

    func append(_ proposal: ProposedViewSize) {
        lock.withLock { storage.append(proposal) }
    }
}

private struct ProposalRecordingLayout: Layout {
    let ledger: ProposalLedger

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        ledger.append(proposal)
        return proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            subview.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

@MainActor
@Observable
private final class LiveAgentSessionProbeModel {
    var rows = (0 ..< 400).map { "history row \($0)" }
    var draft = "composer line"
    var renderRevision = 0
}

private struct LiveAgentSessionProbe: View {
    @Bindable var model: LiveAgentSessionProbeModel
    let counter: EvaluationCounter

    @State private var isPinnedToBottom = true
    @State private var bottomScrollGate = AgentScrollTurnGate()
    private let bottomID = "live-agent-session-bottom"

    var body: some View {
        counter.increment()
        return AgentSessionLayout {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows, id: \.self) { row in
                            Text(row)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        Color.clear
                            .frame(height: 12)
                            .id(bottomID)
                            .onAppear { isPinnedToBottom = true }
                            .onDisappear { isPinnedToBottom = false }
                    }
                }
                .onChange(of: model.renderRevision) { _, _ in
                    guard isPinnedToBottom, bottomScrollGate.claim() else { return }
                    DispatchQueue.main.async {
                        defer { bottomScrollGate.release() }
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }

            VStack(spacing: 0) {
                Divider()
                TextField("Message agent", text: $model.draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .padding(10)
            }
        }
    }
}

/// Counts body evaluations across the SwiftUI/AppKit boundary.
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

/// The shape of a pane's content: a scrolling lazy list, the thing the hang was measuring.
private struct PaneProbe: View {
    let counter: EvaluationCounter
    let rows: Int

    var body: some View {
        counter.increment()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< rows, id: \.self) { index in
                    Text("row \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}
