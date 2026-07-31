import Foundation
import TenonIntentCore
@testable import TenonCore
import XCTest

/// T-049: a plugin publishes a fact, and only the plugins that asked for it hear.
///
/// EVENT, classified by T-042. The two properties these tests exist to hold are that a
/// publisher cannot name a channel it does not own, and that it never learns who listened —
/// the moment either fails, this is a broadcast command rather than a fact.
@MainActor
final class PluginPublishedEventTests: XCTestCase {
    func testAnObserverThatDeclaredTheChannelReceivesTheFact() async throws {
        let fixture = try makeFixture(
            publisherPublishes: ["board.changed"],
            observerObserves: ["dev.tenon.test.publisher/board.changed"]
        )
        let host = fixture.host
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        try await publish(host: host, local: "board.changed", value: "one")

        let heard = await eventually {
            await self.observerLog(host) == "dev.tenon.test.publisher/board.changed=one"
        }
        let log = await observerLog(host)
        XCTAssertTrue(
            heard,
            "the observer never heard the fact; log: \(log ?? "nil")"
        )
    }

    /// Publishing is authority. Naming a channel must not be the same as being allowed to
    /// publish on it (invariant 5) — the blocked half of the pair.
    func testPublishingAnUndeclaredChannelIsRefused() async throws {
        let fixture = try makeFixture(
            publisherPublishes: [],
            observerObserves: ["dev.tenon.test.publisher/board.changed"]
        )
        let host = fixture.host
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        try await publish(host: host, local: "board.changed", value: "one")

        try? await Task.sleep(for: .milliseconds(300))
        let heard = await observerLog(host)
        XCTAssertNil(
            heard,
            "an undeclared publish reached an observer: \(heard ?? "")"
        )
    }

    /// The forgery case, and the reason the runtime hands over only the local half: a
    /// plugin cannot publish `automation.fired`, or another plugin's channel, because it
    /// never gets to say a full name at all. This asserts the shape rather than the check.
    func testAPublisherCannotNameAHostOrForeignChannel() throws {
        // A local name carrying the owner separator is refused at manifest decode, so the
        // "publish as somebody else" attempt never reaches a runtime.
        XCTAssertThrowsError(
            try PluginEventManifest(publishes: ["dev.tenon.other/board.changed"])
        )
        XCTAssertThrowsError(try PluginEventManifest(publishes: ["a/b"]))

        // And whatever a plugin does declare is qualified with its OWN id by the host.
        let owner = PluginID("dev.tenon.test.publisher")
        XCTAssertEqual(
            PluginEventManifest.qualified(local: "automation.fired", owner: owner),
            "dev.tenon.test.publisher/automation.fired",
            "a plugin publishing the local name of a host event still lands in its own namespace"
        )
    }

    /// The observer gate, isolated. The plugin's JavaScript really subscribes — so the
    /// runtime would happily deliver — and its manifest does not declare the channel. Only
    /// the fan-out's check stands between them, which is what makes this test able to fail.
    func testAnObserverThatSubscribesWithoutDeclaringHearsNothing() async throws {
        let fixture = try makeFixture(
            publisherPublishes: ["board.changed"],
            observerObserves: [],
            observerSubscribesTo: ["dev.tenon.test.publisher/board.changed"]
        )
        let host = fixture.host
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        try await publish(host: host, local: "board.changed", value: "one")

        try? await Task.sleep(for: .milliseconds(300))
        let heard = await observerLog(host)
        XCTAssertNil(
            heard,
            "observation is a declared authority; an undeclared listener must hear nothing"
        )
    }

    // MARK: - Manifest bounds

    func testChannelDeclarationsAreBounded() {
        let many = (0 ..< (PluginEventManifest.maximumChannelsPerPlugin + 1))
            .map { "c\($0)" }
        XCTAssertThrowsError(try PluginEventManifest(publishes: many))

        let long = String(
            repeating: "x",
            count: PluginEventManifest.maximumChannelNameCharacters + 1
        )
        XCTAssertThrowsError(try PluginEventManifest(publishes: [long]))
        XCTAssertThrowsError(try PluginEventManifest(publishes: ["", "ok"]))
        XCTAssertThrowsError(try PluginEventManifest(publishes: ["has space"]))
        XCTAssertThrowsError(try PluginEventManifest(publishes: ["a", "a"]))
    }

    func testAnObservedNameMustCarryExactlyOneOwner() {
        XCTAssertThrowsError(try PluginEventManifest(observes: ["board.changed"]))
        XCTAssertThrowsError(try PluginEventManifest(observes: ["a/b/c"]))
        XCTAssertThrowsError(try PluginEventManifest(observes: ["/b"]))
        XCTAssertThrowsError(try PluginEventManifest(observes: ["a/"]))
        XCTAssertNoThrow(try PluginEventManifest(observes: ["a/b"]))
    }

    // MARK: - Fixture

    private struct Fixture {
        let host: PluginHost
    }

    private func makeFixture(
        publisherPublishes: [String],
        observerObserves: [String],
        observerSubscribesTo: [String]? = nil
    ) throws -> Fixture {
        // What the observer's JavaScript listens for, which is NOT the same question as
        // what its manifest declares — the gap between them is the authority being tested.
        let subscriptions = observerSubscribesTo ?? observerObserves
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t049-\(UUID().uuidString)", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try write(
            directory: plugins.appendingPathComponent("publisher", isDirectory: true),
            manifest: """
            {
              "id": "dev.tenon.test.publisher",
              "name": "publisher",
              "version": "1",
              "permissions": [],
              "intents": { "uses": [], "provides": [] },
              "events": { "publishes": \(json(publisherPublishes)), "observes": [] }
            }
            """,
            source: """
            // Triggered by a host event, so the publish crosses the runtime boundary the
            // way it would in production rather than being poked from Swift.
            tenon.events.on("workspace.selected", function (payload) {
              tenon.events.emit("board.changed", { value: payload && payload.value });
            });
            """
        )
        try write(
            directory: plugins.appendingPathComponent("observer", isDirectory: true),
            manifest: """
            {
              "id": "dev.tenon.test.observer",
              "name": "observer",
              "version": "1",
              "permissions": [],
              "intents": { "uses": [], "provides": [] },
              "events": { "publishes": [], "observes": \(json(observerObserves)) }
            }
            """,
            source: """
            \(subscriptions.map { name in
                """
                tenon.events.on("\(name)", function (payload) {
                  tenon.statusBar.set("\(name)=" + (payload && payload.value));
                });
                """
            }.joined(separator: "\n"))
            """
        )

        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory
        )
        return Fixture(host: host)
    }

    private func write(directory: URL, manifest: String, source: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try manifest.write(
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

    private func json(_ values: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: values)
        return String(decoding: data, as: UTF8.self)
    }

    /// Triggers the publisher through a host event, so the publish travels the production
    /// path: host -> publisher runtime -> host fan-out -> observer runtime.
    private func publish(host: PluginHost, local: String, value: String) async throws {
        await host.emit(
            event: "workspace.selected",
            payload: .object(["value": .string(value)])
        )
    }

    private func observerLog(_ host: PluginHost) async -> String? {
        host.statusItems.first {
            $0.pluginID == PluginID("dev.tenon.test.observer")
        }?.text
    }

    private func eventually(
        attempts: Int = 400,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await operation()
    }
}
