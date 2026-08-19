import TenonCore
import XCTest
@testable import TenonApp

/// T-182: `WorkspaceEventBroadcastPump` is what replaced a detached `Task` spawned per
/// `WorkspaceStore.onEvents` firing — the thing that let a burst of firings fan out into
/// overlapping `PluginHost.emit` calls and overflow a subscribed plugin's bounded mailbox.
/// These pin the two properties that removed the amplification: never more than one
/// broadcast in flight, and every firing still observed, in the order it fired.
@MainActor
final class WorkspaceEventBroadcastPumpTests: XCTestCase {
    func testNeverRunsTwoBroadcastsConcurrently() async {
        let tracker = ConcurrencyTracker()
        let pump = WorkspaceEventBroadcastPump { _ in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await tracker.exit()
        }

        for index in 0 ..< 30 {
            pump.enqueue(.init(events: [], snapshot: Self.catalog(index)))
        }

        let observedMax = await Self.eventually(attempts: 400) {
            await tracker.handledCount() == 30
        }
        XCTAssertTrue(observedMax, "the pump never drained every enqueued broadcast")
        let peakConcurrency = await tracker.peakConcurrency()
        XCTAssertEqual(peakConcurrency, 1, "two broadcasts overlapped in flight")
    }

    func testPreservesEnqueueOrderUnderABurst() async {
        let recorder = OrderRecorder()
        let pump = WorkspaceEventBroadcastPump { item in
            let index = Int(item.snapshot.workspaces.first?.path.lastPathComponent ?? "-1") ?? -1
            await recorder.record(index)
        }

        for index in 0 ..< 50 {
            pump.enqueue(.init(events: [], snapshot: Self.catalog(index)))
        }

        let drained = await Self.eventually {
            await recorder.count() == 50
        }
        XCTAssertTrue(drained, "the pump never drained every enqueued broadcast")
        let observed = await recorder.order()
        XCTAssertEqual(observed, Array(0 ..< 50), "broadcasts were not delivered in firing order")
    }

    private static func catalog(_ index: Int) -> WorkspaceCatalog {
        WorkspaceCatalog(
            path: URL(fileURLWithPath: "/tmp/tenon-broadcast-pump-test/\(index)", isDirectory: true)
        )
    }

    private static func eventually(
        attempts: Int = 200,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor ConcurrencyTracker {
    private var inFlight = 0
    private var peak = 0
    private var handled = 0

    func enter() {
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func exit() {
        inFlight -= 1
        handled += 1
    }

    func peakConcurrency() -> Int { peak }
    func handledCount() -> Int { handled }
}

private actor OrderRecorder {
    private var seen: [Int] = []

    func record(_ index: Int) {
        seen.append(index)
    }

    func order() -> [Int] { seen }
    func count() -> Int { seen.count }
}
