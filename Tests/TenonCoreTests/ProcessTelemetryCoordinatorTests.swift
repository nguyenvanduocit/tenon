import Foundation
import XCTest

@testable import TenonCore

/// When a sample happens, and whether its result is allowed to be shown.
///
/// Both halves are concurrency rules, so the seams are injected: the clock and the ticker are
/// stated in nanoseconds rather than waited out, and the sampler is a recorder that can be
/// held open on demand. Nothing here sleeps.
final class ProcessTelemetryCoordinatorTests: XCTestCase {
    // MARK: - Doubles

    /// A sampler that counts calls and, when asked, refuses to finish until released — which
    /// is how "one sample in flight" becomes an assertable fact rather than a race.
    private actor RecordingSampler: ProcessSampling {
        private(set) var calls = 0
        private(set) var lastPanes: [PaneProvenance] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var holding = false
        private var failures: [Error] = []
        var processes: [RawProcessSample] = []
        private var arrived: CheckedContinuation<Void, Never>?

        func hold() { holding = true }

        func release() {
            holding = false
            gate?.resume()
            gate = nil
        }

        /// Suspends until a sample actually starts, so a test never races the actor.
        func waitForArrival() async {
            if calls > 0 { return }
            await withCheckedContinuation { arrived = $0 }
        }

        func failNext(_ count: Int, with error: Error) {
            failures = Array(repeating: error, count: count)
        }

        func setProcesses(_ processes: [RawProcessSample]) { self.processes = processes }

        func sample(panes: [PaneProvenance]) async throws -> ProcessSampleSet {
            calls += 1
            lastPanes = panes
            arrived?.resume()
            arrived = nil
            if holding {
                await withCheckedContinuation { gate = $0 }
            }
            if !failures.isEmpty {
                throw failures.removeFirst()
            }
            return ProcessSampleSet(hostRecord: nil, processes: processes)
        }
    }

    private struct FixedClock: TelemetryClock {
        let nowNanoseconds: UInt64 = 1_000_000_000
        var now: Date { Date(timeIntervalSince1970: 0) }
    }

