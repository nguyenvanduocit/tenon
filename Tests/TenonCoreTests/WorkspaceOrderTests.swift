import XCTest

@testable import TenonCore

final class WorkspaceOrderTests: XCTestCase {
    private func catalog(workspaceCount: Int = 4) -> WorkspaceCatalog {
        var catalog = WorkspaceCatalog(
            name: "Workspace 1",
            path: URL(fileURLWithPath: "/tmp/tenon-workspace-order-1", isDirectory: true)
        )
        for number in 2 ... workspaceCount {
            catalog.addWorkspace(
                name: "Workspace \(number)",
                path: URL(
                    fileURLWithPath: "/tmp/tenon-workspace-order-\(number)",
                    isDirectory: true
                )
            )
        }
        return catalog
    }

    func testMovingAWorkspaceForwardAndBackwardChangesOnlyItsOrder() {
        var catalog = catalog()
        let before = catalog.workspaces
        let active = catalog.activeWorkspaceID

        let forward = catalog.moveWorkspace(before[0].id, to: 2)

        XCTAssertEqual(
            catalog.workspaces.map(\.id),
            [before[1].id, before[2].id, before[0].id, before[3].id]
        )
        XCTAssertEqual(forward, [
            .workspaceMoved(workspace: before[0].id, from: 0, to: 2),
        ])
        XCTAssertEqual(catalog.activeWorkspaceID, active)
        XCTAssertEqual(Set(catalog.workspaces.map(\.id)), Set(before.map(\.id)))

        catalog.moveWorkspace(before[3].id, to: 0)
        XCTAssertEqual(
            catalog.workspaces.map(\.id),
            [before[3].id, before[1].id, before[2].id, before[0].id]
        )
    }

    func testMovingTheActiveWorkspaceKeepsItsTabPaneAndSelection() throws {
        var catalog = catalog()
        let active = try XCTUnwrap(catalog.activeWorkspace)
        let catalogBefore = catalog

        catalog.moveWorkspace(active.id, to: 2)

        XCTAssertEqual(catalog.activeWorkspaceID, active.id)
        XCTAssertEqual(catalog.activeWorkspace, active)
        XCTAssertEqual(catalog.allSlotIDs.sorted(), catalogBefore.allSlotIDs.sorted())
    }

    func testInvalidAndNoOpMovesPublishNothing() {
        var catalog = catalog(workspaceCount: 3)
        let before = catalog
        let id = catalog.workspaces[1].id

        XCTAssertEqual(catalog.moveWorkspace(id, to: 1), [])
        XCTAssertEqual(catalog.moveWorkspace(id, to: -1), [])
        XCTAssertEqual(catalog.moveWorkspace(id, to: 3), [])
        XCTAssertEqual(catalog.moveWorkspace(UUID(), to: 0), [])
        XCTAssertEqual(catalog, before)
    }

    func testTheStorePublishesARealMoveAndKeepsANoOpSilent() {
        let store = WorkspaceStore(catalog: catalog(workspaceCount: 3))
        let ids = store.catalog.workspaces.map(\.id)
        let snapshotBefore = store.snapshotID
        var published: [WorkspaceEvent] = []
        store.onEvents = { events, _ in published.append(contentsOf: events) }

        store.moveWorkspace(ids[2], to: 0)

        XCTAssertEqual(store.catalog.workspaces.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(published, [
            .workspaceMoved(workspace: ids[2], from: 2, to: 0),
        ])
        XCTAssertNotEqual(store.snapshotID, snapshotBefore)

        published.removeAll()
        let settledSnapshot = store.snapshotID
        store.moveWorkspace(ids[2], to: 0)
        XCTAssertEqual(published, [])
        XCTAssertEqual(store.snapshotID, settledSnapshot)
    }

    func testTheChosenOrderSurvivesCatalogRoundTrip() throws {
        var catalog = catalog()
        let ids = catalog.workspaces.map(\.id)
        catalog.selectWorkspace(ids[1])
        catalog.moveWorkspace(ids[3], to: 0)
        catalog.moveWorkspace(ids[0], to: 2)
        let expected = catalog.workspaces.map(\.id)

        let data = try JSONEncoder().encode(WorkspaceCatalogSnapshot.document(capturing: catalog))
        let document = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: data
        )
        let restored = try XCTUnwrap(
            WorkspaceCatalogSnapshot.restore(
                document,
                isDirectory: { _ in true },
                isFileReadable: { _ in true },
                isKnownPluginView: { _, _ in true }
            )
        )

        XCTAssertEqual(restored.catalog.workspaces.map(\.id), expected)
        XCTAssertEqual(restored.catalog.activeWorkspaceID, ids[1])
    }
}
