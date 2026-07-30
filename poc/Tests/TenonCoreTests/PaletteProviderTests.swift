import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// Phase 4 of T-006: dynamic palette providers.
///
/// Classification (docs/architecture-interaction-boundaries.md, recorded in the task
/// file): `registerProvider` and `setResults` are CONTRIBUTIONS, query delivery is an
/// owner-scoped EVENT. The rules these tests pin are the lifetime rules: a publication
/// for a superseded query revision is dropped (keystroke N+1 cancels keystroke N), a
/// retired generation's results never reach the palette, and a slow provider never
/// blocks or reorders the static ranked list.
final class PaletteProviderTests: XCTestCase {
    private static let pluginID = "dev.tenon.palette-tests"
    private static let pluginIdentity: PluginID = "dev.tenon.palette-tests"
    private static let intentName = "dev.tenon.palette-tests.open.v1"

    // MARK: - Runtime boundary

    func testRegisterProviderPublishesResultsForTheDeliveredRevision() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("\(Self.intentName)", async function () { return {}; });
            tenon.palette.registerProvider("files", { title: "Files" });
            tenon.palette.onQuery("files", function (query) {
              tenon.palette.setResults("files", query.revision, [
                {
                  id: "r-" + query.text,
                  title: "Open " + query.text,
                  subtitle: "a file",
                  icon: "doc",
                  intent: { name: "\(Self.intentName)", input: { path: query.text } },
                  actions: [
                    {
                      title: "Reveal",
                      intent: { name: "\(Self.intentName)", input: { reveal: true } }
                    }
                  ]
                }
              ]);
            });
            """
        )
        _ = try await runtime.start()

        var snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.paletteProviders.map(\.providerID), ["files"])
        XCTAssertEqual(snapshot.paletteProviders.first?.title, "Files")
        XCTAssertEqual(snapshot.paletteProviders.first?.publishedRevision, 0)

        await runtime.deliverPaletteQuery(text: "readme", revision: 1)
        let published = await eventually {
            await runtime.snapshot().paletteProviders.first?.publishedRevision == 1
        }
        XCTAssertTrue(published, "the provider's answer for revision 1 never arrived")

        snapshot = await runtime.snapshot()
        let provider = try XCTUnwrap(snapshot.paletteProviders.first)
        XCTAssertEqual(provider.deliveredRevision, 1)
        XCTAssertEqual(provider.results.count, 1)
        let result = try XCTUnwrap(provider.results.first)
        XCTAssertEqual(result.id, "r-readme")
        XCTAssertEqual(result.title, "Open readme")
        XCTAssertEqual(result.subtitle, "a file")
        XCTAssertEqual(result.icon, "doc")
        XCTAssertEqual(result.intentID.rawValue, Self.intentName)
        XCTAssertEqual(result.input.objectValue?["path"]?.stringValue, "readme")
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions.first?.title, "Reveal")
        XCTAssertEqual(result.actions.first?.intentID.rawValue, Self.intentName)

        _ = await runtime.shutdown()
    }

    func testPublicationForASupersededRevisionIsDropped() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("\(Self.intentName)", async function () { return {}; });
            tenon.palette.registerProvider("slow", { title: "Slow" });
            tenon.palette.onQuery("slow", function () {});
            """
        )
        _ = try await runtime.start()

        // Keystroke 1 then keystroke 2: revision 2 is now the only question being asked.
        await runtime.deliverPaletteQuery(text: "a", revision: 1)
        await runtime.deliverPaletteQuery(text: "ab", revision: 2)

        // The answer to keystroke 1 arrives late — it must be dropped.
        _ = try await runtime.evaluateForTesting(
            """
            tenon.palette.setResults("slow", 1, [
              { id: "stale", title: "Stale", intent: { name: "\(Self.intentName)" } }
            ])
            """
        )
        var snapshot = await runtime.snapshot()
        var provider = try XCTUnwrap(snapshot.paletteProviders.first)
        XCTAssertEqual(provider.publishedRevision, 0, "a superseded answer was accepted")
        XCTAssertTrue(provider.results.isEmpty)

        // The answer to the current keystroke is accepted.
        _ = try await runtime.evaluateForTesting(
            """
            tenon.palette.setResults("slow", 2, [
              { id: "fresh", title: "Fresh", intent: { name: "\(Self.intentName)" } }
            ])
            """
        )
        snapshot = await runtime.snapshot()
        provider = try XCTUnwrap(snapshot.paletteProviders.first)
        XCTAssertEqual(provider.publishedRevision, 2)
        XCTAssertEqual(provider.results.map(\.id), ["fresh"])

        _ = await runtime.shutdown()
    }

    func testResultsAreBoundedAndShapeValidated() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("\(Self.intentName)", async function () { return {}; });
            tenon.palette.registerProvider("bounded", { title: "Bounded" });
            tenon.palette.onQuery("bounded", function () {});
            """
        )
        _ = try await runtime.start()
        await runtime.deliverPaletteQuery(text: "x", revision: 1)

        _ = try await runtime.evaluateForTesting(
            """
            (function () {
              var rows = [];
              for (var i = 0; i < 60; i++) {
                rows.push({
                  id: "row-" + i,
                  title: "Row " + i,
                  intent: { name: "\(Self.intentName)" }
                });
              }
              rows[1] = { id: "no-title", intent: { name: "\(Self.intentName)" } };
              rows[2] = {
                id: "foreign-intent",
                title: "Foreign",
                intent: { name: "dev.tenon.other-plugin.steal.v1" }
              };
              var actions = [];
              for (var j = 0; j < 12; j++) {
                actions.push({
                  title: "Action " + j,
                  intent: { name: "\(Self.intentName)" }
                });
              }
              actions[0] = {
                title: "Foreign action",
                intent: { name: "dev.tenon.other-plugin.steal.v1" }
              };
              rows[3] = {
                id: "actions",
                title: "With actions",
                intent: { name: "\(Self.intentName)" },
                actions: actions
              };
              tenon.palette.setResults("bounded", 1, rows);
            })()
            """
        )

        let snapshot = await runtime.snapshot()
        let provider = try XCTUnwrap(snapshot.paletteProviders.first)
        // 60 published rows: the runtime keeps at most 50, and inside that window the
        // malformed row (no title) and the row naming another plugin's intent are gone.
        XCTAssertEqual(provider.results.count, 48)
        XCTAssertFalse(provider.results.contains { $0.id == "no-title" })
        XCTAssertFalse(provider.results.contains { $0.id == "foreign-intent" })
        XCTAssertFalse(provider.results.contains { $0.id == "row-55" })

        // Actions: 12 declared → capped to 8 considered, and the foreign-intent action
        // inside that window is dropped.
        let actionRow = try XCTUnwrap(provider.results.first { $0.id == "actions" })
        XCTAssertEqual(actionRow.actions.count, 7)
        XCTAssertFalse(actionRow.actions.contains { $0.title == "Foreign action" })
        XCTAssertFalse(actionRow.actions.contains { $0.title == "Action 8" })

        _ = await runtime.shutdown()
    }

    func testANinthProviderRegistrationFailsTheRuntime() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("\(Self.intentName)", async function () { return {}; });
            for (var i = 0; i < 9; i++) {
              tenon.palette.registerProvider("provider-" + i, { title: "P" + i });
            }
            """
        )
        await XCTAssertThrowsErrorAsync(try await runtime.start()) { error in
            guard case PluginRuntimeError.resourceLimitExceeded(let what) = error else {
                return XCTFail("expected resourceLimitExceeded, got \(error)")
            }
            XCTAssertEqual(what, "palette providers")
        }
        _ = await runtime.shutdown()
    }

    // MARK: - Host boundary

    @MainActor
    func testASlowProviderNeverBlocksOrReordersTheStaticRankedList() async throws {
        let fixture = try makeHostFixture(
            mainJS: """
            tenon.intents.handle("\(Self.intentName)", async function () { return {}; });
            tenon.palette.registerProvider("never", { title: "Never Answers" });
            tenon.palette.onQuery("never", function () {});
            """
        )
        defer { fixture.tearDown() }
        let host = fixture.host
        try await host.loadAll()
        await waitUntil { host.paletteSections.count == 1 }

        let before = host.commandIndex
            .rank(query: "", now: Date(timeIntervalSince1970: 0))
            .map(\.command.id)
        XCTAssertEqual(
            before,
            [Self.intentName],
            "the static palette row must rank without any provider involvement"
        )

        // One keystroke: setPaletteQuery is a synchronous host mutation. The very next
        // line — no waiting, no yielding — must see the same static ranking and the
        // provider parked in its pending state, because ranking never calls JavaScript
        // and the host never awaits a provider.
        host.setPaletteQuery("anything")
        let after = host.commandIndex
            .rank(query: "", now: Date(timeIntervalSince1970: 0))
            .map(\.command.id)
        XCTAssertEqual(after, before)
        XCTAssertEqual(host.paletteSections.map(\.isPending), [true])
        XCTAssertEqual(host.paletteSections.first?.results, [])

        // The provider never answers; it stays pending instead of ever blocking.
        for _ in 0 ..< 50 { await Task.yield() }
        XCTAssertEqual(host.paletteSections.map(\.isPending), [true])
        await host.shutdown()
    }

    @MainActor
    func testResultsFollowTheCurrentQueryAndRetirementRemovesThem() async throws {
        let fixture = try makeHostFixture(
            mainJS: """
            tenon.intents.handle("\(Self.intentName)", async function () { return {}; });
            tenon.palette.registerProvider("echo", { title: "Echo" });
            tenon.palette.onQuery("echo", function (query) {
              tenon.palette.setResults("echo", query.revision, [
                {
                  id: "echo-" + query.text,
                  title: "Echo " + query.text,
                  intent: { name: "\(Self.intentName)", input: { text: query.text } }
                }
              ]);
            });
            """
        )
        defer { fixture.tearDown() }
        let host = fixture.host
        try await host.loadAll()
        await waitUntil { host.paletteSections.count == 1 }

        host.setPaletteQuery("one")
        await waitUntil {
            host.paletteSections.first?.results.map(\.id) == ["echo-one"]
        }
        XCTAssertEqual(host.paletteSections.first?.isPending, false)

        host.setPaletteQuery("two")
        await waitUntil {
            host.paletteSections.first?.results.map(\.id) == ["echo-two"]
        }

        // Disabling the plugin retires its generation: its contributions leave the
        // palette with it. A late answer from that generation has no session to land
        // in — `PluginHost.accept` drops snapshots whose identity is not current.
        try await host.setEnabled(false, pluginID: Self.pluginIdentity)
        await waitUntil { host.paletteSections.isEmpty }

        try await host.setEnabled(true, pluginID: Self.pluginIdentity)
        await waitUntil { host.paletteSections.count == 1 }
        await host.shutdown()
    }

    // MARK: - Helpers

    private func makeRuntime(source: String) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-palette-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = try PluginManifest(
            id: Self.pluginIdentity,
            name: "palette-tests",
            version: "1",
            intents: PluginIntentManifest(
                provides: [
                    PluginIntentProvision(
                        name: try IntentID(Self.intentName),
                        title: "Open",
                        audiences: [.plugin, .palette],
                        effects: try IntentEffects(
                            kind: .read,
                            idempotency: .none,
                            retentionMilliseconds: nil,
                            confirmation: .never,
                            external: false
                        ),
                        inputSchema: .object([
                            "$schema": .string(
                                "https://json-schema.org/draft/2020-12/schema"
                            ),
                            "type": .string("object"),
                        ]),
                        outputSchema: .object([
                            "$schema": .string(
                                "https://json-schema.org/draft/2020-12/schema"
                            ),
                            "type": .string("object"),
                        ])
                    ),
                ]
            )
        )
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in
                        .failure(
                            error: IntentError(
                                code: .kernel(.providerUnavailable),
                                details: nil,
                                retryable: false,
                                retryAfterMilliseconds: nil,
                                outcome: .notStarted
                            ),
                            requestID: UUID(),
                            providerID: nil
                        )
                    },
                    list: { .array([]) }
                )
            )
        )
    }

    private struct HostFixture {
        let host: PluginHost
        let root: URL
        let stateRoot: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateRoot)
        }
    }

    @MainActor
    private func makeHostFixture(mainJS: String) throws -> HostFixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-palette-host-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = base.appendingPathComponent("plugins", isDirectory: true)
        let stateRoot = base.appendingPathComponent("state", isDirectory: true)
        let pluginDirectory = root.appendingPathComponent(
            "palette-tests",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        let manifest = """
        {
          "id": "\(Self.pluginID)",
          "name": "palette-tests",
          "version": "1",
          "intents": {
            "uses": [],
            "provides": [
              {
                "name": "\(Self.intentName)",
                "title": "Open",
                "audiences": ["plugin", "palette"],
                "effects": {
                  "kind": "read",
                  "idempotency": "none",
                  "confirmation": "never",
                  "external": false
                },
                "inputSchema": {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "type": "object"
                },
                "outputSchema": {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "type": "object"
                },
                "palette": {
                  "category": "Tests",
                  "keywords": []
                }
              }
            ]
          }
        }
        """
        try manifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try mainJS.write(
            to: pluginDirectory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try PluginHost(
            pluginsRoot: root,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory
        )
        return HostFixture(host: host, root: base, stateRoot: stateRoot)
    }

    private func eventually(
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

    @MainActor
    private func waitUntil(
        attempts: Int = 2_000,
        predicate: () async -> Bool
    ) async {
        for _ in 0 ..< attempts {
            if await predicate() {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition did not become true")
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected the expression to throw")
    } catch {
        handler(error)
    }
}
