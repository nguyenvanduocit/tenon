// @domain: process-telemetry
import Foundation

// MARK: - Identity  @domain: process-telemetry

/// What makes two process observations the same process.
///
/// A PID alone does not: macOS reuses PIDs, and a reused PID inheriting the previous
/// occupant's cumulative CPU counter would show one enormous delta at the instant of reuse.
/// `proc_pid_rusage` supplies `ri_proc_start_abstime`, an absolute start stamp that is
/// distinct per process for the machine's uptime, so the pair is the identity everything
/// else here is keyed by.
public struct ProcessIdentity: Hashable, Sendable, Comparable {
    public let pid: Int32
    public let startAbstime: UInt64

    public init(pid: Int32, startAbstime: UInt64) {
        self.pid = pid
        self.startAbstime = startAbstime
    }

    /// Total order so traversal and tie-breaking are reproducible rather than
    /// dictionary-order dependent.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pid, lhs.startAbstime) < (rhs.pid, rhs.startAbstime)
    }
}

// MARK: - Values that may not exist  @domain: process-telemetry

/// Why a figure could not be established.
///
/// Every case is a fact about the reading, never a substitute for one. The product rule this
/// type exists to make unspellable is "a missing value is never displayed as zero": there is
/// no `TelemetryValue` case that carries an invented number, so a caller that cannot read
/// something has to say which of these happened.
public enum TelemetryUnavailability: String, Sendable, Equatable, CaseIterable {
    /// The first observation of a counter has nothing to subtract from.
    case firstObservation
    /// A cumulative counter decreased, so the interval is not interpretable.
    case counterWentBackwards
    /// Elapsed time was zero or negative — the delta has no denominator.
    case invalidInterval
    /// The PID is the same but the start stamp is not: a different process now.
    case identityChanged
    /// The kernel refused the read (`EPERM`) or the process left (`ESRCH`) mid-sweep.
    case unreadable
    /// Checked addition would have wrapped. An aggregate never wraps into a small number.
    case overflow
    /// macOS exposes no public per-process API for this figure at all. Measured, not assumed
    /// — see the feasibility receipt in the T-100 design revalidation.
    case noPublicPerProcessAPI
    /// The process is real, but no pane owns it exclusively.
    case sharedAcrossPanes
    /// The pane has no OS process of its own to report.
    case noExclusiveProcess

    /// A short reason a row can show beside the em dash. Localization happens in the shell;
    /// this is the stable key the shell looks up.
    public var reasonKey: String { "telemetry.unavailable.\(rawValue)" }
}

/// A figure that either was established or was not, with the reason attached when it was not.
public enum TelemetryValue<Wrapped: Equatable & Sendable>: Equatable, Sendable {
    case known(Wrapped)
    case unavailable(TelemetryUnavailability)

    public var value: Wrapped? {
        if case let .known(wrapped) = self { return wrapped }
        return nil
    }

    public var isKnown: Bool { value != nil }

    public var unavailability: TelemetryUnavailability? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

// MARK: - What the sampler hands over  @domain: process-telemetry

/// One process as the native sampler read it, before any ownership or interval rule applies.
///
/// Every metric is optional because a same-user process can still refuse a field mid-sweep.
/// The core turns `nil` into an explicit `.unavailable`, which is why the sampler is allowed
/// to be this blunt: it reports what the kernel said and decides nothing.
public struct RawProcessSample: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    /// `st_rdev` of the controlling terminal, or `nil` when the process has none.
    public let ttyDevice: UInt32?
    public let executableName: String
    /// Cumulative user+system CPU, already converted to nanoseconds through `mach_timebase_info`.
    public let cpuNanoseconds: UInt64?
    public let footprintBytes: UInt64?
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        ttyDevice: UInt32?,
        executableName: String,
        cpuNanoseconds: UInt64?,
        footprintBytes: UInt64?,
        diskBytesRead: UInt64?,
        diskBytesWritten: UInt64?
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.ttyDevice = ttyDevice
        self.executableName = executableName
        self.cpuNanoseconds = cpuNanoseconds
        self.footprintBytes = footprintBytes
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
    }
}

