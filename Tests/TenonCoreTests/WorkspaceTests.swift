import XCTest
@testable import TenonCore

final class WorkspaceCatalogTests: XCTestCase {
    private let projectPath = URL(fileURLWithPath: "/tmp/tenon-project", isDirectory: true)

    func testInitialCatalogHasOneWorkspaceOneTabAndFullGridTerminal() throws {
        let catalog = WorkspaceCatalog(name: "Tenon", path: projectPath)

        XCTAssertEqual(catalog.workspaces.count, 1)
        let workspace = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(workspace.name, "Tenon")
        XCTAssertEqual(workspace.path, projectPath)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs[0].id)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 1)
        XCTAssertEqual(tab.activeSlotID, tab.slots[0].id)
        XCTAssertEqual(tab.slots[0].rect, fullGrid)
        XCTAssertEqual(tab.slots[0].content, .terminal)
        XCTAssertEqual(catalog.allSlotIDs, [tab.slots[0].id])
    }

    func testAddWorkspaceCreatesItsInitialTabAndSelectsIt() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let originalWorkspaceID = catalog.activeWorkspaceID
        let secondPath = URL(fileURLWithPath: "/tmp/second", isDirectory: true)

        let events = catalog.addWorkspace(name: "Two", path: secondPath)

        XCTAssertEqual(catalog.workspaces.count, 2)
        let second = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertNotEqual(second.id, originalWorkspaceID)
        XCTAssertEqual(second.name, "Two")
        XCTAssertEqual(second.path, secondPath)
        XCTAssertEqual(second.tabs.count, 1)
        let tab = try XCTUnwrap(second.tabs.first)
        let slot = try XCTUnwrap(tab.slots.first)
        XCTAssertEqual(events, [
            .workspaceAdded(second.id),
            .tabOpened(tab: tab.id, workspace: second.id),
            .slotOpened(slot: slot.id, tab: tab.id, workspace: second.id),
            .workspaceSelected(second.id),
            .tabSelected(tab: tab.id, workspace: second.id),
            .slotFocused(slot: slot.id, tab: tab.id, workspace: second.id),
        ])
    }

    func testSelectWorkspaceKeepsInactiveWorkspaceSlotsLive() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstWorkspaceID = catalog.activeWorkspaceID
        let firstSlotID = try XCTUnwrap(catalog.activeSlotID)
        catalog.addWorkspace(name: "Two", path: projectPath)
        let secondWorkspaceID = catalog.activeWorkspaceID
        let secondSlotID = try XCTUnwrap(catalog.activeSlotID)

        let events = catalog.selectWorkspace(firstWorkspaceID)

        XCTAssertEqual(catalog.activeWorkspaceID, firstWorkspaceID)
        XCTAssertEqual(Set(catalog.allSlotIDs), Set([firstSlotID, secondSlotID]))
        let selectedTab = try XCTUnwrap(catalog.activeTab)
        let selectedSlotID = try XCTUnwrap(selectedTab.activeSlotID)
        XCTAssertEqual(events, [
            .workspaceSelected(firstWorkspaceID),
            .tabSelected(tab: selectedTab.id, workspace: firstWorkspaceID),
            .slotFocused(
                slot: selectedSlotID,
                tab: selectedTab.id,
                workspace: firstWorkspaceID
            ),
        ])
        XCTAssertEqual(catalog.selectWorkspace(firstWorkspaceID), [])
        XCTAssertNotEqual(firstWorkspaceID, secondWorkspaceID)
    }

    func testSelectUnknownWorkspaceIsAtomicNoOp() {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let before = catalog

        XCTAssertEqual(catalog.selectWorkspace(UUID()), [])
        XCTAssertEqual(catalog, before)
    }

    func testRemoveInactiveWorkspaceDropsItAndKeepsActive() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstID = catalog.activeWorkspaceID
        catalog.addWorkspace(name: "Two", path: projectPath)
        let secondID = catalog.activeWorkspaceID
        let secondSlotID = try XCTUnwrap(catalog.activeSlotID)
        let removed = try XCTUnwrap(catalog.workspaces.first { $0.id == firstID })
        let removedTab = try XCTUnwrap(removed.tabs.first)
        let removedSlot = try XCTUnwrap(removedTab.slots.first)

        let events = catalog.removeWorkspace(firstID)

        XCTAssertEqual(catalog.workspaces.map(\.id), [secondID])
        XCTAssertEqual(catalog.activeWorkspaceID, secondID)
        XCTAssertEqual(catalog.allSlotIDs, [secondSlotID])
        XCTAssertEqual(events, [
            .slotClosed(slot: removedSlot.id, tab: removedTab.id, workspace: firstID),
            .tabClosed(tab: removedTab.id, workspace: firstID),
            .workspaceRemoved(firstID),
        ])
    }

    func testRemoveActiveWorkspaceSelectsANeighbor() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstID = catalog.activeWorkspaceID
        catalog.addWorkspace(name: "Two", path: projectPath)
        let secondID = catalog.activeWorkspaceID
        let removed = try XCTUnwrap(catalog.workspaces.first { $0.id == secondID })
        let removedTab = try XCTUnwrap(removed.tabs.first)
        let removedSlot = try XCTUnwrap(removedTab.slots.first)

        let events = catalog.removeWorkspace(secondID)

        XCTAssertEqual(catalog.workspaces.map(\.id), [firstID])
        XCTAssertEqual(catalog.activeWorkspaceID, firstID)
        let neighbor = try XCTUnwrap(catalog.activeWorkspace)
        let neighborTab = try XCTUnwrap(neighbor.activeTab)
        let neighborSlotID = try XCTUnwrap(neighborTab.activeSlotID)
        XCTAssertEqual(events, [
            .slotClosed(slot: removedSlot.id, tab: removedTab.id, workspace: secondID),
            .tabClosed(tab: removedTab.id, workspace: secondID),
            .workspaceRemoved(secondID),
            .workspaceSelected(firstID),
            .tabSelected(tab: neighborTab.id, workspace: firstID),
            .slotFocused(slot: neighborSlotID, tab: neighborTab.id, workspace: firstID),
        ])
    }

    func testRemoveLastRemainingWorkspaceIsAtomicNoOp() {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let before = catalog

        XCTAssertEqual(catalog.removeWorkspace(catalog.activeWorkspaceID), [])
        XCTAssertEqual(catalog, before)
    }

    func testRemoveUnknownWorkspaceIsAtomicNoOp() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        catalog.addWorkspace(name: "Two", path: projectPath)
        let before = catalog

        XCTAssertEqual(catalog.removeWorkspace(UUID()), [])
        XCTAssertEqual(catalog, before)
    }

    func testNewTabAppendsFullGridTerminalAndSelectsIt() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let workspaceID = catalog.activeWorkspaceID

        let events = catalog.newTab()

        let workspace = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(workspace.tabs.count, 2)
        let tab = try XCTUnwrap(catalog.activeTab)
        let slot = try XCTUnwrap(tab.slots.first)
        XCTAssertEqual(workspace.activeTabID, tab.id)
        XCTAssertEqual(slot.rect, fullGrid)
        XCTAssertEqual(slot.content, .terminal)
        XCTAssertEqual(events, [
            .tabOpened(tab: tab.id, workspace: workspaceID),
            .slotOpened(slot: slot.id, tab: tab.id, workspace: workspaceID),
            .tabSelected(tab: tab.id, workspace: workspaceID),
            .slotFocused(slot: slot.id, tab: tab.id, workspace: workspaceID),
        ])
    }

    func testSelectAndCycleTabsWrapAround() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let first = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let second = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let third = try XCTUnwrap(catalog.activeTab?.id)

        catalog.selectNextTab()
        XCTAssertEqual(catalog.activeTab?.id, first)
        catalog.selectPreviousTab()
        XCTAssertEqual(catalog.activeTab?.id, third)
        catalog.selectTab(second)
        XCTAssertEqual(catalog.activeTab?.id, second)
    }

    func testCloseTabSelectsNeighborAndNeverRemovesLastTab() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let secondTabID = try XCTUnwrap(catalog.activeTab?.id)
        let secondSlotID = try XCTUnwrap(catalog.activeSlotID)

        let events = catalog.closeTab(secondTabID)

        XCTAssertEqual(catalog.activeWorkspace?.tabs.map(\.id), [firstTabID])
        XCTAssertEqual(catalog.activeTab?.id, firstTabID)
        XCTAssertTrue(events.contains(.slotClosed(
            slot: secondSlotID,
            tab: secondTabID,
            workspace: catalog.activeWorkspaceID
        )))
        XCTAssertTrue(events.contains(.tabClosed(
            tab: secondTabID,
            workspace: catalog.activeWorkspaceID
        )))

        let before = catalog
        XCTAssertEqual(catalog.closeTab(firstTabID), [])
        XCTAssertEqual(catalog, before)
    }

    func testCloseActiveMiddleTabSelectsPreviousTab() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let middleTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let lastTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.selectTab(middleTabID)

        catalog.closeTab(middleTabID)

        XCTAssertEqual(catalog.activeTab?.id, firstTabID)
        XCTAssertEqual(catalog.activeWorkspace?.tabs.map(\.id), [firstTabID, lastTabID])
    }

    func testEachTabPreservesItsOwnActiveSlotAcrossTabSwitches() throws {
        // Tab A gets a second pane; the split makes that new pane (B) active.
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let tabAID = try XCTUnwrap(catalog.activeTab?.id)
        let tabAFirstSlotID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let tabAActivePaneID = try XCTUnwrap(catalog.activeSlotID)
        XCTAssertNotEqual(tabAActivePaneID, tabAFirstSlotID)

        // A fresh tab (X) carries its own independent active pane.
        catalog.newTab()
        let tabXID = try XCTUnwrap(catalog.activeTab?.id)
        let tabXActivePaneID = try XCTUnwrap(catalog.activeSlotID)
        XCTAssertNotEqual(tabXActivePaneID, tabAActivePaneID)

        // Returning to tab A restores B — not tab A's first pane, not tab X's pane —
        // and republishes focus on B so the shell can route keystrokes back to it.
        let events = catalog.selectTab(tabAID)
        XCTAssertEqual(catalog.activeTab?.id, tabAID)
        XCTAssertEqual(catalog.activeSlotID, tabAActivePaneID)
        XCTAssertTrue(events.contains(.slotFocused(
            slot: tabAActivePaneID,
            tab: tabAID,
            workspace: catalog.activeWorkspaceID
        )))

        // Tab X still remembers its own active pane, untouched by A's selection.
        catalog.selectTab(tabXID)
        XCTAssertEqual(catalog.activeSlotID, tabXActivePaneID)
    }

    func testAddSlotUsesLargestEmptyRectangleBeforeSplitting() throws {
        let activeSlotID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: activeSlotID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: activeSlotID
        )

        let events = catalog.addSlot(content: .changes)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 2)
        let added = try XCTUnwrap(tab.slots.first { $0.id != activeSlotID })
        XCTAssertEqual(added.rect, GridRect(x: 6, y: 0, width: 6, height: 12))
        XCTAssertEqual(added.content, .changes)
        XCTAssertEqual(tab.activeSlotID, added.id)
        XCTAssertTrue(events.contains(.slotOpened(
            slot: added.id,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testAddSlotAtExactEmptyRectAndDiscardReservationPreserveExistingGeometry() throws {
        let originalID = UUID()
        let reservedID = UUID()
        let originalRect = GridRect(x: 0, y: 0, width: 6, height: 12)
        let targetRect = GridRect(x: 6, y: 0, width: 6, height: 12)
        var catalog = makeCatalog(
            slots: [WorkspaceSlot(id: originalID, rect: originalRect, content: .terminal)],
            activeSlotID: originalID
        )

        let opened = catalog.addSlot(
            id: reservedID,
            content: .empty,
            at: targetRect
        )

        XCTAssertEqual(catalog.slot(id: reservedID)?.rect, targetRect)
        XCTAssertEqual(catalog.activeSlotID, reservedID)
        XCTAssertTrue(opened.contains { if case .slotOpened(slot: reservedID, tab: _, workspace: _) = $0 { return true }; return false })

        let discarded = catalog.discardEmptySlot(reservedID, restoringFocusTo: originalID)

        XCTAssertNil(catalog.slot(id: reservedID))
        XCTAssertEqual(catalog.slot(id: originalID)?.rect, originalRect)
        XCTAssertEqual(catalog.activeSlotID, originalID)
        XCTAssertTrue(discarded.contains { if case .slotClosed(slot: reservedID, tab: _, workspace: _) = $0 { return true }; return false })
    }

    func testDiscardOnlyEmptyReservationClosesItsTabWhenAnotherTabSurvives() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath, content: .empty)
        let reservedTabID = try XCTUnwrap(catalog.activeTab?.id)
        let reservedSlotID = try XCTUnwrap(catalog.activeSlotID)
        catalog.newTab()
        let survivingTabID = try XCTUnwrap(catalog.activeTab?.id)

        let events = catalog.discardEmptySlot(
            reservedSlotID,
            restoringFocusTo: nil
        )

        XCTAssertEqual(catalog.activeWorkspace?.tabs.map(\.id), [survivingTabID])
        XCTAssertTrue(events.contains(.tabClosed(
            tab: reservedTabID,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testAddSlotAtExactRectRejectsOverlapAndUndersizedTargets() {
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

        XCTAssertTrue(catalog.addSlot(
            id: UUID(),
            content: .empty,
            at: GridRect(x: 3, y: 0, width: 6, height: 12)
        ).isEmpty)
        XCTAssertTrue(catalog.addSlot(
            id: UUID(),
            content: .empty,
            at: GridRect(x: 6, y: 0, width: 2, height: 12)
        ).isEmpty)
        XCTAssertEqual(catalog.activeTab?.slots.count, 1)
    }

    func testAddSlotFallsBackToSplittingActiveSlotWhenGridIsFull() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let originalID = try XCTUnwrap(catalog.activeSlotID)

        let events = catalog.addSlot(content: .automation)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 2)
        XCTAssertEqual(tab.slots[0].rect, GridRect(x: 0, y: 0, width: 6, height: 12))
        let added = try XCTUnwrap(tab.slots.first { $0.id != originalID })
        XCTAssertEqual(added.rect, GridRect(x: 6, y: 0, width: 6, height: 12))
        XCTAssertEqual(added.content, .automation)
        XCTAssertTrue(events.contains(.slotSplit(
            original: originalID,
            new: added.id,
            axis: .horizontal,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testAddSlotFallbackUsesVerticalOnlyWhenActiveIsTooNarrowForHorizontal() throws {
        let activeSlotID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: activeSlotID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: UUID(),
                    rect: GridRect(x: 3, y: 0, width: 9, height: 12),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: activeSlotID
        )

        let events = catalog.addSlot(content: .automation)

        let tab = try XCTUnwrap(catalog.activeTab)
        let added = try XCTUnwrap(tab.slots.first {
            $0.id != activeSlotID && $0.content == .automation
        })
        XCTAssertEqual(
            catalog.slot(id: activeSlotID)?.rect,
            GridRect(x: 0, y: 0, width: 3, height: 6)
        )
        XCTAssertEqual(added.rect, GridRect(x: 0, y: 6, width: 3, height: 6))
        XCTAssertTrue(events.contains(.slotSplit(
            original: activeSlotID,
            new: added.id,
            axis: .vertical,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testAddSlotToEmptyTabRestoresOneFullGridSlot() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let originalID = try XCTUnwrap(catalog.activeSlotID)
        catalog.closeSlot(originalID)
        let tabID = try XCTUnwrap(catalog.activeTab?.id)

        catalog.addSlot(
            content: .pluginView(
                pluginID: "dev.tenon.browser",
                viewID: "browser"
            )
        )

        let tab = try XCTUnwrap(catalog.activeTab)
        let slot = try XCTUnwrap(tab.slots.first)
        XCTAssertEqual(tab.id, tabID)
        XCTAssertEqual(tab.slots.count, 1)
        XCTAssertEqual(slot.rect, fullGrid)
        XCTAssertEqual(
            slot.content,
            .pluginView(pluginID: "dev.tenon.browser", viewID: "browser")
        )
        XCTAssertEqual(tab.activeSlotID, slot.id)
    }

    func testSplitActiveSlotSupportsBothAxesAndFocusesNewSlot() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let originalID = try XCTUnwrap(catalog.activeSlotID)

        let events = catalog.splitActiveSlot(.vertical, content: .terminal)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots[0].rect, GridRect(x: 0, y: 0, width: 12, height: 6))
        let added = try XCTUnwrap(tab.slots.first { $0.id != originalID })
        XCTAssertEqual(added.rect, GridRect(x: 0, y: 6, width: 12, height: 6))
        XCTAssertEqual(tab.activeSlotID, added.id)
        XCTAssertTrue(events.contains(.slotSplit(
            original: originalID,
            new: added.id,
            axis: .vertical,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testSplitSlotTargetsGivenSlotEvenWhenItIsNotActive() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let leftID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let rightID = try XCTUnwrap(catalog.activeSlotID)
        XCTAssertNotEqual(leftID, rightID)

        // The right slot is active, yet the context menu targets the left one.
        let events = catalog.splitSlot(leftID, .vertical)

        let tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots.count, 3)
        let left = try XCTUnwrap(tab.slots.first { $0.id == leftID })
        XCTAssertEqual(left.rect, GridRect(x: 0, y: 0, width: 6, height: 6))
        let added = try XCTUnwrap(
            tab.slots.first { $0.id != leftID && $0.id != rightID }
        )
        XCTAssertEqual(added.rect, GridRect(x: 0, y: 6, width: 6, height: 6))
        XCTAssertEqual(tab.activeSlotID, added.id)
        XCTAssertTrue(events.contains(.slotSplit(
            original: leftID,
            new: added.id,
            axis: .vertical,
            tab: tab.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testSplitSlotIgnoresUnknownSlotWithoutMutatingTheTab() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let before = try XCTUnwrap(catalog.activeTab)

        let events = catalog.splitSlot(UUID(), .horizontal)

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(catalog.activeTab, before)
    }

    func testCloseSlotUsesSmartAbsorptionAndClosesTabAfterItsLastSlot() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)
        let leftID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let rightID = try XCTUnwrap(catalog.activeSlotID)
        catalog.newTab()
        let survivingTabID = try XCTUnwrap(catalog.activeTab?.id)
        let survivingSlotID = try XCTUnwrap(catalog.activeSlotID)
        catalog.selectTab(sourceTabID)

        catalog.closeSlot(rightID)

        var tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.slots, [
            WorkspaceSlot(id: leftID, rect: fullGrid, content: .terminal),
        ])
        XCTAssertEqual(tab.activeSlotID, leftID)

        let events = catalog.closeSlot(leftID)

        tab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(tab.id, survivingTabID)
        XCTAssertFalse(catalog.activeWorkspace!.tabs.contains { $0.id == sourceTabID })
        XCTAssertEqual(events, [
            .slotClosed(
                slot: leftID,
                tab: sourceTabID,
                workspace: catalog.activeWorkspaceID
            ),
            .tabClosed(tab: sourceTabID, workspace: catalog.activeWorkspaceID),
            .tabSelected(tab: survivingTabID, workspace: catalog.activeWorkspaceID),
            .slotFocused(
                slot: survivingSlotID,
                tab: survivingTabID,
                workspace: catalog.activeWorkspaceID
            ),
        ])
    }

    func testCloseLastSlotInOnlyTabKeepsTheRequiredTabAsEmpty() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let tabID = try XCTUnwrap(catalog.activeTab?.id)
        let slotID = try XCTUnwrap(catalog.activeSlotID)

        let events = catalog.closeSlot(slotID)

        XCTAssertEqual(catalog.activeWorkspace?.tabs.map(\.id), [tabID])
        XCTAssertTrue(try XCTUnwrap(catalog.activeTab).slots.isEmpty)
        XCTAssertNil(catalog.activeSlotID)
        XCTAssertEqual(events, [
            .slotClosed(
                slot: slotID,
                tab: tabID,
                workspace: catalog.activeWorkspaceID
            ),
        ])
    }

    func testCloseActiveSlotFocusesFirstAbsorbingNeighbor() throws {
        let leftID = UUID()
        let middleID = UUID()
        let rightID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: leftID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 12),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
                WorkspaceSlot(
                    id: middleID,
                    rect: GridRect(x: 3, y: 0, width: 3, height: 12),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: rightID,
                    rect: GridRect(x: 6, y: 0, width: 6, height: 12),
                    content: .changes
                ),
            ],
            activeSlotID: middleID
        )

        let events = catalog.closeSlot(middleID)

        XCTAssertEqual(catalog.activeSlotID, leftID)
        XCTAssertTrue(events.contains(.slotFocused(
            slot: leftID,
            tab: catalog.activeTab!.id,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testCloseInactiveSlotKeepsPreviousActiveSlot() {
        let leftID = UUID()
        let rightID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: leftID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
                WorkspaceSlot(
                    id: rightID,
                    rect: GridRect(x: 6, y: 0, width: 6, height: 12),
                    content: .terminal
                ),
            ],
            activeSlotID: rightID
        )

        catalog.closeSlot(leftID)

        XCTAssertEqual(catalog.activeSlotID, rightID)
    }

    func testFocusAndCycleSlotsFollowStableArrayOrder() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let first = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let second = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.vertical)
        let third = try XCTUnwrap(catalog.activeSlotID)

        catalog.focusNextSlot()
        XCTAssertEqual(catalog.activeSlotID, first)
        catalog.focusPreviousSlot()
        XCTAssertEqual(catalog.activeSlotID, third)
        catalog.focusSlot(second)
        XCTAssertEqual(catalog.activeSlotID, second)
    }

    func testFocusSlotAcrossWorkspaceEmitsWholeSelectionChain() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstWorkspaceID = catalog.activeWorkspaceID
        let firstTabID = try XCTUnwrap(catalog.activeTab?.id)
        let firstSlotID = try XCTUnwrap(catalog.activeSlotID)
        catalog.addWorkspace(name: "Two", path: projectPath)

        let events = catalog.focusSlot(firstSlotID)

        XCTAssertEqual(events, [
            .workspaceSelected(firstWorkspaceID),
            .tabSelected(tab: firstTabID, workspace: firstWorkspaceID),
            .slotFocused(
                slot: firstSlotID,
                tab: firstTabID,
                workspace: firstWorkspaceID
            ),
        ])
    }

    func testEveryContentTypeCanBeAssignedWithoutChangingSlotIdentity() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let slotID = try XCTUnwrap(catalog.activeSlotID)
        let contents: [SlotContent] = [
            .terminal,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"),
            .changes,
            .automation,
            .pluginView(pluginID: "dev.tenon.browser", viewID: "browser"),
            .pluginView(pluginID: "dev.tenon.git", viewID: "graph"),
            .empty,
        ]

        for content in contents.dropFirst() {
            let events = catalog.setSlotContent(slotID, content)
            XCTAssertEqual(catalog.slot(id: slotID)?.content, content)
            XCTAssertEqual(catalog.activeSlotID, slotID)
            XCTAssertTrue(events.contains { event in
                if case .slotContentChanged(let changedID, let changedContent, _, _) = event {
                    return changedID == slotID && changedContent == content
                }
                return false
            })
        }
    }

    func testApplyMoveTransactionCommitsCompleteValidProposal() throws {
        let firstID = UUID()
        let secondID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: firstID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 3),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: secondID,
                    rect: GridRect(x: 6, y: 0, width: 3, height: 3),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: firstID
        )
        let transaction = SpatialLayout.move(
            catalog.activeTab!.spatialSlots,
            slotID: firstID,
            toColumn: 0,
            row: 6
        )

        let events = catalog.applyMove(transaction)

        XCTAssertEqual(
            catalog.slot(id: firstID)?.rect,
            GridRect(x: 0, y: 6, width: 3, height: 3)
        )
        XCTAssertEqual(catalog.slot(id: firstID)?.content, .terminal)
        XCTAssertTrue(events.contains { if case .slotsMoved = $0 { return true }; return false })
    }

    func testApplyInvalidOrForeignMoveTransactionRollsBackEntireMutation() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        catalog.splitActiveSlot(.horizontal)
        let before = catalog
        let activeID = try XCTUnwrap(catalog.activeSlotID)
        let invalid = SpatialLayout.move(
            catalog.activeTab!.spatialSlots,
            slotID: activeID,
            toColumn: 0,
            row: 0
        )

        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(catalog.applyMove(invalid), [])
        XCTAssertEqual(catalog, before)

        let foreignID = UUID()
        let foreign = SpatialLayout.move(
            [SpatialSlot(id: foreignID, rect: GridRect(x: 0, y: 0, width: 3, height: 3))],
            slotID: foreignID,
            toColumn: 6,
            row: 6
        )
        XCTAssertTrue(foreign.isValid)
        XCTAssertEqual(catalog.applyMove(foreign), [])
        XCTAssertEqual(catalog, before)
    }

    func testApplyMoveRejectsStaleBaselineEvenWhenSlotIDsMatch() throws {
        let firstID = UUID()
        let secondID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: firstID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 3),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: secondID,
                    rect: GridRect(x: 6, y: 0, width: 3, height: 3),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: firstID
        )
        let stale = SpatialLayout.move(
            catalog.activeTab!.spatialSlots,
            slotID: firstID,
            toColumn: 0,
            row: 6
        )
        let intervening = SpatialLayout.move(
            catalog.activeTab!.spatialSlots,
            slotID: firstID,
            toColumn: 3,
            row: 0
        )
        catalog.applyMove(intervening)
        let afterIntervening = catalog

        XCTAssertEqual(catalog.applyMove(stale), [])
        XCTAssertEqual(catalog, afterIntervening)
    }

    func testApplyMoveRejectsForeignGeometryWithTheSameSlotIDs() {
        let firstID = UUID()
        let secondID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: firstID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 3),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: secondID,
                    rect: GridRect(x: 6, y: 0, width: 3, height: 3),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: firstID
        )
        let foreignBaseline = [
            SpatialSlot(
                id: firstID,
                rect: GridRect(x: 0, y: 6, width: 3, height: 3)
            ),
            SpatialSlot(
                id: secondID,
                rect: GridRect(x: 6, y: 6, width: 3, height: 3)
            ),
        ]
        let transaction = SpatialLayout.move(
            foreignBaseline,
            slotID: firstID,
            toColumn: 3,
            row: 6
        )
        let before = catalog

        XCTAssertEqual(catalog.applyMove(transaction), [])
        XCTAssertEqual(catalog, before)
    }

    func testApplyMoveRejectsZeroDeltaAndDoesNotEmitEvents() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let slotID = try XCTUnwrap(catalog.activeSlotID)
        let transaction = SpatialLayout.move(
            catalog.activeTab!.spatialSlots,
            slotID: slotID,
            toColumn: 0,
            row: 0
        )
        let before = catalog

        XCTAssertEqual(catalog.applyMove(transaction), [])
        XCTAssertEqual(catalog, before)
    }

    func testApplyMoveRejectsAffectedIDsThatDoNotMatchActualChanges() {
        let firstID = UUID()
        let secondID = UUID()
        var catalog = makeCatalog(
            slots: [
                WorkspaceSlot(
                    id: firstID,
                    rect: GridRect(x: 0, y: 0, width: 3, height: 3),
                    content: .terminal
                ),
                WorkspaceSlot(
                    id: secondID,
                    rect: GridRect(x: 6, y: 0, width: 3, height: 3),
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                ),
            ],
            activeSlotID: firstID
        )
        let baseline = catalog.activeTab!.spatialSlots
        let valid = SpatialLayout.move(
            baseline,
            slotID: firstID,
            toColumn: 0,
            row: 6
        )
        let mismatched = SpatialLayoutTransaction(
            kind: valid.kind,
            isValid: valid.isValid,
            baseline: valid.baseline,
            proposal: valid.proposal,
            affectedSlotIDs: [secondID]
        )
        let before = catalog

        XCTAssertEqual(catalog.applyMove(mismatched), [])
        XCTAssertEqual(catalog, before)
    }

    func testApplySwapTransactionSwapsGeometryButKeepsContentWithIdentity() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstID = try XCTUnwrap(catalog.activeSlotID)
        catalog.setSlotContent(
            firstID,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        catalog.splitActiveSlot(.horizontal, content: .changes)
        let secondID = try XCTUnwrap(catalog.activeSlotID)
        let firstRect = try XCTUnwrap(catalog.slot(id: firstID)?.rect)
        let secondRect = try XCTUnwrap(catalog.slot(id: secondID)?.rect)
        let transaction = SpatialLayout.swap(
            catalog.activeTab!.spatialSlots,
            firstSlotID: firstID,
            secondSlotID: secondID
        )

        let events = catalog.applySwap(transaction)

        XCTAssertEqual(catalog.slot(id: firstID)?.rect, secondRect)
        XCTAssertEqual(catalog.slot(id: secondID)?.rect, firstRect)
        XCTAssertEqual(
            catalog.slot(id: firstID)?.content,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        XCTAssertEqual(catalog.slot(id: secondID)?.content, .changes)
        XCTAssertTrue(events.contains { if case .slotsSwapped = $0 { return true }; return false })
    }

    func testMoveAndSwapTransactionsCannotBeAppliedThroughTheWrongOperation() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let secondID = try XCTUnwrap(catalog.activeSlotID)
        let before = catalog
        let swap = SpatialLayout.swap(
            catalog.activeTab!.spatialSlots,
            firstSlotID: firstID,
            secondSlotID: secondID
        )

        XCTAssertEqual(catalog.applyMove(swap), [])
        XCTAssertEqual(catalog, before)

        let move = SpatialLayout.move(
            catalog.activeTab!.spatialSlots,
            slotID: firstID,
            toColumn: 0,
            row: 6
        )
        XCTAssertTrue(move.isValid)
        XCTAssertEqual(catalog.applySwap(move), [])
        XCTAssertEqual(catalog, before)
    }

    func testApplySwapPreservesDraggedThenTargetOrderInEvent() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let firstInTab = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let secondInTab = try XCTUnwrap(catalog.activeSlotID)
        let tabID = try XCTUnwrap(catalog.activeTab?.id)
        let workspaceID = catalog.activeWorkspaceID
        let transaction = SpatialLayout.swap(
            catalog.activeTab!.spatialSlots,
            firstSlotID: secondInTab,
            secondSlotID: firstInTab
        )

        XCTAssertEqual(catalog.applySwap(transaction), [
            .slotsSwapped(
                first: secondInTab,
                second: firstInTab,
                tab: tabID,
                workspace: workspaceID
            ),
        ])
    }

    func testApplyResizeTransactionCommitsCoupledGeometryAtomically() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let leftID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let rightID = try XCTUnwrap(catalog.activeSlotID)
        let transaction = SpatialLayout.resize(
            catalog.activeTab!.spatialSlots,
            slotID: leftID,
            direction: .east,
            deltaColumns: 2,
            deltaRows: 0
        )

        let events = catalog.applyResize(transaction)

        XCTAssertEqual(
            catalog.slot(id: leftID)?.rect,
            GridRect(x: 0, y: 0, width: 8, height: 12)
        )
        XCTAssertEqual(
            catalog.slot(id: rightID)?.rect,
            GridRect(x: 8, y: 0, width: 4, height: 12)
        )
        XCTAssertTrue(events.contains { event in
            if case .slotsResized(let ids, let detached, _, _) = event {
                return Set(ids) == Set([leftID, rightID]) && !detached
            }
            return false
        })
    }

    func testFillSlotWidthGrowsThePaneIntoTheFreeColumnsBesideIt() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let leftID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let topRightID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitSlot(topRightID, .vertical)
        let tabID = try XCTUnwrap(catalog.activeTab?.id)
        // A detached west drag leaves columns 6..8 of the top band empty, which is the
        // only way a pane ends up with free space to grow back into.
        catalog.applyResize(SpatialLayout.resize(
            try XCTUnwrap(catalog.activeTab?.spatialSlots),
            slotID: topRightID,
            direction: .west,
            deltaColumns: 2,
            deltaRows: 0
        ))
        XCTAssertEqual(
            catalog.slot(id: topRightID)?.rect,
            GridRect(x: 8, y: 0, width: 4, height: 6)
        )

        let events = catalog.fillSlotWidth(topRightID)

        XCTAssertEqual(
            catalog.slot(id: topRightID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 6)
        )
        XCTAssertEqual(
            catalog.slot(id: leftID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(events, [
            .slotsResized(
                slots: [topRightID],
                detached: false,
                tab: tabID,
                workspace: catalog.activeWorkspaceID
            ),
        ])
    }

    func testFillSlotWidthOfAFullBandPaneOrAnUnknownPaneIsANoOp() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let leftID = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal)
        let before = catalog

        XCTAssertEqual(catalog.fillSlotWidth(leftID), [])
        XCTAssertEqual(catalog.fillSlotWidth(UUID()), [])
        XCTAssertEqual(catalog, before)
    }

    func testMoveSlotToNewTabReparentsKeepingIdentityAndReflowsSource() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let leftID = try XCTUnwrap(catalog.activeSlotID)
        catalog.setSlotContent(
            leftID,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        catalog.splitActiveSlot(.horizontal, content: .terminal)
        let rightID = try XCTUnwrap(catalog.activeSlotID)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)
        let wsID = catalog.activeWorkspaceID

        let events = catalog.moveSlotToNewTab(rightID)

        // Source tab reflows: the surviving left slot absorbs the freed space.
        XCTAssertEqual(catalog.activeWorkspace?.tabs.count, 2)
        let sourceTab = try XCTUnwrap(
            catalog.activeWorkspace?.tabs.first { $0.id == sourceTabID }
        )
        XCTAssertEqual(sourceTab.slots.map(\.id), [leftID])
        XCTAssertEqual(sourceTab.slots.first?.rect, fullGrid)
        XCTAssertEqual(sourceTab.activeSlotID, leftID)

        // The moved slot keeps its identity + content, now full-grid in the new tab.
        let newTab = try XCTUnwrap(catalog.activeTab)
        XCTAssertNotEqual(newTab.id, sourceTabID)
        XCTAssertEqual(newTab.slots.map(\.id), [rightID])
        XCTAssertEqual(newTab.slots.first?.rect, fullGrid)
        XCTAssertEqual(newTab.slots.first?.content, .terminal)
        XCTAssertEqual(newTab.activeSlotID, rightID)
        XCTAssertEqual(catalog.activeWorkspace?.activeTabID, newTab.id)
        XCTAssertTrue(catalog.allSlotIDs.contains(rightID))

        XCTAssertEqual(events, [
            .slotsResized(
                slots: [leftID],
                detached: false,
                tab: sourceTabID,
                workspace: wsID
            ),
            .tabOpened(tab: newTab.id, workspace: wsID),
            .slotMovedToTab(
                slot: rightID,
                fromTab: sourceTabID,
                toTab: newTab.id,
                workspace: wsID
            ),
            .tabSelected(tab: newTab.id, workspace: wsID),
            .slotFocused(slot: rightID, tab: newTab.id, workspace: wsID),
        ])
    }

    func testMoveSingleSlotToNewTabClosesTheEmptySourceTab() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let slotID = try XCTUnwrap(catalog.activeSlotID)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)

        let events = catalog.moveSlotToNewTab(slotID)

        XCTAssertEqual(catalog.activeWorkspace?.tabs.count, 1)
        XCTAssertFalse(catalog.activeWorkspace!.tabs.contains { $0.id == sourceTabID })

        let newTab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(newTab.slots.map(\.id), [slotID])
        XCTAssertEqual(newTab.slots.first?.rect, fullGrid)
        XCTAssertEqual(newTab.activeSlotID, slotID)

        XCTAssertFalse(events.contains { if case .slotsResized = $0 { return true }; return false })
        XCTAssertTrue(events.contains(.slotMovedToTab(
            slot: slotID,
            fromTab: sourceTabID,
            toTab: newTab.id,
            workspace: catalog.activeWorkspaceID
        )))
        XCTAssertTrue(events.contains(.tabClosed(
            tab: sourceTabID,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testMoveOnlySlotIntoExistingTabClosesTheEmptySourceTab() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let movingID = try XCTUnwrap(catalog.activeSlotID)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let targetTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.selectTab(sourceTabID)

        let events = catalog.moveSlot(movingID, toTab: targetTabID)

        XCTAssertEqual(catalog.activeWorkspace?.tabs.map(\.id), [targetTabID])
        XCTAssertEqual(catalog.activeTab?.activeSlotID, movingID)
        XCTAssertTrue(events.contains(.tabClosed(
            tab: sourceTabID,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testMoveOnlySlotBesidePaneClosesTheEmptySourceTab() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let movingID = try XCTUnwrap(catalog.activeSlotID)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let targetTabID = try XCTUnwrap(catalog.activeTab?.id)
        let targetSlotID = try XCTUnwrap(catalog.activeSlotID)

        let events = catalog.moveSlot(
            movingID,
            toTab: targetTabID,
            beside: targetSlotID,
            edge: .left
        )

        XCTAssertEqual(catalog.activeWorkspace?.tabs.map(\.id), [targetTabID])
        XCTAssertEqual(catalog.activeTab?.activeSlotID, movingID)
        XCTAssertTrue(events.contains(.tabClosed(
            tab: sourceTabID,
            workspace: catalog.activeWorkspaceID
        )))
    }

    func testMoveUnknownSlotToNewTabIsAtomicNoOp() {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let before = catalog

        XCTAssertEqual(catalog.moveSlotToNewTab(UUID()), [])
        XCTAssertEqual(catalog, before)
    }

    func testMoveSlotIntoExistingTabSplitsFullTargetAndFocusesIt() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let sourceLeft = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(
            .horizontal,
            content: .pluginView(
                pluginID: "dev.tenon.file-explorer",
                viewID: "tree"
            )
        )
        let movingID = try XCTUnwrap(catalog.activeSlotID)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let targetTabID = try XCTUnwrap(catalog.activeTab?.id)
        let targetOriginal = try XCTUnwrap(catalog.activeSlotID)
        catalog.selectTab(sourceTabID)
        let wsID = catalog.activeWorkspaceID

        let events = catalog.moveSlot(movingID, toTab: targetTabID)

        XCTAssertEqual(catalog.activeWorkspace?.activeTabID, targetTabID)
        let targetTab = try XCTUnwrap(catalog.activeTab)
        XCTAssertEqual(Set(targetTab.slots.map(\.id)), Set([targetOriginal, movingID]))
        XCTAssertEqual(targetTab.activeSlotID, movingID)
        XCTAssertEqual(
            catalog.slot(id: movingID)?.content,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        XCTAssertEqual(
            catalog.slot(id: targetOriginal)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(
            catalog.slot(id: movingID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )

        // Source tab reflows to a single full-grid slot.
        let sourceTab = try XCTUnwrap(
            catalog.activeWorkspace?.tabs.first { $0.id == sourceTabID }
        )
        XCTAssertEqual(sourceTab.slots.map(\.id), [sourceLeft])
        XCTAssertEqual(sourceTab.slots.first?.rect, fullGrid)

        XCTAssertTrue(events.contains(.slotMovedToTab(
            slot: movingID,
            fromTab: sourceTabID,
            toTab: targetTabID,
            workspace: wsID
        )))
        XCTAssertTrue(events.contains(.slotsResized(
            slots: [targetOriginal],
            detached: false,
            tab: targetTabID,
            workspace: wsID
        )))
        XCTAssertTrue(events.contains(.tabSelected(tab: targetTabID, workspace: wsID)))
        XCTAssertTrue(events.contains(.slotFocused(
            slot: movingID,
            tab: targetTabID,
            workspace: wsID
        )))
    }

    func testMoveSlotIntoEmptyTargetTabFillsTheGrid() throws {
        let a = UUID()
        let b = UUID()
        let sourceTab = Tab(
            slots: [
                WorkspaceSlot(
                    id: a,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12)
                ),
                WorkspaceSlot(
                    id: b,
                    rect: GridRect(x: 6, y: 0, width: 6, height: 12)
                ),
            ],
            activeSlotID: b
        )
        // An empty non-final tab can only arrive through restored legacy state now that
        // pane-level mutations collapse one immediately. Keep accepting that state so a
        // move into it repairs the catalog instead of refusing the destination.
        let targetTab = Tab(slots: [], activeSlotID: nil, number: 2)
        let workspace = Workspace(
            name: "One",
            path: projectPath,
            tabs: [sourceTab, targetTab],
            activeTabID: sourceTab.id
        )
        var catalog = WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )

        catalog.moveSlot(b, toTab: targetTab.id)

        let repairedTargetTab = try XCTUnwrap(
            catalog.activeWorkspace?.tabs.first { $0.id == targetTab.id }
        )
        XCTAssertEqual(repairedTargetTab.slots.map(\.id), [b])
        XCTAssertEqual(repairedTargetTab.slots.first?.rect, fullGrid)
        XCTAssertEqual(repairedTargetTab.activeSlotID, b)
        XCTAssertEqual(catalog.activeWorkspace?.activeTabID, targetTab.id)

        let repairedSourceTab = try XCTUnwrap(
            catalog.activeWorkspace?.tabs.first { $0.id == sourceTab.id }
        )
        XCTAssertEqual(repairedSourceTab.slots.map(\.id), [a])
        XCTAssertEqual(repairedSourceTab.slots.first?.rect, fullGrid)
    }

    func testMoveSlotBesidePaneInHoverSelectedTabCommitsRequestedEdge() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let sourceLeft = try XCTUnwrap(catalog.activeSlotID)
        catalog.splitActiveSlot(.horizontal, content: .changes)
        let movingID = try XCTUnwrap(catalog.activeSlotID)
        let sourceTabID = try XCTUnwrap(catalog.activeTab?.id)
        catalog.newTab()
        let targetTabID = try XCTUnwrap(catalog.activeTab?.id)
        let targetID = try XCTUnwrap(catalog.activeSlotID)

        // Hover already revealed the target before mouse-up.
        XCTAssertEqual(catalog.activeTab?.id, targetTabID)
        let events = catalog.moveSlot(
            movingID,
            toTab: targetTabID,
            beside: targetID,
            edge: .left
        )

        XCTAssertEqual(catalog.activeTab?.slots.map(\.id), [targetID, movingID])
        XCTAssertEqual(
            catalog.slot(id: movingID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12)
        )
        XCTAssertEqual(
            catalog.slot(id: targetID)?.rect,
            GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        let sourceTab = try XCTUnwrap(
            catalog.activeWorkspace?.tabs.first { $0.id == sourceTabID }
        )
        XCTAssertEqual(sourceTab.slots.map(\.id), [sourceLeft])
        XCTAssertEqual(sourceTab.slots.first?.rect, fullGrid)
        XCTAssertFalse(events.contains {
            if case .tabSelected = $0 { return true }
            return false
        }, "drop must not publish a second selection after hover selected the tab")
    }

    func testMoveSlotAtRectPlacesThePaneInTheChosenEmptyRegion() throws {
        let stayingID = UUID()
        let movingID = UUID()
        let targetID = UUID()
        let sourceTab = Tab(
            slots: [
                WorkspaceSlot(
                    id: stayingID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12)
                ),
                WorkspaceSlot(
                    id: movingID,
                    rect: GridRect(x: 6, y: 0, width: 6, height: 12)
                ),
            ],
            activeSlotID: movingID
        )
        let targetTab = Tab(
            slots: [
                WorkspaceSlot(
                    id: targetID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12)
                ),
            ],
            activeSlotID: targetID,
            number: 2
        )
        let workspace = Workspace(
            name: "One",
            path: projectPath,
            tabs: [sourceTab, targetTab],
            // Hover already revealed the target before mouse-up.
            activeTabID: targetTab.id
        )
        var catalog = WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let rect = GridRect(x: 6, y: 3, width: 6, height: 9)

        let events = catalog.moveSlot(movingID, toTab: targetTab.id, at: rect)

        XCTAssertEqual(catalog.activeTab?.id, targetTab.id)
        XCTAssertEqual(catalog.activeTab?.slots.map(\.id), [targetID, movingID])
        XCTAssertEqual(catalog.slot(id: movingID)?.rect, rect)
        XCTAssertEqual(
            catalog.slot(id: targetID)?.rect,
            GridRect(x: 0, y: 0, width: 6, height: 12),
            "admitting into a hole reshapes no existing pane"
        )
        XCTAssertEqual(catalog.activeTab?.activeSlotID, movingID)
        let sourceAfter = try XCTUnwrap(
            catalog.activeWorkspace?.tabs.first { $0.id == sourceTab.id }
        )
        XCTAssertEqual(sourceAfter.slots.map(\.id), [stayingID])
        XCTAssertEqual(sourceAfter.slots.first?.rect, fullGrid)
        XCTAssertTrue(events.contains(.slotMovedToTab(
            slot: movingID,
            fromTab: sourceTab.id,
            toTab: targetTab.id,
            workspace: workspace.id
        )))
        XCTAssertTrue(events.contains(.slotFocused(
            slot: movingID,
            tab: targetTab.id,
            workspace: workspace.id
        )))
        XCTAssertFalse(events.contains {
            if case .tabSelected = $0 { return true }
            return false
        }, "drop must not publish a second selection after hover selected the tab")
    }

    func testMoveSlotAtRectRefusesOccupiedRegionSameTabAndUnknownTargetAtomically() throws {
        let movingID = UUID()
        let targetID = UUID()
        let sourceTab = Tab(
            slots: [
                WorkspaceSlot(id: movingID, rect: fullGrid),
            ],
            activeSlotID: movingID
        )
        let targetTab = Tab(
            slots: [
                WorkspaceSlot(
                    id: targetID,
                    rect: GridRect(x: 0, y: 0, width: 6, height: 12)
                ),
            ],
            activeSlotID: targetID,
            number: 2
        )
        let workspace = Workspace(
            name: "One",
            path: projectPath,
            tabs: [sourceTab, targetTab],
            activeTabID: targetTab.id
        )
        var catalog = WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let before = catalog

        XCTAssertEqual(catalog.moveSlot(
            movingID,
            toTab: targetTab.id,
            at: GridRect(x: 3, y: 0, width: 6, height: 12)
        ), [], "a region overlapping an existing pane refuses the whole move")
        XCTAssertEqual(catalog, before)

        XCTAssertEqual(catalog.moveSlot(
            movingID,
            toTab: sourceTab.id,
            at: GridRect(x: 6, y: 0, width: 6, height: 12)
        ), [], "the slot's own tab is not a cross-tab destination")
        XCTAssertEqual(catalog, before)

        XCTAssertEqual(catalog.moveSlot(
            movingID,
            toTab: UUID(),
            at: GridRect(x: 6, y: 0, width: 6, height: 12)
        ), [])
        XCTAssertEqual(catalog, before)
    }

    func testMoveSlotIntoSameTabOrUnknownTargetIsAtomicNoOp() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)
        let a = try XCTUnwrap(catalog.activeSlotID)
        let tabID = try XCTUnwrap(catalog.activeTab?.id)
        let before = catalog

        XCTAssertEqual(catalog.moveSlot(a, toTab: tabID), [])
        XCTAssertEqual(catalog, before)

        XCTAssertEqual(catalog.moveSlot(a, toTab: UUID()), [])
        XCTAssertEqual(catalog, before)

        XCTAssertEqual(catalog.moveSlot(UUID(), toTab: tabID), [])
        XCTAssertEqual(catalog, before)
    }

    func testConstructionValidationRejectsDuplicateWorkspaceTabAndSlotIDs() {
        let sharedSlotID = UUID()
        let firstTab = Tab(
            id: UUID(),
            slots: [
                WorkspaceSlot(id: sharedSlotID, rect: fullGrid),
            ],
            activeSlotID: sharedSlotID
        )
        let secondTab = Tab(
            id: UUID(),
            slots: [
                WorkspaceSlot(id: sharedSlotID, rect: fullGrid),
            ],
            activeSlotID: sharedSlotID
        )

        XCTAssertFalse(Workspace.isValid(
            tabs: [firstTab, firstTab],
            activeTabID: firstTab.id
        ))
        XCTAssertFalse(Workspace.isValid(
            tabs: [firstTab, secondTab],
            activeTabID: firstTab.id
        ))

        let firstWorkspace = Workspace(
            name: "One",
            path: projectPath,
            tabs: [firstTab],
            activeTabID: firstTab.id
        )
        XCTAssertFalse(WorkspaceCatalog.isValid(
            workspaces: [firstWorkspace, firstWorkspace],
            activeWorkspaceID: firstWorkspace.id
        ))

        let otherWorkspace = Workspace(
            name: "Two",
            path: projectPath,
            tabs: [secondTab],
            activeTabID: secondTab.id
        )
        XCTAssertFalse(WorkspaceCatalog.isValid(
            workspaces: [firstWorkspace, otherWorkspace],
            activeWorkspaceID: firstWorkspace.id
        ))
    }

    private var fullGrid: GridRect {
        GridRect(
            x: 0,
            y: 0,
            width: SpatialLayout.columns,
            height: SpatialLayout.rows
        )
    }

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
}

final class WorkspaceStoreTests: XCTestCase {
    func testMutationPublishesEventsWithTheSnapshotItProduced() {
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                name: "One",
                path: URL(fileURLWithPath: "/tmp/one", isDirectory: true)
            )
        )
        var received: [(events: [WorkspaceEvent], snapshot: WorkspaceCatalog)] = []
        store.onEvents = { events, snapshot in received.append((events, snapshot)) }

        store.addSlot(
            content: .pluginView(
                pluginID: "dev.tenon.file-explorer",
                viewID: "tree"
            )
        )

        XCTAssertEqual(store.catalog.activeTab?.slots.count, 2)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].snapshot.activeTab?.slots.count, 2)
        XCTAssertTrue(received[0].events.contains { if case .slotOpened = $0 { return true }; return false })
    }

    func testNoOpMutationDoesNotPublishOrForward() {
        let store = WorkspaceStore()
        var batches = 0
        store.onEvents = { _, _ in batches += 1 }

        store.selectWorkspace(store.catalog.activeWorkspaceID)

        XCTAssertEqual(batches, 0)
    }
}
