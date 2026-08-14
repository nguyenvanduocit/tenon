import Observation
import XCTest
@testable import TenonCore

/// `RecentWorkspaceStore` — the "recently opened workspaces" list behind the sidebar's
/// contextual library. All ordering/cap/persistence rules are pure logic here so they
/// can be asserted without a window.
final class RecentWorkspaceStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-recentws-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testRecordMovesNewestToFrontAndDedupesByPath() {
        let store = RecentWorkspaceStore(fileURL: fileURL)
        store.record(name: "A", path: url("/tmp/a"))
        store.record(name: "B", path: url("/tmp/b"))
        // Re-opening A (even under a renamed label) re-surfaces it, no duplicate.
        store.record(name: "A renamed", path: url("/tmp/a"))

        XCTAssertEqual(store.recent.map(\.path), [url("/tmp/a"), url("/tmp/b")])
        XCTAssertEqual(store.recent.first?.name, "A renamed", "the latest label wins")
    }

    func testRecordDedupesEquivalentFolderURLSpellings() {
        let store = RecentWorkspaceStore(fileURL: fileURL)
        store.record(name: "A", path: url("/tmp/a"))
        store.record(
            name: "A reopened",
            path: URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        )

        XCTAssertEqual(store.recent.count, 1)
        XCTAssertEqual(store.recent.first?.name, "A reopened")
    }

    func testRecordCapsAtLimit() {
        let store = RecentWorkspaceStore(fileURL: fileURL, limit: 3)
        for i in 1...5 {
            store.record(name: "w\(i)", path: url("/tmp/w\(i)"))
        }
        XCTAssertEqual(store.recent.map(\.name), ["w5", "w4", "w3"], "oldest fall off the tail")
    }

    func testDefaultStoreRetainsTwentyWorkspaces() {
        let store = RecentWorkspaceStore(fileURL: fileURL)
        for i in 1...25 {
            store.record(name: "w\(i)", path: url("/tmp/w\(i)"))
        }

        XCTAssertEqual(store.recent.count, 20)
        XCTAssertEqual(store.recent.first?.name, "w25")
        XCTAssertEqual(store.recent.last?.name, "w6")
    }

    func testRecentSurvivesReopeningFromDisk() {
        let first = RecentWorkspaceStore(fileURL: fileURL)
        first.record(
            name: "Proj",
            path: url("/tmp/proj"),
            appearance: WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
        first.record(name: "Other", path: url("/tmp/other"))

        let reopened = RecentWorkspaceStore(fileURL: fileURL)
        XCTAssertEqual(reopened.recent.map(\.name), ["Other", "Proj"])
        XCTAssertEqual(reopened.recent.map(\.path), [url("/tmp/other"), url("/tmp/proj")])
        XCTAssertEqual(
            reopened.recent.last?.appearance,
            WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
    }

    func testCustomIconSurvivesReopeningFromDisk() throws {
        let png = try XCTUnwrap(
            Data(base64Encoded: """
                iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8A
                AQUBAScY42YAAAAASUVORK5CYII=
                """.filter { !$0.isWhitespace })
        )
        let icon = try XCTUnwrap(WorkspaceCustomIcon(pngData: png))
        let appearance = WorkspaceAppearance(
            symbol: .server,
            accent: .teal,
            customIcon: icon
        )
        RecentWorkspaceStore(fileURL: fileURL).record(
            name: "Infra",
            path: url("/tmp/infra"),
            appearance: appearance
        )

        XCTAssertEqual(
            RecentWorkspaceStore(fileURL: fileURL).recent.first?.appearance,
            appearance
        )
    }

    func testLegacyRowsRestoreWithDefaultAppearance() throws {
        let data = try XCTUnwrap(
            """
            [{"name":"Legacy","path":"/tmp/legacy"}]
            """.data(using: .utf8)
        )
        try data.write(to: fileURL)

        XCTAssertEqual(
            RecentWorkspaceStore(fileURL: fileURL).recent.first?.appearance,
            .default
        )
    }

    func testIdentityUpdateKeepsTheExistingRecencyPosition() {
        let store = RecentWorkspaceStore(fileURL: fileURL)
        store.record(name: "A", path: url("/tmp/a"))
        store.record(name: "B", path: url("/tmp/b"))

        store.updateIdentity(
            name: "A renamed",
            path: url("/tmp/a"),
            appearance: WorkspaceAppearance(symbol: .book, accent: .purple)
        )

        XCTAssertEqual(store.recent.map(\.name), ["B", "A renamed"])
        XCTAssertEqual(
            store.recent.last?.appearance,
            WorkspaceAppearance(symbol: .book, accent: .purple)
        )
        XCTAssertEqual(
            RecentWorkspaceStore(fileURL: fileURL).recent,
            store.recent,
            "the presentation update persists without becoming another open"
        )
    }

    func testClearEmptiesAndPersists() {
        let store = RecentWorkspaceStore(fileURL: fileURL)
        store.record(name: "A", path: url("/tmp/a"))
        store.clear()
        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertTrue(RecentWorkspaceStore(fileURL: fileURL).recent.isEmpty, "cleared list stays cleared on disk")
    }

    /// The store is the single home for "recently opened": opening a workspace through
    /// the store records it, so the sidebar menu can offer it again after it's closed.
    func testWorkspaceStoreRecordsOpenedWorkspaces() {
        let store = WorkspaceStore(recentWorkspaces: RecentWorkspaceStore(fileURL: fileURL))
        store.addWorkspace(name: "Alpha", path: url("/tmp/alpha"))
        store.addWorkspace(name: "Beta", path: url("/tmp/beta"))

        XCTAssertEqual(store.recentWorkspaces?.recent.map(\.name), ["Beta", "Alpha"])
    }

    func testWorkspaceStoreKeepsRecentPresentationInSync() throws {
        let recent = RecentWorkspaceStore(fileURL: fileURL)
        let store = WorkspaceStore(recentWorkspaces: recent)
        store.addWorkspace(name: "Alpha", path: url("/tmp/alpha"))
        let id = store.catalog.activeWorkspaceID

        store.renameWorkspace(id, to: "Payments")
        store.setWorkspaceAppearance(
            id,
            to: WorkspaceAppearance(symbol: .metrics, accent: .pink)
        )

        let entry = try XCTUnwrap(recent.recent.first)
        XCTAssertEqual(entry.name, "Payments")
        XCTAssertEqual(
            entry.appearance,
            WorkspaceAppearance(symbol: .metrics, accent: .pink)
        )
    }

    func testOpeningRecentPresentationAppliesItToTheNewWorkspace() throws {
        let recent = RecentWorkspaceStore(fileURL: fileURL)
        let store = WorkspaceStore(recentWorkspaces: recent)
        let appearance = WorkspaceAppearance(symbol: .design, accent: .blue)

        store.addWorkspace(
            name: "Design",
            path: url("/tmp/design"),
            appearance: appearance
        )

        XCTAssertEqual(try XCTUnwrap(store.catalog.activeWorkspace).appearance, appearance)
        XCTAssertEqual(recent.recent.first?.appearance, appearance)
    }

    /// The menu offers what you can't already reach: a workspace sitting in the catalog is
    /// one sidebar row away, so it drops out of the recent list until it's closed again.
    func testRecentExcludesTheWorkspacesThatAreOpen() {
        let store = RecentWorkspaceStore(fileURL: fileURL)
        store.record(name: "A", path: url("/tmp/a"))
        store.record(name: "B", path: url("/tmp/b"))
        store.record(name: "C", path: url("/tmp/c"))

        let offered = store.recent(excludingFolders: [
            RecentWorkspaceStore.folderKey(url("/tmp/b"))
        ])

        XCTAssertEqual(offered.map(\.name), ["C", "A"], "the open workspace is not offered again")
        XCTAssertEqual(store.recent.count, 3, "the remembered list itself is untouched")
    }

    /// The two sides spell the same folder differently — the open panel hands back a
    /// directory URL (`/tmp/a/`), the recents file rehydrates a plain path (`/tmp/a`) —
    /// so the comparison standardizes instead of matching `URL` identity.
    func testFolderKeyIgnoresTrailingSlashesAndRelativeSegments() {
        XCTAssertEqual(
            RecentWorkspaceStore.folderKey(URL(fileURLWithPath: "/tmp/a", isDirectory: true)),
            RecentWorkspaceStore.folderKey(URL(fileURLWithPath: "/tmp/a"))
        )
        XCTAssertEqual(
            RecentWorkspaceStore.folderKey(url("/tmp/./nested/../a")),
            RecentWorkspaceStore.folderKey(url("/tmp/a"))
        )
    }

    /// `openWorkspaceFolders` is what the sidebar menu filters against, so it has to name
    /// exactly the workspaces the catalog is holding right now.
    func testOpenWorkspaceFoldersFollowTheCatalog() throws {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: url("/tmp/alpha"))
        )
        let alpha = RecentWorkspaceStore.folderKey(url("/tmp/alpha"))
        let beta = RecentWorkspaceStore.folderKey(url("/tmp/beta"))
        XCTAssertEqual(store.openWorkspaceFolders, [alpha])

        store.addWorkspace(name: "Beta", path: url("/tmp/beta"))
        XCTAssertEqual(store.openWorkspaceFolders, [alpha, beta])

        let opened = try XCTUnwrap(store.catalog.workspaces.first { $0.name == "Beta" })
        store.removeWorkspace(opened.id)
        XCTAssertEqual(store.openWorkspaceFolders, [alpha], "closing a workspace offers it again")
    }

    /// The menu reads this instead of the catalog precisely because the catalog churns on
    /// every tab and pane change, and macOS re-lays-out an open menu whose view re-renders.
    /// So the set must stay silent through that churn (see `WorkspaceSidebarView`).
    func testOpenWorkspaceFoldersStaySilentThroughTabAndPaneChurn() {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: url("/tmp/alpha"))
        )
        let republished = expectation(description: "openWorkspaceFolders republished")
        republished.isInverted = true
        withObservationTracking {
            _ = store.openWorkspaceFolders
        } onChange: {
            republished.fulfill()
        }

        store.newTab()
        store.splitActiveSlot(.horizontal)
        store.setSlotContent(store.catalog.activeSlotID!, .automation)
        wait(for: [republished], timeout: 0.1)
    }

    /// The other half of that trade: a workspace opening *must* refresh the menu, or the
    /// folder someone just opened keeps being offered as a recent one.
    func testOpeningAWorkspaceRepublishesTheOpenFolders() {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: url("/tmp/alpha"))
        )
        let republished = expectation(description: "openWorkspaceFolders republished")
        withObservationTracking {
            _ = store.openWorkspaceFolders
        } onChange: {
            republished.fulfill()
        }

        store.addWorkspace(name: "Beta", path: url("/tmp/beta"))
        wait(for: [republished], timeout: 1)
    }
}
