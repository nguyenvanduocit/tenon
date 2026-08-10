import Foundation
import XCTest

@testable import TenonCore

/// The pure half of T-100: which pane owns a process, what an interval metric means, and what
/// a figure says when it cannot be established.
///
/// Every rule here is a property of the sample set it is given, so none of it needs a machine,
/// a window, or a PTY. The Darwin reading that produces those sample sets is the shell's job
/// and is measured separately.
final class ProcessTelemetryTests: XCTestCase {
    // MARK: - Fixtures

    private let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let tabA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private let tabB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    /// Slot UUIDs are ordered deliberately: `paneA` sorts before `paneB` as a string, which is
    /// the documented tie-break and therefore has to be predictable in the fixtures too.
    private let paneA = UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!
    private let paneB = UUID(uuidString: "0000000B-0000-0000-0000-000000000001")!

    private func pane(
        _ slot: UUID,
        tab: UUID,
        workspace: UUID,
        tty: UInt32?,
        foreground: Int32? = nil
    ) -> PaneProvenance {
        PaneProvenance(slotID: slot, tabID: tab, workspaceID: workspace, ttyDevice: tty, foregroundPID: foreground)
    }

    private func process(
        pid: Int32,
        start: UInt64 = 1,
        parent: Int32 = 1,
        tty: UInt32? = nil,
        name: String = "sh",
        cpu: UInt64? = 0,
        footprint: UInt64? = 1024,
        read: UInt64? = 0,
        written: UInt64? = 0
    ) -> RawProcessSample {
        RawProcessSample(
            identity: ProcessIdentity(pid: pid, startAbstime: start),
            parentPID: parent,
            ttyDevice: tty,
            executableName: name,
            cpuNanoseconds: cpu,
            footprintBytes: footprint,
            diskBytesRead: read,
            diskBytesWritten: written
        )
    }

    // MARK: - Ownership

