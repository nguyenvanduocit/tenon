import TenonCore
import XCTest
@testable import TenonApp

/// A clock a test can move by hand from any thread. `DiagnosticsRuntime` reads it from its
/// watchdog queue, so a plain `var` captured in the closure is a data race Swift 6 rejects
/// outright — which is the compiler making the same point the design does.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval = 0) { self.value = value }

    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// T-092: the watchdog has to survive the condition it watches for.
final class DiagnosticsRuntimeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func makeJournal() -> DiagnosticsJournal {
        DiagnosticsJournal(fileURL: scratch.appendingPathComponent("health.jsonl"))
    }

    func testAStallIsRecordedWithTheProcessFootprint() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { 204 * 1_048_576 },
            captureSample: { _ in .launchFailed }
        )

        clock.now = 30
        subject.probeOnce()

        let records = waitForRecords(kind: "stall-sample-scheduled", in: journal)
        XCTAssertEqual(Array(records.map(\.kind).prefix(2)), ["stall", "stall-sample-scheduled"])
        XCTAssertEqual(records.first?.figures["seconds"], "30.0")
        XCTAssertEqual(
            records.first?.figures["footprintMB"], "204",
            "The figure that told the T-091 story travels with the record."
        )
    }

    func testRecoveryIsRecordedAfterAStall() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )

        clock.now = 10
        subject.probeOnce()
        clock.now = 12
        subject.beat()

        let records = waitForRecords(kind: "recovered", in: journal)
        XCTAssertTrue(records.map(\.kind).contains("recovered"))
        XCTAssertEqual(
            records.first(where: { $0.kind == "recovered" })?.figures["seconds"],
            "12.0"
        )
    }

    func testAHealthyRunloopWritesNothing() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )

        for tick in stride(from: 0.5, through: 20.0, by: 0.5) {
            clock.now = tick
            subject.beat()
            subject.probeOnce()
        }

        XCTAssertEqual(journal.records(), [], "Normal operation must be silent.")
    }

    func testStallCarriesRunBuildCPUAndPhaseAttribution() {
        let journal = makeJournal()
        let clock = TestClock()
        let cpu = MetricSequence([1.0, 1.0, 6.0])
        let identity = DiagnosticsRunIdentity(
            runID: "run-test",
            pid: 4242,
            version: "0.2.0",
            build: "17",
            channel: "staging"
        )
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { nil },
            cpuTimeSeconds: { cpu.next() },
            identity: identity,
            captureSample: { _ in .launchFailed }
        )

        clock.now = 1
        subject.beat()
        subject.probeOnce()
        clock.now = 11
        subject.probeOnce()

        let stall = waitForRecords(kind: "stall", in: journal).first { $0.kind == "stall" }
        XCTAssertEqual(stall?.figures["schema"], "2")
        XCTAssertEqual(stall?.figures["runID"], "run-test")
        XCTAssertEqual(stall?.figures["pid"], "4242")
        XCTAssertEqual(stall?.figures["version"], "0.2.0")
        XCTAssertEqual(stall?.figures["build"], "17")
        XCTAssertEqual(stall?.figures["channel"], "staging")
        XCTAssertEqual(stall?.figures["cpuCorePercent"], "50.0")
        XCTAssertEqual(stall?.figures["footprintMB"], "unavailable")
        XCTAssertEqual(stall?.figures["lastRunloopPhase"], "manual")
        XCTAssertNotNil(stall?.figures["incidentID"])
    }

    @MainActor
    func testCleanStopClosesTheSameRunThatLaunched() {
        let journal = makeJournal()
        let identity = DiagnosticsRunIdentity(
            runID: "clean-run",
            pid: 7,
            version: "1",
            build: "2",
            channel: "production"
        )
        let subject = DiagnosticsRuntime(
            journal: journal,
            identity: identity,
            captureSample: { _ in .launchFailed }
        )

        subject.start()
        subject.stop()
        subject.stop()

        let records = journal.records()
        XCTAssertEqual(records.map(\.kind), ["launch", "termination"])
        XCTAssertEqual(Set(records.compactMap { $0.figures["runID"] }), ["clean-run"])
    }

    /// The old observer-only detector missed this class: phase callbacks can continue while
    /// ordinary main-queue blocks wait behind a saturated queue. One outstanding ping detects
    /// that without enqueuing one probe per timer tick.
    func testMainQueueBacklogIsRecordedWhileSyntheticRunloopBeatsContinue() {
        let journal = makeJournal()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 0.3,
            escalationInterval: 60,
            probeInterval: 0.05,
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )
        subject.startProbe()
        defer { subject.stop() }

        let beating = DispatchGroup()
        beating.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline {
                subject.beat()
                usleep(20_000)
            }
            beating.leave()
        }
        let blockedUntil = Date().addingTimeInterval(0.8)
        while Date() < blockedUntil { _ = (0..<2_000).reduce(0, +) }
        beating.wait()

        let kinds = waitForRecords(kind: "responsiveness-stall", in: journal).map(\.kind)
        XCTAssertTrue(kinds.contains("responsiveness-stall"), "got \(kinds)")
        XCTAssertFalse(kinds.contains("stall"), "synthetic phase beats must prevent no-turn stall")
    }

    func testRunloopToQueueBacklogHandoffKeepsOneIncidentAndOneSample() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            probeInterval: 60,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )
        subject.startProbe()
        defer { subject.stop() }

        let sequence = DispatchGroup()
        sequence.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            clock.now = 10
            subject.probeOnce() // no completed phase: runloop stall
            clock.now = 11
            subject.beat() // runloop recovers, but the original main ping is still pending
            clock.now = 12
            subject.probeOnce() // fresh phase + stale ping: responsiveness handoff
            sequence.leave()
        }
        sequence.wait() // keep the test's main queue from acknowledging the ping

        let records = waitForRecords(kind: "responsiveness-stall", in: journal)
        let runloopID = records.first { $0.kind == "stall" }?.figures["incidentID"]
        let queueID = records.first { $0.kind == "responsiveness-stall" }?
            .figures["incidentID"]
        XCTAssertNotNil(runloopID)
        XCTAssertEqual(queueID, runloopID)
        XCTAssertEqual(records.filter { $0.kind == "stall-sample-scheduled" }.count, 1)
    }

    func testSecondRunloopStallBeforeOldPingAckGetsANewIncidentAndSample() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            probeInterval: 60,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )
        subject.startProbe()
        defer { subject.stop() }

        let sequence = DispatchGroup()
        sequence.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            clock.now = 10
            subject.probeOnce()
            clock.now = 11
            subject.beat()
            clock.now = 20
            subject.probeOnce()
            sequence.leave()
        }
        sequence.wait()

        let records = waitForRecords(kind: "stall-sample-scheduled", count: 2, in: journal)
        let incidentIDs = records.filter { $0.kind == "stall" }.compactMap {
            $0.figures["incidentID"]
        }
        XCTAssertEqual(incidentIDs.count, 2)
        XCTAssertEqual(Set(incidentIDs).count, 2)
        XCTAssertEqual(records.filter { $0.kind == "stall-sample-scheduled" }.count, 2)
    }

    func testQueueBacklogToRunloopHandoffKeepsOneIncidentAndOneSample() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            probeInterval: 60,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )
        subject.startProbe()
        defer { subject.stop() }

        let sequence = DispatchGroup()
        sequence.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            clock.now = 6
            subject.beat()
            subject.probeOnce()
            clock.now = 12
            subject.probeOnce()
            sequence.leave()
        }
        sequence.wait()

        let records = waitForRecords(kind: "stall", in: journal)
        let queueID = records.first { $0.kind == "responsiveness-stall" }?
            .figures["incidentID"]
        let runloopID = records.first { $0.kind == "stall" }?.figures["incidentID"]
        XCTAssertNotNil(queueID)
        XCTAssertEqual(runloopID, queueID)
        XCTAssertEqual(records.filter { $0.kind == "stall-sample-scheduled" }.count, 1)
    }

    func testMainQueuePingCrossingThresholdBetweenWatchdogProbesIsNotMissed() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            probeInterval: 60,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in .launchFailed }
        )
        subject.startProbe()
        defer { subject.stop() }

        clock.now = 6
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let records = waitForRecords(kind: "responsiveness-recovered", in: journal)
        XCTAssertEqual(
            records.filter { $0.kind == "responsiveness-stall" }.count,
            1
        )
        XCTAssertEqual(
            records.filter { $0.kind == "responsiveness-recovered" }.count,
            1
        )
        XCTAssertEqual(
            records.first { $0.kind == "responsiveness-stall" }?.figures["incidentID"],
            records.first { $0.kind == "responsiveness-recovered" }?.figures["incidentID"]
        )
    }

    func testTransitionRingIsBoundedAndContainsOnlyTypedCounts() throws {
        let clock = TestClock()
        let signals = DiagnosticsRuntimeSignals(capacity: 2, now: { clock.now })
        let pane = signals.registerAgentLensPane()
        clock.now = 1
        signals.noteAgentLensSnapshot(
            paneOrdinal: pane,
            account: .chat,
            mode: .session,
            split: false,
            status: .failed("TOP-SECRET-DETAIL"),
            revision: 8,
            messageCount: 4,
            toolCount: 2,
            interactionCount: 0,
            diagnosticCount: 0,
            timelineItemCount: 6
        )
        let snapshotEncoded = String(
            data: try JSONEncoder().encode(signals.snapshot()),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(snapshotEncoded.contains("failed"))
        XCTAssertFalse(snapshotEncoded.contains("TOP-SECRET-DETAIL"))
        clock.now = 2
        signals.noteAgentLensScroll(paneOrdinal: pane, admitted: true, pinned: true)
        clock.now = 3
        signals.noteAgentLensScrollExecuted(paneOrdinal: pane)

        let held = signals.snapshot()
        XCTAssertEqual(
            held.map(\.kind),
            [.agentLensScrollAdmitted, .agentLensScrollExecuted]
        )
        let encoded = String(data: try JSONEncoder().encode(held), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("slotID"))
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("cwd"))
        XCTAssertFalse(encoded.contains("command"))
        XCTAssertFalse(encoded.contains("TOP-SECRET-DETAIL"))
    }

    func testBlockedRecordPersistenceCannotMakeStopWaitWithoutBound() {
        let journal = makeJournal()
        let clock = TestClock()
        let sink = BlockingRecordSink()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { 0 },
            recordFlushTimeout: 0.05,
            persistRecord: { sink.persist($0) },
            captureSample: { _ in .launchFailed }
        )

        clock.now = 10
        subject.probeOnce()
        XCTAssertTrue(sink.waitUntilBlocked())
        let startedAt = Date()
        subject.stop()
        let elapsed = Date().timeIntervalSince(startedAt)
        sink.release()

        XCTAssertLessThan(elapsed, 0.5, "diagnostics persistence must not hang app termination")
    }

    func testRejectedRecordEventDoesNotLaunchAnOrphanCapture() {
        let journal = makeJournal()
        let clock = TestClock()
        let sink = BlockingRecordSink()
        let captures = CallCounter()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { 0 },
            recordQueueCapacity: 1,
            persistRecord: { sink.persist($0) },
            captureSample: { destination in
                captures.increment()
                try? destination.write(contentsOf: Data("sample".utf8))
                return .finished(exitStatus: 0)
            }
        )

        clock.now = 10
        subject.probeOnce()
        XCTAssertTrue(sink.waitUntilBlocked())
        clock.now = 11
        subject.beat()
        clock.now = 20
        subject.probeOnce()
        XCTAssertTrue(captures.waitForCount(1))
        sink.release()
        XCTAssertTrue(subject.waitForCaptureQueueToDrainForTesting())
        clock.now = 21
        subject.beat()
        subject.stop()

        XCTAssertEqual(captures.count, 1, "the rejected second incident must not run its sampler")
        XCTAssertFalse(
            sink.records.contains { $0.kind == "recovered" },
            "a rejected onset must not later produce an orphan recovery receipt"
        )
    }

    /// The one that proves the design rather than the arithmetic: block the main thread the
    /// way the T-091 hang did, and require that the watchdog still writes. A probe scheduled
    /// on the main queue would be stuck behind this very loop and record nothing.
    ///
    /// Uses a real clock and real threads on purpose — the claim is about scheduling, and a
    /// fake clock cannot make it.
    func testTheWatchdogStillFiresWhileTheMainThreadIsBlocked() throws {
        let journal = makeJournal()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 0.3,
            escalationInterval: 60,
            probeInterval: 0.1,
            footprintBytes: { 0 }
        )
        subject.beat() // one healthy turn, then nothing — the main thread is about to freeze
        subject.startProbe()
        defer { subject.stop() }

        // Busy-wait rather than sleep: a sleeping thread still lets its runloop turn, while a
        // spinning one does not — and spinning is what the hang actually did.
        let until = Date().addingTimeInterval(1.5)
        while Date() < until { _ = (0..<5000).reduce(0, +) }

        let kinds = waitForRecords(kind: "stall", in: journal).map(\.kind)
        XCTAssertTrue(
            kinds.contains("stall"),
            "The watchdog must record a stall it observed from off the main thread; got \(kinds)."
        )
    }

    /// The journal has to land where a person (and the export menu) can find it, beside the
    /// other application-level state rather than inside one workspace's folder.
    func testJournalPathSitsUnderApplicationSupportDiagnostics() throws {
        let plugins = scratch.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let paths = try AppStatePaths.resolve(
            instanceChannel: .production,
            environment: ["TENON_PLUGINS_DIR": plugins.path],
            applicationSupportDirectory: scratch
        )

        let file = paths.diagnosticsJournalFile

        XCTAssertEqual(file.lastPathComponent, "health.jsonl")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "diagnostics")
        XCTAssertEqual(
            file.deletingLastPathComponent().deletingLastPathComponent(),
            paths.applicationSupportRoot,
            "Application-level state, not workspace state."
        )
    }

    /// The footprint reader is Mach-specific enough to be worth pinning: a wrong flavor or
    /// count silently returns zero, and a telemetry figure that is always zero is worse than
    /// no figure because it looks answered.
    func testPhysicalFootprintReportsSomethingPlausible() {
        guard let bytes = DiagnosticsRuntime.physicalFootprint() else {
            return XCTFail("TASK_VM_INFO must be available in the macOS test process")
        }

        XCTAssertGreaterThan(bytes, 1_048_576, "A running test process holds more than 1 MB.")
        XCTAssertLessThan(bytes, 64 * 1_073_741_824, "…and less than 64 GB.")
    }

    private func waitForRecords(
        kind: String,
        count: Int = 1,
        in journal: DiagnosticsJournal,
        timeout: TimeInterval = 5
    ) -> [DiagnosticsRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        var records = journal.records()
        while Date() < deadline,
              records.filter({ $0.kind == kind }).count < count {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            records = journal.records()
        }
        return records
    }
}

private final class MetricSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) { self.values = values }

    func next() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private final class BlockingRecordSink: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocksNext = true
    private var storedRecords: [DiagnosticsRecord] = []

    var records: [DiagnosticsRecord] { lock.withLock { storedRecords } }

    func persist(_ record: DiagnosticsRecord) -> Bool {
        let shouldBlock = lock.withLock { () -> Bool in
            defer { blocksNext = false }
            return blocksNext
        }
        if shouldBlock {
            started.signal()
            releaseGate.wait()
        }
        lock.withLock { storedRecords.append(record) }
        return true
    }

    func waitUntilBlocked() -> Bool {
        started.wait(timeout: .now() + 5) == .success
    }

    func release() {
        releaseGate.signal()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var stored = 0

    var count: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
        changed.signal()
    }

    func waitForCount(_ expected: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while count < expected {
            guard changed.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }
}
