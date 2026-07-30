import XCTest
@testable import TenonCore

/// `duplicateSlot` is "give me a second one of this pane": the new pane shows whatever the
/// duplicated pane shows, and it lands in free canvas space when there is any rather than
/// halving the pane that asked. Pure catalog logic, asserted without a window.
final class WorkspaceDuplicateSlotTests: XCTestCase {
    private let projectPath = URL(fileURLWithPath: "/tmp/tenon-duplicate", isDirectory: true)

    private func makeCatalog(
        slots: [WorkspaceSlot],
        activeSlotID: UUID?
    ) -> WorkspaceCatalog {
        let tab = Tab(id: UUID(), slots: slots, activeSlotID: activeSlotID)
        let workspace = Workspace(
            id: UUID(),
            name: "Test",
            path: projectPath,
            tabs: [tab],
            activeTabID: tab.id
        )
        return WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
    }

    private let tree = SlotContent.pluginView(
        pluginID: "dev.tenon.file-explorer",
        viewID: "tree"
    )

    func testDuplicatingTheOnlyPaneSplitsItAndCopiesItsContent() throws {
        let originalID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: originalID,
                    rect: GridRect(x: 0, y: 0, width: 12, height: 12),
                    content: .file(path: "a.swift")
                ),
            ],
            activeSlotID: originalID
        )
        XCTAssertTrue(catalog.canDuplicateSlot(originalID))

        let events = catalog.duplicateSlot(originalID)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 2)
        let copy = try XCTUnwrap(tab.slots.first { $0.id != originalID })
        XCTAssertEqual(copy.content, .file(path: "a.swift"), "the copy shows the same file")
        XCTAssertEqual(catalog.slot(id: originalID)?.rect, GridRect(x: 0, y: 0, width: 6, height: 12))
        XCTAssertEqual(copy.rect, GridRect(x: 6, y: 0, width: 6, height: 12))
        XCTAssertEqual(tab.activeSlotID, copy.id, "the copy is where the person now is")
        XCTAssertTrue(events.contains(.slotSplit(
            original: originalID,
            new: copy.id,
            axis: .horizontal,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testDuplicatingUsesFreeCanvasSpaceInsteadOfShrinkingThePane() throws {
        let originalID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: originalID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: originalID
        )

        let events = catalog.duplicateSlot(originalID)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 2)
        XCTAssertEqual(
            catalog.slot(id: originalID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "the duplicated pane keeps its size — the empty half took the copy"
        )
        let copy = try XCTUnwrap(tab.slots.first { $0.id != originalID })
        XCTAssertEqual(copy.rect, GridRect(x: 6, y: 0, width: 6, height: 12))
        XCTAssertEqual(copy.content, .terminal)
        XCTAssertTrue(events.contains(.slotOpened(
            slot: copy.id,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testDuplicatingAPaneTooNarrowToSplitStacksItInstead() throws {
        let originalID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: originalID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: tree
                ),
                WorkspaceSlot(
                    id: UUID(),
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: originalID
        )

        catalog.duplicateSlot(originalID)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 3)
        XCTAssertEqual(catalog.slot(id: originalID)?.rect, GridRect(x: 0, y: 0, width: 3, height: 6))
        let copy = try XCTUnwrap(tab.slots.first { $0.rect == GridRect(x: 0, y: 6, width: 3, height: 6) })
        XCTAssertEqual(copy.content, tree, "the copy shows the same plugin view")
    }

    func testDuplicatingTargetsTheNamedPaneNotTheActiveOne() throws {
        let activeID = UUID()
        let namedID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: activeID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: namedID,
                    rect: GridRect(x: 6, y: 0, width: 6, height: 12),
                    content: .changes
                ),
            ],
            activeSlotID: activeID
        )

        catalog.duplicateSlot(namedID)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 3)
        XCTAssertEqual(
            catalog.slot(id: activeID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "the active pane was not the one duplicated, so it was not resized"
        )
        XCTAssertEqual(catalog.slot(id: namedID)?.rect, GridRect(x: 6, y: 0, width: 3, height: 12))
        let copy = try XCTUnwrap(tab.slots.first { $0.id != activeID && $0.id != namedID })
        XCTAssertEqual(copy.content, .changes)
    }

    func testDuplicatingAPaneWithNoRoomLeftChangesNothing() throws {
        let originalID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: originalID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 3),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: UUID(),
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: UUID(),
                    rect: GridRect(x: 0, y: 3, width: 3, height: 9),
                    content: .terminal
                ),
            ],
            activeSlotID: originalID
        )
        let before = catalog.activeTab?.slots

        let events = catalog.duplicateSlot(originalID)

        XCTAssertTrue(events.isEmpty, "a pane that can neither be placed nor split is a no-op")
        XCTAssertEqual(catalog.activeTab?.slots, before)
        XCTAssertFalse(
            catalog.canDuplicateSlot(originalID),
            "the menu must be able to see the no-op coming"
        )
    }

    func testDuplicatingAnUnknownPaneChangesNothing() throws {
        let originalID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: originalID,
                    rect: GridRect(x: 0, y: 0, width: 12, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: originalID
        )
        let before = catalog.activeTab?.slots

        let events = catalog.duplicateSlot(UUID())

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(catalog.activeTab?.slots, before)
    }

    func testStoreDuplicatesThroughTheSameRule() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "One", path: projectPath))
        let originalID = try XCTUnwrap(store.catalog.activeSlotID)
        store.setSlotContent(originalID, .docs)

        store.duplicateSlot(originalID)

        let tab = try XCTUnwrap(store.catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 2)
        XCTAssertEqual(tab.slots.map(\.content), [.docs, .docs])
        XCTAssertEqual(tab.activeSlotID, tab.slots.last?.id)
    }
}
