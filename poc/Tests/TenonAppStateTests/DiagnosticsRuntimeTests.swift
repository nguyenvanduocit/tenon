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
            captureSample: { _ in }
        )

        clock.now = 30
        subject.probeOnce()

        let records = journal.records()
        XCTAssertEqual(
            records.map(\.kind),
            ["stall", "stall-sample"],
            "a stall names where its own stack sample was written (T-091)"
        )
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
            captureSample: { _ in }
        )

        clock.now = 10
        subject.probeOnce()
        clock.now = 12
        subject.beat()

        XCTAssertEqual(journal.records().map(\.kind), ["stall", "stall-sample", "recovered"])
        XCTAssertEqual(journal.records().last?.figures["seconds"], "12.0")
    }

    func testAHealthyRunloopWritesNothing() {
        let journal = makeJournal()
        let clock = TestClock()
        let subject = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.now },
            footprintBytes: { 0 },
            captureSample: { _ in }
        )

        for tick in stride(from: 0.5, through: 20.0, by: 0.5) {
            clock.now = tick
            subject.beat()
            subject.probeOnce()
        }

        XCTAssertEqual(journal.records(), [], "Normal operation must be silent.")
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

        let kinds = journal.records().map(\.kind)
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
        let bytes = DiagnosticsRuntime.physicalFootprint()

        XCTAssertGreaterThan(bytes, 1_048_576, "A running test process holds more than 1 MB.")
        XCTAssertLessThan(bytes, 64 * 1_073_741_824, "…and less than 64 GB.")
    }
}
