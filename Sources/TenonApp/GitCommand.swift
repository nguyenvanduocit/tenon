// @domain: repository-read
import Foundation

/// One way for a pane to ask git a question.
///
/// The Changes pane and the diff pane each grew their own "spawn git, drain both pipes without
/// deadlocking, decode the result" — the same twenty lines twice, with different limits. The
/// diff pane stopped reading at four megabytes; the status reader read whatever it was given,
/// so a repository with a pathological status could hand the app an unbounded string through
/// one pane and a bounded one through the other. A single implementation is what makes the
/// bound a property of asking git rather than of which pane happened to ask.
///
/// It is a typed DIRECT service: same semantic owner, no intent, no protocol. Callers run it
/// off the main actor — reading a repository is subprocess work, never UI work.
enum GitCommand {
    /// Four megabytes. Past this a diff is not readable by a person and a status is not a
    /// status; both panes already agreed on the number, only one of them enforced it.
    static let defaultByteLimit = 4 << 20

    struct Output: Sendable {
        let status: Int32
        let data: Data
        /// The command produced more than the limit and was stopped. Distinct from failure:
        /// git was fine, the answer was too big to use.
        let exceededLimit: Bool

        var text: String {
            String(data: data, encoding: .utf8) ?? ""
        }

        var succeeded: Bool {
            status == 0 && !exceededLimit
        }
    }

    /// Runs git in `directory` and returns at most `byteLimit` bytes of its standard output.
    ///
    /// Standard error is drained concurrently and discarded: a chatty stderr filling its pipe
    /// buffer would otherwise deadlock a large stdout read, which is a hang no timeout here
    /// would explain.
    static func run(
        _ arguments: [String],
        in directory: String,
        byteLimit: Int = defaultByteLimit
    ) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        // No index lock (this is a read), no credential prompt (nobody is there to answer it),
        // and a stable locale so parsing sees the same words on every machine.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Output(status: -1, data: Data(), exceededLimit: false)
        }

        let collected = OutputBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = try? standardOutput.fileHandleForReading.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {
                if !collected.append(chunk, limit: byteLimit) {
                    process.terminate()
                    break
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = try? standardError.fileHandleForReading.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {}
            group.leave()
        }
        process.waitUntilExit()
        group.wait()

        return Output(
            status: process.terminationStatus,
            data: collected.snapshot,
            exceededLimit: collected.exceeded
        )
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        private var overflowed = false

        var snapshot: Data { lock.withLock { value } }
        var exceeded: Bool { lock.withLock { overflowed } }

        /// `false` once the limit is passed, which is the caller's signal to stop reading and
        /// terminate the command rather than keep accumulating.
        func append(_ chunk: Data, limit: Int) -> Bool {
            lock.withLock {
                guard value.count + chunk.count <= limit else {
                    overflowed = true
                    return false
                }
                value.append(chunk)
                return true
            }
        }
    }
}
