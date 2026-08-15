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

    private func makeRuntime(
        root: String,
        bridge: FileExplorerIntentBridge
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
                )
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

private actor FileExplorerIntentBridge {
    private let root: String
    private var recorded: [PluginIntentSendRequest] = []

    init(root: String) {
        self.root = root
    }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        recorded.append(request)
        let value: IntentValue
        switch request.intentID.rawValue {
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
