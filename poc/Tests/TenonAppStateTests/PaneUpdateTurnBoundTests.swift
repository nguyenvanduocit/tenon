import AppKit
@testable import TenonApp
import SwiftUI
import XCTest

/// T-091. A pane's update loop has to settle, and this is the measurement that says so.
///
/// The hang was not slowness: the main thread never returned from one runloop-observer call,
/// because each update turn scheduled the next one. What that looks like from inside the
/// process is a body-evaluation count that keeps climbing while nothing changes — so that is
/// what this counts, on the real hierarchy a pane is made of: an `NSHostingView` framed by hand
/// (as `SpatialSlotCardView.layout()` frames it) around a `ScrollView` over a `LazyVStack`.
///
/// It is a bound, not a benchmark. Convergence is the claim; the exact number is not.
@MainActor
final class PaneUpdateTurnBoundTests: XCTestCase {
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
