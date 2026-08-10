// @domain: process-telemetry
import Foundation

// MARK: - The tree a snapshot is  @domain: process-telemetry

/// One row of the monitor, and its children.
///
/// The hierarchy is a tree rather than a flat list with a depth column because sorting is
/// defined *within sibling groups* — a pane's processes reorder under that pane and never
/// float up past another workspace. A flat list would make that rule something the sort has
/// to remember; as a tree it is something the sort cannot express otherwise.
public struct TelemetryNode: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable, Hashable {
        /// Tenon's own process. Sampled from `getpid()` alone — its children are the panes'
        /// shells, and claiming them here would count every terminal twice.
        case app
        /// Real processes with no proven exclusive pane owner: WebKit content processes,
        /// plugin helpers, anything reached but unattributable. Named as a group precisely so
        /// nothing has to be guessed into a pane to be visible.
        case hostShared
        case workspace(UUID)
        case tab(UUID)
        case pane(UUID)
        case process(ProcessIdentity)
    }

    public let kind: Kind
    public let name: String
    public let pid: Int32?
    public let cpuPercent: TelemetryValue<Double>
    public let footprintBytes: TelemetryValue<UInt64>
    public let diskReadBytes: TelemetryValue<UInt64>
    public let diskWrittenBytes: TelemetryValue<UInt64>
    /// Marks the pane's foreground job. Presentation only — it never moved ownership.
    public let isForeground: Bool
    /// The pane this row can reveal, when there is one. Both pane rows and the process rows
    /// under them carry it, which is what makes Return work anywhere in the subtree.
    public let revealsPane: UUID?
    public let children: [TelemetryNode]

    public init(
        kind: Kind,
        name: String,
        pid: Int32? = nil,
        cpuPercent: TelemetryValue<Double>,
        footprintBytes: TelemetryValue<UInt64>,
        diskReadBytes: TelemetryValue<UInt64> = .unavailable(.unreadable),
        diskWrittenBytes: TelemetryValue<UInt64> = .unavailable(.unreadable),
        isForeground: Bool = false,
        revealsPane: UUID? = nil,
        children: [TelemetryNode] = []
    ) {
        self.kind = kind
        self.name = name
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.isForeground = isForeground
        self.revealsPane = revealsPane
        self.children = children
    }

    /// Stable across samples, so SwiftUI keeps a row's expansion state while its numbers move.
    public var id: String {
        switch kind {
        case .app: return "app"
        case .hostShared: return "shared"
        case let .workspace(id): return "w:\(id.uuidString)"
        case let .tab(id): return "t:\(id.uuidString)"
        case let .pane(id): return "p:\(id.uuidString)"
        case let .process(identity): return "x:\(identity.pid):\(identity.startAbstime)"
        }
    }

    /// Every identity in this subtree, used to prove no process is counted twice.
    public var identities: [ProcessIdentity] {
        var found: [ProcessIdentity] = []
        if case let .process(identity) = kind { found.append(identity) }
        for child in children { found.append(contentsOf: child.identities) }
        return found
    }
}

// MARK: - Snapshot state  @domain: process-telemetry

/// What the monitor currently knows. Every case is distinguishable because collapsing any two
/// of them is a lie the operator would act on: an empty machine and a failed collector look
/// identical in a list, and only one of them means "nothing is running".
public enum TelemetryState: Equatable, Sendable {
    /// No successful snapshot has ever been produced.
    case loading
    /// The latest complete sample is on screen.
    case ready
    /// Useful data, but at least one row or metric could not be read.
    case partial(unreadable: Int, truncated: Bool)
    /// Sampling succeeded and found no local terminal processes.
    case empty
    /// Periodic sampling is stopped because nothing is watching. The values are real but old.
    case paused
    /// A collector-level failure; the last good snapshot is still shown.
    case stale(reason: String)
    /// A collector-level failure with no previous snapshot to fall back on.
    case failed(reason: String)

