// @domain: process-telemetry, intent-bus
import Foundation

/// One pane, as the admission rule needs to see it.
///
/// `agentPID` is the host's own resolution of what occupies the pane — the surface's
/// foreground process, checked against the agent providers Agent Lens already knows how to
/// name. It is `nil` for a pane running a shell, a pane whose surface has not materialised,
/// and a pane whose foreground is anything the host does not recognise as an agent. Nothing
/// here is ever something the caller said about itself.
public struct AgentPaneCandidate: Equatable, Sendable {
    public let slotID: UUID
    public let agentPID: Int32?

    public init(slotID: UUID, agentPID: Int32?) {
        self.slotID = slotID
        self.agentPID = agentPID
    }
}

/// One pane an agent's provider hook has bound, as the host sees it from both sides.
///
/// Two independent observations of the same pane, which is the whole point of the type:
///
/// - **declared** — the process group the hook reported for the provider ancestor it walked
///   to (`X-Tenon-Process-Group`). It is written by the client, and `AgentSessionRegistry`
///   stores it without running `AgentHookAdmission.admits` — that check lives only on the
///   live-ingestion path. So it is a claim, and it is treated as one.
/// - **observed** — the pane's foreground process and that process's group, read by the host
///   from its own PTY (`SurfacePool.agentTerminalIdentity`, `getpgid`).
///
/// `candidate(for:)` matches identity against the **observed** pid only, and lets the
/// declared group do exactly one job: veto a pane whose declaration disagrees. That keeps a
/// forged hook post unable to confer an identity — it can only take one away — and it is why
/// reading this registry does not put a provider-reported value into the dispatcher
/// (`docs/architecture-interaction-boundaries.md:617-645`).
public struct AgentPaneOccupancy: Equatable, Sendable {
    public let slotID: UUID
    public let declaredProcessGroupID: UInt64?
    public let observedForegroundPID: UInt64?
    public let observedProcessGroupID: UInt64?

    public init(
        slotID: UUID,
        declaredProcessGroupID: UInt64?,
        observedForegroundPID: UInt64?,
        observedProcessGroupID: UInt64?
    ) {
        self.slotID = slotID
        self.declaredProcessGroupID = declaredProcessGroupID
        self.observedForegroundPID = observedForegroundPID
        self.observedProcessGroupID = observedProcessGroupID
    }
}

/// Which pane a caller is *proven* to be inside, from the kernel's answer rather than the
/// caller's claim.
///
/// The two facts this composes are both observations the host makes about itself:
///
/// - **provenance** — the process on the other end of the control socket, named by
///   `LOCAL_PEERPID`, and its ancestry, walked through `proc_bsdinfo.pbi_ppid`. A process
///   cannot re-parent itself into another process's tree, so this is unforgeable *upward*:
///   nothing outside an agent's descendants can name that agent's pane.
/// - **occupancy** — whether the host resolved an agent as the pane's foreground process.
///
/// Neither is a credential the caller presents, which is the point: `$TENON_PANE_ID` is an
/// ordinary environment variable and scope IDs are "explicit caller-selected designations,
/// never authority" (`docs/architecture-interaction-boundaries.md:508-513`). A principal
/// that can be self-asserted is worse than none, because policy would then trust it.
///
/// **Why ancestry and not the controlling terminal.** Matching the caller's controlling
/// terminal against the pane's PTY is the more obvious rule and it does not work, because
/// the agent that matters detaches its tool subprocesses from the terminal. Measured
/// 2026-08-12 on this machine: `claude` itself holds `ttys020`, while the shell it spawns to
/// run a tool command reports `e_tdev == UInt32.max`, is its own process-group leader, and
/// fails `open("/dev/tty")` — with the sandbox on *and* off. A tty rule would therefore mint
/// nothing in production, replacing one unreachable guard with another. Ancestry survives
/// `setsid` because `setsid` does not change a parent, and it is strictly more precise for
/// what this product needs to tell apart: a human typing at the pane's shell prompt is a
/// child of the *shell*, not of the agent, so they keep the ordinary CLI identity while the
/// agent's own subprocesses do not.
///
/// Fail-closed in every direction: an empty ancestry, no match, an ambiguous match, or a
/// pane with no agent in it all answer `nil`, and the caller stays the ordinary CLI
/// principal it is today. This rule can only ever *narrow* who a caller is; it never widens
/// authority on a guess.
public enum AgentCallerAdmission {
    /// How far outward the walk is willing to look before giving up.
    ///
    /// A bound rather than a whole chain because invariant 10 admits no unbounded loop on a
    /// request path, and because the answer is always near: the shapes this rule exists to
    /// recognise put the agent within a few generations of its tool subprocess. Measured
    /// 2026-08-12, `claude` is the *immediate* parent of the shell it runs tool commands in.
    public static let maximumAncestryDepth = 12

