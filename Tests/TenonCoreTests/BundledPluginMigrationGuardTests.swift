import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
import TenonIntentCore
import XCTest

/// Guards the bundled-Swift replacement boundary: every shipped compiled plugin must delete
/// its JavaScript entrypoint in the same change. View callback behavior is covered by
/// `BundledPluginViewRoutingTests`, which exercises the compiled runtime directly alongside
/// the shipped view ports.
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
        "dev.tenon.browser",
        "dev.tenon.hello-palette",
        "dev.tenon.file-explorer",
        "dev.tenon.claude-sessions",
        "dev.tenon.git",
        "dev.tenon.kanban",
        "dev.tenon.view-gallery",
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
