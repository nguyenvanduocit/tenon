// @domain: intent-bus
import Foundation
import TenonIntentCore

/// Executes one explicitly unsandboxed local process with bounded I/O and lifetime.
public struct ProcessIntentProvider: Sendable {
    public let bindings: [IntentProviderBinding]

    public init() throws {
        let codes = try ErrorCodes()
        bindings = [
            IntentProviderBinding(intentID: try CoreIntentName.processExec.intentID) {
                envelope,
                context in
                await Self.execute(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            }
        ]
    }
}

private extension ProcessIntentProvider {
    struct ErrorCodes: Sendable {
        let launchFailed: IntentErrorCode
        let timedOut: IntentErrorCode
        let outputUnavailable: IntentErrorCode

        init() throws {
            launchFailed = .domain(
                try IntentDomainErrorCode("dev.tenon.core.process-launch-failed")
            )
            timedOut = .domain(
                try IntentDomainErrorCode("dev.tenon.core.process-timed-out")
            )
            outputUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.process-output-unavailable"
                )
            )
        }
    }

    static let maximumCapturedBytes =
        CoreIntentPayloadPolicy.maximumInlineTextCharacters
    static let inheritedEnvironmentKeys: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TERM",
        "TMPDIR",
        "USER",
    ]

    static func execute(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        do {
            let request = try request(from: envelope)
            if ContinuousClock.now >= envelope.deadline {
                return .failure(
                    IntentProviderFailure(code: .kernel(.deadlineExceeded))
                )
            }
            try context.checkCancellation()

            let outcome = await BoundedProcessRunner.run(request)

            switch outcome {
            case let .completed(exitCode, termination, stdout, stderr):
                guard let standardOutput = String(data: stdout, encoding: .utf8),
                      let standardError = String(data: stderr, encoding: .utf8)
                else {
                    return CoreIntentProviderSupport.failure(
                        code: codes.outputUnavailable,
                        reason: "captured-output-is-not-utf8"
                    )
                }
                let output = IntentValue.object([
                    "exitCode": .integer(Int64(exitCode)),
                    "termination": .string(termination),
                    "standardOutput": CoreIntentProviderSupport.textOutput(
                        standardOutput
                    ),
                    "standardError": CoreIntentProviderSupport.textOutput(
                        standardError
                    ),
                ])
                do {
                    try output.validate()
                } catch {
                    return CoreIntentProviderSupport.failure(
                        code: codes.outputUnavailable,
                        reason: "inline-output-limit-exceeded"
                    )
                }
                return .success(output)
            case .requestedTimeout:
                return CoreIntentProviderSupport.failure(
                    code: codes.timedOut,
                    reason: "process-timeout-elapsed"
                )
            case .deadlineExceeded:
                return .failure(
                    IntentProviderFailure(code: .kernel(.deadlineExceeded))
                )
            case .cancelled:
                return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
            case .outputLimitExceeded:
                return CoreIntentProviderSupport.failure(
                    code: codes.outputUnavailable,
                    reason: "captured-output-limit-exceeded"
                )
            case let .launchFailed(reason):
                return CoreIntentProviderSupport.failure(
                    code: codes.launchFailed,
                    reason: reason
                )
            }
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch is CancellationError {
            let code: IntentKernelErrorCode =
                ContinuousClock.now >= envelope.deadline
                    ? .deadlineExceeded
                    : .cancelled
            return .failure(IntentProviderFailure(code: .kernel(code)))
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.launchFailed,
                reason: "process-could-not-launch"
            )
        }
    }

    static func request(
        from envelope: IntentEnvelope
    ) throws -> BoundedProcessRequest {
        let input = try CoreIntentProviderSupport.object(envelope.input)
        let command = try CoreIntentProviderSupport.string("command", in: input)
        let arguments = try CoreIntentProviderSupport.stringArray(
            "arguments",
            in: input
        )
        let workingDirectory = try CoreIntentProviderSupport.string(
            "workingDirectory",
            in: input
        )
        guard command.utf8.allSatisfy({ $0 != 0 }),
              workingDirectory.utf8.allSatisfy({ $0 != 0 }),
              arguments.allSatisfy({ $0.utf8.allSatisfy { $0 != 0 } })
        else {
            throw CoreIntentProviderInputError.missingOrInvalidField("command")
        }

        let inherited = ProcessInfo.processInfo.environment
        var environment = inherited.filter {
            inheritedEnvironmentKeys.contains($0.key)
        }
        for entry in try CoreIntentProviderSupport.optionalObjectArray(
            "environment",
            in: input
        ) {
            let name = try CoreIntentProviderSupport.string("name", in: entry)
            let value = try CoreIntentProviderSupport.string("value", in: entry)
            guard !name.isEmpty,
                  !name.contains("="),
                  name.utf8.allSatisfy({ $0 != 0 }),
                  value.utf8.allSatisfy({ $0 != 0 })
            else {
                throw CoreIntentProviderInputError.missingOrInvalidField(
                    "environment"
                )
            }
            environment[name] = value
        }

        let standardInput: Data?
        if let text = try CoreIntentProviderSupport.optionalTextInput(
            "standardInput",
            in: input
        ) {
            let data = Data(text.utf8)
            guard data.count
                <= CoreIntentPayloadPolicy.maximumInlineTextCharacters
            else {
                throw CoreIntentProviderInputError.missingOrInvalidField(
                    "standardInput"
                )
            }
            standardInput = data
        } else {
            standardInput = nil
        }

        let requestedMilliseconds = try CoreIntentProviderSupport.optionalInteger(
            "timeoutMs",
            in: input
        )
        if let requestedMilliseconds,
           !(1 ... 60_000).contains(requestedMilliseconds)
        {
            throw CoreIntentProviderInputError.missingOrInvalidField("timeoutMs")
        }

        let now = ContinuousClock.now
        if let requestedMilliseconds {
            let requestedDeadline = now.advanced(
                by: .milliseconds(requestedMilliseconds)
            )
            if requestedDeadline < envelope.deadline {
                return BoundedProcessRequest(
                    command: command,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    standardInput: standardInput,
                    deadline: requestedDeadline,
                    deadlineCause: .requestedTimeout,
                    maximumStandardOutputBytes: maximumCapturedBytes,
                    maximumStandardErrorBytes: maximumCapturedBytes
                )
            }
        }
        return BoundedProcessRequest(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            deadline: envelope.deadline,
            deadlineCause: .envelopeDeadline,
            maximumStandardOutputBytes: maximumCapturedBytes,
            maximumStandardErrorBytes: maximumCapturedBytes
        )
    }
}
