import Foundation
@testable import TenonCore
import XCTest

/// T-084: a pane owes its children a death. libghostty signals one process group with SIGHUP and
/// never escalates, so both halves of that sentence need proving here: *which* processes a pane
/// is responsible for (pure, from a `ps` table), and that one which ignores SIGHUP still dies.
final class TerminalJobTerminationTests: XCTestCase {
    // MARK: - Which processes belong to the pane

    /// The shape a real pane produces: the shell leads one group, its foreground job another,
    /// and a background job a third. All three are the pane's doing; all three are targets.
    func testEveryProcessGroupOnThePanesTTYIsATargetWithTheShellsGroupLast() {
        let table = """
          4908  4908 ttys004
          4916  4908 ttys004
          5050  5050 ttys004
          5121  5121 ttys004
          7001  7001 ttys009
        """

        XCTAssertEqual(
            TerminalJobTermination.signalTargets(
                onTTY: "ttys004",
                rootPID: 4908,
                hostPID: 5939,
                in: table
            ),
            [5050, 5121, 4908],
            "every group on the tty, the shell's own group last so the PTY outlives the sweep"
        )
    }

    func testAProcessOnAnotherTerminalIsNeverSignalled() {
        let table = """
          4908  4908 ttys004
          7001  7001 ttys009
        """

        XCTAssertFalse(
            TerminalJobTermination.signalTargets(
                onTTY: "ttys004",
                rootPID: 4908,
                hostPID: 5939,
                in: table
            ).contains(7001)
        )
    }

    /// Tenon launched from a terminal (`swift run tenon`) inherits that terminal's tty. Sweeping
    /// it would kill the developer's own shell, so sharing a tty forbids the sweep outright.
    func testTheHostSharingTheTTYRefusesTheSweepEntirely() {
        let table = """
          4908  4908 ttys004
          5050  5050 ttys004
          5939  5939 ttys004
        """

        XCTAssertEqual(
            TerminalJobTermination.signalTargets(
                onTTY: "ttys004",
                rootPID: 4908,
                hostPID: 5939,
                in: table
            ),
            []
        )
    }

    /// The table no longer describes the process this pane owned — fail closed rather than
    /// signal groups on a tty we cannot tie to the pane.
    func testARootThatIsNotOnThatTTYRefusesTheSweep() {
        let table = """
          5050  5050 ttys004
          5121  5121 ttys004
        """

        XCTAssertEqual(
            TerminalJobTermination.signalTargets(
                onTTY: "ttys004",
                rootPID: 4908,
                hostPID: 5939,
                in: table
            ),
            []
        )
    }

    func testAProcessWithoutAControllingTerminalHasNoTTYToSweep() {
        XCTAssertNil(
            TerminalJobTermination.controllingTTY(of: 4908, in: "  4908  4908 ??")
        )
        XCTAssertNil(
            TerminalJobTermination.controllingTTY(of: 4908, in: "  4908  4908 ?")
        )
        XCTAssertEqual(
            TerminalJobTermination.controllingTTY(of: 4908, in: "  4908  4908 ttys004"),
            "ttys004"
        )
    }

    /// Process groups 0 and 1 belong to nobody's job. Signalling group 1 is how a bug becomes a
    /// logout, so malformed and privileged rows are dropped before any decision is made.
    func testGroupsBelowTwoAndUnparsableRowsAreDropped() {
        let table = """
          4908  4908 ttys004
             1     1 ttys004
          4000     0 ttys004
          garbage line
          9999
        """

        XCTAssertEqual(
            TerminalJobTermination.rows(parsing: table),
            [TerminalJobTermination.ProcessRow(pid: 4908, processGroup: 4908, tty: "ttys004")]
        )
    }

    // MARK: - What the terminator actually sends

    func testTheSweepHupsEveryGroupThenKillsWhatIsStillThere() async {
        let recorder = SignalRecorder()
        // The second read is what a re-scan sees: the foreground job unwound on SIGHUP, the
        // background job did not.
        let tables = [
            "  4908  4908 ttys004",
            "  4908  4908 ttys004\n  4916  4908 ttys004\n  5050  5050 ttys004",
            "  4908  4908 ttys004\n  5050  5050 ttys004",
        ]
        let terminator = TerminalJobTerminator(
            environment: recorder.environment(tables: tables, hostPID: 5939),
            escalationDelay: .milliseconds(1)
        )

        await terminator.terminate(rootPID: 4908)

        XCTAssertEqual(
            recorder.groupSignals,
            [(5050, SIGHUP), (4908, SIGHUP), (5050, SIGKILL), (4908, SIGKILL)]
                .map { SignalRecorder.Sent(target: $0.0, signal: $0.1) }
        )
        XCTAssertEqual(recorder.processSignals, [], "the group sweep needs no per-pid shot")
    }