    /// Records what the coordinator asked to wait for and returns at once, so a cadence is
    /// asserted as a number rather than by elapsing.
    private actor RecordingTicker: TelemetryTicker {
        private(set) var waits: [UInt64] = []
        private let limit: Int
        private var reachedLimit: CheckedContinuation<Void, Never>?
        init(allow: Int) { limit = allow }

        func wait(nanoseconds: UInt64) async throws {
            waits.append(nanoseconds)
            if waits.count >= limit {
                reachedLimit?.resume()
                reachedLimit = nil
                // Ending the loop here is what keeps the test finite: the ladder has been
                // observed, and nothing is served by sampling forever.
                throw CancellationError()
            }
            await Task.yield()
        }

        /// Suspends until the loop has asked to wait `limit` times, so the cadence is read
        /// after it exists rather than raced against it.
        func waitUntilLimitReached() async {
            if waits.count >= limit { return }
            await withCheckedContinuation { reachedLimit = $0 }
        }

        func recorded() -> [UInt64] { waits }
    }

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "collector refused" }
    }

    private let pane = PaneProvenance(
        slotID: UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!,
        tabID: UUID(),
        workspaceID: UUID(),
        ttyDevice: 7,
        foregroundPID: nil
    )

    private func process(pid: Int32, start: UInt64 = 1, tty: UInt32? = 7) -> RawProcessSample {
        RawProcessSample(
            identity: ProcessIdentity(pid: pid, startAbstime: start),
            parentPID: 1,
            ttyDevice: tty,
            executableName: "sh",
            cpuNanoseconds: 0,
            footprintBytes: 1024,
            diskBytesRead: 0,
            diskBytesWritten: 0
        )
    }

    private func makeCoordinator(
        sampler: RecordingSampler,
        ticker: RecordingTicker = RecordingTicker(allow: 1),
        provenance: @escaping @Sendable () async -> ProvenanceSnapshot
    ) -> ProcessTelemetryCoordinator {
        ProcessTelemetryCoordinator(
            sampler: sampler,
            clock: FixedClock(),
            ticker: ticker,
            physicalMemory: 16 << 30,
            provenance: provenance
        )
    }

    // MARK: - Visibility

    func testNoSurfaceMeansNoSampling() async {
        let sampler = RecordingSampler()
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        let visible = await coordinator.isVisible
        XCTAssertFalse(visible)
        let calls = await sampler.calls
        XCTAssertEqual(calls, 0, "a coordinator nobody is watching samples nothing")
    }

    func testOpeningRequestsAnImmediateSample() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.surfaceAppeared()
        await sampler.waitForArrival()
        let calls = await sampler.calls
        XCTAssertGreaterThanOrEqual(calls, 1)
    }

    /// Closing keeps the numbers and relabels them. They are real; they are simply no longer
    /// being refreshed, and a monitor that kept showing them as current would be lying by
    /// omission.
    func testClosingTheLastSurfacePausesRatherThanClearing() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.refreshNow()
        await coordinator.surfaceAppeared()
        await coordinator.surfaceDisappeared()

        let latest = await coordinator.latest
        XCTAssertEqual(latest?.state, .paused)
        XCTAssertFalse(latest?.root.isEmpty ?? true, "the retained tree survives the pause")
        let visible = await coordinator.isVisible
        XCTAssertFalse(visible)
    }

    /// Two popovers, one sampler. Periodic demand ends when the *last* one goes.
    func testDemandIsCountedNotToggled() async {
        let sampler = RecordingSampler()
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.surfaceAppeared()
        await coordinator.surfaceAppeared()
        await coordinator.surfaceDisappeared()
        var visible = await coordinator.isVisible
        XCTAssertTrue(visible, "one surface remains")
        await coordinator.surfaceDisappeared()
        visible = await coordinator.isVisible
        XCTAssertFalse(visible)
    }

    // MARK: - One in flight, one coalesced

    /// Ten requests during one slow sample produce that sample and exactly one follow-up. The
    /// pending marker is a boolean, so there is no queue that could grow.
    func testManyRefreshesDuringOneSlowSampleCoalesceIntoOneFollowUp() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        await sampler.hold()
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }

        let first = Task { await coordinator.refreshNow() }
        await sampler.waitForArrival()
        for _ in 0 ..< 10 {
            await coordinator.refreshNow()
        }
        await sampler.release()
        await first.value

        let calls = await sampler.calls
        XCTAssertEqual(calls, 2, "the active sample plus exactly one coalesced follow-up")
    }

    // MARK: - Stale results

    /// The rule that stops a process being attributed to the wrong workspace for one frame: a
    /// result captured against a hierarchy that has since changed is discarded, not published.
    func testAResultCapturedUnderOldProvenanceIsNeverPublished() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        await sampler.hold()
        let pane = pane
        let revision = Revision()
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: await revision.value, panes: [pane], labels: .none)
        }

        let run = Task { await coordinator.refreshNow() }
        await sampler.waitForArrival()
        // The pane moved while the sample was in flight.
        await revision.bump()
        await sampler.release()
        await run.value

        let latest = await coordinator.latest
        XCTAssertEqual(
            latest?.provenanceRevision, 2,
            "only the replacement, taken under the current hierarchy, may be published"
        )
    }

    /// A result from a session nobody is watching any more is dropped rather than shown.
    func testAResultFromARetiredGenerationIsDiscarded() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        await sampler.hold()
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }

        await coordinator.surfaceAppeared()
        await sampler.waitForArrival()
        await coordinator.surfaceDisappeared()   // bumps generation
        await sampler.release()

        let latest = await coordinator.latest
        XCTAssertNil(latest, "nothing was ever published from the retired generation")
    }

    // MARK: - Failure

    /// A collector failure with a previous reading becomes stale — the last good tree stays on
    /// screen and says it is old.
    func testCollectorFailureAfterAGoodSampleGoesStaleAndKeepsTheTree() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.refreshNow()
        let good = await coordinator.latest
        XCTAssertEqual(good?.state, .ready)

        await sampler.failNext(1, with: Boom())
        await coordinator.refreshNow()

        let stale = await coordinator.latest
        guard case let .stale(reason) = stale?.state else {
            return XCTFail("expected stale, got \(String(describing: stale?.state))")
        }
        XCTAssertTrue(reason.contains("collector refused"))
        XCTAssertFalse(stale?.root.isEmpty ?? true, "the last good tree is still shown")
    }

    /// A collector failure with nothing to fall back on is a terminal error. It must never be
    /// reported as an empty machine — that is the difference between "nothing is running" and
    /// "I could not look".
    func testCollectorFailureWithNoPreviousSampleIsAnErrorNotAnEmptySystem() async {
        let sampler = RecordingSampler()
        await sampler.failNext(1, with: Boom())
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.refreshNow()

        let latest = await coordinator.latest
        guard case .failed = latest?.state else {
            return XCTFail("expected failed, got \(String(describing: latest?.state))")
        }
        XCTAssertNotEqual(latest?.state, .empty)
    }

    func testRetryClearsTheBackoffWithoutStartingASecondConcurrentSample() async {
        let sampler = RecordingSampler()
        await sampler.failNext(3, with: Boom())
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.refreshNow()
        await coordinator.refreshNow()
        await coordinator.retry()

        let calls = await sampler.calls
        XCTAssertEqual(calls, 3, "each request produced exactly one sample")
    }

    // MARK: - Cadence and backoff

    func testHealthySamplingWaitsTwoSeconds() async {
        let sampler = RecordingSampler()
        let ticker = RecordingTicker(allow: 2)
        let pane = pane
        let coordinator = ProcessTelemetryCoordinator(
            sampler: sampler,
            clock: FixedClock(),
            ticker: ticker,
            physicalMemory: 16 << 30,
            provenance: { ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none) }
        )
        await coordinator.surfaceAppeared()
        await ticker.waitUntilLimitReached()
        await coordinator.shutDown()

        let waits = await ticker.recorded()
        XCTAssertEqual(waits.first, ProcessTelemetryCoordinator.refreshInterval)
    }

    /// Consecutive failures back off 2, 4, 8, 16, 30 and then hold at 30 rather than growing.
    func testConsecutiveFailuresBackOffAlongTheDeclaredLadderAndStopThere() async {
        let sampler = RecordingSampler()
        await sampler.failNext(8, with: Boom())
        let ticker = RecordingTicker(allow: 7)
        let pane = pane
        let coordinator = ProcessTelemetryCoordinator(
            sampler: sampler,
            clock: FixedClock(),
            ticker: ticker,
            physicalMemory: 16 << 30,
            provenance: { ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none) }
        )
        await coordinator.surfaceAppeared()
        await ticker.waitUntilLimitReached()
        await coordinator.shutDown()

        let waits = await ticker.recorded().map { $0 / 1_000_000_000 }
        XCTAssertEqual(Array(waits.prefix(6)), [2, 4, 8, 16, 30, 30])
    }

    // MARK: - Capacity

    /// A runaway build cannot make a snapshot unbounded, and the truncation is stated rather
    /// than silent — a capped list that claimed to be complete would read as the whole story.
    func testProcessCapacityTruncatesAndSaysSo() async {
        let sampler = RecordingSampler()
        let many = (0 ..< (ProcessTelemetryCoordinator.processCapacity + 50)).map {
            process(pid: Int32(1000 + $0), tty: nil)
        }
        await sampler.setProcesses(many)
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.refreshNow()

        let latest = await coordinator.latest
        guard case let .partial(_, truncated) = latest?.state else {
            return XCTFail("expected partial, got \(String(describing: latest?.state))")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(latest?.processCount, ProcessTelemetryCoordinator.processCapacity)
    }

    // MARK: - Shutdown

    func testShutDownCancelsDemandAndReachesQuiescence() async {
        let sampler = RecordingSampler()
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.surfaceAppeared()
        await coordinator.shutDown()

        let visible = await coordinator.isVisible
        XCTAssertFalse(visible)
    }

    // MARK: - Counters carry across samples

    /// The second sample of the same process has a delta; the first cannot. This is the seam
    /// the whole CPU column rests on.
    func testTheSecondSampleOfOneProcessProducesADelta() async {
        let sampler = RecordingSampler()
        await sampler.setProcesses([process(pid: 100)])
        let pane = pane
        let coordinator = makeCoordinator(sampler: sampler) {
            ProvenanceSnapshot(revision: 1, panes: [pane], labels: .none)
        }
        await coordinator.refreshNow()
        let first = await coordinator.latest
        XCTAssertEqual(
            findPane(first)?.cpuPercent.unavailability, .firstObservation,
            "nothing to subtract from yet"
        )

        await sampler.setProcesses([
            RawProcessSample(
                identity: ProcessIdentity(pid: 100, startAbstime: 1),
                parentPID: 1,
                ttyDevice: 7,
                executableName: "sh",
                cpuNanoseconds: 500_000_000,
                footprintBytes: 1024,
                diskBytesRead: 4096,
                diskBytesWritten: 0
            )
        ])
        await coordinator.refreshNow()
        let second = await coordinator.latest
        // FixedClock does not advance, so the interval is zero — the honest answer is
        // "invalid interval", never a number invented from a zero denominator.
        XCTAssertEqual(findPane(second)?.cpuPercent.unavailability, .invalidInterval)
        XCTAssertEqual(findPane(second)?.diskReadBytes.value, 4096, "byte deltas need no clock")
    }

    private func findPane(_ snapshot: TelemetrySnapshot?) -> TelemetryNode? {
        func walk(_ nodes: [TelemetryNode]) -> TelemetryNode? {
            for node in nodes {
                if case .pane = node.kind { return node }
                if let found = walk(node.children) { return found }
            }
            return nil
        }
        return snapshot.map { walk($0.root) } ?? nil
    }
}

/// A mutable revision a test can bump from outside the coordinator, standing in for the
/// MainActor bridge that increments when a pane moves.
private actor Revision {
    private(set) var value = 1
    func bump() { value += 1 }
}
