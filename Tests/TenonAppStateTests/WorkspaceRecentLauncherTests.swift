import AppKit
import SwiftUI
import TenonCore
import XCTest
@testable import TenonApp

/// T-099: the empty-pane launcher draws the recents of the workspace it was handed.
///
/// The scoping rules themselves are asserted with two workspaces and no AppKit in
/// `RecentStoreTests`. What needs a hosted view is the last link in the chain: that the
/// workspace threaded down the canvas is the one whose list actually reaches the card. The
/// card renders "Recently opened" only when the list is non-empty and one row per entry, so
/// the rendered height is a faithful witness to which bucket was read — and it fails loudly
/// if a future change reaches past the parameter to some app-wide list again.
@MainActor
final class WorkspaceRecentLauncherTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-recent-launcher-\(UUID().uuidString).json")
    }

    private func height(ofLauncherFor workspaceID: UUID, store: WorkspaceStore) -> CGFloat {
        let hosting = NSHostingView(
            rootView: EmptySlotView(
                slotID: UUID(),
                workspaceID: workspaceID,
                store: store,
                pool: SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() },
                agentSuggestions: [],
                isActive: false
            )
            .preferredColorScheme(.dark)
        )
        return hosting.fittingSize.height
    }

    func testTheLauncherDrawsTheRecentsOfTheWorkspaceItWasHanded() throws {
        let busy = UUID()
        let quiet = UUID()
        let untouched = UUID()
        let recents = RecentStore(fileURL: tempFile())
        for content in [SlotContent.terminal, .changes, .automation] {
            recents.record(content, for: busy, root: URL(fileURLWithPath: "/tmp/tenon-busy"))
        }
        recents.record(.changes, for: quiet, root: URL(fileURLWithPath: "/tmp/tenon-quiet"))

        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                name: "Busy",
                path: URL(fileURLWithPath: "/tmp/tenon-busy", isDirectory: true)
            ),
            recent: recents
        )

        let busyHeight = height(ofLauncherFor: busy, store: store)
        let quietHeight = height(ofLauncherFor: quiet, store: store)
        let untouchedHeight = height(ofLauncherFor: untouched, store: store)

        XCTAssertGreaterThan(busyHeight, 0, "the card drew nothing at all")
        // Three rows > one row > no section: the row count the card drew is the row count the
        // workspace it was handed owns, not the count of some other workspace's list.
        XCTAssertGreaterThan(busyHeight, quietHeight)
        XCTAssertGreaterThan(quietHeight, untouchedHeight)
        // A workspace this store has never recorded against is drawn as having no history,
        // which is the state a launcher is in while its workspace is being restored.
        XCTAssertEqual(
            untouchedHeight,
            height(ofLauncherFor: UUID(), store: store),
            accuracy: 0.5
        )
    }

    func testTheLauncherFollowsItsOwnWorkspaceRatherThanTheSelectedOne() throws {
        let recents = RecentStore(fileURL: tempFile())
        let alphaRoot = URL(fileURLWithPath: "/tmp/tenon-alpha", isDirectory: true)
        let betaRoot = URL(fileURLWithPath: "/tmp/tenon-beta", isDirectory: true)
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(name: "Alpha", path: alphaRoot),
            recent: recents
        )
        let alphaID = store.catalog.activeWorkspaceID
        store.addWorkspace(name: "Beta", path: betaRoot)
        let betaID = try XCTUnwrap(store.catalog.workspaces.first { $0.id != alphaID }?.id)
        for content in [SlotContent.terminal, .changes, .automation] {
            recents.record(content, for: alphaID, root: alphaRoot)
        }

        // Beta is the selected workspace and has no recents at all — the pane it opened with
        // came from construction, not from a mutation. Alpha's launcher must still draw
        // Alpha's three, because the workspace it was handed is the one it reads.
        store.selectWorkspace(betaID)
        XCTAssertEqual(store.catalog.activeWorkspaceID, betaID)

        XCTAssertGreaterThan(
            height(ofLauncherFor: alphaID, store: store),
            height(ofLauncherFor: betaID, store: store)
        )
    }
}