    /// Nothing proves who else belongs to the pane, so this degrades to exactly what Kero does:
    /// the process's group, then the process itself.
    func testNoTTYDegradesToSignallingTheRootsOwnGroupAndTheRoot() async {
        let recorder = SignalRecorder()
        let terminator = TerminalJobTerminator(
            environment: recorder.environment(tables: ["  4908  4908 ??"], hostPID: 5939),
            escalationDelay: .milliseconds(1)
        )

        await terminator.terminate(rootPID: 4908)

        XCTAssertEqual(
            recorder.groupSignals,
            [
                SignalRecorder.Sent(target: 4908, signal: SIGHUP),
                SignalRecorder.Sent(target: 4908, signal: SIGKILL),
            ]
        )
        XCTAssertEqual(
            recorder.processSignals,
            [
                SignalRecorder.Sent(target: 4908, signal: SIGHUP),
                SignalRecorder.Sent(target: 4908, signal: SIGKILL),
            ]
        )
    }

    func testAlreadyDeadAndImpossibleRootsAreSignalledByNobody() async {
        let recorder = SignalRecorder()
        let terminator = TerminalJobTerminator(
            environment: recorder.environment(tables: [""], hostPID: 5939),
            escalationDelay: .milliseconds(1)
        )

        await terminator.terminate(rootPID: 1)

        XCTAssertEqual(recorder.groupSignals, [])
        XCTAssertEqual(recorder.processSignals, [])
    }

    // MARK: - Against a real process

    /// The gap this task exists to close, with a real child: SIGHUP alone leaves it running, and
    /// libghostty sends nothing else. The escalation is what kills it.
    func testAProcessThatIgnoresSIGHUPIsDeadAfterTeardown() async throws {
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The loop matters: `sh -c "trap …; sleep 45"` lets the shell exec sleep in place for a
        // single trailing command, and the exec discards the trap — measured, the process died
        // to plain SIGHUP and the test lost its premise.
        victim.arguments = ["-c", "trap '' HUP; while true; do sleep 0.2; done"]
        try victim.run()
        let pid = victim.processIdentifier
        defer { kill(pid, SIGKILL) }

        // Proof the trap is installed and SIGHUP alone is not enough — otherwise this test
        // would pass even if escalation were deleted. The wait is not decoration: signalling
        // before `sh` reaches its `trap` line kills it for the wrong reason.
        try await Task.sleep(for: .milliseconds(300))
        kill(pid, SIGHUP)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(isLive(pid), "a SIGHUP-ignoring process survives what libghostty sends")

        await TerminalJobTerminator.live.terminate(rootPID: pid)

        let gone = await waitUntilGone(pid)
        XCTAssertTrue(gone, "teardown must not leave a process behind")
    }

