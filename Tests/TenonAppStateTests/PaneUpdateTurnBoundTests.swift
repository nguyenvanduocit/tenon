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

    /// T-141. The shipping Agent Session, mounted the way a pane mounts it, has to stop asking
    /// for layout once the session goes quiet.
    ///
    /// It mounts `AgentSessionView` itself, and that is the whole point of it. A stand-in built
    /// by hand carries the ingredients whoever wrote it thought mattered, and incident
    /// `0009-642b2192` — main thread spinning 1095 s, footprint 534 → 1860 MB — ran through
    /// `.textSelection(.enabled)` and the mount-time bottom scroll. A pane holds what it holds:
    /// selectable markdown rows, a live composer, and a scroll that fires on appear.
    ///
    /// What it counts is AppKit's own question rather than a body-evaluation tally: with nothing
    /// changing, does any view in the subtree still want layout or constraints? That is the
    /// freeze stated precisely — each update pass arms the next, so the pass never settles.
    func testTheShippingAgentSessionStopsAskingForLayoutOnceTheSessionIsQuiet() async {
        let model = Self.liveSessionModel()
        let host = PaneContentHost.make(
            AnyView(
                AgentSessionView(
                    model: model,
                    openTerminal: {},
                    fileLinks: .none
                )
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

        // Mount first, because the freeze began on the mount-time scroll: the transition before
        // it was `agent-lens-scroll-executed` with `pinned:false`, which is the `.onAppear`
        // branch rather than the revision branch `AgentScrollTurnGate` guards.
        await drain(host, turns: 8)

        for revision in 1 ... 24 {
            model.receive(Self.snapshot(messages: revision + 2, revision: revision))
            model.draft = Array(repeating: "composer line", count: 1 + revision % 6)
                .joined(separator: "\n")
            await drain(host, turns: 2)
        }

        await drain(host, turns: 24)

        // Nothing changes from here on.
        var restlessTurns = 0
        for _ in 0 ..< 16 {
            await nextMainLoopTurn()
            restlessTurns += pendingLayoutWork(in: host) > 0 ? 1 : 0
            host.updateConstraintsForSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(
            restlessTurns,
            0,
            """
            the Agent Session kept arming its own next layout pass after row, scroll and \
            multiline-composer churn stopped — \(restlessTurns) of 16 quiet turns still had \
            pending layout work. That is the freeze: the main thread never finishes a turn \
            because finishing one dirties the next.
            """
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
            await nextMainLoopTurn()
        }
    }

    private func nextMainLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// How many views in the pane still want a layout or constraints pass.
    ///
    /// Asked of the whole subtree rather than the host, because the re-arming happens deep in
    /// it: an `NSTextField` whose intrinsic content size is invalidated during the pass posts
    /// its need upward, and a host that has just been laid out reports nothing.
    private func pendingLayoutWork(in view: NSView) -> Int {
        var pending = (view.needsLayout ? 1 : 0) + (view.needsUpdateConstraints ? 1 : 0)
        for subview in view.subviews {
            pending += pendingLayoutWork(in: subview)
        }
        return pending
    }

    /// A live pane holding a session that is mid-run, which is when the freeze happens.
    @MainActor
    private static func liveSessionModel() -> AgentLensViewModel {
        let model = AgentLensViewModel(
            slotID: UUID(),
            terminalPool: nil,
            discovery: AgentLensDiscovery()
        )
        model.receive(snapshot(messages: 3, revision: 0))
        return model
    }

    /// Conversation rows shaped like the ones the pane actually renders: markdown that
    /// `AgentMarkdownText` has to parse, and text a person can select.
    private static func snapshot(messages: Int, revision: Int) -> AgentLensSnapshot {
        var snapshot = AgentLensSnapshot()
        snapshot.provider = .claude
        snapshot.status = .running
        snapshot.canSend = true
        snapshot.renderRevision = revision
        snapshot.messages = (0 ..< messages).map { index in
            AgentLensMessage(
                id: "m\(index)",
                role: index.isMultiple(of: 2) ? .assistant : .user,
                kind: .conversation,
                text: """
                Edited `Sources/TenonApp/AgentLensView.swift:\(400 + index)` and ran **tests**.

                - the first thing it changed
                - the second thing it changed
                """,
                isStreaming: false,
                evidence: .terminalInference(
                    "line \(index)",
                    capturedAt: Date(timeIntervalSince1970: TimeInterval(1000 + index))
                )
            )
        }
        return snapshot
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
