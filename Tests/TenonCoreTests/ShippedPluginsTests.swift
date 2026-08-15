import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
import TenonIntentCore
import XCTest

/// Architecture fitness tests for every plugin implementation that ships with the app.
///
/// JavaScript candidates are inspected source-to-manifest; both backends are then staged
/// through the hybrid factory so exact provider bindings remain a shipped-plugin invariant.
/// Backend-specific boundary fitness lives beside the code shape it constrains.
final class ShippedPluginsTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    func testEveryShippedPluginHasCanonicalIdentityAndValidManifest() throws {
        let records = try shippedPlugins()
        XCTAssertEqual(
            records.map(\.directory.lastPathComponent),
            [
                "browser",
                "claude-sessions",
                "clock",
                "core-commands",
                "file-explorer",
                "git",
                "hello-palette",
                "kanban",
                "view-gallery",
                "workspace-status",
            ]
        )

        for record in records {
            XCTAssertTrue(
                record.manifest.id.rawValue.contains("."),
                "\(record.directory.lastPathComponent) must use a canonical plugin ID"
            )
            XCTAssertEqual(
                record.manifest.name,
                record.directory.lastPathComponent
            )
            XCTAssertTrue(record.manifest.unknownPermissions.isEmpty)
        }
    }

    /// Naming an intent never grants authority (invariant 5), so a compiled plugin that
    /// writes an intent ID its own manifest never declared is a drift the dispatcher would
    /// refuse at runtime — one call path at a time, and only once someone exercises it.
    /// This settles it statically instead, over every versioned ID a plugin's own sources
    /// spell out, whether it reaches `IntentID` directly, through an array, or through a
    /// parameter — `CoreCommandsPlugin` does all three.
    func testEveryCompiledPluginOnlyNamesIntentsItsOwnManifestDeclares() throws {
        let records = try shippedPlugins()
        var checkedPlugins = 0

        for record in records {
            guard record.manifest.runtime == .bundledSwift else { continue }
            let sources = try compiledSources(for: record)
            XCTAssertFalse(
                sources.isEmpty,
                "\(record.directory.lastPathComponent) has no compiled source file"
            )
            checkedPlugins += 1

            let declared = Set(
                record.manifest.intents.uses.map(\.rawValue)
                    + record.manifest.intents.provides.map(\.name.rawValue)
            )
            for (name, source) in sources {
                for intentID in captures(
                    #""([a-z][a-z0-9.-]*\.v[0-9]+)""#,
                    in: source
                ) {
                    XCTAssertTrue(
                        declared.contains(intentID),
                        "\(name) names \(intentID), which "
                            + "\(record.directory.lastPathComponent)'s manifest never declares"
                    )
                }
            }
        }

        XCTAssertEqual(
            checkedPlugins,
            records.count,
            "every shipped plugin is compiled Swift, so every one of them must be checked"
        )
    }

    func testEveryShippedRuntimeStagesAllDeclaredHandlers() async throws {
        for record in try shippedPlugins() {
            let settings = Dictionary(
                uniqueKeysWithValues: record.manifest.settings.compactMap {
                    specification in
                    specification.defaultValue.map {
                        (specification.key, $0.intentValue)
                    }
                }
            )
            let runtime = try await BundledPluginRuntime.factory.make(
                PluginRuntimeConfiguration(
                    manifest: record.manifest,
                    directory: record.directory,
                    intents: PluginRuntimeIntentBridge(
                        send: { _ in Self.unavailableResult() },
                        list: { .array([]) }
                    ),
                    local: PluginRuntimeLocalState(settings: settings)
                )
            )

            do {
                let started = try await runtime.start()
                XCTAssertEqual(
                    Set(started.bindings.map(\.intentID)),
                    Set(record.manifest.intents.provides.map(\.name)),
                    "\(record.directory.lastPathComponent) did not stage every provider"
                )
            } catch {
                _ = await runtime.shutdown(timeout: 2)
                throw error
            }
            let report = await runtime.shutdown(timeout: 2)
            XCTAssertEqual(
                report.executorResult,
                .stopped,
                "\(record.directory.lastPathComponent) did not stop cleanly"
            )
        }
    }

    private struct ShippedPlugin {
        let directory: URL
        let manifest: PluginManifest
    }

    private func shippedPlugins() throws -> [ShippedPlugin] {
        try PluginLoader.discover(in: Self.pluginsRoot)
            .map { directory in
                ShippedPlugin(
                    directory: directory,
                    manifest: try PluginLoader.loadManifest(at: directory)
                )
            }
            .sorted {
                $0.directory.lastPathComponent
                    < $1.directory.lastPathComponent
            }
    }

    /// The compiled sources belonging to one plugin, keyed by file name.
    ///
    /// A plugin's program declares its own `PluginID`, which anchors the group; the files
    /// split out beside it (`ClaudeSessionsScan`, `KanbanBoardView`, `GitStatusParser`)
    /// share that program's file-name prefix. A source that names an intent while matching
    /// no program's prefix would be invisible here, so the group is required to be
    /// non-empty by the caller and the anchor is read from the file rather than guessed.
    private func compiledSources(
        for record: ShippedPlugin
    ) throws -> [(name: String, source: String)] {
        let root = Self.pluginsRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("TenonBundledPlugins")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var contents: [String: String] = [:]
        for file in files {
            contents[file.lastPathComponent] = try String(
                contentsOf: file,
                encoding: .utf8
            )
        }

        let anchor = contents.first { _, source in
            hasMatch(
                #"static let id: PluginID = "\#(record.manifest.id.rawValue)""#,
                in: source
            )
        }
        guard let anchor, let prefix = anchor.key.components(
            separatedBy: "Plugin.swift"
        ).first, !prefix.isEmpty else {
            return []
        }

        return contents
            .filter { $0.key.hasPrefix(prefix) }
            .map { (name: $0.key, source: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func hasMatch(_ pattern: String, in source: String) -> Bool {
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return expression?.firstMatch(
            in: source,
            range: range
        ) != nil
    }

    private func matchCount(
        _ pattern: String,
        in source: String
    ) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        let range = NSRange(source.startIndex..., in: source)
        return expression.numberOfMatches(in: source, range: range)
    }

    private func captures(
        _ pattern: String,
        in source: String
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap {
            match in
            guard let captureRange = Range(match.range(at: 1), in: source)
            else {
                return nil
            }
            return String(source[captureRange])
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
