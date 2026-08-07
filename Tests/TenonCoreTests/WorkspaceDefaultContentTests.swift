import XCTest
@testable import TenonCore

/// The workspace opens new panes with a caller-chosen content, and the store resolves
/// that content from injected providers (the shell wires them to `AppPreferences`).
final class WorkspaceDefaultContentTests: XCTestCase {
    private let projectPath = URL(fileURLWithPath: "/tmp/tenon-project", isDirectory: true)

    // MARK: - Catalog honours the requested content

    func testNewTabOpensWithTheRequestedContent() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)

        catalog.newTab(
            content: .pluginView(
                pluginID: "dev.tenon.file-explorer",
                viewID: "tree"
            )
        )

        let slot = try XCTUnwrap(catalog.activeTab?.slots.first)
        XCTAssertEqual(
            slot.content,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
    }

    func testNewTabStillDefaultsToTerminal() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)

        catalog.newTab()

        XCTAssertEqual(catalog.activeTab?.slots.first?.content, .terminal)
    }

    func testAddWorkspaceOpensWithTheRequestedContent() throws {
        var catalog = WorkspaceCatalog(name: "One", path: projectPath)

        catalog.addWorkspace(name: "Two", path: projectPath, content: .docs)

        let slot = try XCTUnwrap(catalog.activeTab?.slots.first)
        XCTAssertEqual(slot.content, .docs)
    }

    func testInitialWorkspaceInitOpensWithTheRequestedContent() throws {
        let workspace = Workspace(name: "One", path: projectPath, content: .empty)

        XCTAssertEqual(workspace.tabs.first?.slots.first?.content, .empty)
    }

    // MARK: - Store resolves content from providers

    func testStoreNewTabUsesTheNewTabProvider() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "One", path: projectPath))
        store.newTabContentProvider = {
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        }

        store.newTab()

        XCTAssertEqual(
            store.catalog.activeTab?.slots.first?.content,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
    }

    func testStoreSplitUsesTheSplitProvider() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "One", path: projectPath))
        store.newSplitContentProvider = { .changes }

        store.splitActiveSlot(.horizontal)

        let newContent = store.catalog.activeTab?.activeSlot?.content
        XCTAssertEqual(newContent, .changes)
    }

    func testStoreSplitSlotUsesTheSplitProvider() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "One", path: projectPath))
        store.newSplitContentProvider = { .docs }
        let target = try XCTUnwrap(store.catalog.activeSlotID)

        store.splitSlot(target, .vertical)

        XCTAssertEqual(store.catalog.activeTab?.activeSlot?.content, .docs)
    }

    func testStoreAddWorkspaceUsesTheWorkspaceProvider() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "One", path: projectPath))
        store.newWorkspaceContentProvider = {
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        }

        store.addWorkspace(name: "Two", path: projectPath)

        XCTAssertEqual(
            store.catalog.activeTab?.slots.first?.content,
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
    }

    func testExplicitContentOverridesTheProvider() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "One", path: projectPath))
        store.newTabContentProvider = {
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        }

        store.newTab(content: .empty)

        XCTAssertEqual(store.catalog.activeTab?.slots.first?.content, .empty)
    }
}
