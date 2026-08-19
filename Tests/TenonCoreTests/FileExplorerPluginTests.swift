import Foundation
@testable import TenonBundledPlugins
import TenonIntentCore
import XCTest
@testable import TenonCore

final class FileExplorerPluginTests: XCTestCase {
    private static var pluginDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins/file-explorer")
    }

    private static let instanceID = "AAAAAAAA-0000-0000-0000-00000000FE01"

    func testTreeKeepsDirectoryFirstHidesDotGitAndPublishesMenus() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(root: root)
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)

        let ready = await eventually {
            await runtime.snapshot().views.first?.items.count == 3
        }
        XCTAssertTrue(ready)
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(
            view.items.map(\.label),
            ["src", ".env", "README.md"]
        )
        XCTAssertEqual(view.items.map(\.expanded), [false, nil, nil])
        XCTAssertEqual(
            view.items.first?.menu.map(\.id),
            [
                "open-external",
                "reveal",
                "copy-path",
                "cd",
                "new-file",
                "new-folder",
                "rename",
                "trash",
            ]
        )
        XCTAssertEqual(
            view.items.last?.menu.map(\.id),
            [
                "open",
                "open-side",
                "open-external",
                "reveal",
                "copy-path",
                "rename",
                "trash",
            ]
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testDirectoryExpansionAndOpenActionsUseCanonicalIntents() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(root: root)
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)
        let initialReady = await eventually {
            await runtime.snapshot().views.first?.items.count == 3
        }
        XCTAssertTrue(initialReady)

        let sourceDirectory = root + "/src"
        let selectedDirectory = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: sourceDirectory,
            value: nil
        )
        XCTAssertTrue(selectedDirectory)
        let expanded = await eventually {
            await runtime.snapshot().views.first?.items
                .contains { $0.label == "main.swift" } == true
        }
        XCTAssertTrue(expanded)

        let readme = root + "/README.md"
        let opened = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: readme,
            value: nil
        )
        XCTAssertTrue(opened)
        let openedToSide = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: readme,
            value: .string("open-side")
        )
        XCTAssertTrue(openedToSide)
        let routed = await eventually {
            let requests = await bridge.requests()
            return requests.contains {
                $0.intentID.rawValue == "workspace.content.open.v1"
                    && $0.input.objectValue?["content"]?
                    .objectValue?["path"]?.stringValue == readme
            } && requests.contains {
                $0.intentID.rawValue == "workspace.pane.split.v1"
            } && requests.contains {
                $0.intentID.rawValue == "workspace.pane.content.set.v1"
            }
        }
        XCTAssertTrue(routed)
        let requests = await bridge.requests()
        XCTAssertTrue(
            requests.contains {
                $0.intentID.rawValue == "workspace.content.open.v1"
                    && $0.input.objectValue?["content"]?
                    .objectValue?["path"]?.stringValue == readme
            }
        )
        XCTAssertTrue(
            requests.contains {
                $0.intentID.rawValue == "workspace.pane.split.v1"
            }
        )
        XCTAssertTrue(
            requests.contains {
                $0.intentID.rawValue
                    == "workspace.pane.content.set.v1"
            }
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testCreateRenameTrashAndSystemActionsRemainIntentRouted() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(root: root)
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)
        let ready = await eventually {
            await runtime.snapshot().views.first?.items.count == 3
        }
        XCTAssertTrue(ready)

        let sourceDirectory = root + "/src"
        let newFile = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: sourceDirectory,
            value: .string("new-file")
        )
        XCTAssertTrue(newFile)
        let submitted = try await runtime.invokeViewSubmit(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: "draft",
            text: "helper.swift"
        )
        XCTAssertTrue(submitted)
        let readme = root + "/README.md"
        for action in ["reveal", "copy-path", "open-external", "trash"] {
            let invoked = try await runtime.invokeViewSelect(
                viewID: "tree",
                instanceID: Self.instanceID,
                itemID: readme,
                value: .string(action)
            )
            XCTAssertTrue(invoked)
        }

        let allActionsRouted = await eventually {
            let names = Set(await bridge.requests().map(\.intentID.rawValue))
            return [
                "filesystem.file.create.v1",
                "file.reveal.v1",
                "clipboard.write.v1",
                "file.open.v1",
                "filesystem.path.trash.v1",
            ].allSatisfy(names.contains)
        }
        XCTAssertTrue(allActionsRouted)
        let recorded = await bridge.requests()
        let names = Set(recorded.map(\.intentID.rawValue))
        for expected in [
            "filesystem.file.create.v1",
            "file.reveal.v1",
            "clipboard.write.v1",
            "file.open.v1",
            "filesystem.path.trash.v1",
        ] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - FC-FR-037: Open in Agent

    func testDirectoryMenuOffersOneItemPerInstalledAgentAfterCdHere() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(
            root: root,
            installedAgents: [(id: "claude", label: "Claude"), (id: "codex", label: "Codex")]
        )
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)
        let ready = await eventually {
            await runtime.snapshot().views.first?.items.count == 3
        }
        XCTAssertTrue(ready)

        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(
            view.items.first?.menu.map(\.id),
            [
                "open-external",
                "reveal",
                "copy-path",
                "cd",
                "open-in-agent:claude",
                "open-in-agent:codex",
                "new-file",
                "new-folder",
                "rename",
                "trash",
            ],
            "the first row is 'src', the only directory in this fixture"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testSelectingAnInstalledAgentComposesThenOpensAtThatFolder() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(
            root: root,
            installedAgents: [(id: "claude", label: "Claude")]
        )
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)
        _ = await eventually {
            await runtime.snapshot().views.first?.items.count == 3
        }

        let sourceDirectory = root + "/src"
        let invoked = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: sourceDirectory,
            value: .string("open-in-agent:claude")
        )
        XCTAssertTrue(invoked)

        let routed = await eventually {
            let requests = await bridge.requests()
            return requests.contains { $0.intentID.rawValue == "agent.command.v1" }
                && requests.contains { $0.intentID.rawValue == "terminal.open.v1" }
        }
        XCTAssertTrue(routed)
        let requests = await bridge.requests()
        let composeRequest = try XCTUnwrap(
            requests.first { $0.intentID.rawValue == "agent.command.v1" }
        )
        XCTAssertEqual(composeRequest.input.objectValue?["agent"]?.stringValue, "claude")
        let openRequest = try XCTUnwrap(
            requests.first { $0.intentID.rawValue == "terminal.open.v1" }
        )
        XCTAssertEqual(
            openRequest.input.objectValue?["workingDirectory"]?.stringValue,
            sourceDirectory
        )
        XCTAssertEqual(
            openRequest.input.objectValue?["command"]?.stringValue,
            "claude"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testAnAgentThatFailsToComposeNeverOpensAPane() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(root: root, installedAgents: [])
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)
        _ = await eventually {
            await runtime.snapshot().views.first?.items.count == 3
        }

        let sourceDirectory = root + "/src"
        _ = try await runtime.invokeViewSelect(
            viewID: "tree",
            instanceID: Self.instanceID,
            itemID: sourceDirectory,
            value: .string("open-in-agent:claude")
        )

        let composed = await eventually {
            let requests = await bridge.requests()
            return requests.contains { $0.intentID.rawValue == "agent.command.v1" }
        }
        XCTAssertTrue(composed)
        let requests = await bridge.requests()
        XCTAssertFalse(
            requests.contains { $0.intentID.rawValue == "terminal.open.v1" },
            "a failed composition must never open a pane"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - T-182: mailbox overflow under workspace-event churn

    /// Several panes open, then a sustained (not instantaneous) burst of `"workspace.changed"`
    /// firings — what several open panes plus ordinary workspace churn plausibly generate over
    /// a third of a second — while the old, undebounced handler paid one `owningWorkspace`
    /// intent round trip per open pane on *every single firing*. That unbroken run of round
    /// trips was slow enough to let the burst outrun the 256-slot callback mailbox, which fails
    /// the whole plugin generation permanently — a compiled plugin has no hot-reload path to
    /// recover, so every File Explorer pane opened afterward shows "Plugin view unavailable"
    /// until the app restarts. Red without the debounce in `scheduleWorkspaceOwnershipRecheck`
    /// (verified 2026-08-18: 20 panes, 5 ms/intent, 300 firings at ~1/ms → mailbox overflow).
    func testBurstOfWorkspaceEventsAgainstSeveralOpenPanesNeverFailsTheRuntime() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(root: root, delayMilliseconds: 5)
        let capturedLog = DiagnosticLog()
        let runtime = try await makeRuntime(
            root: root,
            bridge: bridge,
            log: { line in await capturedLog.append(line) }
        )
        _ = try await runtime.start()

        let paneCount = 20
        for index in 0 ..< paneCount {
            try await runtime.openViewInstance(viewID: "tree", instanceID: "pane-\(index)")
        }
        _ = await eventually { await runtime.snapshot().views.count == paneCount }

        let burst = 300
        for _ in 0 ..< burst {
            try? await runtime.deliverEvent(
                event: "workspace.changed",
                payload: .object([:])
            )
            try? await Task.sleep(for: .milliseconds(1))
        }

        // The debounced recheck fires ~250 ms after the burst settles (T-182); give it room
        // rather than asserting the instant the loop above returns.
        try? await Task.sleep(for: .milliseconds(400))
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.phase,
            .active,
            "runtime must survive \(burst) workspace events against \(paneCount) open panes"
        )
        let logLines = await capturedLog.lines()
        XCTAssertFalse(
            logLines.contains { $0.contains("mailbox exceeded") },
            "callback mailbox overflowed: \(logLines)"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    /// The debounce in `scheduleWorkspaceOwnershipRecheck` must still do its job — a single
    /// `"workspace.changed"` firing (no burst) has to eventually re-verify every open pane's
    /// owner, just deferred rather than immediate.
    func testASingleWorkspaceChangedEventualyReverifiesEveryPaneOwner() async throws {
        let root = "/tmp/tenon-file-explorer"
        let bridge = FileExplorerIntentBridge(root: root)
        let runtime = try await makeRuntime(root: root, bridge: bridge)
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "tree", instanceID: Self.instanceID)
        _ = await eventually { await runtime.snapshot().views.first?.items.count == 3 }

        let ownerCallsBeforeEvent = await bridge.requests()
            .filter { $0.intentID.rawValue == "workspace.pane.owner.v1" }.count
        try? await runtime.deliverEvent(event: "workspace.changed", payload: .object([:]))

        let reverified = await eventually(attempts: 400) {
            let calls = await bridge.requests()
                .filter { $0.intentID.rawValue == "workspace.pane.owner.v1" }.count
            return calls > ownerCallsBeforeEvent
        }
        XCTAssertTrue(reverified, "the debounced pass must still re-verify pane ownership")
        _ = await runtime.shutdown(timeout: 2)
    }

    private func makeRuntime(
        root: String,
        bridge: FileExplorerIntentBridge,
        log: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> any PluginHostRuntime {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(
                contentsOf: Self.pluginDirectory
                    .appendingPathComponent("manifest.json")
            )
        )
        return try await BundledPluginRuntime.factory.make(
            PluginRuntimeConfiguration(
                manifest: manifest,
                directory: Self.pluginDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { request in await bridge.send(request) },
                    list: { .array([]) }
                ),
                local: PluginRuntimeLocalState(
                    settings: ["rootPath": .string(root)]
                ),
                log: log
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
}

private actor DiagnosticLog {
    private var recorded: [String] = []

    func append(_ line: String) {
        recorded.append(line)
    }

    func lines() -> [String] {
        recorded
    }
}

private actor FileExplorerIntentBridge {
    private let root: String
    private let installedAgents: [(id: String, label: String)]
    /// Stands in for real filesystem-intent latency (T-182): the instant default never lets
    /// the callback pump fall behind a burst of events, which is exactly the condition under
    /// test.
    private let delayMilliseconds: UInt64
    private var recorded: [PluginIntentSendRequest] = []

    init(
        root: String,
        installedAgents: [(id: String, label: String)] = [],
        delayMilliseconds: UInt64 = 0
    ) {
        self.root = root
        self.installedAgents = installedAgents
        self.delayMilliseconds = delayMilliseconds
    }

    func send(_ request: PluginIntentSendRequest) async -> IntentResult {
        if delayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        recorded.append(request)
        let value: IntentValue
        switch request.intentID.rawValue {
        case "agent.inventory.v1":
            value = .object([
                "agents": .array(installedAgents.map { agent in
                    .object([
                        "id": .string(agent.id),
                        "label": .string(agent.label),
                        "arguments": .array([]),
                        "habit": .null,
                    ])
                }),
            ])
        case "agent.command.v1":
            guard
                let agentID = request.input.objectValue?["agent"]?.stringValue,
                installedAgents.contains(where: { $0.id == agentID })
            else {
                return .failure(
                    error: IntentError(
                        code: .domain(try! IntentDomainErrorCode("dev.tenon.core.agent-unavailable")),
                        details: nil,
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: UUID(),
                    providerID: nil
                )
            }
            value = .object([
                "agent": .string(agentID),
                "commandLine": .string(agentID),
                "arguments": .array([]),
                "handoff": .bool(false),
            ])
        case "terminal.open.v1":
            value = .object(["paneID": .string(UUID().uuidString)])
        case "filesystem.directory.list.v2":
            let path = request.input.objectValue?["path"]?.stringValue
            let entries: [IntentValue]
            if path == root {
                entries = [
                    entry(".env", directory: false),
                    entry("README.md", directory: false),
                    entry("src", directory: true),
                    entry(".git", directory: true),
                ]
            } else if path == root + "/src" {
                entries = [entry("main.swift", directory: false)]
            } else {
                entries = []
            }
            value = .object([
                "entries": .array(entries),
                "nextCursor": .null,
            ])
        case "filesystem.directory.create.v1",
             "filesystem.file.create.v1":
            value = .object([
                "path": request.input.objectValue?["path"] ?? .string(""),
            ])
        case "filesystem.path.move.v1":
            value = .object([
                "path": request.input.objectValue?["destinationPath"]
                    ?? .string(""),
            ])
        default:
            value = .object([:])
        }
        return .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    func requests() -> [PluginIntentSendRequest] {
        recorded
    }

    private func entry(
        _ name: String,
        directory: Bool
    ) -> IntentValue {
        .object([
            "name": .string(name),
            "isDirectory": .bool(directory),
        ])
    }
}
