// @domain: agent-lens, workspace-model
import Foundation
import TenonCore

/// Which terminal panes are agent panes right now, said in the one form that survives a quit.
///
/// The binding from a pane to the session running in it lives in memory for the life of the
/// process (`AgentSessionRegistry`), so the pane that was doing the work is exactly the pane
/// that comes back with no route to its own transcript. Captured here at every save, it turns
/// the relaunch into the reading the session list's "Details" opens: the transcript, its
/// evidence, and the offer to resume.
///
/// Eligibility is deliberately not a new judgement. It is the reading the live pane was
/// already showing — `AgentLensDiscovery.boundSession`, the `.exact` branch, which means the
/// provider's own hook named this session for this surface AND the process group it declared
/// still owns the terminal's foreground. A pane whose agent has exited and handed the shell
/// back fails that second half and stays a terminal, which is what the person was looking at
/// when they quit.
enum AgentPaneSessionCapture {
    /// Every pane in the catalog currently holding a terminal, in no particular order.
    /// A pane already reading a recorded session is not here: its content already carries the
    /// session and persists on its own.
    static func terminalSlotIDs(in catalog: WorkspaceCatalog) -> [UUID] {
        catalog.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.slots.compactMap { $0.content == .terminal ? $0.id : nil }
            }
        }
    }

    /// The reference a restored pane would read, or nil when this reading cannot honestly
    /// become one.
    ///
    /// Three refusals, each for its own reason: a confidence below `.exact` is a guess from a
    /// cwd and an mtime, and a guess that survives a restart is indistinguishable from a fact;
    /// a reading with no session id names no session to resume; a reading with no transcript
    /// has nothing to show. The value type refuses the rest.
    static func reference(
        for resolution: AgentLensResolution,
        title: String?
    ) -> AgentSessionRef? {
        guard resolution.confidence == .exact,
              let sessionID = resolution.sessionID,
              let transcriptURL = resolution.transcriptURL
        else { return nil }
        return AgentSessionRef(
            provider: resolution.provider.sessionProvider,
            sessionID: sessionID,
            transcriptPath: transcriptURL.path,
            title: title
        )
    }

    /// The capture the catalog save takes. `identity` answers only for a materialised, still
    /// running surface, so a pane whose shell has exited contributes nothing and comes back as
    /// the terminal it was.
    @MainActor
    static func sessions(
        terminalSlotIDs: [UUID],
        identity: (UUID) -> AgentTerminalIdentity?,
        resolve: (AgentTerminalIdentity) async -> AgentLensResolution?
    ) async -> [UUID: AgentSessionRef] {
        var sessions: [UUID: AgentSessionRef] = [:]
        for slotID in terminalSlotIDs {
            guard let identity = identity(slotID),
                  let resolution = await resolve(identity),
                  let ref = reference(for: resolution, title: identity.title)
            else { continue }
            sessions[slotID] = ref
        }
        return sessions
    }
}
