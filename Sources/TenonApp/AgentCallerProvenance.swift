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
        return AgentCallerAdmission.ancestry(of: peer, parent: parentProcessID(of:))
    }
}