/// Where a pane's processes can be found, as the MainActor saw it at capture time.
///
/// `ttyDevice` is the whole provenance claim. It comes from `ghostty_surface_tty_name`, is
/// stable for the surface's lifetime, and does not move when a shell job starts or stops —
/// which is exactly what disqualifies `foregroundPID` from the same role. The foreground PID
/// rides along as presentation metadata and never decides ownership.
public struct PaneProvenance: Equatable, Sendable {
    public let slotID: UUID
    public let tabID: UUID
    public let workspaceID: UUID
    public let ttyDevice: UInt32?
    public let foregroundPID: Int32?

    public init(
        slotID: UUID,
        tabID: UUID,
        workspaceID: UUID,
        ttyDevice: UInt32?,
        foregroundPID: Int32?
    ) {
        self.slotID = slotID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.ttyDevice = ttyDevice
        self.foregroundPID = foregroundPID
    }
}

// MARK: - Where a terminal's tree begins  @domain: process-telemetry

/// One process attached to a terminal that the sampler was able to read, reduced to the two
/// facts root selection needs.
///
/// Deliberately not `RawProcessSample`: at the moment roots are chosen the sampler has only
/// asked the kernel who the parent is. Identity needs a start stamp, and demanding one here
/// would mean a process whose counters are refused could not even be used to locate the tree
/// it sits in.
public struct AttachedProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32

    public init(pid: Int32, parentPID: Int32) {
        self.pid = pid
        self.parentPID = parentPID
    }
}

/// Which of a terminal's processes begin the tree beneath it.
public enum TerminalProcessTree {
    /// The topmost readable processes among `readable`.
    ///
    /// A root is a process whose parent is not itself in this list. The distinction that makes
    /// this a rule rather than a line of the sweep: the list holds what the sampler could
    /// **read**, not what the kernel merely **enumerated**. Ghostty starts every pane through
    /// setuid-root `/usr/bin/login`, which answers `proc_pidinfo` with EPERM for a UID-501
    /// caller. Judged against the enumerated set, `login` shadows the shell below it while
    /// never qualifying as a root itself, and the pane's whole tree — shell, agent, and every
    /// descendant — disappears behind a parent nobody can see. Judged against the readable
    /// set, the shell is the root, which is the honest answer: it is the topmost process
    /// Tenon can actually account for.
    ///
    /// Sorted, so a sweep walks the same order twice and a test can name the result.
    public static func roots(readable: [AttachedProcess]) -> [Int32] {
        let present = Set(readable.map(\.pid))
        let topmost = readable.filter { !present.contains($0.parentPID) }.map(\.pid).sorted()
        guard topmost.isEmpty else { return topmost }

        // No process is topmost, so the parent links form a cycle — which a PID reused between
        // two reads inside one sweep can produce. Every process here is live and belongs to
        // this pane; answering "no roots" would delete all of them from the pane that owns
        // them, and an empty pane is indistinguishable from an idle one. Entering at the
        // lowest PID is arbitrary but deterministic, and the walk's visited set is what stops
        // it looping.
        return readable.map(\.pid).min().map { [$0] } ?? []
    }
}

/// The names the hierarchy shows. The telemetry core never reaches into `WorkspaceCatalog`
/// for them, so it stays a pure function of its inputs and a test can name a workspace
/// without building one.
public struct TelemetryLabels: Equatable, Sendable {
    public let workspaces: [UUID: String]
    public let tabs: [UUID: String]
    public let panes: [UUID: String]

    public init(workspaces: [UUID: String], tabs: [UUID: String], panes: [UUID: String]) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
    }

    public static let none = TelemetryLabels(workspaces: [:], tabs: [:], panes: [:])
}

/// Everything one native sweep produced.
public struct ProcessSampleSet: Equatable, Sendable {
    /// Tenon's own process, read through the same fields as any other. It is projected only
    /// into the app row: terminal shells are host descendants too, so traversing the host's
    /// children would double-count every pane's work as host overhead.
    public let hostRecord: RawProcessSample?
    /// Every process reachable from a pane TTY root, plus any the sampler could name but not
    /// attribute.
    public let processes: [RawProcessSample]
    /// True when the sweep stopped at its capacity bound rather than at the end of the tree.
    public let truncated: Bool
    /// How many identities the kernel refused. Drives `partial`, never a silent gap.
    public let unreadableCount: Int