    /// The pane an occupancy can identify, or nothing.
    ///
    /// Every refusal here is a pane that keeps the ordinary CLI principal, so read the guards
    /// as the four ways an agent identity is *not* established:
    ///
    /// - **no observed foreground** — the surface never materialised, or its process exited.
    ///   There is nothing for a caller to descend from.
    /// - **an undeclared group** — a binding that never carried one is a binding no hook of
    ///   ours wrote (the ingress refuses `processGroupID <= 0` before an event is built), so
    ///   it has nothing to cross-check and is refused rather than trusted.
    /// - **a disagreement** — the hook declared one process group and the host reads another.
    ///   This is the guard that matters in ordinary use: a binding outlives the agent that
    ///   made it until its pane closes, so without this check a human typing at the shell
    ///   prompt they got back would descend from *that* pane's foreground process and mint an
    ///   agent identity out of a dead agent's binding.
    /// - **a pid no `Int32` can hold** — ancestry is `Int32` because that is what
    ///   `proc_bsdinfo` answers in; a value that does not survive the conversion is refused
    ///   rather than truncated into some other process's identity.
    public static func candidate(for occupancy: AgentPaneOccupancy) -> AgentPaneCandidate? {
        guard let observed = occupancy.observedForegroundPID, observed > 1 else { return nil }
        guard let declared = occupancy.declaredProcessGroupID,
              declared == occupancy.observedProcessGroupID
        else { return nil }
        guard let pid = Int32(exactly: observed) else { return nil }
        return AgentPaneCandidate(slotID: occupancy.slotID, agentPID: pid)
    }

    /// The caller's own pid first, then each parent outward, as far as the bound allows.
    ///
    /// `parent` answers `nil` for a process that has exited between one step and the next,
    /// which ends the walk with what it has rather than inventing a chain. The `seen` guard
    /// is not paranoia about a real process tree — it cannot contain a cycle — but about pid
    /// reuse producing one mid-walk, which would otherwise spin to the bound every time.
    public static func ancestry(
        of pid: Int32,
        limit: Int = maximumAncestryDepth,
        parent: (Int32) -> Int32?
    ) -> [Int32] {
        var chain: [Int32] = []
        var seen: Set<Int32> = []
        var current = pid
        while chain.count < limit, current > 1, seen.insert(current).inserted {
            chain.append(current)
            guard let next = parent(current) else { break }
            current = next
        }
        return chain
    }

    /// Walks outward from the caller and stops at the first generation that names a pane.
    ///
    /// `peerAncestry` is the caller's own pid first, then its parent, then its parent's
    /// parent — the order the walk was read in. Nearest-first is the meaningful order: if an
    /// agent ever runs inside another agent's subtree, the call belongs to the innermost one
    /// that owns it, not to whichever ancestor happens to be checked first.
    public static func admit(
        peerAncestry: [Int32],
        candidates: [AgentPaneCandidate]
    ) -> UUID? {
        for pid in peerAncestry {
            // `launchd` is where every orphan lands, so a chain that reaches it has lost the
            // parent that would have proven anything. It can never identify a pane.
            guard pid > 1 else { continue }
            let matches = candidates.filter { $0.agentPID == pid }
            if matches.isEmpty { continue }
            // Two panes claiming one agent process is a state the host should never reach.
            // If it ever does, picking either one would attribute a call to a pane at
            // random, so neither is picked.
            guard matches.count == 1, let match = matches.first else { return nil }
            return match.slotID
        }
        return nil
    }
}
