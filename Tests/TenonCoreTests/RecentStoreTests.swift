import XCTest
@testable import TenonCore

final class RecentStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-recent-\(UUID().uuidString).json")
    }

    private let alpha = UUID()
    private let beta = UUID()
    private let alphaRoot = URL(fileURLWithPath: "/tmp/tenon-alpha", isDirectory: true)
    private let betaRoot = URL(fileURLWithPath: "/tmp/tenon-beta", isDirectory: true)

    // MARK: - Ordering, dedupe, and cap, per workspace

    func testRecordPutsNewestFirstAndDedupesByValue() {
        let store = RecentStore(fileURL: tempFile())
        let tree = SlotContent.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        store.record(tree, for: alpha, root: alphaRoot)
        store.record(.changes, for: alpha, root: alphaRoot)
        store.record(tree, for: alpha, root: alphaRoot) // re-opening moves it back to the front

        XCTAssertEqual(store.recent(for: alpha), [tree, .changes])
    }

    func testDistinctPluginViewsAreDistinctEntries() {
        let store = RecentStore(fileURL: tempFile())
        let a = SlotContent.pluginView(pluginID: "dev.tenon.browser", viewID: "a")
        let b = SlotContent.pluginView(pluginID: "dev.tenon.browser", viewID: "b")
        store.record(a, for: alpha, root: alphaRoot)
        store.record(b, for: alpha, root: alphaRoot)

        XCTAssertEqual(store.recent(for: alpha), [b, a])
    }

    func testCapKeepsOnlyTheNewest() {
        let store = RecentStore(fileURL: tempFile(), limit: 3)
        let tree = SlotContent.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        for content in [SlotContent.terminal, tree, .changes, .automation] {
            store.record(content, for: alpha, root: alphaRoot)
        }

        XCTAssertEqual(store.recent(for: alpha), [.automation, .changes, tree])
    }

    func testEmptyContentIsIgnored() {
        let store = RecentStore(fileURL: tempFile())
        store.record(.empty, for: alpha, root: alphaRoot)

        XCTAssertTrue(store.recent(for: alpha).isEmpty)
    }

    // MARK: - Isolation between two simultaneous workspaces

    func testEachWorkspaceReadsOnlyItsOwnHistory() {
        let store = RecentStore(fileURL: tempFile())
        let sessions = SlotContent.pluginView(pluginID: "dev.tenon.claude-sessions", viewID: "sessions")
        store.record(sessions, for: alpha, root: alphaRoot)
        store.record(.automation, for: beta, root: betaRoot)

        XCTAssertEqual(store.recent(for: alpha), [sessions])
        XCTAssertEqual(store.recent(for: beta), [.automation])
    }

    func testAWorkspaceWithNoHistoryOffersNothingRatherThanAnotherWorkspacesList() {
        let store = RecentStore(fileURL: tempFile())
        store.record(.changes, for: alpha, root: alphaRoot)

        // The state a launcher is in while its workspace is being restored, or the first time
        // a workspace is opened. Falling back to "whatever was recorded last" is the exact
        // leak this store is scoped to prevent.
        XCTAssertTrue(store.recent(for: beta).isEmpty)
        XCTAssertTrue(store.recent(for: UUID()).isEmpty)
    }

    func testTheSameViewKeepsIndependentRecencyInTwoWorkspaces() {
        let store = RecentStore(fileURL: tempFile())
        store.record(.changes, for: alpha, root: alphaRoot)
        store.record(.terminal, for: alpha, root: alphaRoot)
        store.record(.terminal, for: beta, root: betaRoot)
        store.record(.changes, for: beta, root: betaRoot)

        XCTAssertEqual(store.recent(for: alpha), [.terminal, .changes])
        XCTAssertEqual(store.recent(for: beta), [.changes, .terminal])
    }

    func testRapidlyInterleavedRecordsNeverMixTheTwoLists() {
        let store = RecentStore(fileURL: tempFile())
        for step in 0 ..< 8 {
            store.record(step.isMultiple(of: 2) ? .changes : .terminal, for: alpha, root: alphaRoot)
            store.record(.automation, for: beta, root: betaRoot)
            // Read between every write: there is no "current workspace" cursor to go stale,
            // so both answers stay exact no matter how fast the caller alternates.
            XCTAssertFalse(store.recent(for: alpha).contains(.automation))
            XCTAssertEqual(store.recent(for: beta), [.automation])
        }
    }

    func testClearingOneWorkspaceLeavesTheOtherUntouched() {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        store.record(.changes, for: alpha, root: alphaRoot)
        store.record(.automation, for: beta, root: betaRoot)

        store.clear(alpha)

        XCTAssertTrue(store.recent(for: alpha).isEmpty)
        XCTAssertEqual(store.recent(for: beta), [.automation])
        let reloaded = RecentStore(fileURL: file)
        XCTAssertTrue(reloaded.recent(for: alpha).isEmpty)
        XCTAssertEqual(reloaded.recent(for: beta), [.automation])
    }

    func testTheNumberOfRememberedWorkspacesIsBounded() {
        let store = RecentStore(fileURL: tempFile(), workspaceLimit: 2)
        let first = UUID()
        store.record(.terminal, for: first, root: alphaRoot)
        store.record(.changes, for: beta, root: betaRoot)
        store.record(.automation, for: UUID(), root: URL(fileURLWithPath: "/tmp/tenon-third"))

        XCTAssertTrue(store.recent(for: first).isEmpty)
        XCTAssertEqual(store.recent(for: beta), [.changes])
    }

    // MARK: - Persistence

    func testSurvivesReloadFromDiskWithBothWorkspaces() {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        let browser = SlotContent.pluginView(pluginID: "dev.tenon.browser", viewID: "browser")
        store.record(.terminal, for: alpha, root: alphaRoot)
        store.record(.automation, for: alpha, root: alphaRoot)
        store.record(browser, for: beta, root: betaRoot)

        let reloaded = RecentStore(fileURL: file)
        XCTAssertEqual(reloaded.recent(for: alpha), [.automation, .terminal])
        XCTAssertEqual(reloaded.recent(for: beta), [browser])
    }

    func testInvalidPersistedPluginIdentityIsDropped() throws {
        let file = tempFile()
        try Data(
            """
            [{"workspaceId":"\(alpha.uuidString)","root":"/tmp/tenon-alpha",
              "views":[{"type":"pluginView","pluginID":"browser","viewID":"browser"}]}]
            """.utf8
        ).write(to: file)

        XCTAssertTrue(RecentStore(fileURL: file).recent(for: alpha).isEmpty)
    }

    func testPersistsFullManifestIdentityUnderItsWorkspace() throws {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        store.record(
            .pluginView(pluginID: "dev.tenon.browser", viewID: "browser"),
            for: alpha,
            root: alphaRoot
        )

        let data = try Data(contentsOf: file)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(rows.first?["workspaceId"] as? String, alpha.uuidString)
        XCTAssertEqual(rows.first?["root"] as? String, "/tmp/tenon-alpha")
        let views = try XCTUnwrap(rows.first?["views"] as? [[String: String]])
        XCTAssertEqual(views.first?["pluginID"], "dev.tenon.browser")
        XCTAssertNil(views.first?["plugin"])
    }

    func testTheAppGlobalListThisStoreReplacedIsDiscardedRatherThanGuessedAt() throws {
        let file = tempFile()
        // Exactly what the previous, unscoped store wrote: rows with a view type and no
        // workspace at all. Attributing them would put one project's history into whichever
        // workspace happened to be open first.
        try Data(
            #"[{"type":"terminal"},{"type":"changes"}]"#.utf8
        ).write(to: file)

        let store = RecentStore(
            fileURL: file,
            liveWorkspaces: [WorkspaceRoot(id: alpha, path: alphaRoot)]
        )
        XCTAssertTrue(store.recent(for: alpha).isEmpty)
    }

    // MARK: - Adoption: a rebuilt catalog finds its lists again

    func testAListIsAdoptedByTheLiveWorkspaceRootedAtTheSameFolder() {
        let file = tempFile()
        let beforeCatalogLoss = UUID()
        RecentStore(fileURL: file).record(.automation, for: beforeCatalogLoss, root: alphaRoot)

        // The catalog document was declined at launch, so the same folder came back under a
        // new workspace id.
        let store = RecentStore(
            fileURL: file,
            liveWorkspaces: [WorkspaceRoot(id: alpha, path: alphaRoot)]
        )

        XCTAssertEqual(store.recent(for: alpha), [.automation])
        XCTAssertTrue(store.recent(for: beforeCatalogLoss).isEmpty)
        // Adoption is written through, so it happens once and not again on the next launch.
        XCTAssertEqual(RecentStore(fileURL: file).recent(for: alpha), [.automation])
    }

    func testAListWhoseFolderIsNotOpenIsNeverHandedToAnUnrelatedWorkspace() {
        let file = tempFile()
        let orphan = UUID()
        RecentStore(fileURL: file).record(.automation, for: orphan, root: betaRoot)

        let store = RecentStore(
            fileURL: file,
            liveWorkspaces: [WorkspaceRoot(id: alpha, path: alphaRoot)]
        )

        XCTAssertTrue(store.recent(for: alpha).isEmpty)
        // Kept, not destroyed: that workspace may simply be closed right now.
        XCTAssertEqual(store.recent(for: orphan), [.automation])
    }

    func testALiveWorkspaceKeepsItsOwnListInsteadOfAdoptingAStaleOne() throws {
        let file = tempFile()
        let stale = UUID()
        let seed = RecentStore(fileURL: file)
        seed.record(.changes, for: alpha, root: alphaRoot)
        // The stale list is written LAST, so it is the more recent of the two. That is the
        // ordering an adoption without this rule gets wrong: it would file a second list
        // under Alpha's id, ahead of Alpha's own, and Alpha would read the stale one.
        seed.record(.automation, for: stale, root: alphaRoot)

        let store = RecentStore(
            fileURL: file,
            liveWorkspaces: [WorkspaceRoot(id: alpha, path: alphaRoot)]
        )

        XCTAssertEqual(store.recent(for: alpha), [.changes])
        // One workspace, one list. A duplicate id is invisible through `recent(for:)` when
        // the live list happens to sort first, so assert the document itself.
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: file))
                as? [[String: Any]]
        )
        let ids = rows.compactMap { $0["workspaceId"] as? String }
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
    }

    func testTwoWorkspacesOnOneFolderAdoptDistinctLists() {
        let file = tempFile()
        let firstStale = UUID()
        let secondStale = UUID()
        let seed = RecentStore(fileURL: file)
        seed.record(.automation, for: firstStale, root: alphaRoot)
        seed.record(.changes, for: secondStale, root: alphaRoot)

        // Ordered, so which live workspace takes which list is decided the same way every
        // run: newest list to the first live workspace on that folder.
        let store = RecentStore(
            fileURL: file,
            liveWorkspaces: [
                WorkspaceRoot(id: alpha, path: alphaRoot),
                WorkspaceRoot(id: beta, path: alphaRoot),
            ]
        )

        XCTAssertEqual(store.recent(for: alpha), [.changes])
        XCTAssertEqual(store.recent(for: beta), [.automation])
    }

    func testRootMatchingIgnoresTrailingSlashAndPathNoise() {
        let file = tempFile()
        let stale = UUID()
        RecentStore(fileURL: file).record(
            .automation,
            for: stale,
            root: URL(fileURLWithPath: "/tmp/tenon-alpha/", isDirectory: true)
        )

        let store = RecentStore(
            fileURL: file,
            liveWorkspaces: [
                WorkspaceRoot(id: alpha, path: URL(fileURLWithPath: "/tmp/tenon-alpha")),
            ]
        )

        XCTAssertEqual(store.recent(for: alpha), [.automation])
    }

    // MARK: - What the workspace store files, and where

    func testWorkspaceStoreFilesOpenedContentUnderTheWorkspaceThatOwnsThePane() {
        let file = tempFile()
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "One", path: alphaRoot),
            recent: RecentStore(fileURL: file)
        )
        let tree = SlotContent.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        store.addSlot(content: tree)

        let workspaceID = store.catalog.activeWorkspaceID
        XCTAssertEqual(store.recent?.recent(for: workspaceID), [tree])
    }

    func testTwoOpenWorkspacesAccumulateSeparateHistoriesThroughTheStore() throws {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: alphaRoot),
            recent: RecentStore(fileURL: tempFile())
        )
        let alphaID = store.catalog.activeWorkspaceID
        store.addSlot(content: .changes)

        // Adding a workspace also selects it, so the next pane opens in Beta.
        store.addWorkspace(name: "Beta", path: betaRoot)
        let betaID = try XCTUnwrap(store.catalog.workspaces.first { $0.id != alphaID }?.id)
        store.addSlot(content: .automation)

        XCTAssertEqual(store.recent?.recent(for: alphaID), [.changes])
        XCTAssertEqual(store.recent?.recent(for: betaID), [.automation])
    }

    /// The reason attribution reads the mutation's events rather than the selection:
    /// `setSlotContent` addresses a pane anywhere in the catalog, so filling an empty pane in
    /// a workspace that is not selected has to land in THAT workspace's list.
    func testFillingAPaneInAnUnselectedWorkspaceRecordsThereAndNotInTheSelectedOne() throws {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: alphaRoot),
            recent: RecentStore(fileURL: tempFile())
        )
        let alphaID = store.catalog.activeWorkspaceID
        store.addWorkspace(name: "Beta", path: betaRoot)
        let betaID = try XCTUnwrap(store.catalog.workspaces.first { $0.id != alphaID }?.id)
        let betaSlot = try XCTUnwrap(
            store.catalog.workspaces.first { $0.id == betaID }?.tabs.first?.slots.first?.id
        )

        store.selectWorkspace(alphaID)
        XCTAssertEqual(store.catalog.activeWorkspaceID, alphaID)
        store.setSlotContent(betaSlot, .automation)

        XCTAssertEqual(store.recent?.recent(for: betaID), [.automation])
        XCTAssertFalse(store.recent?.recent(for: alphaID).contains(.automation) ?? true)
    }

    func testAMutationThatChangesNothingRecordsNothing() {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: alphaRoot),
            recent: RecentStore(fileURL: tempFile())
        )
        let alphaID = store.catalog.activeWorkspaceID
        store.setSlotContent(UUID(), .changes)

        XCTAssertTrue(store.recent?.recent(for: alphaID).isEmpty ?? false)
    }

    /// A row this build cannot name is dropped, and only that row.
    ///
    /// The list on disk was written by whatever build ran last, so a word it holds may name a
    /// content this one has retired or has not learned yet. Reading it back must lose that one
    /// entry, never the workspace's remaining history and never the file.
    func testARowNamingAContentThisBuildCannotReadIsDroppedAndTheRestSurvives() throws {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        store.record(.changes, for: alpha, root: alphaRoot)
        store.record(.automation, for: alpha, root: alphaRoot)

        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        )
        var bucket = try XCTUnwrap(rows.first)
        var views = try XCTUnwrap(bucket["views"] as? [[String: String]])
        views.insert(["type": "lantern"], at: 0)
        bucket["views"] = views
        rows[0] = bucket
        try JSONSerialization.data(withJSONObject: rows).write(to: file)

        XCTAssertEqual(
            RecentStore(fileURL: file).recent(for: alpha),
            [.automation, .changes],
            "the unreadable row is gone and the two readable ones keep their order"
        )
    }
}