    public var isUsable: Bool {
        switch self {
        case .ready, .partial, .paused, .stale: return true
        case .loading, .empty, .failed: return false
        }
    }
}

/// One immutable reading, ready to render.
public struct TelemetrySnapshot: Equatable, Sendable {
    public let root: [TelemetryNode]
    public let state: TelemetryState
    /// Aggregate over every claimed identity plus the host — the summary line's figures.
    public let totalCPUPercent: TelemetryValue<Double>
    public let totalFootprintBytes: TelemetryValue<UInt64>
    public let physicalMemoryShare: TelemetryValue<Double>
    public let paneCount: Int
    public let processCount: Int
    /// Monotonic capture instant, for freshness arithmetic that a clock change cannot skew.
    public let capturedAtNanoseconds: UInt64
    /// Wall clock, for showing a person a time.
    public let capturedAt: Date
    /// The sampler lifecycle that produced this. A result from an older one is discarded.
    public let generation: Int
    /// The pane-ownership revision this was captured against. Ownership that moved while the
    /// sample was in flight makes the result unpublishable, not merely out of date.
    public let provenanceRevision: Int
    /// macOS supplies no public per-process network counter; this records that as a fact the
    /// UI can state once, rather than as an empty column that reads as zero traffic.
    public let networkAttribution: TelemetryValue<Never2>

    public init(
        root: [TelemetryNode],
        state: TelemetryState,
        totalCPUPercent: TelemetryValue<Double>,
        totalFootprintBytes: TelemetryValue<UInt64>,
        physicalMemoryShare: TelemetryValue<Double>,
        paneCount: Int,
        processCount: Int,
        capturedAtNanoseconds: UInt64,
        capturedAt: Date,
        generation: Int,
        provenanceRevision: Int,
        networkAttribution: TelemetryValue<Never2> = .unavailable(.noPublicPerProcessAPI)
    ) {
        self.root = root
        self.state = state
        self.totalCPUPercent = totalCPUPercent
        self.totalFootprintBytes = totalFootprintBytes
        self.physicalMemoryShare = physicalMemoryShare
        self.paneCount = paneCount
        self.processCount = processCount
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.capturedAt = capturedAt
        self.generation = generation
        self.provenanceRevision = provenanceRevision
        self.networkAttribution = networkAttribution
    }

    /// The same snapshot, restated as no longer refreshing.
    public func paused() -> TelemetrySnapshot {
        TelemetrySnapshot(
            root: root,
            state: .paused,
            totalCPUPercent: totalCPUPercent,
            totalFootprintBytes: totalFootprintBytes,
            physicalMemoryShare: physicalMemoryShare,
            paneCount: paneCount,
            processCount: processCount,
            capturedAtNanoseconds: capturedAtNanoseconds,
            capturedAt: capturedAt,
            generation: generation,
            provenanceRevision: provenanceRevision
        )
    }

    /// The same snapshot, restated as the last good one after a collector failure.
    public func staled(reason: String) -> TelemetrySnapshot {
        TelemetrySnapshot(
            root: root,
            state: .stale(reason: reason),
            totalCPUPercent: totalCPUPercent,
            totalFootprintBytes: totalFootprintBytes,
            physicalMemoryShare: physicalMemoryShare,
            paneCount: paneCount,
            processCount: processCount,
            capturedAtNanoseconds: capturedAtNanoseconds,
            capturedAt: capturedAt,
            generation: generation,
            provenanceRevision: provenanceRevision
        )
    }
}

/// An uninhabited payload. `TelemetryValue<Never2>` can only ever be `.unavailable`, which is
/// how the network field states "there is no such reading" in the type rather than in a
/// comment. Swift's own `Never` is not `Equatable & Sendable` in a way this generic accepts,
/// so the smallest local equivalent stands in.
public struct Never2: Equatable, Sendable {
    private init() {}
}

// MARK: - Projection  @domain: process-telemetry

