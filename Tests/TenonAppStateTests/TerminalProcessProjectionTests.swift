import Foundation
import TenonCore
import XCTest

@testable import TenonApp

/// The shell half of T-100: turning a TTY path into a device, and the real `libproc` reads
/// behind the sampler.
///
/// These are the claims a pure test cannot make, because they are about what macOS actually
/// does. They run against a real pseudo-terminal and a real process tree this test creates
/// and kills, so nothing depends on what happens to be running on the machine.
final class TerminalProcessProjectionTests: XCTestCase {
    // MARK: - Device resolution

    func testATTYPathResolvesToItsCharacterDevice() throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let device = TerminalDeviceResolver.device(forTTYPath: pty.path)
        XCTAssertNotNil(device, "a live pty must resolve")
    }

    /// A pane whose surface has not materialised reports no name, and a name that is not a
    /// terminal must not resolve — otherwise a stale or malformed value could collide with
    /// some other pane's device number and silently adopt its processes.
    func testANonTerminalPathResolvesToNothing() throws {
        XCTAssertNil(TerminalDeviceResolver.device(forTTYPath: ""))
        XCTAssertNil(TerminalDeviceResolver.device(forTTYPath: "/dev/null/not-a-thing"))
        let regularFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: regularFile)
        defer { try? FileManager.default.removeItem(at: regularFile) }
        XCTAssertNil(
            TerminalDeviceResolver.device(forTTYPath: regularFile.path),
            "a regular file is not a controlling terminal"
        )
    }

    // MARK: - Real process reads

    /// The whole native path end to end: a real shell on a real pty, with a background job, a
    /// pipeline, and a grandchild, all attributed to the pane that owns that terminal.
    func testTheSamplerFindsARealShellAndItsWholeSubtree() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let shell = try pty.spawnShell("sleep 30 & (sleep 30 | cat >/dev/null) & sleep 30")
        defer { shell.kill() }
        try await Task.sleep(nanoseconds: 800_000_000)

        let device = try XCTUnwrap(TerminalDeviceResolver.device(forTTYPath: pty.path))
        let pane = PaneProvenance(
            slotID: UUID(),
            tabID: UUID(),
            workspaceID: UUID(),
            ttyDevice: device,
            foregroundPID: nil
        )
        let samples = try await DarwinProcessSampler().sample(panes: [pane])

        XCTAssertGreaterThanOrEqual(
            samples.processes.count, 4,
            "the shell, its background job, its pipeline, and the grandchild"
        )
        XCTAssertTrue(
            samples.processes.contains { $0.identity.pid == shell.pid },
            "the shell itself is in the sweep"
        )
        // Identity is the pair, and the start stamp must be real — a zero would mean the
        // rusage read silently failed and every PID would collide on reuse.
        for sample in samples.processes {
            XCTAssertGreaterThan(sample.identity.startAbstime, 0, "pid \(sample.identity.pid)")
        }
        XCTAssertNotNil(samples.hostRecord, "the test process stands in for the app row")

        let ownership = ProcessTelemetryGraph.resolveOwnership(panes: [pane], samples: samples)
        for sample in samples.processes {
            XCTAssertEqual(
                ownership.owners[sample.identity], pane.slotID,
                "\(sample.executableName) (\(sample.identity.pid)) belongs to the pane that owns the tty"
            )
        }
        XCTAssertTrue(ownership.shared.isEmpty, "nothing in this tree is unattributable")
    }

    /// The convention that cost the design a wrong answer: `proc_listchildpids` reports an
    /// entry count while `proc_listpids` reports bytes. Read the wrong way, a shell's whole
    /// subtree disappears while the shell still renders — so this asserts the descendants are
    /// actually reached rather than merely that the root was found.
    func testDescendantsAreReachedAndNotSilentlyDroppedByTheCountConvention() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let shell = try pty.spawnShell("sleep 30 & sleep 30 & sleep 30")
        defer { shell.kill() }
        try await Task.sleep(nanoseconds: 800_000_000)

        let device = try XCTUnwrap(TerminalDeviceResolver.device(forTTYPath: pty.path))
        let pane = PaneProvenance(
            slotID: UUID(), tabID: UUID(), workspaceID: UUID(),
            ttyDevice: device, foregroundPID: nil
        )
        let samples = try await DarwinProcessSampler().sample(panes: [pane])
        let descendants = samples.processes.filter { $0.identity.pid != shell.pid }
        XCTAssertGreaterThanOrEqual(descendants.count, 3, "three background sleeps were reached")
    }

    /// A pane with no terminal contributes no roots, so the sweep walks nothing and the pane
    /// is left to render as unavailable rather than matching somebody else's processes.
    func testAPaneWithNoTerminalYieldsNoProcesses() async throws {
        let pane = PaneProvenance(
            slotID: UUID(), tabID: UUID(), workspaceID: UUID(),
            ttyDevice: nil, foregroundPID: nil
        )
        let samples = try await DarwinProcessSampler().sample(panes: [pane])
        XCTAssertTrue(samples.processes.isEmpty)

        let snapshot = TelemetryProjection.project(
            panes: [pane],
            samples: samples,
            previousCounters: [:],
            labels: .none,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            capturedAtNanoseconds: 1,
            capturedAt: Date(),
            generation: 1,
            provenanceRevision: 1
        )
        let paneNode = try XCTUnwrap(firstPane(in: snapshot.root))
        XCTAssertEqual(paneNode.footprintBytes.unavailability, .noExclusiveProcess)
    }

    /// A process that exits between listing and reading is ordinary churn. `proc_pidinfo`
    /// answers 0 with `ESRCH` and leaves the struct zeroed, so a sampler checking `rc >= 0`
    /// would report a dead process as live and idle. This asserts the dead PID produces no
    /// row at all.
    func testAnExitedProcessProducesNoRowRatherThanAZeroedOne() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        // The shell outlives the child that gets killed, so the sweep still has a root to
        // walk. Killing the whole tree would leave nothing to traverse and make every
        // assertion below vacuous — green because the loop never ran.
        let shell = try pty.spawnShell("sleep 30 & sleep 30 & sleep 30")
        defer { shell.kill() }
        try await Task.sleep(nanoseconds: 800_000_000)

        let device = try XCTUnwrap(TerminalDeviceResolver.device(forTTYPath: pty.path))
        let pane = PaneProvenance(
            slotID: UUID(), tabID: UUID(), workspaceID: UUID(),
            ttyDevice: device, foregroundPID: nil
        )
        let before = try await DarwinProcessSampler().sample(panes: [pane])
        let victim = try XCTUnwrap(
            before.processes.first { $0.identity.pid != shell.pid }?.identity,
            "a child to kill"
        )

        Darwin.kill(victim.pid, SIGKILL)
        try await Task.sleep(nanoseconds: 800_000_000)

        let after = try await DarwinProcessSampler().sample(panes: [pane])
        XCTAssertFalse(after.processes.isEmpty, "the shell and its survivors are still walked")
        XCTAssertFalse(
            after.processes.contains { $0.identity == victim },
            "the exited process leaves the snapshot entirely"
        )
        // The failure this guards is not absence but a *present* row full of zeros, which is
        // what `proc_pidinfo` yields for a dead PID if its return is checked loosely.
        for sample in after.processes {
            XCTAssertGreaterThan(
                sample.footprintBytes ?? 0, 0,
                "\(sample.executableName) (\(sample.identity.pid)) has real memory, not a zeroed struct"
            )
            XCTAssertGreaterThan(sample.identity.startAbstime, 0)
            XCTAssertFalse(sample.executableName.isEmpty)
        }
    }

    /// The single most dangerous line in the sampler, pinned directly.
    ///
    /// A live process cannot be held reliably at the instant of its death, so the exit test
    /// above cannot reach this branch — `sh` reaps its children before any sweep sees them.
    /// The rule is therefore asserted where it can be: `proc_pidinfo` reports "gone" as a
    /// **0 return with the caller's struct untouched**, so every loose spelling of the check
    /// admits an all-zeros struct as a real reading. Measured directly during T-100's
    /// feasibility spike: killing a PID and re-reading it gave `rc=0, errno=ESRCH`.
    func testOnlyAnExactlySizedReadCountsAsHavingHappened() {
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertTrue(DarwinProcessSampler.didFill(returnCode: size, expecting: size))

        // The ESRCH shape: success-looking, and entirely zeros.
        XCTAssertFalse(
            DarwinProcessSampler.didFill(returnCode: 0, expecting: size),
            "0 means the process is gone, not that it uses no memory"
        )
        XCTAssertFalse(DarwinProcessSampler.didFill(returnCode: -1, expecting: size))
        XCTAssertFalse(
            DarwinProcessSampler.didFill(returnCode: size / 2, expecting: size),
            "half a struct is half zeros"
        )
        XCTAssertFalse(DarwinProcessSampler.didFill(returnCode: size + 8, expecting: size))
    }

    /// The stub backend has no PTY, so it reports no provenance. The pane stays visible with
    /// unavailable metrics rather than being attributed to whatever else is running.
    @MainActor
    func testAPTYLessBackendReportsNoProvenance() {
        let stub = StubTerminalSurface()
        XCTAssertNil(stub.ttyName)
    }

    // MARK: - Keyboard outline navigation

    /// Arrow keys walk the tree that is actually on screen: a collapsed row's children are
    /// not steps, and opening one makes them steps. Asserted on the model rather than through
    /// a window, because the rule is about the flattened list and not about AppKit.
    @MainActor
    func testArrowNavigationWalksOnlyTheExpandedOutline() async {
        let model = await makeModel()
        let workspace = model.rows.first { if case .workspace = $0.kind { return true } else { return false } }
        let workspaceID = try! XCTUnwrap(workspace?.id)

        XCTAssertEqual(model.visibleRowIDs, [workspaceID], "a collapsed tree is one row")

        model.selection = workspaceID
        model.expandOrDescend()
        XCTAssertTrue(model.expanded.contains(workspaceID))
        XCTAssertGreaterThan(model.visibleRowIDs.count, 1, "its tab is a step now")

        // Right again descends into the row it just opened.
        model.expandOrDescend()
        XCTAssertNotEqual(model.selection, workspaceID)

        // Left from a closed child steps back out to the parent.
        model.collapseOrAscend()
        XCTAssertEqual(model.selection, workspaceID)
    }

    @MainActor
    func testSelectionClampsRatherThanWrapping() async {
        let model = await makeModel()
        model.expanded = Set(model.visibleRowIDs)
        model.moveSelectionToFirst()
        let first = model.selection
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, first, "up from the top stays at the top")

        model.moveSelectionToLast()
        let last = model.selection
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, last, "down from the bottom stays at the bottom")
    }

    /// Return reveals a pane and does nothing else. The monitor has no verb that could reach
    /// a process, which is what keeps "read-only" a property of the type rather than a promise.
    @MainActor
    func testReturnRevealsThePaneAndNothingElse() async {
        let model = await makeModel()
        var revealed: [UUID] = []
        model.revealPane = { revealed.append($0) }

        model.expanded = Set(model.visibleRowIDs)
        for id in model.visibleRowIDs { model.expanded.insert(id) }
        let paneRowID = model.visibleRowIDs.first { $0.hasPrefix("p:") }
        model.selection = try! XCTUnwrap(paneRowID)
        model.activateSelection()

        XCTAssertEqual(revealed.count, 1, "exactly one navigation happened")
    }

    /// Sorting toggles direction on the same column and resets when the column changes.
    @MainActor
    func testSortHeaderTogglesDirectionAndResetsAcrossColumns() async {
        let model = await makeModel()
        XCTAssertEqual(model.sortKey, .memory)
        XCTAssertEqual(model.sortDirection, .descending)

        model.toggleSort(.memory)
        XCTAssertEqual(model.sortDirection, .ascending, "same column flips")

        model.toggleSort(.name)
        XCTAssertEqual(model.sortKey, .name)
        XCTAssertEqual(model.sortDirection, .ascending, "a name column starts A→Z")

        model.toggleSort(.cpu)
        XCTAssertEqual(model.sortDirection, .descending, "a number column starts largest first")
    }

    /// Reading the presentation rows is a hot SwiftUI path. The recursive sort belongs to a
    /// snapshot or sort-choice transition, not to every body access (and not twice in one
    /// body pass for the empty check plus the visible outline).
    @MainActor
    func testRowsAreProjectedOncePerInputTransitionRatherThanOncePerRead() async {
        var projectionCount = 0
        let fixture = await makeModel { nodes, key, direction in
            projectionCount += 1
            return TelemetrySort.apply(nodes, key: key, direction: direction)
        }

        XCTAssertEqual(projectionCount, 1, "publishing the fixture projects its rows once")
        _ = fixture.rows
        _ = fixture.rows
        XCTAssertEqual(projectionCount, 1, "SwiftUI reads reuse the completed projection")

        fixture.toggleSort(.cpu)
        XCTAssertEqual(projectionCount, 2, "changing the sort projects exactly once")
        _ = fixture.rows
        XCTAssertEqual(projectionCount, 2)
    }

    /// SwiftUI cancels a view's `.task` when the popover disappears. The task itself must own
    /// both halves of telemetry demand so a close cannot race ahead of an awaiting open and
    /// leave the hidden monitor polling forever.
    @MainActor
    func testCancellingThePresentationTaskReleasesSamplingDemand() async {
        var projectionCount = 0
        let (model, coordinator) = await makePresentationModel { nodes, key, direction in
            projectionCount += 1
            return TelemetrySort.apply(nodes, key: key, direction: direction)
        }
        let presentation = Task { await model.presented() }

        for _ in 0 ..< 1_000 {
            if model.activePresentationCount == 1,
               model.hasPresentationObserver,
               await coordinator.isVisible,
               projectionCount > 0
            { break }
            await Task.yield()
        }
        XCTAssertEqual(model.activePresentationCount, 1)
        XCTAssertTrue(model.hasPresentationObserver)
        var isVisible = await coordinator.isVisible
        XCTAssertTrue(isVisible, "the visible presentation starts demand")

        presentation.cancel()
        await presentation.value

        XCTAssertEqual(model.activePresentationCount, 0)
        XCTAssertFalse(model.hasPresentationObserver)
        isVisible = await coordinator.isVisible
        XCTAssertFalse(isVisible, "the same task pairs its demand on cancellation")

        let projectionsAtClose = projectionCount
        await coordinator.refreshNow()
        for _ in 0 ..< 100 { await Task.yield() }
        XCTAssertEqual(
            projectionCount,
            projectionsAtClose,
            "a publication after close cannot reach a removed observer"
        )
    }

    /// More than one presentation counts demand independently but shares the one model
    /// observer. Cancelling either one cannot tear down the survivor's telemetry lifetime.
    @MainActor
    func testOverlappingPresentationsRemainBalancedWhenCancelledOutOfOrder() async {
        let (model, coordinator) = await makePresentationModel()
        let first = Task { await model.presented() }
        let second = Task { await model.presented() }

        for _ in 0 ..< 1_000 {
            if model.activePresentationCount == 2, await coordinator.isVisible { break }
            await Task.yield()
        }
        XCTAssertEqual(model.activePresentationCount, 2)
        XCTAssertTrue(model.hasPresentationObserver)

        first.cancel()
        await first.value
        XCTAssertEqual(model.activePresentationCount, 1)
        var isVisible = await coordinator.isVisible
        XCTAssertTrue(isVisible, "the surviving presentation keeps sampling alive")
        XCTAssertTrue(model.hasPresentationObserver, "the observer remains until the final close")

        second.cancel()
        await second.value
        XCTAssertEqual(model.activePresentationCount, 0)
        isVisible = await coordinator.isVisible
        XCTAssertFalse(isVisible)
        XCTAssertFalse(model.hasPresentationObserver)
    }

    /// The cached-row assertion also covers the production observer path. A coordinator
    /// publication projects exactly once; reading the result does not project again.
    @MainActor
    func testCoordinatorPublicationProjectsRowsExactlyOnce() async {
        var projectionCount = 0
        let (model, _) = await makePresentationModel { nodes, key, direction in
            projectionCount += 1
            return TelemetrySort.apply(nodes, key: key, direction: direction)
        }
        let presentation = Task { await model.presented() }

        for _ in 0 ..< 1_000 {
            if projectionCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(projectionCount, 1, "the coordinator publication projects once")
        _ = model.rows
        _ = model.rows
        XCTAssertEqual(projectionCount, 1, "published rows remain cached across reads")

        presentation.cancel()
        await presentation.value
    }

    // MARK: - Helpers

    /// A model holding one published snapshot, with no machine behind it.
    @MainActor
    private func makeModel(
        rowProjector: ResourceMonitorModel.RowProjector? = nil
    ) async -> ResourceMonitorModel {
        let pane = PaneProvenance(
            slotID: UUID(), tabID: UUID(), workspaceID: UUID(),
            ttyDevice: 7, foregroundPID: nil
        )
        let snapshot = TelemetryProjection.project(
            panes: [pane],
            samples: ProcessSampleSet(
                hostRecord: nil,
                processes: [
                    RawProcessSample(
                        identity: ProcessIdentity(pid: 100, startAbstime: 1),
                        parentPID: 1, ttyDevice: 7, executableName: "bash",
                        cpuNanoseconds: 0, footprintBytes: 2048,
                        diskBytesRead: 0, diskBytesWritten: 0
                    )
                ]
            ),
            previousCounters: [:],
            labels: .none,
            physicalMemory: 16 << 30,
            capturedAtNanoseconds: 1,
            capturedAt: Date(),
            generation: 1,
            provenanceRevision: 1
        )
        let coordinator = ProcessTelemetryCoordinator(
            sampler: StaticSampler(snapshotProcesses: []),
            clock: SystemTelemetryClock(),
            ticker: TaskSleepTicker(),
            physicalMemory: 16 << 30,
            provenance: { .none }
        )
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "t", path: URL(fileURLWithPath: "/tmp")))
        let bridge = ProcessTelemetryBridge(store: store, surfaces: SurfacePool(
            backendName: "Stub",
            makeSurfaceWithIdentity: { _, _, _ in StubTerminalSurface() }
        ))
        let model = if let rowProjector {
            ResourceMonitorModel(
                coordinator: coordinator,
                bridge: bridge,
                rowProjector: rowProjector
            )
        } else {
            ResourceMonitorModel(coordinator: coordinator, bridge: bridge)
        }
        model.applyForTesting(snapshot)
        return model
    }

    @MainActor
    private func makePresentationModel(
        rowProjector: ResourceMonitorModel.RowProjector? = nil
    ) async -> (ResourceMonitorModel, ProcessTelemetryCoordinator) {
        let coordinator = ProcessTelemetryCoordinator(
            sampler: StaticSampler(snapshotProcesses: []),
            clock: SystemTelemetryClock(),
            ticker: TaskSleepTicker(),
            physicalMemory: 16 << 30,
            provenance: { .none }
        )
        let store = WorkspaceStore(catalog: WorkspaceCatalog(name: "t", path: URL(fileURLWithPath: "/tmp")))
        let bridge = ProcessTelemetryBridge(store: store, surfaces: SurfacePool(
            backendName: "Stub",
            makeSurfaceWithIdentity: { _, _, _ in StubTerminalSurface() }
        ))
        let model = if let rowProjector {
            ResourceMonitorModel(
                coordinator: coordinator,
                bridge: bridge,
                rowProjector: rowProjector
            )
        } else {
            ResourceMonitorModel(coordinator: coordinator, bridge: bridge)
        }
        return (model, coordinator)
    }

    private func firstPane(in nodes: [TelemetryNode]) -> TelemetryNode? {
        for node in nodes {
            if case .pane = node.kind { return node }
            if let found = firstPane(in: node.children) { return found }
        }
        return nil
    }
}

