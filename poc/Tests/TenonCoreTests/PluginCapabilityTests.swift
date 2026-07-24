import XCTest
@testable import TenonCore

/// The gated capability APIs on `tenon` — fs, process, terminal writes (VISION §5:
/// permissions exist only for sensitive capabilities). Every capability gets a
/// blocked/allowed pair, all enforced at the single gate in `PluginRuntime.installAPI`:
/// a blocked call returns `{ok: false, error}` AND reports a deduped violation —
/// never a throw, never a silent `undefined`.
final class PluginCapabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-capability-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writePlugin(dir: String, manifest: String, js: String) throws -> URL {
        let pluginDir = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try js.write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return pluginDir
    }

    // MARK: - The permission list and API version

    func testKnownPermissionsCoverExactlyTheGatedCapabilities() {
        XCTAssertEqual(PluginManifest.knownPermissions, [
            "terminal.read",
            "terminal.write",
            "filesystem.read",
            "filesystem.write",
            "process.exec",
            "workspace.control",
        ])
    }

    func testApiVersionIs02() throws {
        try writePlugin(dir: "versioned", manifest: #"{"name":"versioned","version":"1"}"#, js: "// noop")
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        let runtime = try XCTUnwrap(host.runtime(named: "versioned"))
        XCTAssertEqual(runtime.evaluateForTesting("tenon.apiVersion")?.toString(), "0.2")
    }

    // MARK: - tenon.fs.* reads (filesystem.read)

    func testFsReadApisAreBlockedWithoutFilesystemRead() throws {
        try writePlugin(
            dir: "fsdenied",
            manifest: #"{"name":"fsdenied","version":"1","permissions":[]}"#,
            js: """
            var d = tenon.fs.readDir("\(root.path)");
            var f = tenon.fs.readFile("\(root.path)/nope.txt");
            var e = tenon.fs.exists("\(root.path)");
            tenon.log("readDir ok=" + d.ok + " readFile ok=" + f.ok + " exists ok=" + e.ok);
            tenon.log("errors=" + [d.error, f.error, e.error].join("|"));
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        // Every blocked call returned an explicit {ok: false, error}…
        XCTAssertTrue(host.log.contains("[fsdenied] readDir ok=false readFile ok=false exists ok=false"),
                      "log: \(host.log)")
        let errors = try XCTUnwrap(host.log.first { $0.contains("errors=") })
        XCTAssertEqual(errors.components(separatedBy: "filesystem.read").count - 1, 3,
                       "each error must name the missing permission: \(errors)")

        // …each API reported its violation with the manifest fix, and the plugin survived.
        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations.count, 3)
        for violation in snapshot.permissionViolations {
            XCTAssertTrue(violation.contains("filesystem.read"), violation)
            XCTAssertTrue(violation.contains("manifest.json"), violation)
        }
        XCTAssertTrue(snapshot.isLoaded)
    }

    func testRepeatedFsViolationIsReportedOnce() throws {
        try writePlugin(
            dir: "fsspam",
            manifest: #"{"name":"fsspam","version":"1","permissions":[]}"#,
            js: """
            for (var i = 0; i < 4; i++) {
              tenon.fs.readFile("/etc/hosts");
            }
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertEqual(host.plugins.first?.permissionViolations.count, 1)
        XCTAssertEqual(host.log.filter { $0.contains("⛔") }.count, 1)
        XCTAssertEqual(host.plugins.first?.isLoaded, true)
    }

    func testFsReadApisWorkWithFilesystemRead() throws {
        let dataDir = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try "hello fs".write(to: dataDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        try writePlugin(
            dir: "fsreader",
            manifest: #"{"name":"fsreader","version":"1","permissions":["filesystem.read"]}"#,
            js: """
            var d = tenon.fs.readDir("\(dataDir.path)");
            tenon.log("dir ok=" + d.ok + " entries=" + d.entries.map(function (e) {
              return e.name + ":" + e.isDirectory;
            }).join(","));
            var f = tenon.fs.readFile("\(dataDir.path)/a.txt");
            tenon.log("file ok=" + f.ok + " content=" + f.content);
            var e1 = tenon.fs.exists("\(dataDir.path)/a.txt");
            var e2 = tenon.fs.exists("\(dataDir.path)/missing.txt");
            tenon.log("exists=" + e1.exists + " missing=" + e2.exists);
            var home = tenon.fs.readDir("~");
            tenon.log("home ok=" + home.ok);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        // Sorted by name, directories flagged.
        XCTAssertTrue(host.log.contains("[fsreader] dir ok=true entries=a.txt:false,sub:true"), "log: \(host.log)")
        XCTAssertTrue(host.log.contains("[fsreader] file ok=true content=hello fs"), "log: \(host.log)")
        XCTAssertTrue(host.log.contains("[fsreader] exists=true missing=false"), "log: \(host.log)")
        // "~" expands to the real home directory.
        XCTAssertTrue(host.log.contains("[fsreader] home ok=true"), "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    // MARK: - tenon.fs.writeFile (filesystem.write)

    func testFsWriteFileIsBlockedWithoutFilesystemWrite() throws {
        // filesystem.read deliberately does NOT grant writes.
        try writePlugin(
            dir: "readonly",
            manifest: #"{"name":"readonly","version":"1","permissions":["filesystem.read"]}"#,
            js: """
            var r = tenon.fs.writeFile("\(root.path)/blocked.txt", "nope");
            tenon.log("write ok=" + r.ok + " error=" + r.error);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains { $0.contains("write ok=false") && $0.contains("filesystem.write") },
                      "log: \(host.log)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked.txt").path),
                       "a blocked write must not touch the disk")
        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations.count, 1)
        XCTAssertTrue(snapshot.isLoaded)
    }

    func testFsWriteFileWorksWithFilesystemWrite() throws {
        let target = root.appendingPathComponent("out.txt")
        try writePlugin(
            dir: "fswriter",
            manifest: #"{"name":"fswriter","version":"1","permissions":["filesystem.write"]}"#,
            js: """
            var r = tenon.fs.writeFile("\(target.path)", "written by plugin");
            tenon.log("write ok=" + r.ok);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains("[fswriter] write ok=true"), "log: \(host.log)")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "written by plugin")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    // MARK: - tenon.process.exec (process.exec)

    func testProcessExecIsBlockedWithoutPermission() throws {
        try writePlugin(
            dir: "execdenied",
            manifest: #"{"name":"execdenied","version":"1","permissions":[]}"#,
            js: """
            tenon.process.exec("/bin/echo", ["hi"], function (r) {
              tenon.log("exec ok=" + r.ok + " error=" + r.error);
            });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        // Blocked exec still calls back — {ok: false}, plus the reported violation.
        XCTAssertTrue(host.log.contains { $0.contains("exec ok=false") && $0.contains("process.exec") },
                      "log: \(host.log)")
        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations.count, 1)
        XCTAssertTrue(snapshot.permissionViolations[0].contains("process.exec"))
        XCTAssertTrue(snapshot.isLoaded)
    }

    func testProcessExecRunsEchoWithPermission() throws {
        try writePlugin(
            dir: "execer",
            manifest: #"{"name":"execer","version":"1","permissions":["process.exec"]}"#,
            js: """
            tenon.process.exec("/bin/echo", ["hi"], function (r) {
              tenon.log("exec ok=" + r.ok + " status=" + r.status + " stdout=" + r.stdout);
            });
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        let ranEcho = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                host.log.contains { $0.contains("exec ok=true status=0 stdout=hi") }
            },
            object: nil
        )

        wait(for: [ranEcho], timeout: 15.0)
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    // MARK: - tenon.terminal.write (terminal.write)

    func testTerminalWriteIsBlockedWithoutPermission() throws {
        try writePlugin(
            dir: "typist",
            manifest: #"{"name":"typist","version":"1","permissions":[]}"#,
            js: """
            var r = tenon.terminal.write("rm -rf /");
            tenon.log("write ok=" + r.ok + " error=" + r.error);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        var received: [String] = []
        host.onTerminalWrite = { received.append($0) }
        host.loadAll()

        XCTAssertEqual(received, [], "a blocked write must never reach the terminal")
        XCTAssertTrue(host.log.contains { $0.contains("write ok=false") && $0.contains("terminal.write") },
                      "log: \(host.log)")
        let snapshot = try XCTUnwrap(host.plugins.first)
        XCTAssertEqual(snapshot.permissionViolations.count, 1)
        XCTAssertTrue(snapshot.isLoaded)
    }

    func testTerminalWriteReachesTheHostWithPermission() throws {
        try writePlugin(
            dir: "writer",
            manifest: #"{"name":"writer","version":"1","permissions":["terminal.write"]}"#,
            js: """
            var r = tenon.terminal.write("echo hello");
            tenon.log("write ok=" + r.ok);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        var received: [String] = []
        host.onTerminalWrite = { received.append($0) }
        host.loadAll()

        XCTAssertEqual(received, ["echo hello"])
        XCTAssertTrue(host.log.contains("[writer] write ok=true"), "log: \(host.log)")
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }

    func testTerminalWriteWithNoTerminalAttachedSaysSo() throws {
        try writePlugin(
            dir: "unplugged",
            manifest: #"{"name":"unplugged","version":"1","permissions":["terminal.write"]}"#,
            js: """
            var r = tenon.terminal.write("echo hello");
            tenon.log("write ok=" + r.ok + " error=" + r.error);
            """
        )
        let host = PluginHost(pluginsRoot: root)
        host.loadAll()

        XCTAssertTrue(host.log.contains("[unplugged] write ok=false error=no terminal attached"),
                      "log: \(host.log)")
        // The permission was declared — a missing terminal is not a violation.
        XCTAssertEqual(host.plugins.first?.permissionViolations, [])
    }
}
