import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// T-080. A plugin's log lines arrive, and arrive in the order they were written.
///
/// Each line used to be its own detached task drawn from the shared 512-slot ledger: two lines
/// emitted in order could arrive in either order, and a full ledger dropped one with nothing
/// said. That is the worst outcome available for the one message whose entire job is to be read
/// by an author who cannot see the failure any other way — and it made the shared suite flaky,
/// because a test that asserts what the last line says was asserting a race.
final class PluginLogOrderingTests: XCTestCase {
    func testLinesArriveInTheOrderTheyWereWritten() async throws {
        let log = LogSink()
        let runtime = try makeRuntime(
            source: """
            for (var i = 0; i < 200; i += 1) {
              tenon.log("line " + i);
            }
            """,
            log: log
        )

        _ = try await runtime.start()
        _ = await runtime.shutdown()

        let numbers = log.lines.compactMap { line -> Int? in
            guard let range = line.range(of: "line ") else { return nil }
            return Int(line[range.upperBound...])
        }
        XCTAssertEqual(numbers.count, 200, "every line must arrive")
        XCTAssertEqual(
            numbers,
            Array(0 ..< 200),
            "lines must arrive in the order the plugin wrote them"
        )
    }

    /// Shutdown drains the chain rather than cancelling it: the last thing a failing generation
    /// says is usually the most useful thing it ever said.
    func testTheFinalLinesSurviveShutdown() async throws {
        let log = LogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.log("first");
            tenon.log("second");
            tenon.log("third");
            """,
            log: log
        )

        _ = try await runtime.start()
        _ = await runtime.shutdown()

        XCTAssertEqual(
            log.lines.map { $0.hasSuffix("third") }.last,
            true,
            "the last line written is the last line delivered"
        )
    }

    // MARK: - Fixture

    private func makeRuntime(source: String, log: LogSink) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t080-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginManifest(
                    id: PluginID("dev.tenon.log-tests"),
                    name: "log-tests",
                    version: "1",
                    permissions: [],
                    intents: PluginIntentManifest(uses: [], provides: [])
                ),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in
                        .failure(
                            error: IntentError(
                                code: .kernel(.internal),
                                details: nil,
                                retryable: false,
                                retryAfterMilliseconds: nil,
                                outcome: .unknown
                            ),
                            requestID: UUID(),
                            providerID: nil
                        )
                    },
                    list: { .array([]) }
                ),
                log: { message in log.append(message) }
            )
        )
    }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}
