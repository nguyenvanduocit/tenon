// @domain: process-telemetry
import Darwin
import Foundation
import TenonCore

// MARK: - Native reading  @domain: process-telemetry

/// The one place Tenon talks to `libproc`.
///
/// It reports what the kernel said and decides nothing: no ownership, no aggregation, no
/// history, no retry, no UI state. Everything that could be argued about is a pure rule in
/// `TenonCore` operating on the values this returns, which is what lets those rules be
/// asserted without a process tree.
///
/// Three calling conventions here are not guessable from the headers and were measured before
/// this file existed (T-100 Phase 0):
///
/// - `proc_listpids` returns a **byte count**; `proc_listchildpids` returns an **entry
///   count**. Dividing the second by `MemoryLayout<pid_t>.size` turns three children into
///   zero, which is exactly the silent-empty-tree failure this monitor exists to avoid.
/// - `proc_pidinfo` on a process that has exited returns **0 with `errno == ESRCH`**, not a
///   negative. A `rc >= 0` check therefore accepts a zeroed struct and reports a live process
///   using no CPU and no memory. Only `rc == MemoryLayout<T>.size` means the read happened.
/// - `PROC_PIDTBSDINFO.e_tdev` is `UInt32.max`, not 0, when a process has no controlling
///   terminal.
/// - A pane's own terminal always holds one process this app may not read: Ghostty starts the
///   shell through `/usr/bin/login`, which is setuid root, so `proc_pidinfo` answers a UID-501
///   caller with `rc=0, errno=EPERM`. It is therefore normal — not an incident — for a
///   terminal's listed PIDs to exceed its readable ones by exactly one, and any rule phrased
///   over the listed set is a rule that will meet an unreadable member on every pane. Root
///   selection was such a rule and reported no roots at all (T-108).
struct DarwinProcessSampler: ProcessSampling {
    /// How many identities one sweep will read before it stops and says it truncated.
    let capacity: Int

    init(capacity: Int = ProcessTelemetryCoordinator.processCapacity) {
        self.capacity = capacity
    }

    /// `UInt32.max` — what `e_tdev` holds when there is no controlling terminal.
    private static let noTTY = UInt32.max

    func sample(panes: [PaneProvenance]) async throws -> ProcessSampleSet {
        // Deliberately synchronous inside an async function on a detached executor: every
        // call below is a fast kernel read (measured p95 ≈ 1 µs each), and hopping executors
        // per process would cost more than the reads.
        try await Task.detached(priority: .utility) {
            try Self.sweep(panes: panes, capacity: capacity)
        }.value
    }

    // MARK: - The sweep  @domain: process-telemetry

    private static func sweep(panes: [PaneProvenance], capacity: Int) throws -> ProcessSampleSet {
        var unreadable = 0
        var records: [ProcessIdentity: RawProcessSample] = [:]
        var truncated = false

        // Roots come from the panes' own terminals. Only these trees are walked, so cost
        // scales with Tenon's panes rather than with everything running on the machine.
        var rootPIDs: [pid_t] = []
        for device in Set(panes.compactMap(\.ttyDevice)).sorted() {
            // Survey first: reduce what the kernel lists to what it will let us read. A
            // listed-but-unreadable process is not counted as lost — every pane has exactly
            // one, the setuid-root `login` Ghostty starts the shell through, and the monitor
            // was never reporting its figures. Counting it would put every healthy pane
            // permanently into `partial`.
            let readable = attachedPIDs(ttyDevice: device).sorted().compactMap { pid -> AttachedProcess? in
                guard let info = bsdInfo(pid) else { return nil }
                return AttachedProcess(pid: pid, parentPID: pid_t(info.pbi_ppid))
            }
            rootPIDs.append(contentsOf: TerminalProcessTree.roots(readable: readable))
        }

        // Breadth-first over the real child links, in a deterministic order, with a visited
        // set that makes a malformed parent chain or a PID reused mid-sweep terminate rather
        // than loop.
        var queue = rootPIDs.sorted()
        var visited = Set<pid_t>()
        while let pid = queue.first {
            queue.removeFirst()
            guard visited.insert(pid).inserted else { continue }
            guard records.count < capacity else { truncated = true; break }

            // The children are queued whether or not this process could be read. `errno` says
            // nothing about descendants and the kernel agrees: `proc_listchildpids` answers
            // for an EPERM process, measured returning `[37403]` for the setuid-root `login`
            // that refuses `proc_pidinfo`. Skipping them would let one privileged process in
            // the middle of a tree — a `sudo` inside a pane — delete everything beneath it
            // from the pane that owns it.
            queue.append(contentsOf: childPIDs(pid).sorted())

            guard let record = read(pid) else {
                // ESRCH is ordinary churn: the process left between listing and reading. It
                // drops out of this snapshot and makes it partial; it does not fail the sweep.
                unreadable += 1
                continue
            }
            records[record.identity] = record
        }

        return ProcessSampleSet(
            hostRecord: read(getpid()),
            processes: Array(records.values).sorted { $0.identity < $1.identity },
            truncated: truncated,
            unreadableCount: unreadable
        )
    }

