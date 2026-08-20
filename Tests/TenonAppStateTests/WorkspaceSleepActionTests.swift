import Foundation
import SwiftUI
@testable import TenonApp
@testable import TenonCore
import TenonIntentCore
import XCTest

@MainActor
final class WorkspaceSleepActionTests: XCTestCase {
    func testSleepingAWorkspaceReleasesOnlyItsOwnTerminalSurfaces() async throws {
        let fixture = try makeFixture()
        let firstPaneID = try XCTUnwrap(fixture.store.catalog.workspaces[0].tabs[0].slots.first?.id)
        let secondPaneID = try XCTUnwrap(fixture.store.catalog.workspaces[1].tabs[0].slots.first?.id)
        _ = fixture.pool.surface(for: firstPaneID, workspacePath: fixture.store.catalog.workspaces[0].path)
        _ = fixture.pool.surface(for: secondPaneID, workspacePath: fixture.store.catalog.workspaces[1].path)
        XCTAssertTrue(fixture.pool.hasEverBeenViewed(firstPaneID))
        XCTAssertTrue(fixture.pool.hasEverBeenViewed(secondPaneID))

        fixture.sleepAction(fixture.store.catalog.workspaces[0].id)

        XCTAssertFalse(fixture.pool.hasEverBeenViewed(firstPaneID))
        XCTAssertTrue(fixture.pool.hasEverBeenViewed(secondPaneID))
    }

    func testSleepingTheActiveWorkspaceSwitchesActiveFirst() async throws {
        let fixture = try makeFixture()
        let first = fixture.store.catalog.workspaces[0].id
        let second = fixture.store.catalog.workspaces[1].id
        XCTAssertEqual(fixture.store.catalog.activeWorkspaceID, first)

        fixture.sleepAction(first)

        XCTAssertEqual(fixture.store.catalog.activeWorkspaceID, second)
    }

    func testSleepingTheOnlyWorkspaceLeavesActiveUnchangedAndStillReleasesItsSurface() async throws {
        let store = WorkspaceStore()
        let host = try makeEmptyHost()
        let registry = SleepTestSurfaceRegistry()
        let pool = SurfacePool(backendName: "Test") { slotID, _ in registry.surface(for: slotID) }
        let webSurfaces = PluginWebSurfacePool()
        let sleepAction = WorkspaceSleepAction()
        sleepAction.perform = Self.performBody(
            store: store,
            terminalSurfaces: pool,
            webSurfaces: webSurfaces,
            host: host
        )
        let onlyWorkspaceID = store.catalog.activeWorkspaceID
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        _ = pool.surface(for: paneID, workspacePath: store.catalog.activeWorkspace!.path)

        sleepAction(onlyWorkspaceID)

        XCTAssertEqual(store.catalog.activeWorkspaceID, onlyWorkspaceID)
        XCTAssertFalse(pool.hasEverBeenViewed(paneID))
    }
}

private extension WorkspaceSleepActionTests {
    struct Fixture {
        let store: WorkspaceStore
        let pool: SurfacePool
        let sleepAction: WorkspaceSleepAction
        // Held only so they outlive this fixture's returning scope — `sleepAction.perform`
        // captures both weakly, so an unretained `webSurfaces`/`host` deallocates the
        // instant `makeFixture()` returns and every later `sleepAction(_:)` call silently
        // no-ops on its own guard.
        let webSurfaces: PluginWebSurfacePool
        let host: PluginHost
    }

    func makeFixture() throws -> Fixture {
        let store = WorkspaceStore()
        store.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/sleep-second"))
        store.selectWorkspace(store.catalog.workspaces[0].id)
        let host = try makeEmptyHost()
        let registry = SleepTestSurfaceRegistry()
        let pool = SurfacePool(backendName: "Test") { slotID, _ in registry.surface(for: slotID) }
        let webSurfaces = PluginWebSurfacePool()
        let sleepAction = WorkspaceSleepAction()
        sleepAction.perform = Self.performBody(
            store: store,
            terminalSurfaces: pool,
            webSurfaces: webSurfaces,
            host: host
        )
        return Fixture(
            store: store,
            pool: pool,
            sleepAction: sleepAction,
            webSurfaces: webSurfaces,
            host: host
        )
    }

    func makeEmptyHost() throws -> PluginHost {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tenon-sleep-empty-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-state", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateRoot) }
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        return try PluginHost(
            pluginsRoot: root,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory
        )
    }

    /// The exact body `TenonApp.swift`'s composition assigns to `sleepAction.perform` in
    /// production — duplicated here rather than shared, because `AppComposition`'s `init`
    /// is not itself unit-testable. Keep the two in sync by contract.
    static func performBody(
        store: WorkspaceStore,
        terminalSurfaces: SurfacePool,
        webSurfaces: PluginWebSurfacePool,
        host: PluginHost
    ) -> (UUID) -> Void {
        { [weak store, weak terminalSurfaces, weak webSurfaces, weak host] workspaceID in
            guard let store, let terminalSurfaces, let webSurfaces, let host,
                  let workspace = store.catalog.workspaces.first(where: { $0.id == workspaceID })
            else { return }

            if store.catalog.activeWorkspaceID == workspaceID,
               let neighbor = store.catalog.workspaces.first(where: { $0.id != workspaceID })
            {
                store.selectWorkspace(neighbor.id)
            }

            let ownedSlotIDs = Set(workspace.tabs.flatMap { $0.slots.map(\.id) })
            terminalSurfaces.retainOnly(
                Set(store.catalog.allSlotIDs).subtracting(ownedSlotIDs)
            )
            let ownedPluginViewSlots = store.catalog.pluginViewSlots.filter {
                ownedSlotIDs.contains($0.slotID)
            }
            webSurfaces.disposeSurfaces(forPluginViewSlots: ownedPluginViewSlots, host: host)
        }
    }
}

private final class SleepTestTerminalSurface: TerminalSurface {
    let backendName = "Test"
    var onTitleChange: ((String) -> Void)?
    var renderedText = ""
    var scrollbackLines: [String] = []
    var processExited = false
    var commandFinishedCount = 0

    func makeView() -> AnyView {
        AnyView(EmptyView())
    }

    func sendText(_ text: String) {}
}

@MainActor
private final class SleepTestSurfaceRegistry {
    var bySlot: [UUID: SleepTestTerminalSurface] = [:]

    func surface(for slotID: UUID) -> SleepTestTerminalSurface {
        if let existing = bySlot[slotID] { return existing }
        let created = SleepTestTerminalSurface()
        bySlot[slotID] = created
        return created
    }
}
