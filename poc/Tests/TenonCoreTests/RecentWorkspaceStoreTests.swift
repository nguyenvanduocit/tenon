import XCTest
@testable import TenonCore

/// `RecentWorkspaceStore` — the "recently opened workspaces" list behind the sidebar's
/// Add-Workspace menu. All ordering/cap/persistence rules are pure logic here so they
/// can be asserted without a window (the shell only calls `record` and reads `recent`).
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

    func testRecordCapsAtLimit() {
        let store = RecentWorkspaceStore(fileURL: fileURL, limit: 3)
        for i in 1...5 {
            store.record(name: "w\(i)", path: url("/tmp/w\(i)"))
        }
        XCTAssertEqual(store.recent.map(\.name), ["w5", "w4", "w3"], "oldest fall off the tail")
    }

    func testRecentSurvivesReopeningFromDisk() {
        let first = RecentWorkspaceStore(fileURL: fileURL)
        first.record(name: "Proj", path: url("/tmp/proj"))
        first.record(name: "Other", path: url("/tmp/other"))

        let reopened = RecentWorkspaceStore(fileURL: fileURL)
        XCTAssertEqual(reopened.recent.map(\.name), ["Other", "Proj"])
        XCTAssertEqual(reopened.recent.map(\.path), [url("/tmp/other"), url("/tmp/proj")])
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
}