/// Turns one sampler reading plus the previous counters into a snapshot.
public enum TelemetryProjection {
    /// Build the tree.
    ///
    /// Ordering of construction matters: ownership is resolved first and globally, so that
    /// each identity is placed exactly once; only then are aggregates rolled up from the
    /// leaves. Aggregating before claiming is how a process under two panes' subtrees would
    /// be added twice — the claim set makes that arithmetically impossible rather than merely
    /// unlikely.
    public static func project(
        panes: [PaneProvenance],
        samples: ProcessSampleSet,
        previousCounters: [ProcessIdentity: ProcessCounters],
        labels: TelemetryLabels,
        physicalMemory: UInt64,
        capturedAtNanoseconds: UInt64,
        capturedAt: Date,
        generation: Int,
        provenanceRevision: Int
    ) -> TelemetrySnapshot {
        let ownership = ProcessTelemetryGraph.resolveOwnership(panes: panes, samples: samples)
        let byIdentity = Dictionary(
            samples.processes.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func counters(for sample: RawProcessSample) -> ProcessCounters {
            ProcessCounters(
                cpuNanoseconds: sample.cpuNanoseconds,
                diskBytesRead: sample.diskBytesRead,
                diskBytesWritten: sample.diskBytesWritten,
                capturedAtNanoseconds: capturedAtNanoseconds
            )
        }

        /// The previous counters for this identity, but only if it is genuinely the same
        /// process. `previousCounters` is keyed by `(pid, start)`, so a reused PID simply
        /// misses and reports `.firstObservation` — the reset is structural.
        func metrics(for sample: RawProcessSample) -> (TelemetryValue<Double>, TelemetryValue<UInt64>, TelemetryValue<UInt64>, TelemetryValue<UInt64>) {
            let previous = previousCounters[sample.identity]
            let cpu = ProcessTelemetryMetrics.cpuPercent(previous: previous, current: counters(for: sample))
            let footprint: TelemetryValue<UInt64> = sample.footprintBytes.map { .known($0) } ?? .unavailable(.unreadable)
            let read = ProcessTelemetryMetrics.intervalBytes(previous: previous?.diskBytesRead, current: sample.diskBytesRead)
            let written = ProcessTelemetryMetrics.intervalBytes(previous: previous?.diskBytesWritten, current: sample.diskBytesWritten)
            return (cpu, footprint, read, written)
        }

        // Process rows, built child-first so a subtree carries its descendants' totals.
        var childrenOfIdentity: [ProcessIdentity: [ProcessIdentity]] = [:]
        for (child, parent) in ownership.parents {
            childrenOfIdentity[parent, default: []].append(child)
        }
        for key in childrenOfIdentity.keys { childrenOfIdentity[key]?.sort() }

        func processNode(_ identity: ProcessIdentity, owner: UUID?, foreground: Int32?) -> TelemetryNode? {
            guard let sample = byIdentity[identity] else { return nil }
            let (cpu, footprint, read, written) = metrics(for: sample)
            // Only descend into children this same pane owns; a child that reparented into
            // another pane's tree is that pane's row, not a duplicate under this one.
            let childNodes = (childrenOfIdentity[identity] ?? []).compactMap { child -> TelemetryNode? in
                guard ownership.owners[child] == owner else { return nil }
                return processNode(child, owner: owner, foreground: foreground)
            }
            return TelemetryNode(
                kind: .process(identity),
                name: sample.executableName,
                pid: identity.pid,
                cpuPercent: ProcessTelemetryMetrics.aggregatePercent([cpu] + childNodes.map(\.cpuPercent)),
                footprintBytes: ProcessTelemetryMetrics.aggregateBytes([footprint] + childNodes.map(\.footprintBytes)),
                diskReadBytes: ProcessTelemetryMetrics.aggregateBytes([read] + childNodes.map(\.diskReadBytes)),
                diskWrittenBytes: ProcessTelemetryMetrics.aggregateBytes([written] + childNodes.map(\.diskWrittenBytes)),
                isForeground: foreground == identity.pid,
                revealsPane: owner,
                children: childNodes
            )
        }

        // Pane rows.
        var paneNodes: [UUID: TelemetryNode] = [:]
        for pane in panes {
            let owned = ownership.owners.filter { $0.value == pane.slotID }.keys
            // Subtree roots for this pane: an owned identity whose parent this pane does not
            // also own. Anything else is already drawn beneath its parent.
            let roots = owned
                .filter { identity in
                    guard let parent = ownership.parents[identity] else { return true }
                    return ownership.owners[parent] != pane.slotID
                }
                .sorted()
            let rows = roots.compactMap { processNode($0, owner: pane.slotID, foreground: pane.foregroundPID) }
            let name = labels.panes[pane.slotID] ?? "Pane"
            paneNodes[pane.slotID] = TelemetryNode(
                kind: .pane(pane.slotID),
                name: name,
                // A pane with no OS process of its own stays visible and says why, rather
                // than reporting a confident zero.
                cpuPercent: rows.isEmpty
                    ? .unavailable(.noExclusiveProcess)
                    : ProcessTelemetryMetrics.aggregatePercent(rows.map(\.cpuPercent)),
                footprintBytes: rows.isEmpty
                    ? .unavailable(.noExclusiveProcess)
                    : ProcessTelemetryMetrics.aggregateBytes(rows.map(\.footprintBytes)),
                diskReadBytes: rows.isEmpty
                    ? .unavailable(.noExclusiveProcess)
                    : ProcessTelemetryMetrics.aggregateBytes(rows.map(\.diskReadBytes)),
                diskWrittenBytes: rows.isEmpty
                    ? .unavailable(.noExclusiveProcess)
                    : ProcessTelemetryMetrics.aggregateBytes(rows.map(\.diskWrittenBytes)),
                revealsPane: pane.slotID,
                children: rows
            )
        }

        // Tab and workspace rows, in the order the panes were given so the monitor mirrors
        // the workspace rather than inventing an order of its own.
        func rollUp(_ kind: TelemetryNode.Kind, name: String, children: [TelemetryNode]) -> TelemetryNode {
            TelemetryNode(
                kind: kind,
                name: name,
                cpuPercent: ProcessTelemetryMetrics.aggregatePercent(children.map(\.cpuPercent)),
                footprintBytes: ProcessTelemetryMetrics.aggregateBytes(children.map(\.footprintBytes)),
                diskReadBytes: ProcessTelemetryMetrics.aggregateBytes(children.map(\.diskReadBytes)),
                diskWrittenBytes: ProcessTelemetryMetrics.aggregateBytes(children.map(\.diskWrittenBytes)),
                children: children
            )
        }

        var workspaceOrder: [UUID] = []
        var tabOrderByWorkspace: [UUID: [UUID]] = [:]
        var panesByTab: [UUID: [UUID]] = [:]
        for pane in panes {
            if !workspaceOrder.contains(pane.workspaceID) { workspaceOrder.append(pane.workspaceID) }
            if tabOrderByWorkspace[pane.workspaceID]?.contains(pane.tabID) != true {
                tabOrderByWorkspace[pane.workspaceID, default: []].append(pane.tabID)
            }
            panesByTab[pane.tabID, default: []].append(pane.slotID)
        }

        let workspaceNodes: [TelemetryNode] = workspaceOrder.map { workspaceID in
            let tabs = (tabOrderByWorkspace[workspaceID] ?? []).map { tabID in
                let children = (panesByTab[tabID] ?? []).compactMap { paneNodes[$0] }
                return rollUp(.tab(tabID), name: labels.tabs[tabID] ?? "Tab", children: children)
            }
            return rollUp(.workspace(workspaceID), name: labels.workspaces[workspaceID] ?? "Workspace", children: tabs)
        }

        // Tenon's own process, and everything real that no pane proved it owns.
        let appNode: TelemetryNode? = samples.hostRecord.map { host in
            let (cpu, footprint, read, written) = metrics(for: host)
            return TelemetryNode(
                kind: .app,
                name: "Tenon",
                pid: host.identity.pid,
                cpuPercent: cpu,
                footprintBytes: footprint,
                diskReadBytes: read,
                diskWrittenBytes: written
            )
        }

        let sharedRows = ownership.shared.sorted().compactMap { identity -> TelemetryNode? in
            guard let sample = byIdentity[identity] else { return nil }
            let (cpu, footprint, read, written) = metrics(for: sample)
            return TelemetryNode(
                kind: .process(identity),
                name: sample.executableName,
                pid: identity.pid,
                cpuPercent: cpu,
                footprintBytes: footprint,
                diskReadBytes: read,
                diskWrittenBytes: written
            )
        }
        let sharedNode: TelemetryNode? = sharedRows.isEmpty
            ? nil
            : rollUp(.hostShared, name: "Host and shared", children: sharedRows)

        var root: [TelemetryNode] = []
        if let appNode { root.append(appNode) }
        if let sharedNode { root.append(sharedNode) }
        root.append(contentsOf: workspaceNodes)

        let allTotals = root.map(\.footprintBytes)
        let totalBytes = ProcessTelemetryMetrics.aggregateBytes(allTotals)
        let totalCPU = ProcessTelemetryMetrics.aggregatePercent(root.map(\.cpuPercent))

        let state: TelemetryState
        if samples.processes.isEmpty, samples.hostRecord == nil {
            state = .empty
        } else if samples.unreadableCount > 0 || samples.truncated {
            state = .partial(unreadable: samples.unreadableCount, truncated: samples.truncated)
        } else {
            state = .ready
        }

        return TelemetrySnapshot(
            root: root,
            state: state,
            totalCPUPercent: totalCPU,
            totalFootprintBytes: totalBytes,
            physicalMemoryShare: ProcessTelemetryMetrics.physicalMemoryShare(
                aggregateBytes: totalBytes,
                physicalMemory: physicalMemory
            ),
            paneCount: panes.count,
            processCount: samples.processes.count + (samples.hostRecord == nil ? 0 : 1),
            capturedAtNanoseconds: capturedAtNanoseconds,
            capturedAt: capturedAt,
            generation: generation,
            provenanceRevision: provenanceRevision
        )
    }

    /// Counters to carry into the next sample. Keyed by identity, so a PID that comes back as
    /// a different process finds nothing here and starts over.
    public static func counters(
        from samples: ProcessSampleSet,
        capturedAtNanoseconds: UInt64
    ) -> [ProcessIdentity: ProcessCounters] {
        var carried: [ProcessIdentity: ProcessCounters] = [:]
        for sample in samples.processes + (samples.hostRecord.map { [$0] } ?? []) {
            carried[sample.identity] = ProcessCounters(
                cpuNanoseconds: sample.cpuNanoseconds,
                diskBytesRead: sample.diskBytesRead,
                diskBytesWritten: sample.diskBytesWritten,
                capturedAtNanoseconds: capturedAtNanoseconds
            )
        }
        return carried
    }
}

// MARK: - Sorting  @domain: process-telemetry

public enum TelemetrySortKey: String, Equatable, Sendable, CaseIterable {
    case name
    case cpu
    case memory
}

public enum TelemetrySortDirection: Equatable, Sendable {
    case ascending
    case descending

