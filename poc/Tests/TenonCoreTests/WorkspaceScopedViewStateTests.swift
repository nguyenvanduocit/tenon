import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-036 regression: a plugin view opened in one workspace keeps state owned by that
/// workspace. Switching the global selection must neither rebind an inactive workspace's
/// view nor wipe its per-instance UI state.
///
/// The real shipped JavaScript runs in a real runtime against a bridge that emulates
/// `workspace.state.v1` for two workspaces, each owning one pane of the view under test.
/// Sharing one runtime per plugin is by design and is not what these tests reject; what
/// they reject is view-instance state riding on that runtime without workspace identity.
final class WorkspaceScopedViewStateTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    private enum Fixture {
        static let workspaceA = "AAAAAAAA-0000-0000-0000-000000000001"
        static let workspaceB = "BBBBBBBB-0000-0000-0000-000000000002"
        static let tabA = "AAAAAAAA-1111-0000-0000-000000000001"
        static let tabB = "BBBBBBBB-1111-0000-0000-000000000002"
        static let paneA = "AAAAAAAA-2222-0000-0000-000000000001"
        static let paneB = "BBBBBBBB-2222-0000-0000-000000000002"
    }

    // MARK: - File Browser (the reported defect)

    func testFileBrowserStateStaysWithItsWorkspaceWhenSelectionChanges() async throws {
        let rootA = "/tmp/tenon-t036-ws-a"
        let rootB = "/tmp/tenon-t036-ws-b"
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.file-explorer", viewID: "tree"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "filesystem.directory.list.v1" else {
                    return nil
                }
                let path = request.input.objectValue?["path"]?.stringValue
                func entry(_ name: String, directory: Bool) -> IntentValue {
                    .object(["name": .string(name), "isDirectory": .bool(directory)])
                }
                let entries: [IntentValue]
                switch path {
                case rootA:
                    entries = [entry("src-a", directory: true), entry("a.txt", directory: false)]
                case rootA + "/src-a":
                    entries = [entry("main-a.swift", directory: false)]
                case rootB:
                    entries = [entry("b.txt", directory: false)]
                default:
                    entries = []
                }
                return .object(["entries": .array(entries), "nextCursor": .null])
            }
        )
        let runtime = try makeRuntime(plugin: "file-explorer", bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("tree")
        XCTAssertTrue(
            instanced,
            "file-explorer must opt into per-pane instances — a singleton view cannot keep independent per-workspace state"
        )
        try await runtime.openViewInstance(viewID: "tree", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "tree", instanceID: Fixture.paneB)

        // Each pane is rooted at the workspace that OWNS it, even though A is selected.
        let bothRooted = await eventually {
            let views = await runtime.snapshot().views
            let a = views.first { $0.instanceID == Fixture.paneA }
            let b = views.first { $0.instanceID == Fixture.paneB }
            return a?.subtitle == rootA && b?.subtitle == rootB
        }
        XCTAssertTrue(
            bothRooted,
            "each File Browser pane must root at its owning workspace, not the selected one"
        )

        // Give A's tree per-instance UI state: expand a directory.
        _ = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Fixture.paneA,
            itemID: rootA + "/src-a"
        )
        let expanded = await eventually {
            await self.items(of: runtime, instance: Fixture.paneA)
                .contains { $0.label == "main-a.swift" }
        }
        XCTAssertTrue(expanded)

        // Switch the global selection to B, then back — the repro from the task file.
        for selected in [Fixture.workspaceB, Fixture.workspaceA] {
            await bridge.select(selected)
            try await runtime.emit(
                event: "workspace.selected",
                payload: .object(["workspaceId": .string(selected)])
            )
            try? await Task.sleep(for: .milliseconds(150))

            let views = await runtime.snapshot().views
            let a = views.first { $0.instanceID == Fixture.paneA }
            let b = views.first { $0.instanceID == Fixture.paneB }
            XCTAssertEqual(
                a?.subtitle,
                rootA,
                "A's browser must not follow the selection (selected: \(selected))"
            )
            XCTAssertEqual(
                b?.subtitle,
                rootB,
                "B's browser must not follow the selection (selected: \(selected))"
            )
            XCTAssertTrue(
                a?.items.contains { $0.label == "main-a.swift" } == true,
                "A's expansion state must survive the selection change (selected: \(selected))"
            )
        }
        _ = await runtime.shutdown()
    }

    // MARK: - Git panel

    func testGitPanelBindsEachPaneToItsOwnWorkspaceRepository() async throws {
        let rootA = try makeTemporaryDirectory(suffix: "repo-a")
        let rootB = try makeTemporaryDirectory(suffix: "repo-b")
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.git", viewID: "git"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                let input = request.input.objectValue
                let arguments = input?["arguments"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
                let workingDirectory = input?["workingDirectory"]?.stringValue ?? "/"
                func inline(_ text: String) -> IntentValue {
                    .object(["kind": .string("inline"), "text": .string(text)])
                }
                func exec(_ stdout: String) -> IntentValue {
                    .object([
                        "exitCode": .integer(0),
                        "standardOutput": inline(stdout),
                        "standardError": inline(""),
                    ])
                }
                switch arguments.first {
                case "rev-parse":
                    return exec(workingDirectory + "\n")
                case "status":
                    let branch = "branch-" + (workingDirectory as NSString).lastPathComponent
                    return exec("# branch.oid 1234567\u{0}# branch.head \(branch)\u{0}")
                default:
                    return exec("")
                }
            }
        )
        let runtime = try makeRuntime(plugin: "git", bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("git")
        XCTAssertTrue(
            instanced,
            "git must opt into per-pane instances — a singleton panel cannot show two workspaces' repos"
        )
        try await runtime.openViewInstance(viewID: "git", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "git", instanceID: Fixture.paneB)

        let bothBound = await eventually {
            let repoA = await self.paneState(of: runtime, instance: Fixture.paneA, key: "repoPath")
            let repoB = await self.paneState(of: runtime, instance: Fixture.paneB, key: "repoPath")
            return repoA == rootA && repoB == rootB
        }
        XCTAssertTrue(
            bothBound,
            "each git pane must resolve the repository of its owning workspace"
        )

        await bridge.select(Fixture.workspaceB)
        try await runtime.emit(
            event: "workspace.selected",
            payload: .object(["workspaceId": .string(Fixture.workspaceB)])
        )
        try? await Task.sleep(for: .milliseconds(150))
        let repoA = await paneState(of: runtime, instance: Fixture.paneA, key: "repoPath")
        let repoB = await paneState(of: runtime, instance: Fixture.paneB, key: "repoPath")
        XCTAssertEqual(repoA, rootA, "A's git panel must not follow the selection to B")
        XCTAssertEqual(repoB, rootB)
        _ = await runtime.shutdown()
    }

    // MARK: - Claude sessions panel

    func testClaudeSessionsListsEachPanesOwnWorkspaceProject() async throws {
        let rootA = "/tmp/tenon-t036-project-a"
        let rootB = "/tmp/tenon-t036-project-b"
        let bridge = WorkspaceBridge(
            plugin: (id: "dev.tenon.claude-sessions", viewID: "sessions"),
            workspaces: [
                .init(id: Fixture.workspaceA, path: rootA, tabID: Fixture.tabA, paneID: Fixture.paneA),
                .init(id: Fixture.workspaceB, path: rootB, tabID: Fixture.tabB, paneID: Fixture.paneB),
            ],
            selectedID: Fixture.workspaceA,
            respond: { request in
                guard request.intentID.rawValue == "process.exec.v1" else { return nil }
                // The sessions directory does not exist; the scan reports that and keeps
                // the per-instance project binding, which is what this test asserts.
                return .object([
                    "exitCode": .integer(3),
                    "standardOutput": .object([
                        "kind": .string("inline"), "text": .string(""),
                    ]),
                    "standardError": .object([
                        "kind": .string("inline"), "text": .string(""),
                    ]),
                ])
            }
        )
        let runtime = try makeRuntime(plugin: "claude-sessions", bridge: bridge)
        _ = try await runtime.start()

        let instanced = await runtime.isViewInstanced("sessions")
        XCTAssertTrue(
            instanced,
            "claude-sessions must opt into per-pane instances — one shared list cannot serve two workspaces"
        )
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.paneA)
        try await runtime.openViewInstance(viewID: "sessions", instanceID: Fixture.paneB)

        let bothBound = await eventually {
            let projectA = await self.paneState(of: runtime, instance: Fixture.paneA, key: "project")
            let projectB = await self.paneState(of: runtime, instance: Fixture.paneB, key: "project")
            return projectA == rootA && projectB == rootB
        }
        XCTAssertTrue(
            bothBound,
            "each sessions pane must list the project of its owning workspace"
        )

        await bridge.select(Fixture.workspaceB)
        try await runtime.emit(
            event: "workspace.selected",
            payload: .object(["workspaceId": .string(Fixture.workspaceB)])
        )
        try await runtime.emit(event: "workspace.changed", payload: .object([:]))
        try? await Task.sleep(for: .milliseconds(150))
        let projectA = await paneState(of: runtime, instance: Fixture.paneA, key: "project")
        let projectB = await paneState(of: runtime, instance: Fixture.paneB, key: "project")
        XCTAssertEqual(projectA, rootA, "A's sessions panel must not follow the selection to B")
        XCTAssertEqual(projectB, rootB)
        _ = await runtime.shutdown()
    }

    // MARK: - The sweep the task file demands

    /// Workspace-dependent shipped views are instanced; the gallery deliberately shares
    /// one body across panes because its demo content depends on no workspace.
    func testEveryWorkspaceDependentShippedViewOptsIntoInstances() async throws {
        for (plugin, viewID) in [
            ("file-explorer", "tree"),
            ("git", "git"),
            ("claude-sessions", "sessions"),
            ("browser", "browser"),
        ] {
            let runtime = try makeRuntime(
                plugin: plugin,
                bridge: WorkspaceBridge(
                    plugin: (id: "dev.tenon.\(plugin)", viewID: viewID),
                    workspaces: [],
                    selectedID: "",
                    respond: { _ in nil }
                )
            )
            _ = try await runtime.start()
            let instanced = await runtime.isViewInstanced(viewID)
            XCTAssertTrue(instanced, "\(plugin)/\(viewID) leaks state across workspaces without instances")
            _ = await runtime.shutdown()
        }

        let gallery = try makeRuntime(
            plugin: "view-gallery",
            bridge: WorkspaceBridge(
                plugin: (id: "dev.tenon.view-gallery", viewID: "gallery"),
                workspaces: [],
                selectedID: "",
                respond: { _ in nil }
            )
        )
        _ = try await gallery.start()
        let galleryInstanced = await gallery.isViewInstanced("gallery")
        XCTAssertFalse(
            galleryInstanced,
            "the gallery's shared body is deliberate — per-pane sharing must survive this fix"
        )
        _ = await gallery.shutdown()
    }

    // MARK: - Helpers

    private func makeRuntime(
        plugin: String,
        bridge: WorkspaceBridge
    ) throws -> PluginRuntime {
        let directory = Self.pluginsRoot.appendingPathComponent(plugin, isDirectory: true)
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginLoader.loadManifest(at: directory),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { request in await bridge.send(request) },
                    list: { .array([]) }
                )
            )
        )
    }

    private func items(
        of runtime: PluginRuntime,
        instance: String
    ) async -> [PluginRowItem] {
        await runtime.snapshot().views
            .first { $0.instanceID == instance }?.items ?? []
    }

    /// Reads one string field of the plugin's per-instance state through the runtime's
    /// diagnostic hook; every instanced shipped plugin keys that state as `panes[id]`.
    private func paneState(
        of runtime: PluginRuntime,
        instance: String,
        key: String
    ) async -> String? {
        let script = "(panes[\"\(instance)\"] || {})[\"\(key)\"] || null"
        guard let value = try? await runtime.evaluateForTesting(script) else {
            return nil
        }
        return value.stringValue
    }

    private func makeTemporaryDirectory(suffix: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t036-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url.path
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
}

