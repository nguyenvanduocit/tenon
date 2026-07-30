import XCTest
@testable import TenonCore

/// `WorkspaceStore.showDiff` is the "open a file's diff without spawning tabs"
/// behaviour: the first diff splits a pane into the active tab, and every diff
/// after reuses that one pane. Pure store logic, asserted without a window.
final class WorkspaceDiffReuseTests: XCTestCase {
    private func request(_ path: String) -> DiffRequest {
        DiffRequest(
            source: .git(repoPath: "/r", path: path, staged: false, untracked: false, origPath: nil),
            fileName: path, title: path
        )
    }

    private func diffSlots(_ store: WorkspaceStore) -> [WorkspaceSlot] {
        (store.catalog.activeTab?.slots ?? []).filter {
            if case .diff = $0.content { return true }
            return false
        }
    }

    func testFirstDiffOpensAPaneAndSecondReusesIt() {
        let store = WorkspaceStore()
        let before = store.catalog.activeTab?.slots.count ?? 0

        store.showDiff(request("a.swift"))
        XCTAssertEqual(store.catalog.activeTab?.slots.count, before + 1, "first diff opens one new pane")
        XCTAssertEqual(diffSlots(store).count, 1)
        XCTAssertEqual(diffSlots(store).first?.content, .diff(request("a.swift")))

        store.showDiff(request("b.swift"))
        XCTAssertEqual(store.catalog.activeTab?.slots.count, before + 1, "second diff reuses the pane — no new split")
        XCTAssertEqual(diffSlots(store).count, 1, "still exactly one diff pane")
        XCTAssertEqual(diffSlots(store).first?.content, .diff(request("b.swift")), "the reused pane now shows the new file")
    }

    func testShowDiffNeverAddsATab() {
        let store = WorkspaceStore()
        let tabs = store.catalog.activeWorkspace?.tabs.count ?? 0
        store.showDiff(request("a.swift"))
        store.showDiff(request("b.swift"))
        store.showDiff(request("c.swift"))
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, tabs, "showDiff must never open a new tab")
    }
}