    public init(
        hostRecord: RawProcessSample?,
        processes: [RawProcessSample],
        truncated: Bool = false,
        unreadableCount: Int = 0
    ) {
        self.hostRecord = hostRecord
        self.processes = processes
        self.truncated = truncated
        self.unreadableCount = unreadableCount
    }
}

// MARK: - Ownership  @domain: process-telemetry

/// Which pane, if any, owns each sampled identity.
public struct ProcessOwnership: Equatable, Sendable {
    /// Identity → owning pane slot. An identity absent here is host/shared, never zero.
    public let owners: [ProcessIdentity: UUID]
    /// Identities that were reached but belong to no pane exclusively.
    public let shared: Set<ProcessIdentity>
    /// Identity → its parent identity within the sampled set, for drawing the child tree.
    public let parents: [ProcessIdentity: ProcessIdentity]
    /// Panes whose TTY produced no process at all.
    public let panesWithoutProcesses: Set<UUID>

    public init(
        owners: [ProcessIdentity: UUID],
        shared: Set<ProcessIdentity>,
        parents: [ProcessIdentity: ProcessIdentity],
        panesWithoutProcesses: Set<UUID>
    ) {
        self.owners = owners
        self.shared = shared
        self.parents = parents
        self.panesWithoutProcesses = panesWithoutProcesses
    }
}

public enum ProcessTelemetryGraph {
    /// Resolve pane ownership over one sample set.
    ///
    /// The rule, in the order it is applied:
    ///
    /// 1. A process whose controlling TTY *is* a pane's TTY belongs to that pane. This is the
    ///    strongest claim and nothing overrides it.
    /// 2. Otherwise a process belongs to the pane whose root tree reaches it in the fewest
    ///    steps. Reachability follows parent links inside the sampled set only, so a process
    ///    that fully reparents outside every root — a daemon that detached — leaves terminal
    ///    ownership rather than being kept by an ancestor that no longer exists.
    /// 3. An exact tie in depth is broken by the owning slot's UUID string, so the answer does
    ///    not depend on dictionary order.
    /// 4. One identity is claimed exactly once across the whole app. Everything unclaimed is
    ///    reported shared, which is what keeps the aggregate footprint from counting a process twice.
    ///
    /// Two panes cannot legitimately share one TTY — a TTY belongs to one surface — but the
    /// function does not assume it, because a stale provenance snapshot briefly can. When it
    /// happens the slot UUID order decides, deterministically, and the loser's processes are
    /// not duplicated into both.
    public static func resolveOwnership(
        panes: [PaneProvenance],
        samples: ProcessSampleSet
    ) -> ProcessOwnership {
        let byIdentity = Dictionary(
            samples.processes.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // PID → identity, for turning a parent PID into a parent identity. A PID appearing
        // twice in one sweep is impossible on a live machine; if it somehow does, the lower
        // identity wins so the map stays a function.
        var identityForPID: [Int32: ProcessIdentity] = [:]
        for sample in samples.processes {
            let pid = sample.identity.pid
            if let existing = identityForPID[pid], existing <= sample.identity { continue }
            identityForPID[pid] = sample.identity
        }

        var parents: [ProcessIdentity: ProcessIdentity] = [:]
        for sample in samples.processes {
            guard let parent = identityForPID[sample.parentPID], parent != sample.identity else { continue }
            parents[sample.identity] = parent
        }

        var childrenOf: [ProcessIdentity: [ProcessIdentity]] = [:]
        for (child, parent) in parents {
            childrenOf[parent, default: []].append(child)
        }
        for key in childrenOf.keys {
            childrenOf[key]?.sort()
        }

        // Panes in a stable order, so every tie-break below is reproducible.
        let orderedPanes = panes.sorted { $0.slotID.uuidString < $1.slotID.uuidString }

        // (1) direct TTY attachment.
        var directOwner: [ProcessIdentity: UUID] = [:]
        for pane in orderedPanes {
            guard let device = pane.ttyDevice else { continue }
            for sample in samples.processes where sample.ttyDevice == device {
                if directOwner[sample.identity] == nil {
                    directOwner[sample.identity] = pane.slotID
                }
            }
        }

        // Roots: a directly attached process whose parent is not attached to the same pane.
        var rootsByPane: [UUID: [ProcessIdentity]] = [:]
        for (identity, slotID) in directOwner {
            let parentIsSamePane = parents[identity].map { directOwner[$0] == slotID } ?? false
            if !parentIsSamePane {
                rootsByPane[slotID, default: []].append(identity)
            }
        }
        for key in rootsByPane.keys {
            rootsByPane[key]?.sort()
        }

        // (2) nearest root by breadth-first depth, (3) slot UUID breaking an exact tie.
        var bestDepth: [ProcessIdentity: Int] = [:]
        var owners: [ProcessIdentity: UUID] = [:]
        for pane in orderedPanes {
            guard let roots = rootsByPane[pane.slotID] else { continue }
            var frontier = roots
            var depth = 0
            var visited = Set<ProcessIdentity>()
            while !frontier.isEmpty {
                var next: [ProcessIdentity] = []
                for identity in frontier {
                    guard visited.insert(identity).inserted else { continue }
                    // A direct claim by another pane is never displaced by depth.
                    if let direct = directOwner[identity], direct != pane.slotID {
                        continue
                    }
                    if let existing = bestDepth[identity], existing <= depth {
                        // Equal depth is settled by the ordered pane loop: the first pane in
                        // slot-UUID order already claimed it, so leave it alone.
                        continue
                    }
                    bestDepth[identity] = depth
                    owners[identity] = pane.slotID
                    next.append(contentsOf: childrenOf[identity] ?? [])
                }
                frontier = next
                depth += 1
            }
        }

        // A direct attachment always wins, even if no BFS reached it (a pane whose root is
        // its only process, or one attached below a foreign subtree).
        for (identity, slotID) in directOwner {
            owners[identity] = slotID
        }

        // (4) one claim per identity; everything left over is shared, not zero.
        let claimed = Set(owners.keys)
        let shared = Set(byIdentity.keys).subtracting(claimed)

        let occupied = Set(owners.values)
        let empty = Set(panes.map(\.slotID)).subtracting(occupied)

        return ProcessOwnership(
            owners: owners,
            shared: shared,
            parents: parents,
            panesWithoutProcesses: empty
        )
    }
}

// MARK: - Interval metrics  @domain: process-telemetry

/// The cumulative counters carried from one sample to the next.
public struct ProcessCounters: Equatable, Sendable {
    public let cpuNanoseconds: UInt64?
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?
    /// The monotonic instant the counters were read, in nanoseconds.
    public let capturedAtNanoseconds: UInt64