    public var toggled: TelemetrySortDirection { self == .ascending ? .descending : .ascending }
}

public enum TelemetrySort {
    /// Sort every sibling group, leaving the hierarchy intact.
    ///
    /// Unavailable always sorts last regardless of direction. Treating it as zero would put
    /// "we could not read this" at whichever end zero belongs to, which reads as a confident
    /// answer; keeping it at the bottom in both directions keeps it visibly a non-answer.
    public static func apply(
        _ nodes: [TelemetryNode],
        key: TelemetrySortKey,
        direction: TelemetrySortDirection
    ) -> [TelemetryNode] {
        let sorted = nodes.sorted { lhs, rhs in
            compare(lhs, rhs, key: key, direction: direction)
        }
        return sorted.map { node in
            TelemetryNode(
                kind: node.kind,
                name: node.name,
                pid: node.pid,
                cpuPercent: node.cpuPercent,
                footprintBytes: node.footprintBytes,
                diskReadBytes: node.diskReadBytes,
                diskWrittenBytes: node.diskWrittenBytes,
                isForeground: node.isForeground,
                revealsPane: node.revealsPane,
                children: apply(node.children, key: key, direction: direction)
            )
        }
    }

    private static func compare(
        _ lhs: TelemetryNode,
        _ rhs: TelemetryNode,
        key: TelemetrySortKey,
        direction: TelemetrySortDirection
    ) -> Bool {
        switch key {
        case .name:
            let left = lhs.name.lowercased()
            let right = rhs.name.lowercased()
            if left != right { return direction == .ascending ? left < right : left > right }
        case .cpu:
            if let ordered = order(lhs.cpuPercent.value, rhs.cpuPercent.value, direction) { return ordered }
        case .memory:
            if let ordered = order(lhs.footprintBytes.value, rhs.footprintBytes.value, direction) { return ordered }
        }
        // Ties: normalized name, then the stable row identity, so the order never flickers
        // between two samples that measured the same numbers.
        let left = lhs.name.lowercased()
        let right = rhs.name.lowercased()
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    private static func order<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        _ direction: TelemetrySortDirection
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right { return nil }
            return direction == .ascending ? left < right : left > right
        case (nil, _?): return false   // unavailable sinks
        case (_?, nil): return true
        case (nil, nil): return nil
        }
    }
}

