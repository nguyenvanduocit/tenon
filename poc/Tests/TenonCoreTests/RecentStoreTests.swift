import XCTest
@testable import TenonCore

final class RecentStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-recent-\(UUID().uuidString).json")
    }

    func testRecordPutsNewestFirstAndDedupesByValue() {
        let store = RecentStore(fileURL: tempFile())
        store.record(.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"))
        store.record(.changes)
        store.record(.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")) // re-opening moves it back to the front

        XCTAssertEqual(
            store.recent,
            [.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"), .changes]
        )
    }

    func testDistinctPluginViewsAreDistinctEntries() {
        let store = RecentStore(fileURL: tempFile())
        let a = SlotContent.pluginView(pluginID: "dev.tenon.browser", viewID: "a")
        let b = SlotContent.pluginView(pluginID: "dev.tenon.browser", viewID: "b")
        store.record(a)
        store.record(b)

        XCTAssertEqual(store.recent, [b, a])
    }

    func testCapKeepsOnlyTheNewest() {
        let store = RecentStore(fileURL: tempFile(), limit: 3)
        store.record(.terminal)
        store.record(.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"))
        store.record(.changes)
        store.record(.docs)

        XCTAssertEqual(
            store.recent,
            [.docs, .changes, .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")]
        )
    }

    func testEmptyContentIsIgnored() {
        let store = RecentStore(fileURL: tempFile())
        store.record(.empty)

        XCTAssertTrue(store.recent.isEmpty)
    }

    func testSurvivesReloadFromDisk() {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        store.record(.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"))
        store.record(.pluginView(pluginID: "dev.tenon.browser", viewID: "browser"))

        let reloaded = RecentStore(fileURL: file)
        XCTAssertEqual(reloaded.recent, store.recent)
    }

    func testClearEmptiesAndPersists() {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        store.record(.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"))
        store.clear()

        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertTrue(RecentStore(fileURL: file).recent.isEmpty)
    }

    func testWorkspaceStoreRecordsOpenedContent() {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                name: "One",
                path: URL(fileURLWithPath: "/tmp/tenon-recent", isDirectory: true)
            ),
            recent: RecentStore(fileURL: tempFile())
        )
        store.addSlot(
            content: .pluginView(
                pluginID: "dev.tenon.file-explorer",
                viewID: "tree"
            )
        )

        XCTAssertEqual(
            store.recent?.recent.first,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
    }

    func testInvalidPersistedPluginIdentityIsDropped() throws {
        let file = tempFile()
        try Data(
            #"[{"type":"pluginView","pluginID":"browser","viewID":"browser"}]"#.utf8
        ).write(to: file)

        XCTAssertTrue(RecentStore(fileURL: file).recent.isEmpty)
    }

    func testPersistsFullManifestIdentity() throws {
        let file = tempFile()
        let store = RecentStore(fileURL: file)
        store.record(.pluginView(pluginID: "dev.tenon.browser", viewID: "browser"))

        let data = try Data(contentsOf: file)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [[String: String]]
        )
        XCTAssertEqual(rows.first?["pluginID"], "dev.tenon.browser")
        XCTAssertNil(rows.first?["plugin"])
    }
}
