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
    public enum Inspection: Equatable, Sendable {
        case idle
        case running
        case unavailable
    }

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

    /// Whether any inspected terminal contains work beyond its foreground shell.
    ///
    /// A live interactive terminal always contributes one process group: its shell (and any
    /// wrapper/helper in that same group). A foreground command, pipeline, or background job
    /// contributes another group on that tty. Resolving the tty from the backend's current
    /// foreground pid keeps the rule independent of shell names and catches quiet jobs as
    /// well as jobs producing output.
    ///
    /// Missing foreground rows are `unavailable`, not `idle`: the process may have raced the
    /// table read or `ps` may have failed. A destructive close can then fail safe by asking.
    public static func inspection(
        foregroundPIDs: Set<UInt64>,
        in table: String
    ) -> Inspection {
        guard !foregroundPIDs.isEmpty else { return .idle }

        let rows = rows(parsing: table)
        var ttyNames: Set<String> = []
        for rawPID in foregroundPIDs {
            guard rawPID > 1,
                  rawPID <= UInt64(pid_t.max),
                  let row = rows.first(where: { $0.pid == pid_t(rawPID) }),
                  row.tty != "?",
                  row.tty != "??"
            else { return .unavailable }
            ttyNames.insert(row.tty)
        }
        guard ttyNames.count == foregroundPIDs.count else { return .unavailable }

        for tty in ttyNames {
            let processes = rows.filter { $0.tty == tty }
            guard !processes.isEmpty else { return .unavailable }
            if Set(processes.map(\.processGroup)).count > 1 { return .running }
        }
        return .idle
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

    /// Every process group left on `tty` once the pane's own shell is gone.
    ///
    /// T-140: a shell that exits does not take its `nohup`ed or disowned jobs with it, and the
    /// pane that started them is still the only thing that owns them. `signalTargets` cannot
    /// decide this case — it proves the tty belongs to this pane by finding the root pid on it,
    /// and the root pid is exactly what has died.
    ///
    /// That proof has to come from somewhere else, and it does: the caller holds the pty master
    /// open across the sweep, so the kernel cannot have reissued this tty to anybody. Hence no
    /// root-pid guard here, and hence the host check below is load-bearing on its own — it is
    /// the only line stopping a `swift run` session from sweeping the developer's own terminal.
    ///
    /// No ordering to preserve, unlike `signalTargets`: there is no shell group left whose death
    /// would collapse the PTY early.
    public static func orphanTargets(
        onTTY tty: String,
        hostPID: pid_t,
        in table: String
    ) -> [pid_t] {
        let onThisTTY = rows(parsing: table).filter { $0.tty == tty }
        guard !onThisTTY.contains(where: { $0.pid == hostPID }) else { return [] }
        return Set(onThisTTY.map(\.processGroup)).sorted()
    }
}

/// Reads the process table away from `MainActor` for the tab-close confirmation path.
/// The decision itself stays pure in `TerminalJobTermination.inspection` above.
public actor TerminalJobInspector {
    public typealias ProcessTable = @Sendable ([String]) -> String

    private let processTable: ProcessTable

    public init(processTable: @escaping ProcessTable) {
        self.processTable = processTable
    }

    public static let live = TerminalJobInspector(
        processTable: TerminalJobTerminator.Environment.live.processTable
    )

    public func inspect(foregroundPIDs: Set<UInt64>) -> TerminalJobTermination.Inspection {
        TerminalJobTermination.inspection(
            foregroundPIDs: foregroundPIDs,
            in: processTable(["-A", "-o", "pid=,pgid=,tty="])
        )
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

    /// Stop the job tree a pane owns. Safe to call for a process that already exited — every
    /// signal path treats a missing target as success, because it is.
    ///
    /// `rootPID` is the pane's foreground process, and it is optional because a pane outlives it:
    /// a shell that exits leaves `nohup`ed jobs holding the tty with no root left to name them.
    ///
    /// `paneOwnedTTY` is what makes that case sweepable, and it carries an obligation. Passing it
    /// asserts the caller is holding this tty open — the pty master fd, in the only production
    /// caller — for the whole call, so the kernel cannot have reissued it to another terminal in
    /// the meantime. Without that, sweeping a tty whose root is gone could signal a stranger.
    /// Callers that cannot make the promise pass nil and get the root-derived behaviour, where
    /// finding the root on the tty is itself the proof.
    public func terminate(rootPID: pid_t?, paneOwnedTTY: String? = nil) async {
        let root = rootPID.flatMap { $0 > 1 ? $0 : nil }
        let scope: SweepScope
        if let paneOwnedTTY {
            scope = SweepScope(tty: paneOwnedTTY, rootPID: root, ttyHeldByCaller: true)
        } else {
            guard let root else { return }
            let derived = TerminalJobTermination.controllingTTY(
                of: root,
                in: environment.processTable(["-p", String(root), "-o", "pid=,pgid=,tty="])
            )
            scope = SweepScope(tty: derived, rootPID: root, ttyHeldByCaller: false)
        }

        sweep(signal: SIGHUP, in: scope)
        try? await Task.sleep(for: escalationDelay)
        sweep(signal: SIGKILL, in: scope)
    }

    /// What the sweep is allowed to reach, and why it is allowed to reach it.
    private struct SweepScope {
        let tty: String?
        let rootPID: pid_t?
        /// The caller holds this tty open for the duration, so it still belongs to that pane.
        /// Only then may a sweep proceed without finding the root on it.
        let ttyHeldByCaller: Bool
    }

    /// One signal round. Re-reads the process table so late rounds signal what is live now.
    private func sweep(signal: Int32, in scope: SweepScope) {
        guard let tty = scope.tty else { return signalRootOnly(signal, rootPID: scope.rootPID) }
        let table = environment.processTable(["-t", tty, "-o", "pid=,pgid=,tty="])

        if let rootPID = scope.rootPID {
            let targets = TerminalJobTermination.signalTargets(
                onTTY: tty,
                rootPID: rootPID,
                hostPID: environment.hostPID,
                in: table
            )
            if !targets.isEmpty {
                for group in targets { environment.signalProcessGroup(group, signal) }
                return
            }
        }

        // The root is gone or was never known. The tty is still this pane's only because the
        // caller is holding it; anything else falls through to the floor below.
        guard scope.ttyHeldByCaller else { return signalRootOnly(signal, rootPID: scope.rootPID) }
        let orphans = TerminalJobTermination.orphanTargets(
            onTTY: tty,
            hostPID: environment.hostPID,
            in: table
        )
        guard !orphans.isEmpty else { return signalRootOnly(signal, rootPID: scope.rootPID) }
        for group in orphans { environment.signalProcessGroup(group, signal) }
    }

    /// What is left when the kernel will not say who else belongs to this pane: signal the
    /// process's own group, then the process itself for a launch that never led one. This is
    /// Kero's whole strategy (`TerminalSession.swift:170-183`) and Tenon's floor.
    private func signalRootOnly(_ signal: Int32, rootPID: pid_t?) {
        guard let rootPID else { return }
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
