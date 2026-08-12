// @domain: plugin-host
import Darwin
import Foundation

/// A child process that leads its own POSIX process group, so the plugin runtime can end the whole
/// job — not just the command it named.
///
/// `PRT-FR-042`. Foundation's `Process` cannot be told to lead a process group, and `terminate()`
/// signals the leader alone: `npm run dev` dies while the server it forked keeps the port. The
/// plugin author guide has been telling authors to avoid such commands, which is a rule standing in
/// for a guarantee. `posix_spawn` with `POSIX_SPAWN_SETPGROUP` supplies the guarantee, and
/// `ProcessIntentProvider` already launches the finite `process.exec.v1` path exactly this way.
///
/// Why a process group rather than walking the process tree: a tree read after the parent dies has
/// already lost its children to `launchd`, and a tree read before is stale the moment a new child
/// is forked. The group is decided at spawn and inherited, so `killpg` reaches descendants that did
/// not exist when the kill was decided. `PRT-FR-042` allows an "equivalently race-free descendant
/// set"; a tree walk is not one.
///
/// Deliberately not shared with `ProcessIntentProvider`'s spawn yet. That path needs stdin and a
/// working directory before exec; this one needs streaming reads and an exit callback. Two uses is
/// where a common helper is guessed at rather than known — the third one extracts it.
final class PluginStreamProcess: @unchecked Sendable {
    struct LaunchError: Error {
        let reason: String
    }

    /// Long enough for a well-behaved job to unwind on SIGTERM, short enough that a cancelled
    /// stream does not visibly linger. The same reasoning, and the same number, as the pane
    /// teardown in `TerminalJobTerminator`.
    private static let escalationDelay: Duration = .milliseconds(120)

    let standardOutput: FileHandle
    let standardError: FileHandle

    /// Called once with the child's exit status. Cleared by the runtime when it stops caring.
    var terminationHandler: ((Int32) -> Void)?

    private let executable: String
    private let arguments: [String]
    private let workingDirectory: String?
    private let environment: [String: String]
    private let childOutput: Int32
    private let childError: Int32

    private let lock = NSLock()
    private var pid: pid_t?
    private var exited = false
    private var exitStatus: Int32 = 0
    private var exitSource: DispatchSourceProcess?

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) throws {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else {
            throw LaunchError(reason: "stdout-pipe-unavailable")
        }
        guard pipe(&errorPipe) == 0 else {
            Darwin.close(outputPipe[0])
            Darwin.close(outputPipe[1])
            throw LaunchError(reason: "stderr-pipe-unavailable")
        }

        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        childOutput = outputPipe[1]
        childError = errorPipe[1]
        standardOutput = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
        standardError = FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid != nil && !exited
    }

    /// The leader's pid, which is also its process-group id. Exposed so a caller can tell the
    /// leader apart from the descendants that inherited its group — the distinction the whole
    /// type exists for, and one a test cannot make from a `ps` line alone.
    var processIdentifier: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    func run() throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            throw LaunchError(reason: "spawn-configuration-failed")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, childOutput, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, childError, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, childOutput) == 0,
              posix_spawn_file_actions_addclose(&actions, childError) == 0
        else {
            throw LaunchError(reason: "spawn-file-actions-failed")
        }
        if let workingDirectory {
            guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) == 0 else {
                throw LaunchError(reason: "working-directory-unavailable")
            }
        }

        // The whole point of this type. `setpgroup(0)` makes the child the leader of a new group
        // whose id is its own pid, so every descendant it forks inherits that group unless it
        // deliberately leaves — and `killpg` below reaches all of them.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw LaunchError(reason: "process-group-configuration-failed")
        }

        let argumentValues = CommandStrings([executable] + arguments)
        let environmentValues = CommandStrings(
            environment.map { "\($0.key)=\($0.value)" }.sorted()
        )
        guard argumentValues.isComplete, environmentValues.isComplete else {
            throw LaunchError(reason: "process-arguments-unavailable")
        }

        var spawned: pid_t = 0
        let status = argumentValues.withUnsafeMutablePointer { argumentPointer in
            environmentValues.withUnsafeMutablePointer { environmentPointer in
                posix_spawn(
                    &spawned,
                    executable,
                    &actions,
                    &attributes,
                    argumentPointer,
                    environmentPointer
                )
            }
        }
        guard status == 0 else {
            throw LaunchError(
                reason: status == ENOENT ? "process-could-not-launch" : "process-spawn-failed"
            )
        }

        // The write ends belong to the child now. Holding them here would keep the reader waiting
        // for EOF that never comes after the child exits.
        Darwin.close(childOutput)
        Darwin.close(childError)

        lock.lock()
        pid = spawned
        lock.unlock()
        observeExit(of: spawned)
    }

    /// End the job: the group first, then the leader for the case where the group is already gone.
    ///
    /// Signalling the group is what separates this from `Process.terminate()`. The escalation is
    /// the other half — a job that traps SIGTERM would otherwise survive a cancel and keep
    /// streaming into a runtime that has stopped listening.
    func terminate() {
        lock.lock()
        let target = exited ? nil : pid
        lock.unlock()
        guard let target, target > 1 else { return }

        kill(-target, SIGTERM)
        kill(target, SIGTERM)
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: Self.escalationDelay)
            guard let self, self.isRunning else { return }
            kill(-target, SIGKILL)
            kill(target, SIGKILL)
        }
    }

    private func observeExit(of child: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(child, &status, 0)
            let code = Self.exitCode(from: status)
            self.lock.lock()
            self.exited = true
            self.exitStatus = code
            let handler = self.terminationHandler
            self.lock.unlock()
            handler?(code)
            source.cancel()
        }
        lock.lock()
        exitSource = source
        lock.unlock()
        source.resume()
    }

    /// A signalled child reports its signal, not an exit code. Reporting `128 + signal` is the
    /// shell's convention, and it keeps "killed" distinguishable from "exited 0".
    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }
}

/// Null-terminated C string vector for `posix_spawn`, owning its copies for the call's duration.
private final class CommandStrings {
    private var pointers: [UnsafeMutablePointer<CChar>?]
    let isComplete: Bool

    init(_ strings: [String]) {
        let values = strings.map { strdup($0) }
        isComplete = values.allSatisfy { $0 != nil }
        pointers = values + [nil]
    }

    deinit {
        for pointer in pointers.dropLast() {
            free(pointer)
        }
    }

    func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
