import Darwin
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

    enum DeadlineCause: Sendable {
        case requestedTimeout
        case envelopeDeadline
    }

    struct Request: Sendable {
        let command: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let standardInput: Data?
        let deadline: ContinuousClock.Instant
        let deadlineCause: DeadlineCause
    }

    enum ExecutionOutcome: Sendable {
        case completed(
            exitCode: Int32,
            termination: String,
            standardOutput: Data,
            standardError: Data
        )
        case requestedTimeout
        case deadlineExceeded
        case cancelled
        case outputLimitExceeded
        case launchFailed(String)
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

            let execution = POSIXProcessExecution(
                request: request,
                maximumCapturedBytes: maximumCapturedBytes
            )
            let worker = Task.detached(priority: Task.currentPriority) {
                execution.run()
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                execution.cancel()
            }

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

    static func request(from envelope: IntentEnvelope) throws -> Request {
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
                return Request(
                    command: command,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    standardInput: standardInput,
                    deadline: requestedDeadline,
                    deadlineCause: .requestedTimeout
                )
            }
        }
        return Request(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            deadline: envelope.deadline,
            deadlineCause: .envelopeDeadline
        )
    }
}

private final class POSIXProcessExecution: @unchecked Sendable {
    private enum StopReason {
        case completed
        case requestedTimeout
        case deadlineExceeded
        case cancelled
        case outputLimitExceeded
    }

    private struct ChildResult {
        let exitCode: Int32
        let termination: String
    }

    private struct SpawnedProcess {
        let pid: pid_t
        var standardInput: Int32
        var standardOutput: Int32
        var standardError: Int32
    }

    private struct CapturedStream {
        var data = Data()
        var exceeded = false
    }

    private let request: ProcessIntentProvider.Request
    private let maximumCapturedBytes: Int
    private let cancellation = ProcessCancellationState()
    private let terminationGrace: Duration = .milliseconds(150)
    private let reapDeadline: Duration = .seconds(2)

    init(
        request: ProcessIntentProvider.Request,
        maximumCapturedBytes: Int
    ) {
        self.request = request
        self.maximumCapturedBytes = maximumCapturedBytes
    }

    func run() -> ProcessIntentProvider.ExecutionOutcome {
        if ContinuousClock.now >= request.deadline {
            return deadlineOutcome()
        }
        guard !cancellation.isCancelled else { return .cancelled }

        let spawned: SpawnedProcess
        do {
            spawned = try spawn()
        } catch let error as POSIXProcessError {
            return .launchFailed(error.reason)
        } catch {
            return .launchFailed("process-could-not-launch")
        }

        var process = spawned
        cancellation.attach(processGroup: spawned.pid)
        var standardOutput = CapturedStream()
        var standardError = CapturedStream()
        var inputOffset = 0
        var childResult: ChildResult?
        var stopReason: StopReason?
        var terminationStartedAt: ContinuousClock.Instant?
        var killSentAt: ContinuousClock.Instant?

        defer {
            closeDescriptor(&process.standardInput)
            closeDescriptor(&process.standardOutput)
            closeDescriptor(&process.standardError)
            cancellation.detach()
        }

        while true {
            let now = ContinuousClock.now
            if childResult == nil {
                do {
                    childResult = try reapIfAvailable(pid: process.pid)
                } catch {
                    terminateGroup(process.pid, signal: SIGKILL)
                    scheduleFallbackReap(process.pid)
                    return .launchFailed("process-reap-failed")
                }
            }

            pollPipes(
                process: &process,
                inputOffset: &inputOffset,
                standardOutput: &standardOutput,
                standardError: &standardError
            )

            if stopReason == nil {
                if now >= request.deadline {
                    stopReason = request.deadlineCause == .requestedTimeout
                        ? .requestedTimeout
                        : .deadlineExceeded
                } else if cancellation.isCancelled {
                    stopReason = .cancelled
                } else if standardOutput.exceeded || standardError.exceeded {
                    stopReason = .outputLimitExceeded
                } else if childResult != nil {
                    stopReason = .completed
                }
            }

            if let stopReason {
                if terminationStartedAt == nil {
                    terminationStartedAt = now
                    closeDescriptor(&process.standardInput)
                    terminateGroup(process.pid, signal: SIGTERM)
                }

                let graceElapsed = terminationStartedAt.map {
                    now >= $0.advanced(by: terminationGrace)
                } ?? false
                if graceElapsed,
                   killSentAt == nil,
                   processGroupExists(process.pid)
                {
                    terminateGroup(process.pid, signal: SIGKILL)
                    killSentAt = now
                }

                if let killSentAt,
                   childResult == nil,
                   now >= killSentAt.advanced(by: reapDeadline)
                {
                    terminateGroup(process.pid, signal: SIGKILL)
                    scheduleFallbackReap(process.pid)
                    return .launchFailed("process-reap-timeout")
                }

                if childResult != nil,
                   !processGroupExists(process.pid)
                {
                    drainAvailable(
                        descriptor: process.standardOutput,
                        capture: &standardOutput
                    )
                    drainAvailable(
                        descriptor: process.standardError,
                        capture: &standardError
                    )
                    return outcome(
                        reason: stopReason,
                        childResult: childResult,
                        standardOutput: standardOutput.data,
                        standardError: standardError.data
                    )
                }
            }
        }
    }

