import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// Architecture fitness tests for the JavaScript that ships with the app.
///
/// These tests intentionally inspect source and manifests together. Adding a public
/// bridge surface or hiding an undeclared intent behind a helper must fail locally
/// before the plugin can ship.
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

    func testShippedSourceUsesOnlyTheCurrentPluginRuntimeSurface() throws {
        let bannedPatterns = [
            #"\btenon\.workspace\b"#,
            #"\btenon\.ui\b"#,
            #"\btenon\.terminal\b"#,
            #"\btenon\.commands\b"#,
            #"\btenon\.web\b"#,
            #"\btenon\.shell\b"#,
            #"\btenon\.clipboard\b"#,
            #"\btenon\.process\.exec\b"#,
            #"\btenon\.fs\.(readDir|trash|mkdir|createFile|rename)\b"#,
            #"\btenon\.timers\.debounce\b"#,
            #"\btenon\.pluginName\b"#,
        ]

        for record in try shippedPlugins() {
            for pattern in bannedPatterns {
                XCTAssertFalse(
                    hasMatch(pattern, in: record.source),
                    "\(record.directory.lastPathComponent) uses banned surface \(pattern)"
                )
            }
        }
    }

    func testEveryLiteralSendAndHandlerMatchesItsManifestExactly() throws {
        for record in try shippedPlugins() {
            let sends = captures(
                #"(?:tenon\.intents|call)\.send\(\s*["']([^"']+)["']"#,
                in: record.source
            )
            let handlers = captures(
                #"tenon\.intents\.handle\(\s*["']([^"']+)["']"#,
                in: record.source
            )
            let uses = record.manifest.intents.uses.map(\.rawValue)
            let provides = record.manifest.intents.provides.map {
                $0.name.rawValue
            }

            XCTAssertEqual(
                matchCount(
                    #"(?:tenon\.intents|call)\.send\("#,
                    in: record.source
                ),
                sends.count,
                "\(record.directory.lastPathComponent) must send literal intent IDs"
            )
            XCTAssertEqual(
                matchCount(
                    #"tenon\.intents\.handle\("#,
                    in: record.source
                ),
                handlers.count,
                "\(record.directory.lastPathComponent) must handle literal intent IDs"
            )
            XCTAssertEqual(
                Set(sends),
                Set(uses),
                "\(record.directory.lastPathComponent) send declarations drifted"
            )
            XCTAssertEqual(
                Set(handlers),
                Set(provides),
                "\(record.directory.lastPathComponent) handler declarations drifted"
            )
            XCTAssertEqual(
                handlers.count,
                Set(handlers).count,
                "\(record.directory.lastPathComponent) binds one handler more than once"
            )
            XCTAssertEqual(
                provides.count,
                Set(provides).count,
                "\(record.directory.lastPathComponent) provides one contract more than once"
            )
        }
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
            let runtime = try PluginRuntime(
                configuration: PluginRuntimeConfiguration(
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
                _ = await runtime.shutdown()
                throw error
            }
            let report = await runtime.shutdown()
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
        let source: String
    }

    private func shippedPlugins() throws -> [ShippedPlugin] {
        try PluginLoader.discover(in: Self.pluginsRoot)
            .map { directory in
                let sourceURL = directory.appendingPathComponent("main.js")
                return ShippedPlugin(
                    directory: directory,
                    manifest: try PluginLoader.loadManifest(at: directory),
                    source: try String(
                        contentsOf: sourceURL,
                        encoding: .utf8
                    )
                )
            }
            .sorted {
                $0.directory.lastPathComponent
                    < $1.directory.lastPathComponent
            }
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