    // MARK: - Single-process reads  @domain: process-telemetry

    /// Everything one process contributes, or `nil` if any part of its identity could not be
    /// established. A half-read process is not reported with the half that worked: without a
    /// start stamp it has no identity, and without identity its counters cannot be carried
    /// across samples without risking a reused PID's history.
    private static func read(_ pid: pid_t) -> RawProcessSample? {
        guard let info = bsdInfo(pid), let usage = rusage(pid) else { return nil }

        let comm = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }

        return RawProcessSample(
            identity: ProcessIdentity(pid: pid, startAbstime: usage.ri_proc_start_abstime),
            parentPID: pid_t(info.pbi_ppid),
            ttyDevice: info.e_tdev == noTTY ? nil : info.e_tdev,
            executableName: comm.isEmpty ? "process \(pid)" : comm,
            // rusage reports CPU already in nanoseconds, so no `mach_timebase_info`
            // conversion is needed here and none is done — a conversion applied to
            // already-converted values would scale every CPU figure by ~41 on Apple silicon.
            cpuNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
            // Physical footprint, the figure Activity Monitor's Memory column shows and the
            // one the health journal already records. It counts what a process is answerable
            // for — including compressed pages and IOKit mappings — where resident size counts
            // only what happens to be in RAM right now. The T-091 incident was 11 GB of
            // footprint behind an unremarkable resident size, so an operator watching for that
            // shape of failure needs this field and not the other one.
            footprintBytes: usage.ri_phys_footprint,
            diskBytesRead: usage.ri_diskio_bytesread,
            diskBytesWritten: usage.ri_diskio_byteswritten
        )
    }

    /// Whether a `proc_pidinfo` call actually filled the struct it was given.
    ///
    /// Its own function because it is the single most dangerous line in this file and the
    /// only one a test can pin without racing a process into its grave. `proc_pidinfo`
    /// signals "that process is gone" by returning **0** — not a negative — and leaving the
    /// caller's struct exactly as it found it, which for a freshly-initialised Swift value is
    /// all zeros. Every loose spelling of this check (`>= 0`, `!= -1`, `> -1`) therefore turns
    /// an exited process into a live one using no CPU and no memory: the precise failure the
    /// whole monitor exists to avoid, arriving as data rather than as an error.
    ///
    /// A short read is refused for the same reason. Half a struct is half zeros.
    static func didFill(returnCode: Int32, expecting size: Int32) -> Bool {
        returnCode == size
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let returnCode = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard didFill(returnCode: returnCode, expecting: size) else { return nil }
        return info
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        } == 0
        return ok ? usage : nil
    }

    /// Every process whose controlling terminal is `ttyDevice`. Returns a **byte** count.
    private static func attachedPIDs(ttyDevice: UInt32) -> [pid_t] {
        let stride = MemoryLayout<pid_t>.size
        let sizing = proc_listpids(UInt32(PROC_TTY_ONLY), ttyDevice, nil, 0)
        guard sizing > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(sizing) / stride + 16)
        let written = proc_listpids(UInt32(PROC_TTY_ONLY), ttyDevice, &buffer, Int32(buffer.count * stride))
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written) / stride).filter { $0 > 0 })
    }

    /// Direct children of `pid`. Returns an **entry** count — not bytes.
    private static func childPIDs(_ pid: pid_t) -> [pid_t] {
        let stride = MemoryLayout<pid_t>.size
        var buffer = [pid_t](repeating: 0, count: 256)
        let written = proc_listchildpids(pid, &buffer, Int32(buffer.count * stride))
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written)).filter { $0 > 0 })
    }
}

// MARK: - TTY name to device  @domain: process-telemetry

/// Turns the path libghostty reports into the `st_rdev` `proc_listpids` wants.
///
/// Pure enough to test with any path: it answers `nil` for anything that is not a character
/// device, so a stale or malformed name leaves that one pane unavailable instead of matching
/// some other pane's processes by accident.
enum TerminalDeviceResolver {
    static func device(forTTYPath path: String) -> UInt32? {
        guard !path.isEmpty else { return nil }
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        guard (status.st_mode & S_IFMT) == S_IFCHR else { return nil }
        return UInt32(truncatingIfNeeded: status.st_rdev)
    }
}
