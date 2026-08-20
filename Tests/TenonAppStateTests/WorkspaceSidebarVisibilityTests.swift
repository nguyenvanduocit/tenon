import Foundation
@testable import TenonApp
@testable import TenonCore
import XCTest

final class WorkspaceSidebarVisibilityTests: XCTestCase {
    private func makeWorkspaces(visibility: [WorkspaceVisibility]) -> [Workspace] {
        visibility.enumerated().map { index, visibility in
            var workspace = Workspace(
                name: "W\(index)",
                path: URL(fileURLWithPath: "/tmp/w\(index)")
            )
            workspace.visibility = visibility
            return workspace
        }
    }

    func testAbsoluteIndexSkipsAnInterleavedBackgroundWorkspace() {
        // A(visible), B(background), C(visible) — visible order is [A, C].
        let workspaces = makeWorkspaces(visibility: [.visible, .background, .visible])

        // Moving to visible-destination 1 (after C) resolves to C's absolute index (2).
        XCTAssertEqual(
            absoluteWorkspaceIndex(forVisibleDestination: 1, in: workspaces),
            2
        )
        // Moving to visible-destination 0 (before A, i.e. staying at A) resolves to A's
        // absolute index (0).
        XCTAssertEqual(
            absoluteWorkspaceIndex(forVisibleDestination: 0, in: workspaces),
            0
        )
    }

    func testAbsoluteIndexPastTheLastVisibleRowTargetsTheLastVisibleWorkspace() {
        let workspaces = makeWorkspaces(visibility: [.visible, .background, .visible])

        XCTAssertEqual(
            absoluteWorkspaceIndex(forVisibleDestination: 5, in: workspaces),
            2
        )
    }

    func testAbsoluteIndexWithNoVisibleWorkspacesReturnsNil() {
        let workspaces = makeWorkspaces(visibility: [.background, .background])

        XCTAssertNil(absoluteWorkspaceIndex(forVisibleDestination: 0, in: workspaces))
    }

    func testAbsoluteIndexWithNoBackgroundWorkspacesMatchesTheAbsoluteIndexDirectly() {
        let workspaces = makeWorkspaces(visibility: [.visible, .visible, .visible])

        for destination in 0 ..< 3 {
            XCTAssertEqual(
                absoluteWorkspaceIndex(forVisibleDestination: destination, in: workspaces),
                destination
            )
        }
    }
}
