import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// T-093. A slow observer costs its own generation, and nobody else's.
///
/// The host fans a fact out to every subscribed generation. When that fan-out ran the
/// observers' JavaScript inline, one plugin holding its thread delayed the next plugin's
/// delivery and the publisher's own pending host task — so a plugin nobody was looking at could
/// stall quit, reload, and every other plugin's view of the world. What bounds that is
/// acceptance: the host hands the fact to a generation's mailbox and returns.
final class PluginEventBackpressureTests: XCTestCase {
    @MainActor
    func testASlowObserverBlocksNeitherThePublisherNorAnotherObserver() async throws {
        let host = try makeHost()
        try await host.loadAll()

        let started = ContinuousClock.now
        await host.emit(
            event: "workspace.changed",
            payload: .object(["value": .string("one")])
        )
        let publishDuration = started.duration(to: .now)

        XCTAssertLessThan(
            publishDuration,
            .milliseconds(400),
            """
            publishing must cost a bounded enqueue; the slow observer holds its JavaScript \
            thread for well over a second
            """
        )

        let fastArrived = await eventually {
            status(host, "dev.tenon.test.fast-observer") == "fast:one"
        }
        XCTAssertTrue(fastArrived, "the fast observer never received the fact")
        XCTAssertNil(
            status(host, "dev.tenon.test.slow-observer"),
            "precondition: the slow observer must still be busy, or this proves nothing"
        )

        let slowArrived = await eventually(attempts: 600) {
            status(host, "dev.tenon.test.slow-observer") == "slow:one"
        }
        XCTAssertTrue(
            slowArrived,
            "a slow observer still gets its fact — it is delayed, not dropped"
        )

        await host.shutdown()
    }

    /// Ordering is what makes "published after" mean anything to an observer, and a queue is
    /// exactly where it could be lost.
    @MainActor
    func testFactsArriveInTheOrderTheGenerationAcceptedThem() async throws {
        let host = try makeHost()
        try await host.loadAll()

        for value in ["one", "two", "three"] {
            await host.emit(
                event: "workspace.changed",
                payload: .object(["value": .string(value)])
            )
        }

        let arrived = await eventually(attempts: 600) {
            status(host, "dev.tenon.test.fast-observer") == "fast:one|two|three"
        }
        XCTAssertTrue(
            arrived,
            "expected every fact in order; got "
                + (status(host, "dev.tenon.test.fast-observer") ?? "nil")
        )

        await host.shutdown()
    }

    // MARK: - Fixture

    @MainActor
    private func makeHost() throws -> PluginHost {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t093-\(UUID().uuidString)", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try write(
            directory: plugins.appendingPathComponent("slow", isDirectory: true),
            id: "dev.tenon.test.slow-observer",
            source: """
            tenon.events.on("workspace.changed", function (payload) {
              // A plugin that does too much work in a handler. Deliberately synchronous:
              // an await would yield the thread and prove nothing.
              var end = Date.now() + 1500;
              while (Date.now() < end) {}
              tenon.statusBar.set("slow:" + (payload && payload.value));
            });
            """
        )
        try write(
            directory: plugins.appendingPathComponent("fast", isDirectory: true),
            id: "dev.tenon.test.fast-observer",
            source: """
            var seen = [];
            tenon.events.on("workspace.changed", function (payload) {
              seen.push(payload && payload.value);
              tenon.statusBar.set("fast:" + seen.join("|"));
            });
            """
        )

        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        return try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory
        )
    }

    private func write(directory: URL, id: String, source: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "\(id)",
          "name": "\(id)",
          "version": "1",
          "permissions": [],
          "intents": { "uses": [], "provides": [] }
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
    }

    @MainActor
    private func status(_ host: PluginHost, _ id: String) -> String? {
        host.statusItems.first { $0.pluginID.rawValue == id }?.text
    }

    @MainActor
    private func eventually(
        attempts: Int = 200,
        operation: @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
