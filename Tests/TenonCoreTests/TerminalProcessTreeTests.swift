import XCTest

@testable import TenonCore

/// Where a pane's process tree begins.
///
/// These exist because the answer was wrong in production while every process-level test
/// passed: the sweep chose roots against the processes the kernel *listed* rather than the
/// ones it could *read*, and a setuid-root `/usr/bin/login` — which Ghostty puts at the top of
/// every pane — is listed but never readable. It shadowed each shell without ever becoming a
/// root, so no pane had a root at all and the monitor attributed nothing. The rule is a pure
/// function here precisely so that case can be stated without a process tree to arrange.
final class TerminalProcessTreeTests: XCTestCase {
    // MARK: - The production case

    /// A shell whose parent could not be read is the top of what Tenon can account for.
    func testAProcessWhoseParentIsUnreadableBeginsTheTree() {
        // `login` (37402) is attached and enumerated, but EPERM means it is absent from what
        // the sampler could read. `fish` names it as a parent and is the topmost readable
        // process; everything below hangs off `fish`.
        let readable = [
            AttachedProcess(pid: 37403, parentPID: 37402),  // fish, child of login
            AttachedProcess(pid: 40098, parentPID: 37403),  // claude
            AttachedProcess(pid: 40225, parentPID: 40098),  // node
        ]

        XCTAssertEqual(
            TerminalProcessTree.roots(readable: readable),
            [37403],
            "the shell below an unreadable login is the root, not nothing"
        )
    }

    /// The regression in its exact shipped shape: every attached process has a readable parent
    /// except the one at the top, and the top one is unreadable.
    func testNoTerminalReadableAtAllProducesNoRoots() {
        XCTAssertEqual(
            TerminalProcessTree.roots(readable: []),
            [],
            "a terminal with nothing readable has no tree, and says so by being empty"
        )
    }

    // MARK: - The ordinary cases the old rule already got right

    /// A parent outside this terminal — Tenon itself, or a daemon — does not make its child a
    /// non-root just by being readable somewhere else. Only membership in this list counts.
    func testAParentOutsideTheTerminalLeavesItsChildARoot() {
        let readable = [
            AttachedProcess(pid: 500, parentPID: 1),  // reparented to launchd
            AttachedProcess(pid: 501, parentPID: 500),
        ]

        XCTAssertEqual(TerminalProcessTree.roots(readable: readable), [500])
    }

    /// A shell that exec'd a job leaves two readable processes at the same level; both are
    /// roots, and the order is stable so a sweep walks them the same way twice.
    func testSiblingRootsAreBothReportedInOrder() {
        let readable = [
            AttachedProcess(pid: 900, parentPID: 42),
            AttachedProcess(pid: 700, parentPID: 42),
            AttachedProcess(pid: 901, parentPID: 900),
        ]

        XCTAssertEqual(
            TerminalProcessTree.roots(readable: readable),
            [700, 900],
            "both topmost processes are roots, sorted"
        )
    }

    /// A readable parent still hides its child, which is the whole point of choosing roots:
    /// the BFS reaches the child through the parent, and listing both would walk it twice.
    func testAReadableParentKeepsItsChildOutOfTheRoots() {
        let readable = [
            AttachedProcess(pid: 100, parentPID: 99),
            AttachedProcess(pid: 101, parentPID: 100),
            AttachedProcess(pid: 102, parentPID: 101),
        ]

        XCTAssertEqual(TerminalProcessTree.roots(readable: readable), [100])
    }

    // MARK: - A malformed parent chain still yields a tree

    /// A PID reused between two reads inside one sweep can leave a parent cycle, in which no
    /// member qualifies as a root. Reporting none would delete live processes from the pane
    /// that owns them — the empty-system failure this monitor exists to avoid — so the lowest
    /// PID in the cycle is entered instead, and the walk's visited set bounds the traversal.
    func testACycleStillEntersTheTreeAtItsLowestPID() {
        let readable = [
            AttachedProcess(pid: 301, parentPID: 300),
            AttachedProcess(pid: 300, parentPID: 301),
        ]

        XCTAssertEqual(
            TerminalProcessTree.roots(readable: readable),
            [300],
            "a cycle has no topmost process, so the walk is entered at a deterministic point rather than abandoned"
        )
    }

    /// The cycle rule is a last resort, not a second opinion: when genuine roots exist it
    /// contributes nothing, so an unreadable parent never adds a spurious second entry point.
    func testTheCycleFallbackDoesNotFireWhenARootExists() {
        let readable = [
            AttachedProcess(pid: 400, parentPID: 12),  // genuine root
            AttachedProcess(pid: 402, parentPID: 403),  // cycle hanging off nothing
            AttachedProcess(pid: 403, parentPID: 402),
        ]

        XCTAssertEqual(TerminalProcessTree.roots(readable: readable), [400])
    }
}