    func testProcessOnAPaneTTYBelongsToThatPane() {
        let samples = ProcessSampleSet(hostRecord: nil, processes: [process(pid: 100, tty: 7)])
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: samples
        )
        XCTAssertEqual(ownership.owners[ProcessIdentity(pid: 100, startAbstime: 1)], paneA)
        XCTAssertTrue(ownership.shared.isEmpty)
    }

    /// A background child that dropped its controlling terminal is still the pane's work. This
    /// is the case foreground-PID ownership gets wrong and reachability gets right.
    func testDescendantWithoutItsOwnTTYIsOwnedByTheNearestRoot() {
        let samples = ProcessSampleSet(
            hostRecord: nil,
            processes: [
                process(pid: 100, parent: 1, tty: 7, name: "bash"),
                process(pid: 101, parent: 100, tty: nil, name: "node"),
                process(pid: 102, parent: 101, tty: nil, name: "esbuild"),
            ]
        )
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: samples
        )
        for pid in [Int32(100), 101, 102] {
            XCTAssertEqual(
                ownership.owners[ProcessIdentity(pid: pid, startAbstime: 1)], paneA,
                "pid \(pid) should be owned through reachability"
            )
        }
    }

    /// The rule that keeps two panes' totals honest: an identity is claimed once, globally.
    func testOneIdentityIsClaimedByExactlyOnePane() {
        let samples = ProcessSampleSet(
            hostRecord: nil,
            processes: [
                process(pid: 100, parent: 1, tty: 7),
                process(pid: 200, parent: 1, tty: 8),
                process(pid: 201, parent: 200, tty: nil),
            ]
        )
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            samples: samples
        )
        let claims = ownership.owners
        XCTAssertEqual(claims.count, 3)
        XCTAssertEqual(Set(claims.keys).count, 3, "no identity may appear under two owners")
        XCTAssertEqual(claims[ProcessIdentity(pid: 201, startAbstime: 1)], paneB)
    }

    /// Direct TTY attachment outranks depth even when another pane's tree reaches the process
    /// first. Depth is the fallback, not the rule.
    func testDirectTTYOwnershipBeatsNearerAncestry() {
        let samples = ProcessSampleSet(
            hostRecord: nil,
            processes: [
                process(pid: 100, parent: 1, tty: 7, name: "bash"),
                // A child of pane A's shell that has taken pane B's controlling terminal.
                process(pid: 101, parent: 100, tty: 8, name: "attached-elsewhere"),
                process(pid: 200, parent: 1, tty: 8, name: "bash"),
            ]
        )
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            samples: samples
        )
        XCTAssertEqual(ownership.owners[ProcessIdentity(pid: 101, startAbstime: 1)], paneB)
    }

    /// A process whose parent is not in the sampled set at all has reparented away. It is not
    /// kept by an ancestor that no longer exists, and it is not silently dropped either — it
    /// becomes shared, which is a visible statement.
    func testFullyReparentedProcessLeavesPaneOwnershipAndBecomesShared() {
        let samples = ProcessSampleSet(
            hostRecord: nil,
            processes: [
                process(pid: 100, parent: 1, tty: 7),
                process(pid: 900, parent: 1, tty: nil, name: "daemonised"),
            ]
        )
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: samples
        )
        XCTAssertNil(ownership.owners[ProcessIdentity(pid: 900, startAbstime: 1)])
        XCTAssertTrue(ownership.shared.contains(ProcessIdentity(pid: 900, startAbstime: 1)))
    }

    func testPaneWithNoProcessesIsReportedRatherThanOmitted() {
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: ProcessSampleSet(hostRecord: nil, processes: [])
        )
        XCTAssertEqual(ownership.panesWithoutProcesses, [paneA])
    }

    /// Two panes claiming one TTY cannot happen on a healthy machine, but a stale provenance
    /// snapshot can describe it for one sample. The answer must be deterministic and must not
    /// duplicate the process into both.
    func testTwoPanesOnOneTTYResolveDeterministicallyWithoutDuplication() {
        let samples = ProcessSampleSet(hostRecord: nil, processes: [process(pid: 100, tty: 7)])
        let panes = [
            pane(paneB, tab: tabB, workspace: workspaceB, tty: 7),
            pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
        ]
        let first = ProcessTelemetryGraph.resolveOwnership(panes: panes, samples: samples)
        let second = ProcessTelemetryGraph.resolveOwnership(panes: panes.reversed(), samples: samples)
        XCTAssertEqual(first.owners, second.owners, "input order must not change the answer")
        XCTAssertEqual(first.owners[ProcessIdentity(pid: 100, startAbstime: 1)], paneA, "lower slot UUID wins")
        XCTAssertEqual(first.owners.count, 1)
    }

    /// A parent link that points at itself is malformed data, not a reason to loop forever.
    func testSelfParentingDoesNotLoop() {
        let samples = ProcessSampleSet(
            hostRecord: nil,
            processes: [process(pid: 100, parent: 100, tty: 7)]
        )
        let ownership = ProcessTelemetryGraph.resolveOwnership(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: samples
        )
        XCTAssertEqual(ownership.owners.count, 1)
        XCTAssertTrue(ownership.parents.isEmpty)
    }

    // MARK: - Identity and PID reuse

    /// The whole reason identity is a pair. A recycled PID must not inherit the previous
    /// occupant's cumulative counter — if it did, the new process would show one enormous
    /// spike at the moment of reuse.
    func testReusedPIDDoesNotInheritTheEarlierProcessCounters() {
        let old = ProcessIdentity(pid: 100, startAbstime: 1)
        let new = ProcessIdentity(pid: 100, startAbstime: 2)
        XCTAssertNotEqual(old, new)

        let previous = [old: ProcessCounters(
            cpuNanoseconds: 5_000_000_000,
            diskBytesRead: 0,
            diskBytesWritten: 0,
            capturedAtNanoseconds: 0
        )]
        let snapshot = TelemetryProjection.project(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: ProcessSampleSet(
                hostRecord: nil,
                processes: [process(pid: 100, start: 2, tty: 7, cpu: 10_000_000)]
            ),
            previousCounters: previous,
            labels: .none,
            physicalMemory: 8 << 30,
            capturedAtNanoseconds: 1_000_000_000,
            capturedAt: Date(),
            generation: 1,
            provenanceRevision: 1
        )
        let paneNode = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .pane(self.paneA) })
        let processNode = try! XCTUnwrap(paneNode.children.first)
        XCTAssertEqual(
            processNode.cpuPercent.unavailability, .firstObservation,
            "a reused PID starts over rather than reporting a spike"
        )
    }

    // MARK: - CPU

    func testFirstObservationHasNoDeltaAndSaysSo() {
        let value = ProcessTelemetryMetrics.cpuPercent(
            previous: nil,
            current: ProcessCounters(cpuNanoseconds: 500, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1000)
        )
        XCTAssertEqual(value.unavailability, .firstObservation)
        XCTAssertEqual(TelemetryFormat.percent(value), "—")
    }

    func testCPUIsTheConvertedIntervalDelta() {
        let previous = ProcessCounters(cpuNanoseconds: 1_000_000_000, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 0)
        let current = ProcessCounters(cpuNanoseconds: 1_500_000_000, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1_000_000_000)
        // half a core-second in one wall second
        XCTAssertEqual(ProcessTelemetryMetrics.cpuPercent(previous: previous, current: current).value!, 50, accuracy: 0.001)
    }

    /// Work spanning cores genuinely exceeds 100%, and the number is the point: capping it
    /// would make a four-thread build indistinguishable from a busy shell.
    func testCPUAboveOneHundredPercentIsReportedNotCapped() {
        let previous = ProcessCounters(cpuNanoseconds: 0, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 0)
        let current = ProcessCounters(cpuNanoseconds: 4_000_000_000, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1_000_000_000)
        let value = ProcessTelemetryMetrics.cpuPercent(previous: previous, current: current)
        XCTAssertEqual(value.value!, 400, accuracy: 0.001)
        XCTAssertEqual(TelemetryFormat.percent(value), "400.0%")
    }

    func testCounterGoingBackwardsIsUnavailableRatherThanNegative() {
        let previous = ProcessCounters(cpuNanoseconds: 5_000, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 0)
        let current = ProcessCounters(cpuNanoseconds: 1_000, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1_000_000_000)
        XCTAssertEqual(
            ProcessTelemetryMetrics.cpuPercent(previous: previous, current: current).unavailability,
            .counterWentBackwards
        )
    }

    func testZeroElapsedTimeIsNotADivision() {
        let previous = ProcessCounters(cpuNanoseconds: 0, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1000)
        let current = ProcessCounters(cpuNanoseconds: 10, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1000)
        XCTAssertEqual(
            ProcessTelemetryMetrics.cpuPercent(previous: previous, current: current).unavailability,
            .invalidInterval
        )
    }

    func testUnreadableCPUIsUnavailableAndNotZero() {
        let current = ProcessCounters(cpuNanoseconds: nil, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 1000)
        let previous = ProcessCounters(cpuNanoseconds: 0, diskBytesRead: nil, diskBytesWritten: nil, capturedAtNanoseconds: 0)
        let value = ProcessTelemetryMetrics.cpuPercent(previous: previous, current: current)
        XCTAssertEqual(value.unavailability, .unreadable)
        XCTAssertNil(value.value)
    }

    // MARK: - Memory

    func testAggregateRSSSumsClaimedIdentitiesExactly() {
        let total = ProcessTelemetryMetrics.aggregateBytes([.known(1000), .known(2000), .known(3)])
        XCTAssertEqual(total.value, 3003)
    }

    /// Overflow produces an explicit unavailable. It never wraps into a small, plausible,
    /// wrong number.
    func testAggregateRSSOverflowIsUnavailableRatherThanWrapping() {
        let total = ProcessTelemetryMetrics.aggregateBytes([.known(.max), .known(1)])
        XCTAssertEqual(total.unavailability, .overflow)
        XCTAssertNil(total.value)
    }

    /// One unreadable child does not erase the memory the pane can prove; it makes the
    /// snapshot partial and keeps the provable total.
    func testAggregateKeepsWhatItCanProveWhenOneChildIsUnreadable() {
        let total = ProcessTelemetryMetrics.aggregateBytes([.known(1000), .unavailable(.unreadable)])
        XCTAssertEqual(total.value, 1000)
    }

    func testAggregateOfNothingReadableIsUnavailableNotZero() {
        let total = ProcessTelemetryMetrics.aggregateBytes([.unavailable(.unreadable)])
        XCTAssertNil(total.value)
        XCTAssertEqual(TelemetryFormat.bytes(total), "—")
    }

    /// The first sample of a whole tree has no deltas anywhere. Reporting 0% would say the
    /// machine is idle when the truth is that nothing has been measured yet.
    func testAggregateCPUOfAFirstSampleIsUnavailableNotZero() {
        let total = ProcessTelemetryMetrics.aggregatePercent([.unavailable(.firstObservation), .unavailable(.firstObservation)])
        XCTAssertEqual(total.unavailability, .firstObservation)
        XCTAssertNil(total.value)
    }

    func testPhysicalShareRefusesToDivideByNothing() {
        XCTAssertEqual(
            ProcessTelemetryMetrics.physicalMemoryShare(aggregateBytes: .known(10), physicalMemory: 0).unavailability,
            .unreadable
        )
    }

    // MARK: - Network

    /// macOS publishes no per-process network counter — measured, not assumed: no field of
    /// `rusage_info_v4` or `proc_taskinfo` carries one, socket info exposes only current
    /// buffer occupancy, and `nettop` costs seconds per sample. The snapshot therefore states
    /// the absence rather than showing an empty column that reads as "no traffic".
    func testNetworkAttributionIsUnavailableWithAReasonAndCanNeverCarryANumber() {
        let snapshot = makeSnapshot(processes: [process(pid: 100, tty: 7)])
        XCTAssertEqual(snapshot.networkAttribution.unavailability, .noPublicPerProcessAPI)
        XCTAssertNil(snapshot.networkAttribution.value)
    }

    // MARK: - Aggregation through the hierarchy

    func testWorkspaceAndTabAggregatesRollUpFromPanes() {
        let snapshot = makeSnapshot(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabA, workspace: workspaceA, tty: 8),
            ],
            processes: [
                process(pid: 100, tty: 7, footprint: 1000),
                process(pid: 200, tty: 8, footprint: 2000),
            ]
        )
        let workspace = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .workspace(self.workspaceA) })
        XCTAssertEqual(workspace.footprintBytes.value, 3000)
        let tab = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .tab(self.tabA) })
        XCTAssertEqual(tab.footprintBytes.value, 3000)
    }

    /// The app row is `getpid()` only. Traversing its children would re-count every pane's
    /// shell as host overhead, because a terminal is a descendant of the app.
    func testAppRowCountsOnlyTheHostProcess() {
        let snapshot = makeSnapshot(
            processes: [process(pid: 100, parent: 42, tty: 7, footprint: 5000)],
            host: process(pid: 42, parent: 1, name: "Tenon", footprint: 900)
        )
        let app = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .app })
        XCTAssertEqual(app.footprintBytes.value, 900)
        XCTAssertTrue(app.children.isEmpty)
    }

    /// Nothing is counted twice across the whole tree — the arithmetic guarantee behind every
    /// aggregate above.
    func testNoIdentityAppearsTwiceAnywhereInTheTree() {
        let snapshot = makeSnapshot(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            processes: [
                process(pid: 100, parent: 1, tty: 7),
                process(pid: 101, parent: 100, tty: nil),
                process(pid: 200, parent: 1, tty: 8),
                process(pid: 201, parent: 200, tty: nil),
                process(pid: 900, parent: 1, tty: nil, name: "shared-helper"),
            ]
        )
        let identities = snapshot.root.flatMap(\.identities)
        XCTAssertEqual(identities.count, Set(identities).count, "an identity is drawn once")
        XCTAssertEqual(identities.count, 5)
    }

    /// The sharp case for deduplication: a child whose own terminal belongs to a *different*
    /// pane than its parent's.
    ///
    /// Ownership already answers this — direct TTY wins — but the tree is built by walking
    /// parents, so a subtree walk that descends into every reachable child rather than only
    /// the ones this pane owns will draw that process twice: once under its parent's pane and
    /// once as its own pane's root. Both panes then report its memory, and the workspace total
    /// counts it twice. The identity count is the arithmetic statement of that.
    func testAChildOwnedByAnotherPaneIsNotAlsoDrawnUnderItsParent() {
        let snapshot = makeSnapshot(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            processes: [
                process(pid: 100, parent: 1, tty: 7, name: "bash", footprint: 100),
                // a child of pane A's shell that has taken pane B's controlling terminal
                process(pid: 101, parent: 100, tty: 8, name: "moved", footprint: 500),
                process(pid: 200, parent: 1, tty: 8, name: "bash", footprint: 200),
            ]
        )
        let identities = snapshot.root.flatMap(\.identities)
        XCTAssertEqual(
            identities.count, Set(identities).count,
            "a process reachable from two panes is still drawn once"
        )
        XCTAssertEqual(identities.count, 3)

        let paneANode = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .pane(self.paneA) })
        XCTAssertFalse(
            paneANode.identities.contains(ProcessIdentity(pid: 101, startAbstime: 1)),
            "the moved child belongs to pane B and must not appear under pane A"
        )
        XCTAssertEqual(paneANode.footprintBytes.value, 100, "and its memory is not counted here")

        let paneBNode = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .pane(self.paneB) })
        XCTAssertTrue(paneBNode.identities.contains(ProcessIdentity(pid: 101, startAbstime: 1)))
        XCTAssertEqual(paneBNode.footprintBytes.value, 700, "counted exactly once, here")
    }

    /// A real process with no proven pane owner is named in its own group. It is never
    /// apportioned among panes to make the columns add up.
    func testUnattributableProcessAppearsUnderHostAndSharedRatherThanInAPane() {
        let snapshot = makeSnapshot(
            processes: [
                process(pid: 100, parent: 1, tty: 7),
                process(pid: 900, parent: 1, tty: nil, name: "com.apple.WebKit.WebContent"),
            ]
        )
        let shared = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .hostShared })
        XCTAssertEqual(shared.children.map(\.name), ["com.apple.WebKit.WebContent"])
        let paneNode = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .pane(self.paneA) })
        XCTAssertEqual(paneNode.identities, [ProcessIdentity(pid: 100, startAbstime: 1)])
    }

    /// A pane that has no OS process of its own stays on screen and says why. An invented
    /// `0 B` would be indistinguishable from a genuinely idle shell.
    func testPaneWithoutAnExclusiveProcessShowsUnavailableRatherThanZero() {
        let snapshot = makeSnapshot(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: nil)],
            processes: []
        )
        let paneNode = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .pane(self.paneA) })
        XCTAssertEqual(paneNode.footprintBytes.unavailability, .noExclusiveProcess)
        XCTAssertEqual(TelemetryFormat.bytes(paneNode.footprintBytes), "—")
        XCTAssertEqual(paneNode.cpuPercent.unavailability, .noExclusiveProcess)
    }

    /// Foreground PID marks a row and moves nothing.
    func testForegroundPIDMarksARowWithoutChangingOwnership() {
        let snapshot = makeSnapshot(
            panes: [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7, foreground: 101)],
            processes: [
                process(pid: 100, parent: 1, tty: 7, name: "bash"),
                process(pid: 101, parent: 100, tty: nil, name: "vim"),
            ]
        )
        let paneNode = try! XCTUnwrap(findNode(snapshot.root) { $0.kind == .pane(self.paneA) })
        let root = try! XCTUnwrap(paneNode.children.first)
        XCTAssertEqual(root.pid, 100, "the root is still the shell, not the foreground job")
        XCTAssertTrue(root.children.contains { $0.pid == 101 && $0.isForeground })
    }

    /// A retained workspace that nobody is looking at still reports. Its panes exist, so its
    /// processes are the operator's business.
    func testInactiveRetainedWorkspaceStillReports() {
        let snapshot = makeSnapshot(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            processes: [process(pid: 100, tty: 7, footprint: 10), process(pid: 200, tty: 8, footprint: 20)]
        )
        XCTAssertNotNil(findNode(snapshot.root) { $0.kind == .workspace(self.workspaceB) })
    }

    // MARK: - Churn

    /// A process that left between the sweep and the projection simply is not in the set. Its
    /// row disappears; no other row is disturbed.
    func testProcessExitRemovesOnlyItsOwnRow() {
        let before = makeSnapshot(processes: [
            process(pid: 100, parent: 1, tty: 7, footprint: 100),
            process(pid: 101, parent: 100, footprint: 200),
        ])
        let after = makeSnapshot(processes: [process(pid: 100, parent: 1, tty: 7, footprint: 100)])
        XCTAssertEqual(findNode(before.root) { $0.kind == .pane(self.paneA) }?.footprintBytes.value, 300)
        XCTAssertEqual(findNode(after.root) { $0.kind == .pane(self.paneA) }?.footprintBytes.value, 100)
    }

    func testUnreadableRowsMakeTheSnapshotPartialRatherThanReady() {
        let snapshot = makeSnapshot(processes: [process(pid: 100, tty: 7)], unreadable: 2)
        XCTAssertEqual(snapshot.state, .partial(unreadable: 2, truncated: false))
    }

    /// The distinction the operator acts on: a sample that succeeded and found nothing is not
    /// the same fact as a collector that failed.
    func testASuccessfulSampleFindingNothingIsEmptyNotAnError() {
        let snapshot = makeSnapshot(panes: [], processes: [], host: nil)
        XCTAssertEqual(snapshot.state, .empty)
    }

    // MARK: - Sorting

    func testSortingStaysWithinSiblingGroups() {
        let snapshot = makeSnapshot(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            processes: [
                process(pid: 100, parent: 1, tty: 7, name: "bash", footprint: 10),
                process(pid: 101, parent: 100, name: "big", footprint: 9_000_000),
                process(pid: 200, parent: 1, tty: 8, name: "bash", footprint: 20),
            ]
        )
        let sorted = TelemetrySort.apply(snapshot.root, key: .memory, direction: .descending)
        // The heavy process is under pane A and must not float to the top level.
        XCTAssertNil(sorted.first { $0.name == "big" })
        let workspaceA = try! XCTUnwrap(sorted.first { $0.kind == .workspace(self.workspaceA) })
        let paneNode = workspaceA.children.first!.children.first!
        XCTAssertEqual(paneNode.children.first!.name, "bash", "the subtree root stays the root")
    }

    func testMemoryDescendingPutsTheHeaviestSiblingFirst() {
        let snapshot = makeSnapshot(
            panes: [
                pane(paneA, tab: tabA, workspace: workspaceA, tty: 7),
                pane(paneB, tab: tabB, workspace: workspaceB, tty: 8),
            ],
            processes: [process(pid: 100, tty: 7, footprint: 10), process(pid: 200, tty: 8, footprint: 5000)]
        )
        let sorted = TelemetrySort.apply(snapshot.root, key: .memory, direction: .descending)
        let workspaces = sorted.filter { if case .workspace = $0.kind { return true } else { return false } }
        XCTAssertEqual(workspaces.first?.kind, .workspace(workspaceB))
    }

    /// Unavailable sorts last in *both* directions. Treating it as zero would park "could not
    /// read" at whichever end zero belongs to and make it look like an answer.
    func testUnavailableValuesSortLastInBothDirections() {
        let known = TelemetryNode(kind: .pane(paneA), name: "known", cpuPercent: .known(1), footprintBytes: .known(1))
        let unknown = TelemetryNode(kind: .pane(paneB), name: "unknown", cpuPercent: .unavailable(.unreadable), footprintBytes: .unavailable(.unreadable))
        for direction in [TelemetrySortDirection.ascending, .descending] {
            let sorted = TelemetrySort.apply([unknown, known], key: .memory, direction: direction)
            XCTAssertEqual(sorted.last?.name, "unknown", "direction \(direction)")
        }
    }

    func testTiesBreakOnNameThenIdentitySoOrderNeverFlickers() {
        let a = TelemetryNode(kind: .process(ProcessIdentity(pid: 2, startAbstime: 1)), name: "same", cpuPercent: .known(1), footprintBytes: .known(1))
        let b = TelemetryNode(kind: .process(ProcessIdentity(pid: 1, startAbstime: 1)), name: "same", cpuPercent: .known(1), footprintBytes: .known(1))
        let first = TelemetrySort.apply([a, b], key: .memory, direction: .descending).map(\.id)
        let second = TelemetrySort.apply([b, a], key: .memory, direction: .descending).map(\.id)
        XCTAssertEqual(first, second)
    }

    // MARK: - History

    func testHistoryKeepsSixtySamplesAndDropsTheOldest() {
        var history = TelemetryHistory()
        for index in 0 ..< 100 {
            history.record(makeSnapshot(
                processes: [process(pid: 100, tty: 7, footprint: UInt64(index))],
                capturedAt: UInt64(index) * 1_000_000_000
            ))
        }
        let series = history.samples(for: "p:\(paneA.uuidString)")
        XCTAssertEqual(series.count, TelemetryHistory.capacity)
        XCTAssertEqual(series.first, 40)
        XCTAssertEqual(series.last, 99)
    }

    /// No ring per PID. A `make -j16` would otherwise allocate sixteen histories for
    /// processes that live four seconds.
    func testProcessRowsGetNoHistory() {
        var history = TelemetryHistory()
        history.record(makeSnapshot(processes: [process(pid: 100, tty: 7)]))
        XCTAssertTrue(history.samples(for: "x:100:1").isEmpty)
        XCTAssertFalse(history.samples(for: "p:\(paneA.uuidString)").isEmpty)
    }

    func testEvictedKeysLeaveImmediately() {
        var history = TelemetryHistory()
        history.record(makeSnapshot(processes: [process(pid: 100, tty: 7)]))
        history.evict(["p:\(paneA.uuidString)"])
        XCTAssertTrue(history.samples(for: "p:\(paneA.uuidString)").isEmpty)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        panes: [PaneProvenance]? = nil,
        processes: [RawProcessSample],
        host: RawProcessSample? = nil,
        unreadable: Int = 0,
        truncated: Bool = false,
        capturedAt: UInt64 = 1_000_000_000,
        previous: [ProcessIdentity: ProcessCounters] = [:]
    ) -> TelemetrySnapshot {
        TelemetryProjection.project(
            panes: panes ?? [pane(paneA, tab: tabA, workspace: workspaceA, tty: 7)],
            samples: ProcessSampleSet(
                hostRecord: host,
                processes: processes,
                truncated: truncated,
                unreadableCount: unreadable
            ),
            previousCounters: previous,
            labels: .none,
            physicalMemory: 16 << 30,
            capturedAtNanoseconds: capturedAt,
            capturedAt: Date(timeIntervalSince1970: 0),
            generation: 1,
            provenanceRevision: 1
        )
    }

    private func findNode(_ nodes: [TelemetryNode], where predicate: (TelemetryNode) -> Bool) -> TelemetryNode? {
        for node in nodes {
            if predicate(node) { return node }
            if let found = findNode(node.children, where: predicate) { return found }
        }
        return nil
    }
}
