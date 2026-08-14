import XCTest
@testable import TenonCore

/// T-027: the workspace catalog survives a relaunch. The persisted document, the fail-soft
/// restore rules, launch precedence, and the coalescing durable store are all pure rules,
/// asserted here without a window.
final class WorkspaceCatalogPersistenceTests: XCTestCase {
    // MARK: - Fixtures

    private let alphaPath = URL(fileURLWithPath: "/tmp/tenon-catalog-a", isDirectory: true)
    private let betaPath = URL(fileURLWithPath: "/tmp/tenon-catalog-b", isDirectory: true)

    private let anyDirectory: (String) -> Bool = { _ in true }
    private let anyFile: (String) -> Bool = { _ in true }
    private let anyPluginView: (String, String) -> Bool = { _, _ in true }

    /// Two workspaces, three tabs, one split — the shape the task's launch smoke uses —
    /// with every persistable content kind.
    private func makeRichCatalog() -> (
        catalog: WorkspaceCatalog,
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
        return (catalog, fileSlot.id)
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
        let (catalog, _) = makeRichCatalog()

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
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
    }

    func testAutomationPaneRoundTripsThroughCatalogPersistence() throws {
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: documentJSON(contentJSON: #"{"type":"automation"}"#)
        )
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            decoded,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.catalog.activeTab?.activeSlot?.content, .automation)

