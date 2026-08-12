import Foundation
@testable import TenonCore
import XCTest

/// `PRT-FR-042`: a streaming command's descendants are the plugin's responsibility too.
///
/// The premise these tests defend is measurable and was measurable before the fix: a child that
/// forks a grandchild and dies leaves that grandchild running, because signalling the leader is not
/// signalling the job. Everything here runs against real processes, since a process group is a
/// kernel fact and a fake would only prove the fake.
final class PluginStreamProcessTests: XCTestCase {
    /// The whole feature in one assertion: the grandchild outlives its parent's death by design,
    /// and dies anyway because it inherited the group.
    func testTerminatingAStreamKillsTheDescendantsItForked() async throws {
        // Any duration will do, because this test finds its subject by parentage rather than by
        // name. An earlier version searched for `sleep 4084` and kept finding the fixture of
        // `TerminalJobTerminationTests`, which uses that same number and runs on the same machine —
        // it then measured that test's process being cleaned up and called the feature proven.
        let duration = "3600"
        let process = try PluginStreamProcess(
            executable: "/bin/sh",
            arguments: [
                "-c",
                // The grandchild leads no group of its own but inherits this stream's, which is
                // the only thing tying it back here once `sh` is waiting rather than parenting.
                "/bin/sleep \(duration) & wait",
            ],
            workingDirectory: nil,
            environment: [:]
        )
        try process.run()
        let leader = process.processIdentifier

        guard let leader, let descendant = try await waitForChild(of: leader)
        else {
            throw XCTSkip("the fixture's descendant did not appear in time to be measured")
        }
        addTeardownBlock { kill(descendant, SIGKILL) }
        // The premise, asserted rather than assumed. Without this the test passed while
        // `terminate()` signalled the leader alone — because `ps` prints the shell's whole command
        // line, the search had been finding the shell and calling it the descendant.
        XCTAssertNotEqual(
            descendant,
            leader,
            "the process being measured must be the forked child, not the shell that forked it"
        )
        // The mechanism, stated as a fact rather than trusted: the descendant is only reachable
        // by `killpg` if it actually inherited the leader's group.
        XCTAssertEqual(
            processGroup(of: descendant),
            leader,
            "the descendant is in group \(processGroup(of: descendant).map(String.init) ?? "none")"
                + ", not the leader's \(leader)"
        )

        process.terminate()

        let gone = await waitUntilGone(descendant)
        XCTAssertTrue(
            gone,
            "the descendant survived — terminate() reached the leader only, which is the defect"
        )
    }

    /// Exit is reported once, with the child's own status, so a plugin's `onExit` still means what
    /// it meant under Foundation `Process`.
    func testAFinishedCommandReportsItsExitCodeOnce() async throws {
        let process = try PluginStreamProcess(
            executable: "/bin/sh",
            arguments: ["-c", "exit 3"],
            workingDirectory: nil,
            environment: [:]
        )
        let reported = Reported()
        process.terminationHandler = { code in reported.record(code) }
        try process.run()

        let settled = await eventually { reported.count == 1 }
        XCTAssertTrue(settled, "exit was never reported")
        XCTAssertEqual(reported.codes, [3])
        XCTAssertFalse(process.isRunning)
    }

    func testOutputReachesTheReaderAndClosesAtExit() async throws {
        let process = try PluginStreamProcess(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            workingDirectory: nil,
            environment: [:]
        )
        try process.run()

        let data = process.standardOutput.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
    }

    /// A working directory that does not exist must fail the launch rather than run the command
    /// somewhere else — the plugin named a directory for a reason.
    func testAnImpossibleWorkingDirectoryFailsTheLaunch() throws {
        let process = try PluginStreamProcess(
            executable: "/bin/sh",
            arguments: ["-c", "true"],
            workingDirectory: "/nonexistent-\(UUID().uuidString)",
            environment: [:]
        )
        XCTAssertThrowsError(try process.run())
    }

    // MARK: - Helpers

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int32] = []

        var codes: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var count: Int { codes.count }

        func record(_ code: Int32) {
            lock.lock()
            recorded.append(code)
            lock.unlock()
        }
    }

    /// The forked child, identified by who its parent is.
    ///
    /// Parentage is the only identifier that cannot collide with another test's fixture on the
    /// same machine, and this suite shares a machine with `TerminalJobTerminationTests`, which
    /// launches sleeps of its own. It also survives the shell exiting: the child is captured while
    /// its parent is still alive, before `terminate()` is called.
    private func waitForChild(of parent: pid_t) async throws -> pid_t? {
        for _ in 0 ..< 100 {
            if let found = children(of: parent).first { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func children(of parent: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> pid_t? in
                let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard fields.count >= 2,
                      let pid = pid_t(fields[0]),
                      pid_t(fields[1]) == parent
                else { return nil }
                return pid
            }
    }

    private func processGroup(of pid: pid_t) -> pid_t? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "pgid="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        // `.whitespacesAndNewlines`, not `.whitespaces`: `ps` ends its line with a newline, and
        // `pid_t("48506\n")` is nil — which this test reported as "the process is in group none",
        // i.e. as evidence about the kernel rather than about my parsing.
        return pid_t(
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// A zombie still answers `kill(pid, 0)`, so read the state instead — otherwise "signalled and
    /// awaiting reaping" reads as "survived", which is the opposite conclusion.
    private func waitUntilGone(_ pid: pid_t, within: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if !isLive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !isLive(pid)
    }

    private func isLive(_ pid: pid_t) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "stat="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let state = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !state.isEmpty && !state.hasPrefix("Z")
    }

    private func eventually(
        within: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
