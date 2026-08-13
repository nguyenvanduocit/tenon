import AppKit
import SwiftUI
@testable import TenonApp
import TenonCore
import XCTest

/// The sidebar's destructive workspace gesture and the tab strip's close gesture cross one
/// process-inspection gate. These tests drive that shared app-layer owner directly so every
/// asynchronous and fail-safe branch is deterministic.
@MainActor
final class WorkspaceCloseConfirmationTests: XCTestCase {
    func testTargetWithNoLiveTerminalClosesImmediatelyWithoutInspection() async {
        let target = workspaceTarget(name: "Idle", slotIDs: [UUID()])
        var committed: [ShellCloseCoordinator.Target] = []
        var inspections = 0
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 0, foregroundPIDs: []) },
            inspect: { _ in inspections += 1; return .running },
            commit: { committed.append($0) }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(committed, [target])
        XCTAssertEqual(inspections, 0)
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testCompleteIdentityAndIdleInspectionClosesImmediately() async {
        let target = tabTarget(name: "Shell", slotIDs: [UUID()])
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 1, foregroundPIDs: [41]) },
            inspect: { pids in
                XCTAssertEqual(pids, [41])
                return .idle
            },
            commit: { committed.append($0) }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(committed, [target])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testRunningWorkPresentsWorkspaceConfirmationAndCommitsOnlyAfterConfirmation() async {
        let target = workspaceTarget(name: "Build", slotIDs: [UUID(), UUID()])
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 2, foregroundPIDs: [41, 42]) },
            inspect: { _ in .running },
            commit: { committed.append($0) }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(committed, [])
        XCTAssertEqual(coordinator.pendingConfirmation?.target, target)
        XCTAssertEqual(coordinator.pendingConfirmation?.reason, .running)

        coordinator.confirmPendingClose()

        XCTAssertEqual(committed, [target])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testIncompleteProcessIdentityFailsSafeWithoutRunningInspector() async {
        let target = workspaceTarget(name: "Unknown", slotIDs: [UUID(), UUID()])
        var inspections = 0
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 2, foregroundPIDs: [41]) },
            inspect: { _ in inspections += 1; return .idle },
            commit: { committed.append($0) }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(inspections, 0)
        XCTAssertEqual(committed, [])
        XCTAssertEqual(coordinator.pendingConfirmation?.reason, .unavailable)
    }

    func testUnavailableInspectionPresentsTabConfirmation() async {
        let target = tabTarget(name: "Deploy", slotIDs: [UUID()])
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 1, foregroundPIDs: [41]) },
            inspect: { _ in .unavailable }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(coordinator.pendingConfirmation?.target.kind, .tab)
        XCTAssertEqual(coordinator.pendingConfirmation?.target.title, "Deploy")
        XCTAssertEqual(coordinator.pendingConfirmation?.reason, .unavailable)
    }

    func testRequestSnapshotsEveryPaneInTheWorkspace() async {
        let slotIDs = [UUID(), UUID(), UUID()]
        let target = workspaceTarget(name: "All panes", slotIDs: slotIDs)
        var capturedSlots: Set<UUID> = []
        let coordinator = makeCoordinator(
            snapshot: { slots in
                capturedSlots = slots
                return .init(liveTerminalCount: 0, foregroundPIDs: [])
            }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(capturedSlots, Set(slotIDs))
    }

    func testChangedSlotSetFailsSafeInsteadOfApplyingAnIdleInspection() async {
        let target = workspaceTarget(name: "Changing", slotIDs: [UUID()])
        let gate = WorkspaceCloseInspectionGate()
        let currentState = CurrentTargetStateBox()
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 1, foregroundPIDs: [41]) },
            inspect: { pids in await gate.inspect(pids) },
            isCurrent: { _ in currentState.value },
            commit: { committed.append($0) }
        )

        let request = Task { @MainActor in await coordinator.requestClose(target) }
        await gate.waitUntilStarted()
        currentState.value = .changed
        await gate.resolve(.idle)
        await request.value

        XCTAssertEqual(committed, [])
        XCTAssertEqual(coordinator.pendingConfirmation?.target, target)
        XCTAssertEqual(coordinator.pendingConfirmation?.reason, .unavailable)
    }

    func testChangedForegroundPIDFailsSafeInsteadOfApplyingAStaleIdleInspection() async {
        let target = workspaceTarget(name: "Changing process", slotIDs: [UUID()])
        let gate = WorkspaceCloseInspectionGate()
        var snapshotCount = 0
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in
                snapshotCount += 1
                let pid: UInt64 = snapshotCount == 1 ? 41 : 42
                return .init(liveTerminalCount: 1, foregroundPIDs: [pid])
            },
            inspect: { pids in await gate.inspect(pids) },
            commit: { committed.append($0) }
        )

        let request = Task { @MainActor in await coordinator.requestClose(target) }
        await gate.waitUntilStarted()
        await gate.resolve(.idle)
        await request.value

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(committed, [])
        XCTAssertEqual(coordinator.pendingConfirmation?.target, target)
        XCTAssertEqual(coordinator.pendingConfirmation?.reason, .unavailable)
    }

    func testOlderInspectionCannotActAfterANewerCloseRequest() async {
        let first = workspaceTarget(name: "First", slotIDs: [UUID()])
        let second = workspaceTarget(name: "Second", slotIDs: [UUID()])
        let gate = WorkspaceCloseInspectionGate()
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { targetSlots in
                if targetSlots == first.slotIDs {
                    return .init(liveTerminalCount: 1, foregroundPIDs: [41])
                }
                return .init(liveTerminalCount: 0, foregroundPIDs: [])
            },
            inspect: { pids in await gate.inspect(pids) },
            commit: { committed.append($0) }
        )

        let firstRequest = Task { @MainActor in await coordinator.requestClose(first) }
        await gate.waitUntilStarted()

        await coordinator.requestClose(second)
        await gate.resolve(.running)
        await firstRequest.value

        XCTAssertEqual(committed, [second])
        XCTAssertNil(
            coordinator.pendingConfirmation,
            "a superseded process-table answer must not present for the older target"
        )
    }

    func testInspectionForATargetThatDisappearedDoesNothing() async {
        let target = workspaceTarget(name: "Gone", slotIDs: [UUID()])
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 1, foregroundPIDs: [41]) },
            inspect: { _ in .idle },
            isCurrent: { _ in .missing },
            commit: { committed.append($0) }
        )

        await coordinator.requestClose(target)

        XCTAssertEqual(committed, [])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testCancelClearsConfirmationWithoutCommitting() async {
        let target = workspaceTarget(name: "Cancel", slotIDs: [UUID()])
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 1, foregroundPIDs: [41]) },
            inspect: { _ in .running },
            commit: { committed.append($0) }
        )

        await coordinator.requestClose(target)
        coordinator.cancelPendingClose()

        XCTAssertNil(coordinator.pendingConfirmation)
        XCTAssertEqual(committed, [])
    }

    func testWorkspacePendingStatePresentsTheNativeAlertAndCancelIsWired() async throws {
        _ = NSApplication.shared
        let target = workspaceTarget(name: "Native build", slotIDs: [UUID()])
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { _ in .init(liveTerminalCount: 1, foregroundPIDs: [41]) },
            inspect: { _ in .running },
            commit: { committed.append($0) }
        )
        let host = NSHostingView(
            rootView: Color.clear
                .frame(width: 360, height: 220)
                .shellCloseConfirmation(coordinator)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // Programmatic test windows are otherwise released by `close()` and again when this
        // local owner leaves scope, which poisons the next AppKit-hosted test in the bundle.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        await coordinator.requestClose(target)
        let sheet = try await attachedSheet(of: window)
        let copy = descendantText(in: sheet.contentView)
        let buttons = descendantButtons(in: sheet.contentView)

        XCTAssertTrue(copy.contains("Remove Workspace?"), "native sheet copy: \(copy)")
        XCTAssertTrue(copy.contains("Native build"), "native sheet copy: \(copy)")
        XCTAssertTrue(copy.contains("has running terminal processes"), "native sheet copy: \(copy)")
        XCTAssertFalse(copy.contains("couldn’t verify"), "native sheet copy: \(copy)")
        XCTAssertTrue(buttons.map(\.title).contains("Remove Workspace"))
        let cancel = try XCTUnwrap(buttons.first(where: { $0.title == "Cancel" }))

        cancel.performClick(nil)
        try await waitForSheetDismissal(of: window)

        XCTAssertNil(coordinator.pendingConfirmation)
        XCTAssertEqual(committed, [])
    }

    func testSidebarRemovalActionBehaviorallyEntersTheSharedCoordinator() async {
        let workspace = makeWorkspace(name: "Sidebar", slotIDs: [UUID()])
        var snapshottedSlots: Set<UUID> = []
        var committed: [ShellCloseCoordinator.Target] = []
        let coordinator = makeCoordinator(
            snapshot: { slots in
                snapshottedSlots = slots
                return .init(liveTerminalCount: 0, foregroundPIDs: [])
            },
            commit: { committed.append($0) }
        )
        let action = WorkspaceRemovalAction(workspace: workspace, coordinator: coordinator)

        await action.perform().value

        XCTAssertEqual(snapshottedSlots, Set(workspace.tabs.flatMap(\.slots).map(\.id)))
        XCTAssertEqual(committed, [.workspace(workspace)])
    }

    private func makeCoordinator(
        snapshot: @escaping ShellCloseCoordinator.Snapshot = { _ in
            .init(liveTerminalCount: 0, foregroundPIDs: [])
        },
        inspect: @escaping ShellCloseCoordinator.Inspect = { _ in .idle },
        isCurrent: @escaping ShellCloseCoordinator.IsCurrent = { _ in .exact },
        commit: @escaping ShellCloseCoordinator.Commit = { _ in }
    ) -> ShellCloseCoordinator {
        ShellCloseCoordinator(
            snapshot: snapshot,
            inspect: inspect,
            isCurrent: isCurrent,
            commit: commit
        )
    }

    private func workspaceTarget(name: String, slotIDs: [UUID]) -> ShellCloseCoordinator.Target {
        let workspace = makeWorkspace(name: name, slotIDs: slotIDs)
        return .workspace(workspace)
    }

    private func tabTarget(name: String, slotIDs: [UUID]) -> ShellCloseCoordinator.Target {
        let workspace = makeWorkspace(name: name, slotIDs: slotIDs)
        return .tab(workspace.tabs[0], workspaceID: workspace.id, title: name)
    }

    private func makeWorkspace(name: String, slotIDs: [UUID]) -> Workspace {
        let tabs = slotIDs.enumerated().map { index, slotID in
            let slot = WorkspaceSlot(
                id: slotID,
                rect: GridRect(x: 0, y: 0, width: 12, height: 12)
            )
            return Tab(slots: [slot], activeSlotID: slotID, number: index + 1)
        }
        return Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true),
            tabs: tabs,
            activeTabID: tabs[0].id
        )
    }

    private func attachedSheet(of window: NSWindow) async throws -> NSWindow {
        for _ in 0 ..< 100 {
            if let sheet = window.attachedSheet { return sheet }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeAlertError.sheetNeverAppeared
    }

    private func waitForSheetDismissal(of window: NSWindow) async throws {
        for _ in 0 ..< 100 {
            if window.attachedSheet == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeAlertError.sheetNeverDismissed
    }

    private func descendantText(in view: NSView?) -> String {
        guard let view else { return "" }
        let own = (view as? NSTextField)?.stringValue ?? ""
        return ([own] + view.subviews.map { descendantText(in: $0) })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func descendantButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var buttons = (view as? NSButton).map { [$0] } ?? []
        buttons.append(contentsOf: view.subviews.flatMap { descendantButtons(in: $0) })
        return buttons
    }
}

private enum NativeAlertError: Error {
    case sheetNeverAppeared
    case sheetNeverDismissed
}

@MainActor
private final class CurrentTargetStateBox {
    var value: ShellCloseCoordinator.TargetState = .exact
}

private actor WorkspaceCloseInspectionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: CheckedContinuation<TerminalJobTermination.Inspection, Never>?

    func inspect(_ foregroundPIDs: Set<UInt64>) async -> TerminalJobTermination.Inspection {
        precondition(!foregroundPIDs.isEmpty)
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resolve(_ inspection: TerminalJobTermination.Inspection) {
        result?.resume(returning: inspection)
        result = nil
    }
}
