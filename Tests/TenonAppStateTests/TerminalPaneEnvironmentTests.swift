import Foundation
@testable import TenonApp
@testable import TenonCore
import XCTest

/// Every terminal Tenon opens carries the same Tenon facts, whether an agent ever runs in it
/// or not: a shell a person opened by hand and a pane an agent was launched into export the
/// identical set. A variable that appears only in agent panes would be a variable the
/// harness cannot tell an agent to rely on.
final class TerminalPaneEnvironmentTests: XCTestCase {
    private let paneID = UUID()
    private let surfaceToken = UUID()
    private let tabID = UUID()
    private let workspaceID = UUID()

    func testEveryTerminalCarriesItsPaneTabAndWorkspaceIdentity() {
        let environment = TerminalPaneEnvironment.variables(
            paneID: paneID,
            surfaceToken: surfaceToken,
            owner: TerminalPaneEnvironment.Owner(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            socketPath: "/tmp/tenon.sock",
            codexHomePath: "/tmp/codex",
            agentHookScriptPath: "/tmp/hook.sh",
            agentHookPort: 51_234 as UInt16,
            agentHookToken: "secret"
        )

        XCTAssertEqual(environment["TENON_PANE_ID"], paneID.uuidString)
        XCTAssertEqual(environment["TENON_TAB_ID"], tabID.uuidString)
        XCTAssertEqual(environment["TENON_WORKSPACE_ID"], workspaceID.uuidString)
        XCTAssertEqual(environment["TENON_SOCKET_PATH"], "/tmp/tenon.sock")
        XCTAssertEqual(environment["TENON_AGENT_SURFACE_TOKEN"], surfaceToken.uuidString)
        XCTAssertEqual(environment["TENON_AGENT_HOOK_PORT"], "51234")
        XCTAssertEqual(environment["TENON_AGENT_HOOK_TOKEN"], "secret")
    }

    /// A pane materializes before the catalog can always answer for it, and the hook server
    /// may not have a port. Neither may publish an empty or placeholder value: a shell that
    /// reads `TENON_TAB_ID=""` would treat the empty string as an id and scope an intent to
    /// nothing. Absent is the honest answer, and `[ -n "$TENON_TAB_ID" ]` is how a script
    /// asks.
    func testAnUnresolvedOwnerOrHookLeavesItsVariablesAbsentRatherThanEmpty() {
        let environment = TerminalPaneEnvironment.variables(
            paneID: paneID,
            surfaceToken: surfaceToken,
            owner: nil,
            socketPath: "/tmp/tenon.sock",
            codexHomePath: "/tmp/codex",
            agentHookScriptPath: "/tmp/hook.sh",
            agentHookPort: nil,
            agentHookToken: nil
        )

        XCTAssertNil(environment["TENON_TAB_ID"])
        XCTAssertNil(environment["TENON_WORKSPACE_ID"])
        XCTAssertNil(environment["TENON_AGENT_HOOK_PORT"])
        XCTAssertNil(environment["TENON_AGENT_HOOK_TOKEN"])
        // The pane's own identity never depends on the catalog answering.
        XCTAssertEqual(environment["TENON_PANE_ID"], paneID.uuidString)
        XCTAssertEqual(environment["TENON_SOCKET_PATH"], "/tmp/tenon.sock")
    }

    /// The owner is read from the live catalog, so a pane in a workspace nobody is looking
    /// at exports the same identity as the focused one.
    func testTheOwnerComesFromTheCatalogForAnyPaneNotJustTheFocusedOne() throws {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "First", path: URL(fileURLWithPath: "/first"))
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/second"))
        let second = try XCTUnwrap(catalog.workspaces.last)
        catalog.selectWorkspace(try XCTUnwrap(catalog.workspaces.first).id)

        let unselectedTab = try XCTUnwrap(second.tabs.first)
        let unselectedPane = try XCTUnwrap(unselectedTab.slots.first).id

        let owner = try XCTUnwrap(
            TerminalPaneEnvironment.Owner(catalog: catalog, paneID: unselectedPane)
        )
        XCTAssertEqual(owner.workspaceID, second.id)
        XCTAssertEqual(owner.tabID, unselectedTab.id)
    }
}