    func cancel() {
        cancellation.cancel()
    }

    private func deadlineOutcome() -> ProcessIntentProvider.ExecutionOutcome {
        request.deadlineCause == .requestedTimeout
            ? .requestedTimeout
            : .deadlineExceeded
    }

    private func outcome(
        reason: StopReason,
        childResult: ChildResult?,
        standardOutput: Data,
        standardError: Data
    ) -> ProcessIntentProvider.ExecutionOutcome {
        switch reason {
        case .completed:
            guard let childResult else {
                return .launchFailed("process-result-missing")
            }
            return .completed(
                exitCode: childResult.exitCode,
                termination: childResult.termination,
                standardOutput: standardOutput,
                standardError: standardError
            )
        case .requestedTimeout:
            return .requestedTimeout
        case .deadlineExceeded:
            return .deadlineExceeded
        case .cancelled:
            return .cancelled
        case .outputLimitExceeded:
            return .outputLimitExceeded
        }
    }

    private func spawn() throws -> SpawnedProcess {
        var standardInput = [Int32](repeating: -1, count: 2)
        var standardOutput = [Int32](repeating: -1, count: 2)
        var standardError = [Int32](repeating: -1, count: 2)
        guard pipe(&standardInput) == 0,
              pipe(&standardOutput) == 0,
              pipe(&standardError) == 0
        else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError("pipe-creation-failed")
        }
        guard Darwin.fcntl(
            standardInput[1],
            F_SETNOSIGPIPE,
            1
        ) != -1 else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError("stdin-signal-suppression-failed")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError("spawn-configuration-failed")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let childDescriptors = [
            (standardInput[0], STDIN_FILENO),
            (standardOutput[1], STDOUT_FILENO),
            (standardError[1], STDERR_FILENO),
        ]
        for (source, destination) in childDescriptors {
            guard posix_spawn_file_actions_adddup2(
                &actions,
                source,
                destination
            ) == 0 else {
                closePipe(&standardInput)
                closePipe(&standardOutput)
                closePipe(&standardError)
                throw POSIXProcessError("spawn-file-actions-failed")
            }
        }
        for descriptor in standardInput + standardOutput + standardError {
            guard posix_spawn_file_actions_addclose(
                &actions,
                descriptor
            ) == 0 else {
                closePipe(&standardInput)
                closePipe(&standardOutput)
                closePipe(&standardError)
                throw POSIXProcessError("spawn-file-actions-failed")
            }
        }
        guard posix_spawn_file_actions_addchdir_np(
            &actions,
            request.workingDirectory
        ) == 0 else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError("working-directory-unavailable")
        }

        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError("process-group-configuration-failed")
        }

        let arguments = CStringArray([request.command] + request.arguments)
        let environment = CStringArray(
            request.environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        )
        guard arguments.isComplete, environment.isComplete else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError("process-arguments-unavailable")
        }

        var pid: pid_t = 0
        let status = arguments.withUnsafeMutablePointer { argumentPointer in
            environment.withUnsafeMutablePointer { environmentPointer in
                posix_spawn(
                    &pid,
                    request.command,
                    &actions,
                    &attributes,
                    argumentPointer,
                    environmentPointer
                )
            }
        }
        guard status == 0 else {
            closePipe(&standardInput)
            closePipe(&standardOutput)
            closePipe(&standardError)
            throw POSIXProcessError(
                status == ENOENT
                    ? "process-could-not-launch"
                    : "process-spawn-failed-\(status)"
            )
        }

        Darwin.close(standardInput[0])
        Darwin.close(standardOutput[1])
        Darwin.close(standardError[1])
        return SpawnedProcess(
            pid: pid,
            standardInput: standardInput[1],
            standardOutput: standardOutput[0],
            standardError: standardError[0]
        )
    }

    private func pollPipes(
        process: inout SpawnedProcess,
        inputOffset: inout Int,
        standardOutput: inout CapturedStream,
        standardError: inout CapturedStream
    ) {
        var descriptors: [pollfd] = []
        if process.standardOutput >= 0 {
            descriptors.append(
                pollfd(
                    fd: process.standardOutput,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            )
        }
        if process.standardError >= 0 {
            descriptors.append(
                pollfd(
                    fd: process.standardError,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            )
        }
        if process.standardInput >= 0,
           inputOffset < (request.standardInput?.count ?? 0)
        {
            descriptors.append(
                pollfd(
                    fd: process.standardInput,
                    events: Int16(POLLOUT | POLLHUP | POLLERR),
                    revents: 0
                )
            )
        } else {
            closeDescriptor(&process.standardInput)
        }

        if descriptors.isEmpty {
            usleep(5_000)
            return
        }
        let result = poll(&descriptors, nfds_t(descriptors.count), 5)
        guard result > 0 else { return }

        for descriptor in descriptors {
            if descriptor.fd == process.standardOutput,
               descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0
            {
                readOnce(
                    descriptor: descriptor.fd,
                    capture: &standardOutput
                )
            } else if descriptor.fd == process.standardError,
                      descriptor.revents
                      & Int16(POLLIN | POLLHUP | POLLERR) != 0
            {
                readOnce(
                    descriptor: descriptor.fd,
                    capture: &standardError
                )
            } else if descriptor.fd == process.standardInput {
                if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 {
                    closeDescriptor(&process.standardInput)
                    continue
                }
                if descriptor.revents & Int16(POLLOUT) != 0 {
                    let canContinue = writeInput(
                        descriptor: descriptor.fd,
                        offset: &inputOffset
                    )
                    if !canContinue
                        || inputOffset
                            >= (request.standardInput?.count ?? 0)
                    {
                        closeDescriptor(&process.standardInput)
                    }
                }
            }
        }
    }

    private func readOnce(
        descriptor: Int32,
        capture: inout CapturedStream
    ) {
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return }
        let remaining = max(0, maximumCapturedBytes - capture.data.count)
        capture.data.append(contentsOf: buffer.prefix(min(count, remaining)))
        if count > remaining {
            capture.exceeded = true
        }
    }

    private func drainAvailable(
        descriptor: Int32,
        capture: inout CapturedStream
    ) {
        guard descriptor >= 0 else { return }
        while true {
            var item = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            guard poll(&item, 1, 0) > 0,
                  item.revents & Int16(POLLIN) != 0
            else {
                return
            }
            let previousCount = capture.data.count
            readOnce(descriptor: descriptor, capture: &capture)
            if capture.data.count == previousCount { return }
        }
    }

    private func writeInput(descriptor: Int32, offset: inout Int) -> Bool {
        guard let input = request.standardInput, offset < input.count else {
            return false
        }
        return input.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return false
            }
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                min(8 * 1_024, rawBuffer.count - offset)
            )
            if count > 0 {
                offset += count
                return true
            }
            return count < 0
                && (errno == EINTR
                    || errno == EAGAIN
                    || errno == EWOULDBLOCK)
        }
    }

    private func reapIfAvailable(pid: pid_t) throws -> ChildResult? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return nil }
        if result < 0 {
            if errno == EINTR { return nil }
            throw POSIXProcessError("waitpid-failed-\(errno)")
        }

        let signal = status & 0x7F
        if signal == 0 {
            return ChildResult(
                exitCode: (status >> 8) & 0xFF,
                termination: "exited"
            )
        }
        return ChildResult(
            exitCode: signal,
            termination: "signalled"
        )
    }

    private func processGroupExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func terminateGroup(_ pid: pid_t, signal: Int32) {
        _ = Darwin.kill(-pid, signal)
    }

    private func scheduleFallbackReap(_ pid: pid_t) {
        Task.detached {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
    }

    private func closeDescriptor(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func closePipe(_ descriptors: inout [Int32]) {
        for index in descriptors.indices where descriptors[index] >= 0 {
            Darwin.close(descriptors[index])
            descriptors[index] = -1
        }
    }
}

private final class ProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroup: pid_t?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func attach(processGroup: pid_t) {
        let shouldTerminate = lock.withLock {
            self.processGroup = processGroup
            return cancelled
        }
        if shouldTerminate {
            _ = Darwin.kill(-processGroup, SIGTERM)
        }
    }

    func cancel() {
        let processGroup = lock.withLock {
            cancelled = true
            return self.processGroup
        }
        if let processGroup {
            _ = Darwin.kill(-processGroup, SIGTERM)
        }
    }

    func detach() {
        lock.withLock {
            processGroup = nil
        }
    }
}

private final class CStringArray {
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

private struct POSIXProcessError: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}
