import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// A compiled generation's own local values, and the two directions that cross its boundary.
///
/// The JavaScript backend has had `testSettingsChangedUpdatesLocalValueBeforeHandlersRun`
/// (`PluginBuiltinsTests.swift`) since settings shipped: the host delivers `settings.changed`,
/// the runtime refreshes the plugin's owned settings cache, and only then does the plugin's
/// handler run — so the handler that asks for the key it was just told about reads the new
/// value, never the one captured at activation. These are that test's compiled twins, plus the
/// half that travels the other way: a program publishing a fact on a channel its own manifest
/// declares.
final class BundledPluginLocalStateTests: XCTestCase {
    private static let pluginID: PluginID = "dev.example.local-state"

    // MARK: - Host → plugin delivery

    func testDeliveredSettingsChangedReachesTheProgramCarryingTheNewValue() async throws {
        let recorder = LocalStateSnapshotRecorder()
        let runtime = try makeRuntime(
            program: makeProgram(
                subscribedEvents: ["settings.changed"],
                activate: { context in
                    BundledPluginContribution(
                        statusBarText: "root:" + Self.text(context.setting("root"))
                    )
                },
                receiveEvent: { event, payload, context in
                    guard event == "settings.changed",
                          case let .object(fields) = payload,
                          case let .string(key)? = fields["key"]
                    else {
                        return nil
                    }
                    return BundledPluginContribution(
                        statusBarText: key + ":" + Self.text(context.setting(key))
                    )
                }
            ),
            local: PluginRuntimeLocalState(settings: ["root": .string("old")]),
            onStateChange: { await recorder.record($0) }
        )

        let started = try await runtime.start()
        XCTAssertEqual(started.snapshot.statusBarText, "root:old")

        try await runtime.deliverEvent(
            event: "settings.changed",
            payload: .object([
                "key": .string("root"),
                "value": .string("new"),
            ])
        )

        let updated = try await recorder.snapshot {
            $0.statusBarText == "root:new"
        }
        XCTAssertEqual(updated.phase, .active)
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - Plugin-owned storage

    /// A storage read answers with the last value the host committed, so a refused write
    /// leaves the previous one standing rather than a value nobody persisted.
    func testStorageReadsTheCommittedValueAndARefusedWriteKeepsThePrevious() async throws {
        let recorder = LocalStateSnapshotRecorder()
        let runtime = try makeRuntime(
            program: makeProgram(
                subscribedEvents: ["poke"],
                receiveEvent: { _, _, context in
                    try await context.setStorageValue("favourite", .string("first"))
                    let committed = Self.text(context.storageValue("favourite"))
                    do {
                        try await context.setStorageValue("favourite", .string("refused"))
                    } catch {
                        // The host refused the write; the read below must still answer.
                    }
                    let afterRefusal = Self.text(context.storageValue("favourite"))
                    return BundledPluginContribution(
                        statusBarText: committed + "/" + afterRefusal
                    )
                }
            ),
            persistStorage: { _, value in
                if value == .string("refused") {
                    throw PluginRuntimeError.runtimeStopped
                }
            },
            onStateChange: { await recorder.record($0) }
        )

        _ = try await runtime.start()
        XCTAssertTrue(runtime.acceptEvent(event: "poke", payload: .object([:])))

        let updated = try await recorder.snapshot {
            $0.statusBarText == "first/first"
        }
        XCTAssertEqual(updated.phase, .active)
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - Plugin → host publication

    func testAProgramPublishesOnlyTheChannelsItsManifestDeclares() async throws {
        let recorder = LocalStateSnapshotRecorder()
        let published = PublishedFactLog()
        let runtime = try makeRuntime(
            program: makeProgram(
                subscribedEvents: ["poke"],
                receiveEvent: { _, _, context in
                    try await context.emit(event: "board.changed", payload: .string("one"))
                    var refusal = "none"
                    do {
                        try await context.emit(event: "smuggled", payload: .string("two"))
                    } catch let error as PluginRuntimeError {
                        refusal = error == .undeclaredEventPublication("smuggled")
                            ? "undeclared"
                            : "other"
                    }
                    return BundledPluginContribution(statusBarText: "refused:" + refusal)
                }
            ),
            publishes: ["board.changed"],
            publishEvent: { event, payload in
                await published.record(event: event, payload: payload)
            },
            onStateChange: { await recorder.record($0) }
        )

        _ = try await runtime.start()
        XCTAssertTrue(runtime.acceptEvent(event: "poke", payload: .object([:])))

        let updated = try await recorder.snapshot {
            $0.statusBarText == "refused:undeclared"
        }
        XCTAssertEqual(updated.phase, .active)
        let facts = await published.facts
        XCTAssertEqual(facts.map(\.event), ["board.changed"])
        XCTAssertEqual(facts.map(\.payload), [.string("one")])
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - Fixture

    private func makeProgram(
        subscribedEvents: Set<String>,
        activate: @escaping BundledPluginProgram.Activate = { _ in .empty },
        receiveEvent: @escaping BundledPluginProgram.ReceiveEvent
    ) -> BundledPluginProgram {
        BundledPluginProgram(
            id: Self.pluginID,
            subscribedEvents: subscribedEvents,
            providedIntents: [],
            activate: activate,
            receiveEvent: receiveEvent,
            invokeIntent: { envelope, _ in
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        )
    }

    private func makeRuntime(
        program: BundledPluginProgram,
        local: PluginRuntimeLocalState = PluginRuntimeLocalState(),
        publishes: [String] = [],
        persistStorage: @escaping PluginRuntimeConfiguration.PersistStorage = { _, _ in },
        publishEvent: @escaping PluginRuntimeConfiguration.PublishEvent = { _, _ in },
        onStateChange: @escaping PluginRuntimeConfiguration.StateChange = { _ in }
    ) throws -> BundledPluginRuntimeActor {
        BundledPluginRuntimeActor(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginManifest(
                    id: program.id,
                    name: "local-state",
                    version: "1.0.0",
                    runtime: .bundledSwift,
                    events: try PluginEventManifest(publishes: publishes)
                ),
                directory: FileManager.default.temporaryDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailableResult() },
                    list: { .array([]) }
                ),
                local: local,
                persistStorage: persistStorage,
                onStateChange: onStateChange,
                publishEvent: publishEvent
            ),
            program: program
        )
    }

    private static func text(_ value: IntentValue?) -> String {
        switch value {
        case let .string(text): text
        case .none: "nil"
        default: "?"
        }
    }

    private static func unavailableResult() -> IntentResult {
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

private actor LocalStateSnapshotRecorder {
    private var snapshots: [PluginRuntimeSnapshot] = []

    func record(_ snapshot: PluginRuntimeSnapshot) {
        snapshots.append(snapshot)
    }

    func snapshot(
        where predicate: @Sendable (PluginRuntimeSnapshot) -> Bool
    ) async throws -> PluginRuntimeSnapshot {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let match = snapshots.first(where: predicate) {
                return match
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalStateTestFailure.timedOut(
            observed: snapshots.compactMap(\.statusBarText)
        )
    }
}

private actor PublishedFactLog {
    struct Fact: Equatable {
        let event: String
        let payload: IntentValue
    }

    private(set) var facts: [Fact] = []

    func record(event: String, payload: IntentValue) {
        facts.append(Fact(event: event, payload: payload))
    }
}

private enum LocalStateTestFailure: Error {
    case timedOut(observed: [String])
}
