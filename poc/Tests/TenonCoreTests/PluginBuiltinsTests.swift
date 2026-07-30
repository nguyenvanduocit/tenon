import Foundation
import JavaScriptCore
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginBuiltinsTests: XCTestCase {
    func testEventBridgeBindsFirstHandlerAndUnbindsLastHandlerOnce() throws {
        let mailbox = PluginJavaScriptMailbox()
        let context = try XCTUnwrap(JSContext())
        let nativePost: @convention(block) (String, JSValue) -> Void = {
            topic,
            value in
            mailbox.post(topic: topic, value: value)
        }
        context.setObject(
            nativePost,
            forKeyedSubscript: "__tenonNativePost" as NSString
        )
        context.evaluateScript(PluginRuntimeBootstrap.source)
        context.evaluateScript(
            """
            __tenonStart({
              pluginID: "dev.tenon.event-tests",
              uses: [],
              provides: [],
              settings: {},
              storage: {}
            });
            var handler = function () {};
            var unsubscribeFirst = tenon.events.on("workspace.changed", handler);
            var unsubscribeSecond = tenon.events.on("workspace.changed", handler);
            unsubscribeFirst();
            unsubscribeFirst();
            unsubscribeSecond();
            """
        )
        XCTAssertNil(context.exception)

        XCTAssertEqual(
            mailbox.drain().messages.map(\.topic),
            ["event.bind", "event.unbind"]
        )
    }

    func testRuntimeStopsHandlingEventAfterLastUnsubscribe() async throws {
        let runtime = try makeRuntime(
            source: """
            var handler = function () {};
            globalThis.unsubscribeFirst =
              tenon.events.on("workspace.changed", handler);
            globalThis.unsubscribeSecond =
              tenon.events.on("workspace.changed", handler);
            """
        )
        _ = try await runtime.start()
        var handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertTrue(handlesEvent)

        _ = try await runtime.evaluateForTesting("unsubscribeFirst()")
        handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertTrue(handlesEvent)

        _ = try await runtime.evaluateForTesting("unsubscribeSecond()")
        handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertFalse(handlesEvent)
        _ = await runtime.shutdown()
    }

    func testRuntimeShutdownClearsNativeEventSubscriptions() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.events.on("workspace.changed", function () {});
            """
        )
        _ = try await runtime.start()
        var handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertTrue(handlesEvent)

        _ = await runtime.shutdown()

        handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertFalse(handlesEvent)
    }

    func testRuntimeExportsOnlyTheClassifiedPublicSurface() async throws {
        let runtime = try makeRuntime(
            source: """
            var paths = [];
            Object.getOwnPropertyNames(tenon).forEach(function (key) {
              var value = tenon[key];
              if (value !== null && typeof value === "object") {
                Object.getOwnPropertyNames(value).forEach(function (member) {
                  paths.push("tenon." + key + "." + member);
                });
              } else {
                paths.push("tenon." + key);
              }
            });
            tenon.statusBar.set(paths.sort().join(","));
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.statusBarText,
            [
                "tenon.apiVersion",
                "tenon.events.on",
                "tenon.fs.watch",
                "tenon.intents.handle",
                "tenon.intents.list",
                "tenon.intents.send",
                "tenon.log",
                "tenon.path.basename",
                "tenon.path.dirname",
                "tenon.path.extname",
                "tenon.path.join",
                "tenon.path.normalize",
                "tenon.process.stream",
                "tenon.settings.get",
                "tenon.statusBar.set",
                "tenon.storage.get",
                "tenon.storage.set",
                "tenon.timers.after",
                "tenon.timers.cancel",
                "tenon.timers.every",
                "tenon.views.onClose",
                "tenon.views.onOpen",
                "tenon.views.onSelect",
                "tenon.views.onSubmit",
                "tenon.views.register",
                "tenon.views.set",
            ].joined(separator: ",")
        )
        XCTAssertEqual(
            PluginScopedFacility.allCases.map(\.rawValue).sorted(),
            ["tenon.log", "tenon.settings", "tenon.storage"]
        )
        _ = await runtime.shutdown()
    }

    func testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.statusBar.set(
              typeof console + "|"
                + Object.getOwnPropertyNames(globalThis).sort().join(",")
            );
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let ecmaScriptBuiltins = [
            "AggregateError", "Array", "ArrayBuffer", "Atomics", "BigInt",
            "BigInt64Array", "BigUint64Array", "Boolean", "DataView", "Date",
            "Error", "EvalError", "FinalizationRegistry", "Float16Array",
            "Float32Array", "Float64Array", "Function", "Infinity",
            "Int16Array", "Int32Array", "Int8Array", "Intl", "Iterator",
            "JSON", "Map", "Math", "NaN", "Number", "Object", "Promise",
            "Proxy", "RangeError", "ReferenceError", "Reflect", "RegExp",
            "Set", "String", "Symbol", "SyntaxError", "TypeError", "URIError",
            "Uint16Array", "Uint32Array", "Uint8Array", "Uint8ClampedArray",
            "WeakMap", "WeakRef", "WeakSet", "WebAssembly", "decodeURI",
            "decodeURIComponent", "encodeURI", "encodeURIComponent", "escape",
            "eval", "globalThis", "isFinite", "isNaN", "parseFloat",
            "parseInt", "undefined", "unescape",
        ]
        // The __tenon* hooks are exempt from invariant 1 by decision (T-037):
        // they are the host's only call channel into this generation — looked
        // up on globalThis per call — non-configurable, non-writable, and
        // invoking one can only disturb the calling plugin's own generation.
        let hostCallHooks = [
            "__tenonActivate", "__tenonBeginShutdown", "__tenonCancelProvider",
            "__tenonEmit", "__tenonFireTimer", "__tenonInvokeProvider",
            "__tenonProcessExit", "__tenonProcessOutput",
            "__tenonSettleIntent", "__tenonSettleList",
            "__tenonSettleNestedIntent", "__tenonSettleStorage",
            "__tenonShutdown", "__tenonStart", "__tenonViewClose",
            "__tenonViewOpen", "__tenonViewSelect", "__tenonViewSubmit",
            "__tenonWatchPaths", "__tenonWatchRejected",
        ]
        let reported = try XCTUnwrap(snapshot.statusBarText)
            .components(separatedBy: "|")
        XCTAssertEqual(reported.first, "undefined")
        XCTAssertEqual(
            reported.last?.components(separatedBy: ","),
            (ecmaScriptBuiltins + hostCallHooks + ["tenon"]).sorted()
        )
        _ = await runtime.shutdown()
    }

    func testStoragePublishesToLocalCacheOnlyAfterPersistenceCommits() async throws {
        let persisted = PersistedValues()
        let runtime = try makeRuntime(
            source: """
            tenon.storage.set("answer", tenon.settings.get("seed") + 1)
              .then(function () {
                tenon.statusBar.set([
                  tenon.path.join("/a", "b", "c.txt"),
                  tenon.path.normalize("/a/./b/../c"),
                  tenon.path.basename("/a/b/c.txt"),
                  tenon.path.dirname("/a/b/c.txt"),
                  tenon.path.extname("/a/b/c.tar.gz"),
                  tenon.storage.get("answer")
                ].join("|"));
              });
            """,
            local: PluginRuntimeLocalState(
                settings: ["seed": .integer(40)],
                storage: ["answer": .integer(1)]
            ),
            persistStorage: { key, value in
                await persisted.set(key, value)
            }
        )
        _ = try await runtime.start()
        let committed = await eventually {
            await runtime.snapshot().statusBarText
                == "/a/b/c.txt|/a/c|c.txt|/a/b|.gz|41"
        }
        XCTAssertTrue(committed)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.statusBarText,
            "/a/b/c.txt|/a/c|c.txt|/a/b|.gz|41"
        )
        let persistedAnswer = await persisted.value(for: "answer")
        XCTAssertEqual(persistedAnswer, .integer(41))
        _ = await runtime.shutdown()
    }

    func testFailedStorageWriteLeavesCommittedCacheVisible() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.storage.set("answer", 2)
              .then(function () { tenon.statusBar.set("unexpected"); })
              .catch(function () {
                tenon.statusBar.set("failed:" + tenon.storage.get("answer"));
              });
            """,
            local: PluginRuntimeLocalState(
                storage: ["answer": .integer(1)]
            ),
            persistStorage: { _, _ in throw StorageTestError.rejected }
        )
        _ = try await runtime.start()
        let rolledBack = await eventually {
            await runtime.snapshot().statusBarText == "failed:1"
        }
        XCTAssertTrue(rolledBack)
        _ = await runtime.shutdown()
    }

    func testStorageWritesCommitFIFOAndShutdownDrainsAcceptedWrite() async throws {
        let persisted = PersistedValues()
        let runtime = try makeRuntime(
            source: """
            Promise.all([
              tenon.storage.set("answer", 1),
              tenon.storage.set("answer", 2)
            ]).then(function () {
              tenon.statusBar.set("committed:" + tenon.storage.get("answer"));
            });
            """,
            persistStorage: { key, value in
                if value == .integer(1) {
                    try await Task.sleep(for: .milliseconds(25))
                }
                await persisted.append(key, value)
            }
        )
        _ = try await runtime.start()
        _ = await runtime.shutdown()
        let writes = await persisted.writes()
        XCTAssertEqual(
            writes,
            [
                PersistedValue(key: "answer", value: .integer(1)),
                PersistedValue(key: "answer", value: .integer(2)),
            ]
        )
    }

    func testSettingsChangedUpdatesLocalValueBeforeHandlersRun() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.events.on("settings.changed", function (event) {
              tenon.statusBar.set(event.key + ":" + tenon.settings.get(event.key));
            });
            """,
            local: PluginRuntimeLocalState(
                settings: ["root": .string("old")]
            )
        )
        _ = try await runtime.start()
        try await runtime.emit(
            event: "settings.changed",
            payload: .object([
                "key": .string("root"),
                "value": .string("new"),
            ])
        )
        let observed = await eventually {
            await runtime.snapshot().statusBarText == "root:new"
        }
        XCTAssertTrue(observed)
        _ = await runtime.shutdown()
    }

    func testIntentScopeAcceptsEntityUUIDsAndRejectsCallerGesture() async throws {
        let workspaceID = UUID()
        let paneID = UUID()
        let request = try PluginRuntimeValueParsing.intentRequest(
            name: .string("workspace.select.v1"),
            input: .null,
            options: .object([
                "scope": .object([
                    "workspaceID": .string(workspaceID.uuidString),
                    "paneID": .string(paneID.uuidString),
                ]),
            ])
        )
        XCTAssertEqual(
            request.scopeOverride,
            InvocationScopeOverride(
                workspaceID: workspaceID,
                paneID: paneID
            )
        )

        let runtime = try makeRuntime(
            source: """
            try {
              tenon.intents.send("workspace.select.v1", null, {
                scope: {
                  userGestureID: "00000000-0000-0000-0000-000000000001"
                }
              });
            } catch (error) {
              tenon.statusBar.set(error.message);
            }
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.statusBarText,
            "intent scope userGestureID is host-owned"
        )
        _ = await runtime.shutdown()
    }

    func testTimersFireAndCancelWithinRuntimeLifetime() async throws {
        let runtime = try makeRuntime(
            source: """
            var count = 0;
            tenon.timers.after(5, function () {
              tenon.statusBar.set("after");
            });
            var handle = tenon.timers.every(10, function () {
              count += 1;
              if (count === 3) {
                tenon.timers.cancel(handle);
                tenon.statusBar.set("every:" + count);
              }
            });
            """
        )
        _ = try await runtime.start()
        let fired = await eventually {
            await runtime.snapshot().statusBarText == "every:3"
        }
        XCTAssertTrue(fired)
        try await Task.sleep(for: .milliseconds(30))
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.statusBarText, "every:3")
        _ = await runtime.shutdown()
    }

    func testRepeatingTimersEnforceTenMillisecondMinimumWithoutRestrictingOneShot() async throws {
        let runtime = try makeRuntime(
            source: """
            const oneShot = tenon.timers.after(0, () => {});
            tenon.timers.cancel(oneShot);
            const acceptedRepeating = tenon.timers.every(10, () => {});
            tenon.timers.cancel(acceptedRepeating);
            try {
              const rejectedRepeating = tenon.timers.every(9, () => {});
              tenon.timers.cancel(rejectedRepeating);
            } catch (error) {
              tenon.statusBar.set(error.message);
            }
            """
        )

        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.statusBarText,
            "tenon.timers.every requires at least 10 milliseconds"
        )
        _ = await runtime.shutdown()
    }

    func testProcessStreamDeliversOwnedOutputBackToRuntime() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.process.stream("/usr/bin/printf", ["stream-ok"], {
              onStdout: function (chunk) {
                tenon.statusBar.set(chunk);
              }
            });
            """,
            permissions: ["process.exec"]
        )
        _ = try await runtime.start()
        let delivered = await eventually {
            await runtime.snapshot().statusBarText == "stream-ok"
        }
        XCTAssertTrue(delivered)
        _ = await runtime.shutdown()
    }

    private func makeRuntime(
        source: String,
        permissions: [String] = [],
        local: PluginRuntimeLocalState = PluginRuntimeLocalState(),
        persistStorage: @escaping PluginRuntimeConfiguration.PersistStorage = {
            _, _ in
        }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-builtins-\(UUID().uuidString)",
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
            id: "dev.tenon.builtins-tests",
            name: "builtins-tests",
            version: "1",
            permissions: permissions
        )
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailable() },
                    list: { .array([]) }
                ),
                local: local,
                persistStorage: persistStorage
            )
        )
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

    private static func unavailable() -> IntentResult {
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
    }
}

private actor PersistedValues {
    private var values: [String: IntentValue] = [:]
    private var orderedWrites: [PersistedValue] = []

    func set(_ key: String, _ value: IntentValue) {
        values[key] = value
        orderedWrites.append(PersistedValue(key: key, value: value))
    }

    func append(_ key: String, _ value: IntentValue) {
        set(key, value)
    }

    func value(for key: String) -> IntentValue? {
        values[key]
    }

    func writes() -> [PersistedValue] {
        orderedWrites
    }
}

private struct PersistedValue: Sendable, Equatable {
    let key: String
    let value: IntentValue
}

private enum StorageTestError: Error {
    case rejected
}
