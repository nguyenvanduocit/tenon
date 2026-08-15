import Foundation
@testable import TenonBundledPlugins
import TenonIntentCore
import XCTest
@testable import TenonCore

/// Runtime truth, not a regex over source: the real shipped `file-explorer` and `git`
/// runtimes are evaluated with their real manifests, and asked whether they actually register
/// a subscription for the pane-directory fact.
///
/// This is the half of T-030 that a plugin owns. It is deliberately assertable without the
/// publisher being wired, so "the plugins will re-root when the event lands" is evidence
/// rather than a claim.
final class PaneCwdSubscriptionTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    func testTheFileExplorerSubscribesToThePaneDirectoryFact() async throws {
        try await assertSubscribes(plugin: "file-explorer", to: "pane.cwd-changed")
    }

    func testTheGitPanelSubscribesToThePaneDirectoryFact() async throws {
        try await assertSubscribes(plugin: "git", to: "pane.cwd-changed")
    }

    /// Both panels also follow focus: without this they would re-root for whichever pane
    /// last moved, rather than the pane the human is working in.
    func testBothPanelsAlsoFollowTheFocusedPane() async throws {
        try await assertSubscribes(plugin: "file-explorer", to: "workspace.slot-focused")
        try await assertSubscribes(plugin: "git", to: "workspace.slot-focused")
    }

    /// The event carries a directory, so it must NOT be named into the `terminal.` prefix
    /// that `PluginHost.emit` gates behind the `terminal.read` permission. Neither panel
    /// asks for that permission, and neither should have to in order to know where it is.
    func testNeitherPanelNeedsTerminalReadToLearnItsDirectory() throws {
        for plugin in ["file-explorer", "git"] {
            let manifest = try PluginLoader.loadManifest(
                at: Self.pluginsRoot.appendingPathComponent(plugin, isDirectory: true)
            )
            XCTAssertFalse(
                manifest.permissions.contains("terminal.read"),
                """
                \(plugin) must not need permission to read terminal contents just to \
                re-root — that is why the fact is named `pane.cwd-changed`
                """
            )
        }
    }

    // MARK: - Helper

    private func assertSubscribes(
        plugin: String,
        to event: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let directory = Self.pluginsRoot.appendingPathComponent(plugin, isDirectory: true)
        let configuration = PluginRuntimeConfiguration(
            manifest: try PluginLoader.loadManifest(at: directory),
            directory: directory,
            intents: PluginRuntimeIntentBridge(
                // The plugin's start-up work fails closed here; the subscriptions it
                // registers at module scope are what this asserts.
                send: { _ in Self.unavailable() },
                list: { .array([]) }
            )
        )
        let runtime: any PluginHostRuntime
        if plugin == "git" {
            runtime = BundledPluginRuntimeActor(
                configuration: configuration,
                program: GitPlugin.makeProgram(),
                watcherStart: { _ in false }
            )
        } else {
            runtime = try await BundledPluginRuntime.factory.make(configuration)
        }
        _ = try await runtime.start()
        let handles = await runtime.handles(event: event)
        XCTAssertTrue(
            handles,
            "\(plugin) does not observe \(event)",
            file: file,
            line: line
        )
        _ = await runtime.shutdown(timeout: 2)
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