// MARK: - Bounded history  @domain: process-telemetry

/// Sixty aggregate footprint readings per key — two minutes at the two-second cadence.
///
/// Only aggregates get history. A ring per PID would grow with a `make -j16`, and a
/// sparkline for a process that lives four seconds answers no question worth the allocation.
public struct TelemetryHistory: Equatable, Sendable {
    public static let capacity = 60
    /// A key unseen for this long is dropped even if its pane still exists.
    public static let evictionInterval: UInt64 = 10 * 60 * 1_000_000_000

    public private(set) var series: [String: [UInt64]] = [:]
    private var lastSeen: [String: UInt64] = [:]

    public init() {}

    /// Record this snapshot's aggregates and forget what is gone.
    ///
    /// Eviction is two rules, not one: a key whose row left the tree goes immediately, because
    /// a closed pane's memory is not history anyone wants; a key still present but unseen for
    /// ten minutes goes on age, which is what bounds a workspace that is retained but never
    /// looked at.
    public mutating func record(_ snapshot: TelemetrySnapshot) {
        var live: Set<String> = []
        func walk(_ nodes: [TelemetryNode]) {
            for node in nodes {
                switch node.kind {
                case .process:
                    continue   // no per-process history, by design
                case .app, .hostShared, .workspace, .tab, .pane:
                    live.insert(node.id)
                    if case let .known(bytes) = node.footprintBytes {
                        var ring = series[node.id] ?? []
                        ring.append(bytes)
                        if ring.count > Self.capacity { ring.removeFirst(ring.count - Self.capacity) }
                        series[node.id] = ring
                    }
                    lastSeen[node.id] = snapshot.capturedAtNanoseconds
                    walk(node.children)
                }
            }
        }
        walk(snapshot.root)

        for key in series.keys where !live.contains(key) {
            let age = snapshot.capturedAtNanoseconds &- (lastSeen[key] ?? 0)
            if age > Self.evictionInterval || lastSeen[key] == nil {
                series.removeValue(forKey: key)
                lastSeen.removeValue(forKey: key)
            }
        }
    }

    /// Drop a key the instant its row leaves the catalog.
    public mutating func evict(_ ids: Set<String>) {
        for id in ids {
            series.removeValue(forKey: id)
            lastSeen.removeValue(forKey: id)
        }
    }

    public func samples(for id: String) -> [UInt64] { series[id] ?? [] }
}
