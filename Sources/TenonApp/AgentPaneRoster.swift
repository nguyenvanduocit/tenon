// @domain: agent-lens
import Foundation
import Observation
import TenonCore

/// Which panes an agent is sitting in, answerable synchronously, for every workspace at once.
///
/// The host already knows this twice over and neither answer reaches a sidebar row.
/// `AgentSessionRegistry` is an `actor`, so asking it is `await` — a view body cannot.
/// `AgentLensPool.ingest` routes a live hook only to a per-pane model that is already mounted
/// (`AgentLensSession.swift:950`), so a pane in a workspace nobody is looking at drops the
/// very facts that say what it is doing. A supervision surface whose whole job is the
/// workspaces you are NOT looking at cannot be built on either.
///
/// So this is a third reader of the same hook stream rather than a third judgement: it stores
/// the pane and the surface incarnation, and nothing about what the agent said.
///
/// One writer is enough, and knowing why matters. `AgentSessionRegistry` lags an agent because
/// its own `record` refuses an event with no session-bearing payload
/// (`AgentSessionHooks.swift:145-149`), so a session that has not run a tool is absent from
/// *it*. This roster asks less — a pane id and a surface token, which every hook carries — and
/// `SessionStart` is in the installed set (`AgentSessionHooks.swift:213`) and reaches the bus
/// unfiltered. So a pane is named from the moment the session starts, and a second writer at
/// the launch site would be a second path to the same fact with nothing left to cover: it
/// would not even catch the agent this cannot see, the one a person started by typing `claude`
/// into a shell, because that one has no launch site here either.
///
/// Bounded two ways (invariant 10): a slot whose surface token has changed, or whose surface
/// is gone, no longer matches at the read, and the oldest binding is evicted past `capacity`
/// so a machine left running for a week cannot grow without limit.
///
/// **The one thing it cannot see**: an agent that exits and hands its shell back. The pane
/// keeps its surface and its token, so the binding still matches and the row goes on naming
/// it. No provider hook reports it — the installed set is `SessionStart`, `UserPromptSubmit`,
/// `PreToolUse`, `PostToolUse`, `Notification`, `Stop` (`AgentSessionHooks.swift:213-218`),
/// and none of those means "the session ended". The synchronous check that would settle it is
/// `AgentCallerAdmission.candidate`'s: compare the pane's live foreground process group
/// against the one the hook declared, which is what `AgentPaneOccupancyReader` does
/// asynchronously for the CLI. It is not done here because that read costs an FFI call plus a
/// `getpgid` per agent pane on a body that already re-renders at the attention poll's cadence,
/// and T-141 is what unmeasured per-pane work on that path costs. Until it is measured, a
/// finished agent keeps its line until the pane is rebuilt.
@MainActor
@Observable
final class AgentPaneRoster {
    /// How many panes may be remembered at once. A person supervising more concurrent agents
    /// than this has a bigger problem than a stale roster entry.
    static let capacity = 64

    /// Slot id to the surface incarnation the binding was made against. Observed, so a row
    /// that reads it re-renders when an agent arrives in a workspace it is drawing.
    private(set) var bindings: [UUID: UUID] = [:]

    /// Insertion order, oldest first — the eviction queue, and nothing a reader needs.
    @ObservationIgnored
    private var recency: [UUID] = []

    /// Remember this incarnation of this pane as an agent's. Re-noting an already-known pane
    /// refreshes its place in the eviction queue, so the pane that keeps reporting is the last
    /// one evicted rather than the first.
    func note(slotID: UUID, surfaceToken: UUID) {
        bindings[slotID] = surfaceToken
        recency.removeAll { $0 == slotID }
        recency.append(slotID)
        while recency.count > Self.capacity {
            bindings.removeValue(forKey: recency.removeFirst())
        }
    }

    /// One provider lifecycle hook, read for the only thing this type wants from it: that an
    /// agent is in that pane.
    ///
    /// A subagent's hook is refused, matching the two readers already on this stream
    /// (`AgentSessionRegistry.record`, `AgentHookLensProjection.events`): a subagent runs
    /// nested inside a tool call the root session already accounts for, and counting it would
    /// report one agent's pane twice.
    func ingest(_ event: AgentHookEvent) {
        guard event.agentID == nil else { return }
        note(slotID: event.paneID, surfaceToken: event.surfaceToken)
    }

    /// The panes an agent occupies, checked against the surface incarnations that exist right
    /// now.
    ///
    /// The token comparison is what makes a reused slot id safe. A pane torn down and rebuilt
    /// keeps its slot id and gets a fresh token, so the old agent cannot be inherited by the
    /// shell that replaced it — the same guard `AgentPaneOccupancyReader` applies
    /// (`AgentCallerProvenance.swift:94-100`), applied here at the read because a view cannot
    /// wait for an actor.
    func panes(matching currentTokens: [UUID: UUID]) -> Set<UUID> {
        var live: Set<UUID> = []
        for (slotID, token) in bindings where currentTokens[slotID] == token {
            live.insert(slotID)
        }
        return live
    }
}
