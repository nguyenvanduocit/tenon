// @domain: terminal-teardown
import Foundation

/// Who a closing pane is responsible for killing, decided from a `ps` table alone.
///
/// A pane's shell leads one process group; every job it starts leads another. libghostty's own
/// teardown signals a single group, so a background job — `nohup … &`, a dev server, an agent
/// that detached — outlives the pane that started it (measured 2026-08-07, T-084). Guessing more
/// pids does not fix that, because a pane cannot know how many groups it fathered. Asking the
/// kernel does: every one of them is still attached to the pane's tty.
///
/// This is the whole decision, and it is pure — a `ps` table in, process groups out, so the rule
/// is assertable with no PTY and no window. `TerminalJobTerminator` is the part that runs `ps`
/// and signals.
public enum TerminalJobTermination {
    public struct ProcessRow: Equatable, Sendable {
        public let pid: pid_t
        public let processGroup: pid_t
        public let tty: String

        public init(pid: pid_t, processGroup: pid_t, tty: String) {
            self.pid = pid
            self.processGroup = processGroup
            self.tty = tty
        }
    }

    /// The `ps -o pid=,pgid=,tty=` shape, in the order those columns are asked for.
    ///
    /// A process group of 0 or 1 is never a target: no ordinary job leads them, and signalling
    /// them is how a bug becomes a logout.
    public static func rows(parsing table: String) -> [ProcessRow] {
        table.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(
                whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }
            )
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let processGroup = pid_t(fields[1]),
                  pid > 0,
                  processGroup > 1
            else { return nil }
            return ProcessRow(pid: pid, processGroup: processGroup, tty: String(fields[2]))
        }
    }

    /// The pane's terminal, or nil when the process has none — `ps` writes `?`/`??` there.
    ///
    /// Nil is not a failure to report: it is the answer that forbids the group sweep, because
    /// without a tty there is nothing that proves which processes belong to this pane.
    public static func controllingTTY(of pid: pid_t, in table: String) -> String? {
        guard let row = rows(parsing: table).first(where: { $0.pid == pid }),
              row.tty != "?", row.tty != "??"
        else { return nil }
        return row.tty
    }

    /// Every process group on `tty`, with the root's group LAST.
    ///
    /// Order matters: the root's group owns the terminal, so killing it first can collapse the
    /// PTY while the other groups are still being signalled.
    ///
    /// Empty means "do not sweep", and it is returned for two different reasons, both
    /// fail-closed. The host sharing this tty means Tenon was launched from that very terminal
    /// (a `swift run` dev session) — sweeping would kill the developer's own shell. The root's
    /// group being absent means the table no longer describes the process this pane owned.
    public static func signalTargets(
        onTTY tty: String,
        rootPID: pid_t,
        hostPID: pid_t,
        in table: String
    ) -> [pid_t] {
        let onThisTTY = rows(parsing: table).filter { $0.tty == tty }
        guard !onThisTTY.contains(where: { $0.pid == hostPID }),
              let rootGroup = onThisTTY.first(where: { $0.pid == rootPID })?.processGroup
        else { return [] }

        let groups = Set(onThisTTY.map(\.processGroup))
        return groups.filter { $0 != rootGroup }.sorted() + [rootGroup]
    }
}

/// Runs the decision above: SIGHUP to everything the pane owns, a moment to unwind, then SIGKILL
/// to whatever is still there.
///
/// The escalation is the point. libghostty sends SIGHUP and stops (`nm ghostty-internal.a` has
/// `U _killpg` and no SIGKILL at all), so any process that traps or ignores SIGHUP currently
/// outlives its pane. Kero — same libghostty backend — reaches for the same two-step at
/// `TerminalSession.swift:126-183`, and 120 ms is its number.
///
/// The second sweep re-reads `ps` rather than reusing the first list. A pid list 120 ms old can
/// name a process that already exited and whose number the kernel handed to somebody else; Orca
/// documents that exact hazard at `pty-handler.ts:148-167`.
public struct TerminalJobTerminator: Sendable {
    public struct Environment: Sendable {
        public var processTable: @Sendable ([String]) -> String
        public var signalProcessGroup: @Sendable (pid_t, Int32) -> Void
        public var signalProcess: @Sendable (pid_t, Int32) -> Void
        public var hostPID: pid_t

        public init(
            processTable: @escaping @Sendable ([String]) -> String,
            signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Void,
            signalProcess: @escaping @Sendable (pid_t, Int32) -> Void,
            hostPID: pid_t
        ) {
            self.processTable = processTable
            self.signalProcessGroup = signalProcessGroup
            self.signalProcess = signalProcess
            self.hostPID = hostPID
        }
    }

    public let environment: Environment
    /// Kero's number (`TerminalSession.swift:154-157`): long enough for a shell to unwind its
    /// jobs, short enough that a closed pane never visibly lingers.
    public let escalationDelay: Duration

    public init(environment: Environment, escalationDelay: Duration = .milliseconds(120)) {
        self.environment = environment
        self.escalationDelay = escalationDelay
    }

    public static let live = TerminalJobTerminator(environment: .live)

    /// Stop the job tree rooted at `rootPID`. Safe to call for a process that already exited —
    /// every signal path treats a missing target as success, because it is.
    public func terminate(rootPID: pid_t) async {
        guard rootPID > 1 else { return }
        let tty = TerminalJobTermination.controllingTTY(
            of: rootPID,
            in: environment.processTable(["-p", String(rootPID), "-o", "pid=,pgid=,tty="])
        )
        sweep(signal: SIGHUP, tty: tty, rootPID: rootPID)
        try? await Task.sleep(for: escalationDelay)
        sweep(signal: SIGKILL, tty: tty, rootPID: rootPID)
    }

    /// One signal round. Re-reads the process table so late rounds signal what is live now.
    private func sweep(signal: Int32, tty: String?, rootPID: pid_t) {
        guard let tty else { return signalRootOnly(signal, rootPID: rootPID) }
        let targets = TerminalJobTermination.signalTargets(
            onTTY: tty,
            rootPID: rootPID,
            hostPID: environment.hostPID,
            in: environment.processTable(["-t", tty, "-o", "pid=,pgid=,tty="])
        )
        guard !targets.isEmpty else { return signalRootOnly(signal, rootPID: rootPID) }
        for group in targets {
            environment.signalProcessGroup(group, signal)
        }
    }

    /// What is left when the kernel will not say who else belongs to this pane: signal the
    /// process's own group, then the process itself for a launch that never led one. This is
    /// Kero's whole strategy (`TerminalSession.swift:170-183`) and Tenon's floor.
    private func signalRootOnly(_ signal: Int32, rootPID: pid_t) {
        environment.signalProcessGroup(rootPID, signal)
        environment.signalProcess(rootPID, signal)
    }
}

public extension TerminalJobTerminator.Environment {
    static let live = TerminalJobTerminator.Environment(
        processTable: { arguments in
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = arguments
            let output = Pipe()
            ps.standardOutput = output
            ps.standardError = FileHandle.nullDevice
            do {
                try ps.run()
            } catch {
                return ""
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        },
        signalProcessGroup: { group, signal in
            _ = killpg(group, signal)
        },
        signalProcess: { pid, signal in
            _ = kill(pid, signal)
        },
        hostPID: getpid()
    )
}
