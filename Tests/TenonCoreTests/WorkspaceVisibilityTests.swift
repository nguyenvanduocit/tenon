// @domain: workspace-model
import Foundation
import TenonCore
import XCTest

final class WorkspaceVisibilityTests: XCTestCase {
    func testNewWorkspaceStartsVisible() {
        let catalog = WorkspaceCatalog()
        XCTAssertEqual(catalog.workspaces[0].visibility, .visible)
    }

    func testSettingBackgroundOnANonActiveWorkspaceEmitsOnlyVisibilityChanged() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = catalog.workspaces[1].id
        catalog.selectWorkspace(catalog.workspaces[0].id)

        let events = catalog.setVisibility(second, to: .background)

        XCTAssertEqual(events, [.workspaceVisibilityChanged(second)])
        XCTAssertEqual(catalog.workspaces.first { $0.id == second }?.visibility, .background)
        XCTAssertEqual(catalog.activeWorkspaceID, catalog.workspaces[0].id)
    }

    func testBackgroundingTheActiveWorkspaceReselectsAVisibleNeighbor() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let first = catalog.workspaces[0].id
        let second = catalog.workspaces[1].id
        catalog.selectWorkspace(first)

        let events = catalog.setVisibility(first, to: .background)

        XCTAssertEqual(catalog.activeWorkspaceID, second)
        XCTAssertTrue(events.contains(.workspaceVisibilityChanged(first)))
        XCTAssertTrue(events.contains(.workspaceSelected(second)))
        guard let tab = catalog.workspaces.first(where: { $0.id == second })?.activeTab else {
            return XCTFail("second workspace lost its active tab")
        }
        XCTAssertTrue(events.contains(.tabSelected(tab: tab.id, workspace: second)))
    }

    func testBackgroundingTheOnlyVisibleWorkspaceIsRefused() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let first = catalog.workspaces[0].id
        let second = catalog.workspaces[1].id
        _ = catalog.setVisibility(second, to: .background)

        let events = catalog.setVisibility(first, to: .background)

        XCTAssertEqual(events, [])
        XCTAssertEqual(catalog.workspaces.first { $0.id == first }?.visibility, .visible)
    }

    func testSettingVisibleOnAnAlreadyVisibleWorkspaceIsANoOp() {
        var catalog = WorkspaceCatalog()
        let id = catalog.workspaces[0].id
        XCTAssertEqual(catalog.setVisibility(id, to: .visible), [])
    }

    func testRestoringVisibilityAfterBackgroundingEmitsOnlyVisibilityChanged() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = catalog.workspaces[1].id
        _ = catalog.setVisibility(second, to: .background)

        let events = catalog.setVisibility(second, to: .visible)

        XCTAssertEqual(events, [.workspaceVisibilityChanged(second)])
        XCTAssertEqual(catalog.workspaces.first { $0.id == second }?.visibility, .visible)
    }

    func testSettingVisibilityOnAnUnknownWorkspaceIsANoOp() {
        var catalog = WorkspaceCatalog()
        XCTAssertEqual(catalog.setVisibility(UUID(), to: .background), [])
    }

    func testStoreSetVisibilityAppliesThroughTheCatalogAndPublishesEvents() {
        let store = WorkspaceStore()
        var published: [WorkspaceEvent] = []
        store.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = store.catalog.workspaces[1].id
        // addWorkspace makes the new workspace active; reselect the first so backgrounding
        // the second is the non-active, single-event case this test means to cover.
        store.selectWorkspace(store.catalog.workspaces[0].id)
        store.onEvents = { events, _ in published = events }

        store.setVisibility(second, to: .background)

        XCTAssertEqual(store.catalog.workspaces.first { $0.id == second }?.visibility, .background)
        XCTAssertEqual(published, [.workspaceVisibilityChanged(second)])
    }
}
