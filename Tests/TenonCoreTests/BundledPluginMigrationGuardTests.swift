import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
import TenonIntentCore
import XCTest

/// Guards the boundary T-155 stated in prose: compiled plugin view callbacks are a follow-up,
/// so no shipped bundled-swift plugin may publish a view until the runtime routes them.
///
/// `ShippedPluginsTests` proves both backends stage their declared handlers; it cannot see
/// this failure mode, because a bundled-swift plugin that publishes views stages cleanly and
/// then drops every select/submit in `BundledPluginRuntimeActor` — working-looking UI whose
/// clicks go nowhere. When view routing lands, the view assertions here are the ones to
/// replace with routing coverage, in the same change.
final class BundledPluginMigrationGuardTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    private static let portedIDs: Set<PluginID> = [
        "dev.tenon.clock",
        "dev.tenon.core-commands",
        "dev.tenon.workspace-status",
    ]

    func testEveryPortedPluginStaysBundledAndRetainsNoJavaScriptEntrypoint() throws {
        let bundled = try bundledSwiftPlugins()
        XCTAssertTrue(
            Self.portedIDs.isSubset(of: Set(bundled.map(\.manifest.id))),
            "a ported plugin regressed to JavaScript: bundled-swift inventory is "
                + "\(bundled.map(\.manifest.id.rawValue).sorted())"
        )
        for record in bundled {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: record.directory
                        .appendingPathComponent("main.js").path
                ),
                "\(record.manifest.id.rawValue) is compiled Swift but still ships main.js; "
                    + "replacement finishes — delete the shadowing entrypoint"
            )
        }
    }

    func testBundledPluginsPublishNoViewsWhileTheRuntimeDropsViewCallbacks() async throws {
        for record in try bundledSwiftPlugins() {
            let runtime = try await BundledPluginRuntime.factory.make(
                configuration(for: record)
            )
            let started = try await runtime.start()
            XCTAssertTrue(
                started.snapshot.views.isEmpty,
                "\(record.manifest.id.rawValue) publishes views "
                    + "\(started.snapshot.views.map(\.viewID)), but the compiled runtime "
                    + "drops every view callback — route select/submit/open/close through "
                    + "BundledPluginProgram first, then replace this guard with routing "
                    + "coverage (T-155 follow-up, docs/plugin-migration-bundled-swift.md)"
            )
            let selectHandled = try await runtime.invokeViewSelect(
                viewID: "any",
                instanceID: nil,
                itemID: "any",
                value: nil
            )
            let submitHandled = try await runtime.invokeViewSubmit(
                viewID: "any",
                instanceID: nil,
                itemID: "any",
                text: ""
            )
            XCTAssertFalse(
                selectHandled || submitHandled,
                "the compiled runtime now handles view callbacks; the views-empty guard "
                    + "above must become routing coverage in this same change"
            )
            let report = await runtime.shutdown(timeout: 2)
            XCTAssertEqual(report.executorResult, .stopped)
        }
    }

    private struct BundledPlugin {
        let directory: URL
        let manifest: PluginManifest
    }

    private func bundledSwiftPlugins() throws -> [BundledPlugin] {
        let bundled = try PluginLoader.discover(in: Self.pluginsRoot)
            .map { directory in
                try BundledPlugin(
                    directory: directory,
                    manifest: PluginLoader.loadManifest(at: directory)
                )
            }
            .filter { $0.manifest.runtime == .bundledSwift }
            .sorted { $0.manifest.id.rawValue < $1.manifest.id.rawValue }
        XCTAssertFalse(
            bundled.isEmpty,
            "the shipped inventory has no bundled-swift plugin, so this guard covers "
                + "nothing — discovery broke or the compiled backend was removed"
        )
        return bundled
    }

    private func configuration(
        for record: BundledPlugin
    ) -> PluginRuntimeConfiguration {
        let settings = Dictionary(
            uniqueKeysWithValues: record.manifest.settings.compactMap {
                specification in
                specification.defaultValue.map {
                    (specification.key, $0.intentValue)
                }
            }
        )
        return PluginRuntimeConfiguration(
            manifest: record.manifest,
            directory: record.directory,
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
            ),
            local: PluginRuntimeLocalState(settings: settings)
        )
    }
}
