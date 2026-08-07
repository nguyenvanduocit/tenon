import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// T-091. The next spin has to leave a receipt taken while it was still a spin.
///
/// The only sample of that two-hour hang was taken by hand near the end, after 10.4 GB had
/// swapped out — by then every turn was slow for reasons that had nothing to do with the cause,
/// and the first turns were invisible. A sample taken seconds into the stall is the evidence
/// the reproduction still needs.
final class StallSampleCaptureTests: XCTestCase {
    func testTheFirstStallSamplesTheProcessOnce() throws {
        let captures = CaptureLog()
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            escalationInterval: 1,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.record($0) }
        )

        clock.value = 0
        runtime.beat()
        clock.value = 10
        runtime.probeOnce()
        captures.waitForCount(1)

        XCTAssertEqual(captures.count, 1, "a stall must sample the process")
        XCTAssertEqual(
            captures.destinations.first?.lastPathComponent,
            "stall-sample.txt"
        )
        XCTAssertEqual(
            captures.destinations.first?.deletingLastPathComponent(),
            journalURL.deletingLastPathComponent(),
            "the sample belongs beside the journal that names it"
        )

        // A spin lasting hours must not spend those hours writing samples.
        clock.value = 20
        runtime.probeOnce()
        clock.value = 40
        runtime.probeOnce()
        XCTAssertEqual(captures.count, 1, "an ongoing stall re-samples nothing")
    }

    func testARunloopThatKeepsTurningSamplesNothing() throws {
        let captures = CaptureLog()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: try temporaryJournalURL()),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.record($0) }
        )

        for step in stride(from: 0.0, through: 20.0, by: 1.0) {
            clock.value = step
            runtime.beat()
            runtime.probeOnce()
        }

        XCTAssertEqual(captures.count, 0)
    }

    /// A stall that ends and happens again is two incidents, and the second one is often the
    /// interesting one.
    func testASecondStallSamplesAgain() throws {
        let captures = CaptureLog()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: try temporaryJournalURL()),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.record($0) }
        )

        clock.value = 0
        runtime.beat()
        clock.value = 10
        runtime.probeOnce()
        captures.waitForCount(1)

        clock.value = 11
        runtime.beat()
        clock.value = 30
        runtime.probeOnce()
        captures.waitForCount(2)

        XCTAssertEqual(captures.count, 2)
    }

    // MARK: - Fixture

    private func temporaryJournalURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t091-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("health.jsonl")
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The sample runs off the main queue — the thread it would otherwise be wedged behind — so
/// the test waits for it rather than assuming it already ran.
private final class CaptureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var count: Int { lock.withLock { urls.count } }
    var destinations: [URL] { lock.withLock { urls } }

    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    func waitForCount(_ expected: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, count < expected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