/// Emulates the host's `workspace.state.v1` for a fixed catalog of workspaces, each with
/// one tab and one pane showing the plugin view under test. Every other intent is answered
/// by the test's `respond` closure, or by an empty success so start-up work fails soft.
private actor WorkspaceBridge {
    struct Workspace {
        let id: String
        let path: String
        let tabID: String
        let paneID: String
    }

    private let plugin: (id: String, viewID: String)
    private let workspaces: [Workspace]
    private var selectedID: String
    private let respond: @Sendable (PluginIntentSendRequest) -> IntentValue?
    private var recorded: [PluginIntentSendRequest] = []

    init(
        plugin: (id: String, viewID: String),
        workspaces: [Workspace],
        selectedID: String,
        respond: @escaping @Sendable (PluginIntentSendRequest) -> IntentValue?
    ) {
        self.plugin = plugin
        self.workspaces = workspaces
        self.selectedID = selectedID
        self.respond = respond
    }

    func select(_ workspaceID: String) {
        selectedID = workspaceID
    }

    func requests() -> [PluginIntentSendRequest] {
        recorded
    }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        recorded.append(request)
        let value: IntentValue
        if request.intentID.rawValue == "workspace.state.v1" {
            value = stateValue()
        } else {
            value = respond(request) ?? .object([:])
        }
        return .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    private func stateValue() -> IntentValue {
        var nodes: [IntentValue] = []
        for workspace in workspaces {
            nodes.append(.object([
                "kind": .string("workspace"),
                "id": .string(workspace.id),
                "name": .string((workspace.path as NSString).lastPathComponent),
                "path": .string(workspace.path),
                "selected": .bool(workspace.id == selectedID),
                "activeTabID": .string(workspace.tabID),
            ]))
            nodes.append(.object([
                "kind": .string("tab"),
                "id": .string(workspace.tabID),
                "workspaceID": .string(workspace.id),
                "selected": .bool(true),
                "activePaneID": .string(workspace.paneID),
            ]))
            nodes.append(.object([
                "kind": .string("pane"),
                "id": .string(workspace.paneID),
                "tabID": .string(workspace.tabID),
                "content": .object([
                    "kind": .string("plugin"),
                    "pluginID": .string(plugin.id),
                    "viewID": .string(plugin.viewID),
                ]),
                "frame": .object([
                    "x": .integer(0),
                    "y": .integer(0),
                    "width": .integer(1),
                    "height": .integer(1),
                ]),
            ]))
        }
        return .object([
            "snapshotID": .string(UUID().uuidString),
            "activeWorkspaceID": .string(selectedID),
            "activePaneID": .null,
            "nodes": .array(nodes),
            "nextCursor": .null,
        ])
    }
}
