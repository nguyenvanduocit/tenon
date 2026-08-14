// @domain: companion
import Foundation
import TenonCore

enum CompanionTaskFailure: Error, LocalizedError, Equatable {
    case unavailable
    case invalidWorkingDirectory(String)
    case launchFailed(String)
    case failed(Int32, String)
    case timedOut
    case outputTooLarge
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            Shell.text("The selected Companion agent is not installed or is not on PATH.")
        case .invalidWorkingDirectory(let path):
            Shell.text(
                "The Companion working folder is unavailable: \(path)",
                comment: "Companion error; the variable is the unavailable directory path."
            )
        case .launchFailed(let detail):
            Shell.text(
                "The Companion could not start: \(detail)",
                comment: "Companion error; the variable is a process launch failure reason."
            )
        case let .failed(status, detail):
            detail.isEmpty
                ? Shell.text(
                    "The Companion exited with status \(status).",
                    comment: "Companion error; the variable is the process exit status."
                )
                : Shell.text(
                    "The Companion exited with status \(status): \(detail.prefix(240))",
                    comment: "Companion error; the variables are exit status and stderr."
                )
        case .timedOut:
            Shell.text("The Companion took longer than 60 seconds.")
        case .outputTooLarge:
            Shell.text("The Companion returned more data than this task accepts.")
        case .malformedOutput:
            Shell.text("The Companion did not return the required JSON.")
        }
    }
}

struct CompanionProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
}

/// One bounded cancellable subprocess primitive shared by host-owned Companion tasks.
/// Provider adapters own their CLI arguments and response grammar; this type owns process
/// policy while the shared TenonCore runner owns process groups, bounded pipes, and reaping.
struct CompanionProcessRunner: Sendable {
    static let timeoutSeconds = 60
    static let maximumOutputBytes = 64 << 10
    static let maximumErrorBytes = 8 << 10

    @concurrent
    static func run(
        executableURL: URL,
        arguments: [String],
        prompt: String,
        workingDirectoryURL: URL,
        maximumOutputBytes: Int = maximumOutputBytes
    ) async throws -> CompanionProcessOutput {
        let outcome = await BoundedProcessRunner.run(BoundedProcessRequest(
            command: executableURL.path,
            arguments: arguments,
            workingDirectory: workingDirectoryURL.path,
            environment: ProcessInfo.processInfo.environment,
            standardInput: Data(prompt.utf8),
            deadline: .now.advanced(by: .seconds(timeoutSeconds)),
            deadlineCause: .requestedTimeout,
            maximumStandardOutputBytes: maximumOutputBytes,
            maximumStandardErrorBytes: maximumErrorBytes
        ))
        switch outcome {
        case let .completed(status, _, stdout, stderr):
            guard status != 0 else {
                try Task.checkCancellation()
                return CompanionProcessOutput(stdout: stdout, stderr: stderr)
            }
            let detail = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CompanionTaskFailure.failed(status, detail)
        case .requestedTimeout, .deadlineExceeded:
            throw CompanionTaskFailure.timedOut
        case .cancelled:
            throw CancellationError()
        case .outputLimitExceeded:
            throw CompanionTaskFailure.outputTooLarge
        case let .launchFailed(reason):
            throw CompanionTaskFailure.launchFailed(reason)
        }
    }
}
