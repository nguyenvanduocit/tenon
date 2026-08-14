import XCTest
@testable import TenonCore

/// `WorkspaceStore.openContent` is the "open something without spawning tabs"
/// placement policy: the first open splits a pane into the active tab, and every
/// open after lands in that same pane. Pure store logic, asserted without a window.
final class WorkspaceOpenContentTests: XCTestCase {
    private func request(_ path: String) -> DiffRequest {
        DiffRequest(
            source: .git(repoPath: "/r", path: path, staged: false, untracked: false, origPath: nil),
            fileName: path, title: path
        )
    }

    private func slots(_ store: WorkspaceStore) -> [WorkspaceSlot] {
        store.catalog.activeTab?.slots ?? []
    }

    private func contents(_ store: WorkspaceStore) -> [SlotContent] {
        slots(store).map(\.content)
    }

    private func filePaths(_ store: WorkspaceStore) -> [String] {
        contents(store).compactMap {
            if case let .file(path) = $0 { return path }
            return nil
        }
    }

    /// A store whose active tab holds exactly the panes given, so a test can state the
    /// canvas geometry the placement policy has to read.
    private func store(occupying rects: [GridRect]) -> WorkspaceStore {
        let slots = rects.map { WorkspaceSlot(rect: $0, content: .terminal) }
        let tab = Tab(slots: slots, activeSlotID: slots.first?.id)
        let workspace = Workspace(
            name: "w",
            path: URL(fileURLWithPath: "/tmp", isDirectory: true),
            tabs: [tab],
            activeTabID: tab.id
        )
        return WorkspaceStore(catalog: WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        ))
    }

    func testFirstFileOpensAPaneAndTheSecondReusesIt() {
        let store = WorkspaceStore()
        let before = slots(store).count

        store.openContent(.file(path: "a.swift"))
        XCTAssertEqual(slots(store).count, before + 1, "the first file opens one new pane")
        XCTAssertEqual(filePaths(store), ["a.swift"])

        store.openContent(.file(path: "b.swift"))
        XCTAssertEqual(slots(store).count, before + 1, "the second file reuses the pane — no new split")
        XCTAssertEqual(filePaths(store), ["b.swift"], "the reused pane now shows the new file")
    }

    func testOpeningFocusesTheReusedPane() throws {
        let store = WorkspaceStore()
        store.openContent(.file(path: "a.swift"))
        let editor = try XCTUnwrap(slots(store).first { $0.content == .file(path: "a.swift") })
        let terminal = try XCTUnwrap(slots(store).first { $0.content == .terminal })
        store.focusSlot(terminal.id)

        store.openContent(.file(path: "b.swift"))
        XCTAssertEqual(
            store.catalog.activeSlotID,
            editor.id,
            "the pane that took the file is the one the person is now looking at"
        )
    }

    func testOpeningNeverAddsATab() {
        let store = WorkspaceStore()
        let tabs = store.catalog.activeWorkspace?.tabs.count ?? 0
        store.openContent(.file(path: "a.swift"))
        store.openContent(.file(path: "b.swift"))
        store.openContent(.diff(request("c.swift")))
        store.openContent(.diff(request("d.swift")))
        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.count,
            tabs,
            "openContent must never open a new tab"
        )
    }

    func testATerminalOrPluginPaneIsNeverHijacked() {
        let store = WorkspaceStore()
        let tree = SlotContent.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        store.splitActiveSlot(.horizontal, content: tree)
        let before = slots(store).count

        store.openContent(.file(path: "a.swift"))
        XCTAssertEqual(slots(store).count, before + 1, "a file splits rather than taking the tree's pane")
        XCTAssertTrue(contents(store).contains(.terminal), "the terminal survived")
        XCTAssertTrue(contents(store).contains(tree), "the file tree survived")
        XCTAssertEqual(filePaths(store), ["a.swift"])
    }

    func testAnEmptyPaneIsFilledInsteadOfSplit() {
        let store = WorkspaceStore()
        store.splitActiveSlot(.horizontal, content: .empty)
        let before = slots(store).count

        store.openContent(.file(path: "a.swift"))
        XCTAssertEqual(slots(store).count, before, "the blank pane took the file — nothing was split")
        XCTAssertEqual(filePaths(store), ["a.swift"])
        XCTAssertFalse(contents(store).contains(.empty), "no blank pane is left over")
    }

    func testAFilePaneWinsOverABlankPane() {
        let store = WorkspaceStore()
        store.splitActiveSlot(.horizontal, content: .file(path: "a.swift"))
        store.splitActiveSlot(.vertical, content: .empty)
        let before = slots(store).count

        store.openContent(.file(path: "b.swift"))
        XCTAssertEqual(slots(store).count, before, "no new pane")
        XCTAssertEqual(filePaths(store), ["b.swift"], "the file pane took it")
        XCTAssertTrue(contents(store).contains(.empty), "the blank pane was left alone")
    }

    func testTheFocusedFilePaneTakesTheFile() throws {
        let store = WorkspaceStore()
        store.splitActiveSlot(.horizontal, content: .file(path: "a.swift"))
        let first = try XCTUnwrap(slots(store).first { $0.content == .file(path: "a.swift") })
        store.splitActiveSlot(.vertical, content: .file(path: "b.swift"))
        let second = try XCTUnwrap(slots(store).first { $0.content == .file(path: "b.swift") })
        store.focusSlot(first.id)

        store.openContent(.file(path: "c.swift"))
        XCTAssertEqual(
            store.catalog.slot(id: first.id)?.content,
            .file(path: "c.swift"),
            "the focused editor takes the file"
        )
        XCTAssertEqual(
            store.catalog.slot(id: second.id)?.content,
            .file(path: "b.swift"),
            "the unfocused editor keeps what it had"
        )
    }

    func testFirstDiffOpensAPaneAndTheSecondReusesIt() {
        let store = WorkspaceStore()
        let before = slots(store).count

        store.openContent(.diff(request("a.swift")))
        XCTAssertEqual(slots(store).count, before + 1, "the first diff opens one new pane")
        XCTAssertEqual(
            contents(store).filter {
                if case .diff = $0 { return true }
                return false
            },
            [.diff(request("a.swift"))]
        )

        store.openContent(.diff(request("b.swift")))
        XCTAssertEqual(slots(store).count, before + 1, "the second diff reuses the pane")
        XCTAssertEqual(
            contents(store).filter {
                if case .diff = $0 { return true }
                return false
            },
            [.diff(request("b.swift"))]
        )
    }

    func testDiffsKeepTheirOwnPaneAlongsideAFile() throws {
        let store = WorkspaceStore()
        store.openContent(.file(path: "a.swift"))
        let editor = try XCTUnwrap(slots(store).first { $0.content == .file(path: "a.swift") })
        let before = slots(store).count

        store.openContent(.diff(request("a.swift")))
        XCTAssertEqual(slots(store).count, before + 1, "a diff does not take the editor's pane")
        store.openContent(.diff(request("b.swift")))
        XCTAssertEqual(slots(store).count, before + 1, "the second diff reuses the diff pane")
        XCTAssertEqual(
            store.catalog.slot(id: editor.id)?.content,
            .file(path: "a.swift"),
            "the editor still shows its file"
        )
        XCTAssertEqual(
            contents(store).filter {
                if case .diff = $0 { return true }
                return false
            },
            [.diff(request("b.swift"))]
        )
    }

    func testOpeningTheSamePluginViewTwiceFocusesItInstead() throws {
        let store = WorkspaceStore()
        let tree = SlotContent.pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        store.openContent(tree)
        let opened = try XCTUnwrap(slots(store).first { $0.content == tree })
        let before = slots(store).count

        store.openContent(tree)
        XCTAssertEqual(slots(store).count, before, "the same view is focused, not opened twice")
        XCTAssertEqual(store.catalog.activeSlotID, opened.id)
    }

    // MARK: - Free canvas is taken before any pane is split

    func testAFileTakesFreeCanvasInsteadOfHalvingTheOnlyPane() throws {
        // Half the canvas is occupied and half is empty — the state a 1/2 creation
        // maximum leaves behind, and the state a person leaves by dragging a border.
        let store = store(occupying: [GridRect(x: 0, y: 0, width: 6, height: 12)])
        let terminal = try XCTUnwrap(slots(store).first)

        store.openContent(.file(path: "a.swift"))

        XCTAssertEqual(
            store.catalog.slot(id: terminal.id)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "the open pane keeps its width: free canvas was available, so nothing was split"
        )
        let editor = try XCTUnwrap(slots(store).first { $0.content == .file(path: "a.swift") })
        XCTAssertEqual(
            editor.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12),
            "the file lands in the empty half"
        )
    }

    func testAFileStillSplitsWhenTheCanvasIsFull() throws {
        let store = store(occupying: [GridRect(x: 0, y: 0, width: 12, height: 12)])
        let terminal = try XCTUnwrap(slots(store).first)

        store.openContent(.file(path: "a.swift"))

        XCTAssertEqual(
            store.catalog.slot(id: terminal.id)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "with no free canvas the pane is halved, exactly as before"
        )
        let editor = try XCTUnwrap(slots(store).first { $0.content == .file(path: "a.swift") })
        XCTAssertEqual(editor.rect, GridRect(x: 6, y: 0, width: 6, height: 12))
    }

    func testTheNewPaneObeysTheCreationMaximumWhenItTakesFreeCanvas() throws {
        let store = store(occupying: [GridRect(x: 0, y: 0, width: 4, height: 12)])
        store.newPaneSizingProvider = { NewPaneSizing(maximumWidth: .oneThird) }

        store.openContent(.file(path: "a.swift"))

        let editor = try XCTUnwrap(slots(store).first { $0.content == .file(path: "a.swift") })
        XCTAssertEqual(
            editor.rect,
            GridRect(x: 4, y: 0, width: 4, height: 12),
            "the hole was 8 wide; a 1/3 maximum takes 4 of it and leaves the rest empty"
        )
    }

    func testOpeningAutomationTwiceReusesAndFocusesItsPane() throws {
        let store = WorkspaceStore()
        store.openContent(.automation)
        let opened = try XCTUnwrap(
            slots(store).first { $0.content == .automation }
        )
        let before = slots(store).count
        let terminal = try XCTUnwrap(
            slots(store).first { $0.content == .terminal }
        )
        store.focusSlot(terminal.id)

        store.openContent(.automation)

        XCTAssertEqual(slots(store).count, before)
        XCTAssertEqual(store.catalog.activeSlotID, opened.id)
    }
}