    public init(
        cpuNanoseconds: UInt64?,
        diskBytesRead: UInt64?,
        diskBytesWritten: UInt64?,
        capturedAtNanoseconds: UInt64
    ) {
        self.cpuNanoseconds = cpuNanoseconds
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.capturedAtNanoseconds = capturedAtNanoseconds
    }
}

public enum ProcessTelemetryMetrics {
    /// Interval CPU as a percentage of one core-second per wall second.
    ///
    /// Deliberately **not** normalized by core count and **not** capped: a four-thread build
    /// on an eight-core machine genuinely spends four core-seconds per second, and 400% is
    /// the true statement about it. Capping at 100 would make the busiest pane in the list
    /// indistinguishable from a merely busy one, which is the question the monitor exists to
    /// answer.
    public static func cpuPercent(
        previous: ProcessCounters?,
        current: ProcessCounters
    ) -> TelemetryValue<Double> {
        guard let currentCPU = current.cpuNanoseconds else { return .unavailable(.unreadable) }
        guard let previous, let previousCPU = previous.cpuNanoseconds else {
            return .unavailable(.firstObservation)
        }
        guard current.capturedAtNanoseconds > previous.capturedAtNanoseconds else {
            return .unavailable(.invalidInterval)
        }
        guard currentCPU >= previousCPU else { return .unavailable(.counterWentBackwards) }
        let elapsed = current.capturedAtNanoseconds - previous.capturedAtNanoseconds
        let used = currentCPU - previousCPU
        return .known(100 * Double(used) / Double(elapsed))
    }

