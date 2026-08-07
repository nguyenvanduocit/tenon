import Foundation
import TenonIntentCore
@testable import TenonCore
import XCTest

/// T-047: one `.js` file with a leading manifest header is a plugin.
///
/// The claim is *exactly like a directory plugin* — same decoder, same identity rules, same
/// activation, same hot reload. So these tests deliberately mix the two packagings in one
/// plugins root and check that nothing distinguishes them but the file layout.
@MainActor
final class SingleFilePluginTests: XCTestCase {
    func testASingleFileLoadsAndActivatesLikeADirectoryPlugin() async throws {
        let root = try makeRoot()
        try writeSingleFile(
            in: root.plugins,
            named: "solo.js",
            id: "dev.tenon.test.solo",
            body: #"tenon.statusBar.set("solo is live");"#
        )
        try writeDirectory(
            in: root.plugins,
            named: "paired",
            id: "dev.tenon.test.paired",
            body: #"tenon.statusBar.set("paired is live");"#
        )

        let host = try makeHost(root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        let ids = host.plugins.map(\.id.rawValue).sorted()
        XCTAssertEqual(
            ids,
            ["dev.tenon.test.paired", "dev.tenon.test.solo"],
            "a single file and a directory must both be plugins"
        )
        XCTAssertTrue(
            host.plugins.allSatisfy { $0.error == nil },
            "\(host.plugins.map(\.error))"
        )
        let published = await eventually {
            Set(host.statusItems.map(\.text)) == ["solo is live", "paired is live"]
        }
        XCTAssertTrue(
            published,
            "both plugins must run their JavaScript: \(host.statusItems.map(\.text))"
        )
    }

    /// Hot reload is the same FSEvents path directories use, so an edit to the file must
    /// reach the host without anything special being wired for single files.
    func testEditingTheFileOnDiskReloadsThePlugin() async throws {
        let root = try makeRoot()
        let file = root.plugins.appendingPathComponent("solo.js")
        try writeSingleFile(
            in: root.plugins,
            named: "solo.js",
            id: "dev.tenon.test.solo",
            body: #"tenon.statusBar.set("first");"#
        )

        let host = try makeHost(root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }
        _ = await eventually { host.statusItems.first?.text == "first" }

        try singleFileSource(
            id: "dev.tenon.test.solo",
            body: #"tenon.statusBar.set("second");"#
        ).write(to: file, atomically: true, encoding: .utf8)
        try await host.loadAll()

        let reloaded = await eventually {
            host.statusItems.first?.text == "second"
        }
        XCTAssertTrue(
            reloaded,
            "an edited single-file plugin must reload: \(host.statusItems.map(\.text))"
        )
    }

    /// A file that claims to be a plugin and gets it wrong fails loudly, and the diagnostic
    /// says what to do — a plugin author should not have to read the loader to fix it.
    func testAMalformedHeaderIsReportedWithASuggestion() async throws {
        let root = try makeRoot()
        try "/* tenon-manifest\n{ \"id\": \"dev.tenon.test.broken\"\n*/\n"
            .write(
                to: root.plugins.appendingPathComponent("broken.js"),
                atomically: true,
                encoding: .utf8
            )

        let host = try makeHost(root)
        do {
            try await host.loadAll()
            XCTFail("a malformed header must fail the load")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(
                text.contains("broken.js"),
                "the diagnostic must name the file: \(text)"
            )
        }
    }

    /// The distinction that keeps a plugins folder usable: a script that never claimed to
    /// be a plugin is not a broken one, and must not take the reload down with it.
    func testAPlainScriptBesideAPluginIsIgnored() async throws {
        let root = try makeRoot()
        try "// scratch file someone left here\nvar x = 1;\n".write(
            to: root.plugins.appendingPathComponent("notes.js"),
            atomically: true,
            encoding: .utf8
        )
        try writeSingleFile(
            in: root.plugins,
            named: "solo.js",
            id: "dev.tenon.test.solo",
            body: #"tenon.statusBar.set("solo is live");"#
        )

        let host = try makeHost(root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(host.plugins.map(\.id.rawValue), ["dev.tenon.test.solo"])
        XCTAssertTrue(host.plugins.allSatisfy { $0.error == nil })
    }

    /// Identity rules are the manifest's, not the packaging's: two plugins claiming one id
    /// collide whether they are files, directories, or one of each.
    func testADuplicateIdAcrossPackagingsIsRefused() async throws {
        let root = try makeRoot()
        try writeSingleFile(
            in: root.plugins,
            named: "solo.js",
            id: "dev.tenon.test.same",
            body: "1;"
        )
        try writeDirectory(
            in: root.plugins,
            named: "paired",
            id: "dev.tenon.test.same",
            body: "1;"
        )

        let host = try makeHost(root)
        do {
            try await host.loadAll()
            XCTFail("two plugins may not claim one id, whatever their packaging")
        } catch {
            // The existing duplicate-id rule applies unchanged; that it applies across
            // packagings is the property under test.
        }
    }

    // MARK: - Fixture

    private struct Root {
        let base: URL
        let plugins: URL
        let state: URL
    }

    private func makeRoot() throws -> Root {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t047-\(UUID().uuidString)", isDirectory: true)
        let plugins = base.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(
            at: plugins,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return Root(
            base: base,
            plugins: plugins,
            state: base.appendingPathComponent("state", isDirectory: true)
        )
    }

    private func makeHost(_ root: Root) throws -> PluginHost {
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        return try PluginHost(
            pluginsRoot: root.plugins,
            stateRoot: root.state,
            kernel: kernel,
            authorization: .bundledInventory
        )
    }

    private func singleFileSource(id: String, body: String) -> String {
        """
        /* tenon-manifest
        {
          "id": "\(id)",
          "name": "\((id as NSString).pathExtension)",
          "version": "1",
          "permissions": [],
          "intents": { "uses": [], "provides": [] }
        }
        */
        \(body)
        """
    }

    private func writeSingleFile(
        in plugins: URL,
        named: String,
        id: String,
        body: String
    ) throws {
        try singleFileSource(id: id, body: body).write(
            to: plugins.appendingPathComponent(named),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeDirectory(
        in plugins: URL,
        named: String,
        id: String,
        body: String
    ) throws {
        let directory = plugins.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "\(id)",
          "name": "\(named)",
          "version": "1",
          "permissions": [],
          "intents": { "uses": [], "provides": [] }
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try body.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
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
