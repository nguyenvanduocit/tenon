// @domain: cli-control, process-telemetry
import Darwin
import Foundation
import TenonCore

/// What the kernel will say about the process on the other end of the control socket.
///
/// Two questions, both answered by the kernel rather than by the caller: *which process is
/// this* (`LOCAL_PEERPID` on the connected descriptor) and *who is its parent*
/// (`proc_bsdinfo.pbi_ppid`). Composing them gives the caller's ancestry, which
/// `AgentCallerAdmission` turns into a pane — or, far more often, into nothing.
///
/// Nothing here reads the wire. The CLI envelope is closed in both directions and has no
/// slot for a credential (`CLIProtocol.swift:212-214`, `CLIAction.swift:81-91`), which is the
/// point: an identity a caller can type is an identity a caller can forge.
enum AgentCallerProvenance {
    /// The pid on the other end of a connected `AF_UNIX` socket.
    ///
    /// Read once, at accept, before the client has sent a byte — so nothing the client says
    /// can influence it. `pid > 1` refuses both the zero an unfilled option leaves behind and
    /// `launchd`, neither of which can identify a pane.
    static func peerProcessID(of descriptor: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == socklen_t(MemoryLayout<pid_t>.size),
              pid > 1
        else { return nil }
        return pid
    }

    /// The parent of `pid`, or `nil` if the process is gone.
    ///
    /// The `didFill` rule is `DarwinProcessSampler`'s and is repeated deliberately rather
    /// than loosened: `proc_pidinfo` signals "that process is gone" by returning **0** and
    /// leaving the caller's struct untouched, so every loose spelling of the check
    /// (`>= 0`, `!= -1`) reads a zeroed struct as a live process whose parent is pid 0.
    /// Here that would mean a dead caller acquiring an ancestry it never had.
    static func parentProcessID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let returnCode = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard DarwinProcessSampler.didFill(returnCode: returnCode, expecting: size) else {
            return nil
        }
        let parent = Int32(bitPattern: info.pbi_ppid)
        return parent > 1 ? parent : nil
    }

    /// The caller's ancestry, ready for `AgentCallerAdmission.admit`.
    static func ancestry(ofPeer descriptor: Int32) -> [Int32] {
        guard let peer = peerProcessID(of: descriptor) else { return [] }
        return ancestry(ofProcess: peer)
    }

    /// The same walk, from a pid the socket already captured.
    ///
    /// The peer pid is read once at accept and travels with the request, because the
    /// descriptor is closed by the time the intent settles — and because a pid read later
    /// could name a process that replaced the caller.
    static func ancestry(ofProcess pid: Int32) -> [Int32] {
        AgentCallerAdmission.ancestry(of: pid, parent: parentProcessID(of:))
    }

    /// The process group `pid` belongs to, or `pid` itself when the kernel has no answer.
    ///
    /// Falling back to the pid rather than to zero keeps a vanished process from colliding
    /// with a real declared group: `AgentCallerAdmission.candidate` compares this against
    /// what a hook declared, and a shared sentinel would make unrelated panes agree.
    static func processGroupID(of pid: UInt64) -> UInt64 {
        guard let narrowed = Int32(exactly: pid) else { return pid }
        let group = getpgid(narrowed)
        return group > 0 ? UInt64(group) : pid
    }
}

/// What the host itself can see about which of its panes an agent occupies.
///
/// Both halves are host observations and neither is a value a caller supplied: the pane set
/// comes from the hook binding registry (membership only), and the pid each candidate is
/// matched on comes from the host's own read of that pane's PTY. The declared process group
/// is only allowed to *drop* a pane whose declaration disagrees with that read, which is what
/// keeps a forged hook post unable to hand anyone an identity.
@MainActor
enum AgentPaneOccupancyReader {
    static func candidates(
        surfaces: SurfacePool,
        registry: AgentSessionRegistry,
        processGroupID: (UInt64) -> UInt64 = AgentCallerProvenance.processGroupID(of:)
    ) async -> [AgentPaneCandidate] {
        let bound = await registry.boundPanes()
        guard !bound.isEmpty else { return [] }
        return bound.compactMap { pane in
            // `agentTerminalIdentity` is the host's own read and already refuses a surface
            // that never materialised or whose process exited. The surface token must be the
            // one the binding was made against, so a pane that was torn down and rebuilt
            // under the same slot id cannot inherit the old incarnation's agent.
            guard let identity = surfaces.agentTerminalIdentity(for: pane.paneID),
                  identity.surfaceToken == pane.surfaceToken
            else { return nil }
            return AgentCallerAdmission.candidate(
                for: AgentPaneOccupancy(
                    slotID: pane.paneID,
                    declaredProcessGroupID: pane.processGroupID,
                    observedForegroundPID: identity.foregroundPID,
                    observedProcessGroupID: processGroupID(identity.foregroundPID)
                )
            )
        }
    }
}