    /// The measured survivor, reproduced: a background job leads its own process group, so no
    /// amount of signalling the shell's group reaches it. Needs a PTY of its own — `script(1)`
    /// provides one, and the host must not share it or the sweep correctly refuses.
    func testABackgroundJobInThePanesTTYDiesWithIt() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            throw XCTSkip("script(1) is how this test gets a PTY")
        }
        let pane = Process()
        pane.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // An INTERACTIVE shell is what makes this a faithful pane: job control is why a
        // background job leads its own process group, and only an interactive shell turns it
        // on. Measured, `sh -c` and even `bash -mc` both left the job in the shell's group,
        // which quietly removes the very thing this test is about. `-f` skips the user's
        // rc files so the fixture does not inherit a machine's dotfiles.
        pane.arguments = [
            "-q", "/dev/null", "/bin/zsh", "-f", "-ic",
            "nohup sleep 4084 >/dev/null 2>&1 & trap '' HUP; while true; do sleep 0.2; done",
        ]
        pane.standardOutput = FileHandle.nullDevice
        pane.standardError = FileHandle.nullDevice
        try pane.run()
        // The fixture ignores SIGHUP on purpose, so cleanup has to be SIGKILL and has to reach
        // the shell inside the PTY too — `script` dying does not take it with it. Without this,
        // a failing run leaks an orphaned shell (observed while mutation-testing this very file).
        var shell: pid_t?
        defer {
            kill(pane.processIdentifier, SIGKILL)
            if let shell { kill(shell, SIGKILL) }
            for stray in pids(matching: "sleep 4084") { kill(stray, SIGKILL) }
        }

        shell = try await waitForChild(of: pane.processIdentifier)
        guard let shell, let backgroundJob = try await waitForBackgroundJob() else {
            throw XCTSkip("the PTY job tree did not come up in time to be measured")
        }
        XCTAssertNotEqual(
            processGroup(of: backgroundJob),
            processGroup(of: shell),
            "the premise: a background job leads its own group, so SIGHUP to the shell's"
                + " group never reaches it"
        )

        await TerminalJobTerminator.live.terminate(rootPID: shell)

        let jobGone = await waitUntilGone(backgroundJob)
        let shellGone = await waitUntilGone(shell)
        XCTAssertTrue(jobGone, "the background job is the pane's too")
        XCTAssertTrue(shellGone)
    }

    // MARK: - Process helpers

    private func isLive(_ pid: pid_t) -> Bool {
        // A zombie answers kill(pid, 0) — read the state instead, so "reaped in a moment" is
        // never mistaken for "still running".
        let state = ps(["-p", String(pid), "-o", "stat="]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !state.isEmpty && !state.hasPrefix("Z")
    }

    private func waitUntilGone(_ pid: pid_t, within: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if !isLive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !isLive(pid)
    }

    /// macOS `ps` has no parent selector (`-P` means something else entirely), so the whole
    /// table is read and filtered on ppid.
    private func waitForChild(of parent: pid_t) async throws -> pid_t? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let child = ps(["-eo", "pid=,ppid="])
                .split(separator: "\n")
                .compactMap { line -> pid_t? in
                    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    guard fields.count >= 2,
                          let pid = pid_t(fields[0]),
                          pid_t(fields[1]) == parent
                    else { return nil }
                    return pid
                }
                .first
            if let child { return child }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func waitForBackgroundJob() async throws -> pid_t? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let job = pids(matching: "sleep 4084").first { return job }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func processGroup(of pid: pid_t) -> pid_t? {
        pid_t(
            ps(["-p", String(pid), "-o", "pgid="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Exact command match: the `sh -c "…"` wrapper's own argv contains the string too, and
    /// mistaking the shell for its background job would make the assertion meaningless.
    private func pids(matching command: String) -> [pid_t] {
        ps(["-eo", "pid=,command="])
            .split(separator: "\n")
            .compactMap { line -> pid_t? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let pid = pid_t(trimmed.prefix(while: \.isNumber)) else { return nil }
                let argv = trimmed.drop(while: \.isNumber).trimmingCharacters(in: .whitespaces)
                return argv == command ? pid : nil
            }
    }

    private func ps(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Records what was signalled, and serves a scripted `ps` table per read so a re-scan can show a
/// different world than the first scan did. Signals are recorded synchronously under a lock:
/// the assertions are about ORDER, which an async hop would destroy.
private final class SignalRecorder: @unchecked Sendable {
    struct Sent: Equatable {
        let target: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var _groupSignals: [Sent] = []
    private var _processSignals: [Sent] = []
    private var tables: [String] = []
    private var reads = 0

    var groupSignals: [Sent] { lock.withLock { _groupSignals } }
    var processSignals: [Sent] { lock.withLock { _processSignals } }

    func environment(tables: [String], hostPID: pid_t) -> TerminalJobTerminator.Environment {
        lock.withLock { self.tables = tables }
        return TerminalJobTerminator.Environment(
            processTable: { [self] _ in
                lock.withLock {
                    defer { reads += 1 }
                    return tables[min(reads, tables.count - 1)]
                }
            },
            signalProcessGroup: { [self] group, signal in
                lock.withLock { _groupSignals.append(Sent(target: group, signal: signal)) }
            },
            signalProcess: { [self] pid, signal in
                lock.withLock { _processSignals.append(Sent(target: pid, signal: signal)) }
            },
            hostPID: hostPID
        )
    }
}