/// A sampler that returns a fixed set, for tests about presentation rather than about macOS.
private struct StaticSampler: ProcessSampling {
    let snapshotProcesses: [RawProcessSample]
    func sample(panes: [PaneProvenance]) async throws -> ProcessSampleSet {
        ProcessSampleSet(hostRecord: nil, processes: snapshotProcesses)
    }
}

/// A real pseudo-terminal with a real process tree on it, created and destroyed by the test.
private final class PseudoTerminal {
    let path: String
    private var master: Int32 = -1
    private var slave: Int32 = -1

    init() throws {
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        path = name.withUnsafeBufferPointer { buffer in
            let bytes = UnsafeRawBufferPointer(buffer)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    func close() {
        if master >= 0 { Darwin.close(master) }
        if slave >= 0 { Darwin.close(slave) }
    }

    func spawnShell(_ script: String) throws -> SpawnedShell {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in Int32(0) ... 2 {
            posix_spawn_file_actions_adddup2(&actions, slave, descriptor)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, so the spawned shell owns this pty as its controlling terminal —
        // which is exactly the shape a Ghostty pane produces.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let argv: [String] = ["/bin/sh", "-c", script]
        var arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for argument in arguments where argument != nil { free(argument) } }
        guard posix_spawn(&pid, "/bin/sh", &actions, &attributes, &arguments, environ) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return SpawnedShell(pid: pid)
    }
}

private final class SpawnedShell {
    let pid: pid_t
    private var killed = false

    init(pid: pid_t) { self.pid = pid }

    /// Kills the whole process group, so the background jobs go with the shell rather than
    /// being left behind on the machine running the suite.
    func kill() {
        guard !killed else { return }
        killed = true
        Darwin.kill(-pid, SIGKILL)
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
    }
}