        let recaptured = WorkspaceCatalogSnapshot.document(
            capturing: restored.catalog
        )
        let roundTripped = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            recaptured,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))
        XCTAssertEqual(
            roundTripped.catalog.activeTab?.activeSlot?.content,
            .automation
        )
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

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
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
        let (catalog, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
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
    }

    func testRestoreReturnsNothingWhenEveryWorkspaceFolderIsGone() {
        let (catalog, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)

        XCTAssertNil(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: { _ in false },
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))
    }

    func testADeletedFileDegradesThatPaneToEmptyAndKeepsTheCatalog() throws {
        let (catalog, fileSlotID) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)

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
        let (catalog, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: { _, _ in false }
        ))

        let treeSlots = restored.catalog.workspaces[0].tabs[1].slots
        XCTAssertEqual(treeSlots.map(\.content), [.empty])
    }

    /// A newer build's content type, or one this build has retired — the saved document was
    /// written by whatever ran last, so both arrive the same way and both cost exactly the one
    /// pane. The layout it held stays, because the shape of a workspace is not something an
    /// unreadable word should be able to change.
    func testAContentTypeThisBuildCannotNameDegradesThatPaneToEmpty() throws {
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
            capturing: makeRichCatalog().catalog
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

    // MARK: - Launch precedence

    func testABareLaunchRestoresTheSavedCatalogAsSaved() {
        let (catalog, _) = makeRichCatalog()
        let restored = RestoredWorkspaceCatalog(catalog: catalog)

        let launched = WorkspaceCatalogSnapshot.launchCatalog(
            restored: restored,
            launchDirectory: nil,
            launchContent: .terminal,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(launched.catalog, catalog)
    }

    func testAnExplicitLaunchDirectoryMatchingAnOpenWorkspaceSelectsItInsteadOfDuplicatingIt() {
        let (catalog, _) = makeRichCatalog()
        let restored = RestoredWorkspaceCatalog(catalog: catalog)
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
        let (catalog, _) = makeRichCatalog()
        let restored = RestoredWorkspaceCatalog(catalog: catalog)
        let newDirectory = URL(fileURLWithPath: "/tmp/tenon-catalog-c", isDirectory: true)

        let launched = WorkspaceCatalogSnapshot.launchCatalog(
            restored: restored,
            launchDirectory: newDirectory,
            launchContent: .changes,
            fallbackDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(launched.catalog.workspaces.count, 3)
        let added = launched.catalog.workspaces[2]
        XCTAssertEqual(added.path, newDirectory)
        XCTAssertEqual(launched.catalog.activeWorkspaceID, added.id)
        XCTAssertEqual(
            added.tabs.flatMap(\.slots).map(\.content),
            [.changes],
            "the added workspace opens with the configured launch content"
        )
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
        let (catalog, fileSlotID) = makeRichCatalog()

        for _ in 0..<9 {
            await store.noteChange(
                WorkspaceCatalogSnapshot.document(capturing: catalog)
            )
        }
        let last = WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            titles: [fileSlotID: "latest"]
        )
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
        let (catalog, _) = makeRichCatalog()
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)

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
        let (catalog, _) = makeRichCatalog()

        await store.noteChange(
            WorkspaceCatalogSnapshot.document(capturing: catalog)
        )
        await store.flush()

        // The stable sibling lock DurableJSONFile serializes on is the observable proof
        // the write took the locked path rather than a bare `Data.write`.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path + ".lock")
        )
        XCTAssertNotNil(WorkspaceCatalogStore.loadDocument(at: fileURL))
    }

    // MARK: - A tab's number survives a relaunch (T-105)

    /// Numbers that gap are the whole point of the design, so the fixture gaps: a number
    /// restored from position would read `1, 2` and quietly rename the second tab.
    func testATabsNumberSurvivesTheDocumentEvenWhenTheNumbersGap() throws {
        let firstSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .terminal
        )
        let secondSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .terminal
        )
        let first = Tab(slots: [firstSlot], activeSlotID: firstSlot.id, number: 1)
        let second = Tab(slots: [secondSlot], activeSlotID: secondSlot.id, number: 5)
        let workspace = Workspace(
            name: "Alpha",
            path: alphaPath,
            tabs: [first, second],
            activeTabID: first.id
        )
        let catalog = WorkspaceCatalog(workspaces: [workspace], activeWorkspaceID: workspace.id)

        let encoded = try JSONEncoder().encode(
            WorkspaceCatalogSnapshot.document(capturing: catalog)
        )
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            try JSONDecoder().decode(WorkspaceCatalogSnapshot.Document.self, from: encoded),
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.workspaces.first?.tabs.map(\.number),
            [1, 5],
            "a relaunch renamed a tab, which is the defect this number exists to prevent"
        )
        XCTAssertEqual(
            restored.catalog.workspaces.first?.nextTabNumber,
            6,
            "the next tab must not take a number a restored tab already answers to"
        )
    }

    /// A catalog written before tabs had numbers still opens, and the strip it opens with is
    /// where its numbers come from — once. From then on they are recorded like any other.
    func testACatalogWrittenBeforeTabsHadNumbersRestoresInStripOrder() throws {
        let json = Data("""
        {
            "version": 1,
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
                                    "content": {"type": "terminal"}
                                }
                            ]
                        },
                        {
                            "id": "44444444-4444-4444-4444-444444444444",
                            "activeSlotID": "55555555-5555-5555-5555-555555555555",
                            "slots": [
                                {
                                    "id": "55555555-5555-5555-5555-555555555555",
                                    "x": 0, "y": 0, "width": 12, "height": 12,
                                    "content": {"type": "terminal"}
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """.utf8)

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            try JSONDecoder().decode(WorkspaceCatalogSnapshot.Document.self, from: json),
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.workspaces.first?.tabs.map(\.number),
            [1, 2],
            "a catalog with no numbers must open with dense ones in the order it was saved"
        )

        // And they are numbers now, not positions: recapture, reorder, restore.
        var catalog = restored.catalog
        let ids = try XCTUnwrap(catalog.workspaces.first?.tabs.map(\.id))
        _ = catalog.moveTab(ids[0], to: 1)
        let recaptured = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            WorkspaceCatalogSnapshot.document(capturing: catalog),
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))
        XCTAssertEqual(
            recaptured.catalog.workspaces.first?.tabs.map(\.number),
            [2, 1],
            "the numbers must travel with their tabs across the move and the relaunch"
        )
    }

    // MARK: - An agent pane comes back reading its own session  @domain: workspace-model

    /// T-145 / `WS-FR-027`. A pane that was running an agent when the app quit holds the only
    /// route back to that transcript: the pane→session binding lives in memory and dies with
    /// the process. Captured beside the terminal record, it turns the relaunch into the same
    /// reading the session list's "Details" opens — summary, evidence, and `+ Resume`.
    private func agentRef(
        sessionID: String = "9f1c4d10-0000-4000-8000-000000000001",
        path: String = "/tmp/tenon-catalog-a/session.jsonl",
        title: String? = "Wire the restore path"
    ) throws -> AgentSessionRef {
        try XCTUnwrap(AgentSessionRef(
            provider: .claude,
            sessionID: sessionID,
            transcriptPath: path,
            title: title
        ))
    }

    func testAPaneRunningAnAgentIsCapturedAsATerminalCarryingThatSession() throws {
        let agentSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 6, height: 12),
            content: .terminal
        )
        let shellSlot = WorkspaceSlot(
            rect: GridRect(x: 6, y: 0, width: 6, height: 12),
            content: .terminal
        )
        let tab = Tab(slots: [agentSlot, shellSlot], activeSlotID: agentSlot.id)
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
        let ref = try agentRef()

        let document = WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            agentSessions: [agentSlot.id: ref]
        )

        let slots = try XCTUnwrap(document.workspaces.first?.tabs.first?.slots)
        let agentRecord = try XCTUnwrap(slots.first { $0.id == agentSlot.id }).content
        XCTAssertEqual(
            agentRecord.type,
            "terminal",
            "the pane WAS a terminal: an older build reading this file must still get a shell"
        )
        XCTAssertEqual(agentRecord.agentSession?.sessionID, ref.sessionID)
        XCTAssertEqual(agentRecord.agentSession?.transcriptPath, ref.transcriptPath)
        XCTAssertEqual(agentRecord.agentSession?.provider, "claude")
        XCTAssertEqual(agentRecord.agentSession?.title, ref.title)

        let shellRecord = try XCTUnwrap(slots.first { $0.id == shellSlot.id }).content
        XCTAssertNil(
            shellRecord.agentSession,
            "a pane holding a plain shell has no session to come back to"
        )
    }

    func testAnAgentPaneRestoresAsTheRecordedSessionReadingRatherThanABlankShell() throws {
        let agentSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .terminal
        )
        let tab = Tab(slots: [agentSlot], activeSlotID: agentSlot.id)
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
        let ref = try agentRef()

        let document = WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            cwds: [agentSlot.id: alphaPath],
            agentSessions: [agentSlot.id: ref]
        )
        let encoded = try JSONEncoder().encode(document)
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

        XCTAssertEqual(
            restored.catalog.activeTab?.activeSlot?.content,
            .agentSession(ref),
            "the pane comes back reading the session it was running, with resume on it"
        )
        XCTAssertEqual(
            restored.cwds[agentSlot.id],
            alphaPath,
            "resuming spawns a shell, so the directory it spawns into has to survive too"
        )
    }

    func testAnAgentPaneWhoseTranscriptIsGoneComesBackAsATerminalNotABlankPane() throws {
        let agentSlot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .terminal
        )
        let tab = Tab(slots: [agentSlot], activeSlotID: agentSlot.id)
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

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            WorkspaceCatalogSnapshot.document(
                capturing: catalog,
                agentSessions: [agentSlot.id: try agentRef()]
            ),
            isDirectory: anyDirectory,
            isFileReadable: { _ in false },
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.activeTab?.activeSlot?.content,
            .terminal,
            "with no transcript there is nothing to read, and the pane is still a terminal"
        )
    }

    func testATerminalRecordWrittenBeforeSessionsWereCapturedStillRestoresAsATerminal() throws {
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: documentJSON(contentJSON: #"{"type":"terminal"}"#)
        )

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            decoded,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.catalog.activeTab?.activeSlot?.content, .terminal)
    }

    func testAMalformedCapturedSessionLeavesTheTerminalRatherThanTheWholeCatalog() throws {
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: documentJSON(contentJSON: """
            {
                "type": "terminal",
                "agentSession": {
                    "provider": "gemini",
                    "sessionID": "abc",
                    "transcriptPath": "/tmp/tenon-catalog-a/session.jsonl"
                }
            }
            """)
        )

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            decoded,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.activeTab?.activeSlot?.content,
            .terminal,
            "a provider this build cannot name degrades the reading, never the pane"
        )
    }
}