    /// Bytes moved between two readings of a cumulative counter.
    public static func intervalBytes(
        previous: UInt64?,
        current: UInt64?
    ) -> TelemetryValue<UInt64> {
        guard let current else { return .unavailable(.unreadable) }
        guard let previous else { return .unavailable(.firstObservation) }
        guard current >= previous else { return .unavailable(.counterWentBackwards) }
        return .known(current - previous)
    }

    /// Sum footprint bytes without ever wrapping.
    ///
    /// An aggregate of unknowns is unknown, but an aggregate of *some* knowns is the sum of
    /// those: a pane with one unreadable child still reports the memory it can prove, and the
    /// snapshot goes partial to say so. Only an empty set of readable children is unavailable.
    public static func aggregateBytes(_ values: [TelemetryValue<UInt64>]) -> TelemetryValue<UInt64> {
        var total: UInt64 = 0
        var sawKnown = false
        for value in values {
            guard case let .known(bytes) = value else { continue }
            let (sum, overflowed) = total.addingReportingOverflow(bytes)
            if overflowed { return .unavailable(.overflow) }
            total = sum
            sawKnown = true
        }
        return sawKnown ? .known(total) : .unavailable(unanimousReason(values))
    }

    /// Sum CPU percentages the same way. If no descendant produced a usable delta — which is
    /// exactly what happens on the very first sample — the aggregate says so instead of
    /// claiming an idle tree.
    public static func aggregatePercent(_ values: [TelemetryValue<Double>]) -> TelemetryValue<Double> {
        var total = 0.0
        var sawKnown = false
        for value in values {
            guard case let .known(percent) = value else { continue }
            total += percent
            sawKnown = true
        }
        return sawKnown ? .known(total) : .unavailable(unanimousReason(values))
    }

    /// What an aggregate of nothing-readable should say.
    ///
    /// When every child failed the same way, that reason IS the parent's reason: a pane whose
    /// only process is on its first observation is itself on its first observation, and
    /// reporting a vaguer `unreadable` there would throw away the one fact that explains the
    /// em dash. Only genuinely mixed failures collapse, because no single reason is true of
    /// the whole.
    private static func unanimousReason<Wrapped>(
        _ values: [TelemetryValue<Wrapped>]
    ) -> TelemetryUnavailability {
        var reasons: Set<TelemetryUnavailability> = []
        for value in values {
            if let reason = value.unavailability { reasons.insert(reason) }
        }
        return reasons.count == 1 ? reasons.first! : .unreadable
    }

    /// Aggregate footprint as a share of installed memory. Zero installed memory is not a division
    /// this code is allowed to perform.
    public static func physicalMemoryShare(
        aggregateBytes: TelemetryValue<UInt64>,
        physicalMemory: UInt64
    ) -> TelemetryValue<Double> {
        guard physicalMemory > 0 else { return .unavailable(.unreadable) }
        guard case let .known(bytes) = aggregateBytes else {
            return .unavailable(aggregateBytes.unavailability ?? .unreadable)
        }
        return .known(Double(bytes) / Double(physicalMemory))
    }
}

// MARK: - Formatting  @domain: process-telemetry

public enum TelemetryFormat {
    /// The em dash a missing value shows. Never "0", never blank.
    public static let missing = "—"

    /// SI units, because this panel is read beside Activity Monitor and every other place
    /// macOS prints a size. Matching the operating system is what lets an operator check one
    /// number against another without first converting between two conventions 4.9% apart.
    public static func bytes(_ value: TelemetryValue<UInt64>) -> String {
        guard case let .known(bytes) = value else { return missing }
        let units = ["B", "kB", "MB", "GB", "TB"]
        var amount = Double(bytes)
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        return index == 0
            ? "\(bytes) B"
            : String(format: "%.1f %@", amount, units[index])
    }

    public static func percent(_ value: TelemetryValue<Double>) -> String {
        guard case let .known(percent) = value else { return missing }
        return String(format: "%.1f%%", percent)
    }

    public static func share(_ value: TelemetryValue<Double>) -> String {
        guard case let .known(share) = value else { return missing }
        return String(format: "%.1f%%", share * 100)
    }
}
