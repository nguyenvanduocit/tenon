// @domain: terminal-surface, agent-control
import Foundation
import TenonCore

/// The Tenon facts every terminal surface exports into its PTY.
///
/// One set, for every terminal: a shell a person opened by hand carries exactly what a pane
/// an agent was launched into carries. That uniformity is the whole point — the harness
/// Tenon installs into a person's global agent instructions can only tell an agent to read
/// `$TENON_PANE_ID` if the variable is there whatever the pane turned out to be used for,
/// and an agent started by hand in an ordinary terminal is the common case.
///
/// **`TENON_TAB_ID` and `TENON_WORKSPACE_ID` are a spawn-time snapshot.** A pane can be
/// dragged to another tab while its shell keeps running, and a running process's environment
/// cannot be rewritten from outside. `workspace.pane.owner.v1` answers from the live catalog
/// and is the only account that stays true; these two are the cheap answer for the ordinary
/// case where the pane has not moved. `TENON_PANE_ID` has no such caveat — a pane keeps its
/// id wherever it is moved to.
enum TerminalPaneEnvironment {
    /// The workspace and tab that owned a pane at the moment its shell was spawned.
    struct Owner: Equatable, Sendable {
        let workspaceID: UUID
        let tabID: UUID

        init(workspaceID: UUID, tabID: UUID) {
            self.workspaceID = workspaceID
            self.tabID = tabID
        }

        /// Resolves against the whole catalog rather than the selection, so a pane
        /// materializing in a workspace nobody is looking at exports the same identity as
        /// the focused one. Answers nil when the pane is not in the catalog at all.
        init?(catalog: WorkspaceCatalog, paneID: UUID) {
            guard let owner = catalog.owner(ofSlot: paneID) else { return nil }
            self.init(workspaceID: owner.workspaceID, tabID: owner.tabID)
        }
    }

    /// Absent rather than empty is deliberate for every optional value here. A shell reading
    /// `TENON_TAB_ID=""` would carry the empty string into an intent scope and address
    /// nothing; `[ -n "$TENON_TAB_ID" ]` is how a script asks whether the answer exists.
    static func variables(
        paneID: UUID,
        surfaceToken: UUID,
        owner: Owner?,
        socketPath: String,
        codexHomePath: String,
        agentHookScriptPath: String,
        agentHookPort: UInt16?,
        agentHookToken: String?
    ) -> [String: String] {
        var environment = [
            "CODEX_HOME": codexHomePath,
            "TENON_SOCKET_PATH": socketPath,
            "TENON_AGENT_HOOK_SCRIPT": agentHookScriptPath,
            "TENON_PANE_ID": paneID.uuidString,
            "TENON_AGENT_SURFACE_TOKEN": surfaceToken.uuidString,
        ]
        if let owner {
            environment["TENON_TAB_ID"] = owner.tabID.uuidString
            environment["TENON_WORKSPACE_ID"] = owner.workspaceID.uuidString
        }
        if let agentHookPort, let agentHookToken {
            environment["TENON_AGENT_HOOK_PORT"] = String(agentHookPort)
            environment["TENON_AGENT_HOOK_TOKEN"] = agentHookToken
        }
        return environment
    }
}
