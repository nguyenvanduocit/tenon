import XCTest
@testable import TenonCore

/// T-027: the workspace catalog survives a relaunch. The persisted document, the fail-soft
/// restore rules, the T-030 project-root pin round-trip, launch precedence, and the
/// coalescing durable store are all pure rules, asserted here without a window.
final class WorkspaceCatalogPersistenceTests: XCTestCase {
    // MARK: - Fixtures

    private let alphaPath = URL(fileURLWithPath: "/tmp/tenon-catalog-a", isDirectory: true)
    private let betaPath = URL(fileURLWithPath: "/tmp/tenon-catalog-b", isDirectory: true)

    private let anyDirectory: (String) -> Bool = { _ in true }
    private let anyFile: (String) -> Bool = { _ in true }
    private let anyPluginView: (String, String) -> Bool = { _, _ in true }

    /// Two workspaces, three tabs, one split — the shape the task's launch smoke uses —
    /// with every persistable content kind and one T-030 pin.
    private func makeRichCatalog() -> (
        catalog: WorkspaceCatalog,
        pins: [UUID: URL],
        fileSlotID: UUID
    ) {
        let terminalSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 6, height: 12),
            content: .terminal
        )
        let fileSlot = WorkspaceSlot(
            rect: GridRect(x: 6, y: 0, width: 6, height: 12),
            content: .file(path: "/tmp/tenon-catalog-a/README.md")
        )
        let splitTab = Tab(
            slots: [terminalSlot, fileSlot],
            activeSlotID: fileSlot.id
        )

        let treeSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        let treeTab = Tab(slots: [treeSlot], activeSlotID: treeSlot.id)

        let alpha = Workspace(
            name: "Alpha",
            path: alphaPath,
            tabs: [splitTab, treeTab],
            activeTabID: treeTab.id
        )

        let diffSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .diff(DiffRequest(
                source: .git(
                    repoPath: "/tmp/tenon-catalog-b",
                    path: "src/main.swift",
                    staged: true,
                    untracked: false,
                    origPath: "src/old.swift"
                ),
                fileName: "main.swift",
                title: "main.swift"
            ))
        )
        let diffTab = Tab(slots: [diffSlot], activeSlotID: diffSlot.id)
        let beta = Workspace(
            name: "Beta",
            path: betaPath,
            tabs: [diffTab],
            activeTabID: diffTab.id
        )

        let catalog = WorkspaceCatalog(
            workspaces: [alpha, beta],
            activeWorkspaceID: beta.id
        )
        let pins = [
            fileSlot.id: URL(fileURLWithPath: "/tmp/tenon-catalog-pin", isDirectory: true),
        ]
        return (catalog, pins, fileSlot.id)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tenon-catalog-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// A complete, well-formed version-1 document as raw JSON, for the decode-side tests
    /// that exercise bytes a Swift encoder would never produce.
    private func documentJSON(
        version: Int = 1,
        contentJSON: String = #"{"type": "terminal"}"#,
        topLevelExtra: String = ""
    ) -> Data {
        Data("""
        {
            "version": \(version),\(topLevelExtra)
            "activeWorkspaceID": "11111111-1111-1111-1111-111111111111",
            "workspaces": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "name": "Alpha",
                    "path": "/tmp/tenon-catalog-a",
                    "activeTabID": "22222222-2222-2222-2222-222222222222",
                    "tabs": [
                        {
                            "id": "22222222-2222-2222-2222-222222222222",
                            "activeSlotID": "33333333-3333-3333-3333-333333333333",
                            "slots": [
                                {
                                    "id": "33333333-3333-3333-3333-333333333333",
                                    "x": 0, "y": 0, "width": 12, "height": 12,
                                    "content": \(contentJSON)
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """.utf8)
    }

    // MARK: - Round trip

    func testCatalogTreeRoundTripsThroughTheDocumentWithAnExplicitSchemaVersion() throws {
        let (catalog, pins, _) = makeRichCatalog()

        let document = WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            pins: pins
        )
        let encoded = try JSONEncoder().encode(document)

        // The explicit schema version is on the wire, not just in the type.
        let topLevel = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(topLevel["version"] as? Int, WorkspaceCatalogSnapshot.version)

        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: encoded
        )
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            decoded,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.catalog, catalog)
        XCTAssertEqual(restored.pins, pins)
    }

    func testAnInlineDiffPaneIsCapturedAsEmptyBecauseItsTextsAreLivePluginState() throws {
        let inlineSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .diff(DiffRequest(
                source: .inline(oldText: "a", newText: "b"),
                fileName: "scratch",
                title: "scratch"
            ))
        )
        let tab = Tab(slots: [inlineSlot], activeSlotID: inlineSlot.id)
        let workspace = Workspace(
            name: "Alpha",
            path: alphaPath,
            tabs: [tab],
            activeTabID: tab.id
        )
        let catalog = WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: [:])
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.slot(id: inlineSlot.id)?.content,
            .empty
        )
    }

    // MARK: - Fail-soft restore, case by case

    func testAWorkspaceWhoseFolderIsGoneIsDroppedWithoutLosingTheOthers() throws {
        let (catalog, pins, fileSlotID) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: pins)
        let betaFolder = betaPath.path

        // Beta — the saved *active* workspace — is gone; Alpha survives untouched.
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: { $0 != betaFolder },
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.catalog.workspaces.map(\.name), ["Alpha"])
        XCTAssertEqual(
            restored.catalog.activeWorkspaceID,
            restored.catalog.workspaces[0].id,
            "the active selection falls back to a surviving workspace"
        )
        XCTAssertEqual(
            restored.pins.keys.sorted(by: { $0.uuidString < $1.uuidString }),
            [fileSlotID],
            "pins of surviving panes stay; nothing lingers for dropped ones"
        )
    }

    func testRestoreReturnsNothingWhenEveryWorkspaceFolderIsGone() {
        let (catalog, pins, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: pins)

        XCTAssertNil(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: { _ in false },
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))
    }

    func testADeletedFileDegradesThatPaneToEmptyAndKeepsTheCatalog() throws {
        let (catalog, pins, fileSlotID) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: pins)

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: { _ in false },
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.catalog.slot(id: fileSlotID)?.content, .empty)
        // The degraded pane keeps its place in the layout…
        XCTAssertEqual(
            restored.catalog.slot(id: fileSlotID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        // …and its neighbours keep their content.
        XCTAssertEqual(restored.catalog.workspaces.count, 2)
        XCTAssertTrue(restored.catalog.workspaces[0].tabs[0].slots
            .contains { $0.content == .terminal })
    }

    func testAnUnknownPluginViewDegradesThatPaneToEmpty() throws {
        let (catalog, pins, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: pins)

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: { _, _ in false }
        ))

        let treeSlots = restored.catalog.workspaces[0].tabs[1].slots
        XCTAssertEqual(treeSlots.map(\.content), [.empty])
    }

    func testAContentTypeFromANewerBuildDegradesThatPaneToEmpty() throws {
        let data = documentJSON(
            contentJSON: #"{"type": "hologram", "wavelength": 550}"#
        )
        let document = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: data
        )

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.workspaces[0].tabs[0].slots.map(\.content),
            [.empty]
        )
    }

    func testUnknownFieldsFromAFutureBuildAreIgnoredEverywhere() throws {
        let data = documentJSON(
            contentJSON: #"{"type": "terminal", "shellProfile": "zsh"}"#,
            topLevelExtra: #" "layoutEngine": "v2", "#
        )

        let document = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: data
        )
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.workspaces[0].tabs[0].slots.map(\.content),
            [.terminal]
        )
    }

    func testADocumentVersionFromANewerBuildIsNotRestoredAndTheFileIsLeftAlone() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent(".workspace-catalog.json")
        let newerBytes = documentJSON(version: 99)
        try newerBytes.write(to: fileURL)

        XCTAssertNil(WorkspaceCatalogStore.loadDocument(at: fileURL))
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            newerBytes,
            "declining to restore must not touch the newer build's file"
        )
    }

    func testACorruptFileRestoresNothingInsteadOfCrashing() throws {
        let dir = try makeTempDir()

        let garbage = dir.appendingPathComponent("garbage.json")
        try Data("not json {{{".utf8).write(to: garbage)
        XCTAssertNil(WorkspaceCatalogStore.loadDocument(at: garbage))

        // Duplicate keys are ambiguity, and persisted state treats ambiguity as corruption.
        let duplicated = dir.appendingPathComponent("duplicated.json")
        try Data(#"{"version": 1, "version": 1, "workspaces": []}"#.utf8)
            .write(to: duplicated)
        XCTAssertNil(WorkspaceCatalogStore.loadDocument(at: duplicated))

        let missing = dir.appendingPathComponent("never-written.json")
        XCTAssertNil(WorkspaceCatalogStore.loadDocument(at: missing))
    }

    func testAStructurallyInvalidTabIsDroppedWithoutDiscardingTheCatalog() throws {
        var document = WorkspaceCatalogSnapshot.document(
            capturing: makeRichCatalog().catalog,
            pins: [:]
        )
        // Corrupt the first tab of Alpha: two slots claiming the same full-grid rect is
        // not a valid spatial layout, and must never reach a domain precondition.
        document.workspaces[0].tabs[0].slots[0].x = 0
        document.workspaces[0].tabs[0].slots[0].width = 12

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.workspaces[0].tabs.count,
            1,
            "the broken tab is dropped, the valid one survives"
        )
        XCTAssertEqual(restored.catalog.workspaces.count, 2)
    }

    // MARK: - T-030 handoff: the project-root pin

    func testTheProjectRootPinRoundTripsVerbatimEvenWhenItsTargetIsGone() throws {
        let (catalog, _, fileSlotID) = makeRichCatalog()
        let vanishedWorktree = URL(
            fileURLWithPath: "/tmp/tenon-worktree-that-was-deleted",
            isDirectory: true
        )

        let document = WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            pins: [fileSlotID: vanishedWorktree]
        )
        // Every existence probe fails except workspace folders: the pin's target is gone
        // AND the pinned pane's file is gone. The pin must still come back verbatim —
        // it is a human override the user can see and clear, so the pane's content
        // degrades but its pin does not.
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: { _ in false },
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.pins[fileSlotID], vanishedWorktree)
        XCTAssertEqual(restored.catalog.slot(id: fileSlotID)?.content, .empty)
    }

    func testAPinForAPaneOutsideTheCatalogIsNotCaptured() {
        let (catalog, _, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            pins: [UUID(): URL(fileURLWithPath: "/tmp/tenon-stale-pin", isDirectory: true)]
        )
        let allPins = document.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.slots.compactMap(\.projectRootPin)
            }
        }
        XCTAssertTrue(allPins.isEmpty)
    }

    // MARK: - Launch precedence

    func testABareLaunchRestoresTheSavedCatalogAsSaved() {
        let (catalog, pins, _) = makeRichCatalog()
        let restored = RestoredWorkspaceCatalog(catalog: catalog, pins: pins)

        let launched = WorkspaceCatalogSnapshot.launchCatalog(
            restored: restored,
            launchDirectory: nil,
            launchContent: .terminal,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(launched.catalog, catalog)
        XCTAssertEqual(launched.pins, pins)
    }

    func testAnExplicitLaunchDirectoryMatchingAnOpenWorkspaceSelectsItInsteadOfDuplicatingIt() {
        let (catalog, pins, _) = makeRichCatalog()
        let restored = RestoredWorkspaceCatalog(catalog: catalog, pins: pins)
        let alphaID = catalog.workspaces[0].id

        let launched = WorkspaceCatalogSnapshot.launchCatalog(
            restored: restored,
            launchDirectory: alphaPath,
            launchContent: .terminal,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(launched.catalog.workspaces.count, 2)
        XCTAssertEqual(launched.catalog.activeWorkspaceID, alphaID)
    }

    func testAnExplicitLaunchDirectoryNotInTheCatalogAddsAWorkspaceInsteadOfReplacingTheTree() {
        let (catalog, pins, _) = makeRichCatalog()
        let restored = RestoredWorkspaceCatalog(catalog: catalog, pins: pins)
        let newDirectory = URL(fileURLWithPath: "/tmp/tenon-catalog-c", isDirectory: true)

        let launched = WorkspaceCatalogSnapshot.launchCatalog(
            restored: restored,
            launchDirectory: newDirectory,
            launchContent: .docs,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(launched.catalog.workspaces.count, 3)
        let added = launched.catalog.workspaces[2]
        XCTAssertEqual(added.path, newDirectory)
        XCTAssertEqual(launched.catalog.activeWorkspaceID, added.id)
        XCTAssertEqual(
            added.tabs.flatMap(\.slots).map(\.content),
            [.docs],
            "the added workspace opens with the configured launch content"
        )
        XCTAssertEqual(launched.pins, pins)
    }

    func testWithNothingRestoredTheLaunchDirectorySeedsAFreshCatalog() {
        let launchDirectory = URL(fileURLWithPath: "/tmp/tenon-catalog-d", isDirectory: true)

        let launched = WorkspaceCatalogSnapshot.launchCatalog(
            restored: nil,
            launchDirectory: launchDirectory,
            launchContent: .terminal,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(launched.catalog.workspaces.count, 1)
        XCTAssertEqual(launched.catalog.workspaces[0].path, launchDirectory)
        XCTAssertTrue(launched.pins.isEmpty)

        let bare = WorkspaceCatalogSnapshot.launchCatalog(
            restored: nil,
            launchDirectory: nil,
            launchContent: .terminal,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        XCTAssertEqual(
            bare.catalog.workspaces[0].path,
            URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
    }

    // MARK: - The durable, coalescing store

    func testRapidMutationsCoalesceIntoASingleWrite() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent(".workspace-catalog.json")
        let store = WorkspaceCatalogStore(
            fileURL: fileURL,
            debounce: .milliseconds(100)
        )
        let (catalog, pins, _) = makeRichCatalog()

        for _ in 0..<9 {
            await store.noteChange(
                WorkspaceCatalogSnapshot.document(capturing: catalog, pins: [:])
            )
        }
        let last = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: pins)
        await store.noteChange(last)

        let wrote = await waitUntil { await store.writeCount == 1 }
        XCTAssertTrue(wrote, "the coalesced write happens after the debounce window")

        // Settle past another full window: ten notes still mean one write, and the
        // write is the last snapshot, not the first.
        try await Task.sleep(for: .milliseconds(250))
        let writeCount = await store.writeCount
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(WorkspaceCatalogStore.loadDocument(at: fileURL), last)
    }

    func testFlushWritesThePendingSnapshotImmediately() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent(".workspace-catalog.json")
        // A debounce far longer than the test: only flush can explain the write.
        let store = WorkspaceCatalogStore(fileURL: fileURL, debounce: .seconds(60))
        let (catalog, pins, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog, pins: pins)

        await store.noteChange(document)
        await store.flush()

        let writeCount = await store.writeCount
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(WorkspaceCatalogStore.loadDocument(at: fileURL), document)
    }

    func testWritesGoThroughTheDurableFileLock() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent(".workspace-catalog.json")
        let store = WorkspaceCatalogStore(fileURL: fileURL, debounce: .seconds(60))
        let (catalog, _, _) = makeRichCatalog()

        await store.noteChange(
            WorkspaceCatalogSnapshot.document(capturing: catalog, pins: [:])
        )
        await store.flush()

        // The stable sibling lock DurableJSONFile serializes on is the observable proof
        // the write took the locked path rather than a bare `Data.write`.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path + ".lock")
        )
        XCTAssertNotNil(WorkspaceCatalogStore.loadDocument(at: fileURL))
    }
}
