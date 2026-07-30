import Darwin
import Foundation
import TenonCore
@testable import TenonIntentCore
import XCTest

final class ProcessIntentProviderTests: XCTestCase {
    func testExecCapturesBoundedStandardInputOutputAndEnvironment() async throws {
        let provider = try ProcessIntentProvider()
        let reply = try await invoke(
            input: .object([
                "command": .string("/bin/cat"),
                "arguments": .array([]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
                "environment": .array([
                    .object([
                        "name": .string("TENON_PROCESS_PROVIDER_TEST"),
                        "value": .string("set"),
                    ])
                ]),
                "standardInput": .object([
                    "kind": .string("inline"),
                    "text": .string("hello from stdin"),
                ]),
                "timeoutMs": .integer(2_000),
            ]),
            bindings: provider.bindings
        )

        let output = try object(try successValue(reply))
        XCTAssertEqual(try integer(output["exitCode"]), 0)
        XCTAssertEqual(try string(output["termination"]), "exited")
        let standardOutput = try object(output["standardOutput"])
        XCTAssertEqual(try string(standardOutput["kind"]), "inline")
        XCTAssertEqual(try string(standardOutput["text"]), "hello from stdin")
        XCTAssertEqual(try integer(standardOutput["byteCount"]), 16)
        let standardError = try object(output["standardError"])
        XCTAssertEqual(try string(standardError["text"]), "")

        let environmentReply = try await invoke(
            input: .object([
                "command": .string("/usr/bin/env"),
                "arguments": .array([]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
                "environment": .array([
                    .object([
                        "name": .string("TENON_PROCESS_PROVIDER_TEST"),
                        "value": .string("set"),
                    ])
                ]),
            ]),
            bindings: provider.bindings
        )
        let environmentOutput = try object(
            try object(try successValue(environmentReply))["standardOutput"]
        )
        XCTAssertTrue(
            try string(environmentOutput["text"])
                .split(separator: "\n")
                .contains("TENON_PROCESS_PROVIDER_TEST=set")
        )
    }

    func testExecHandlesChildClosingStandardInputWithoutSIGPIPE()
        async throws
    {
        let reply = try await invoke(
            input: .object([
                "command": .string("/bin/sh"),
                "arguments": .array([
                    .string("-c"),
                    .string("exec 0<&-; sleep 0.05; exit 0"),
                ]),
                "workingDirectory": .string(
                    FileManager.default.temporaryDirectory.path
                ),
                "standardInput": .object([
                    "kind": .string("inline"),
                    "text": .string(
                        String(
                            repeating: "x",
                            count: CoreIntentPayloadPolicy
                                .maximumInlineTextCharacters
                        )
                    ),
                ]),
                "timeoutMs": .integer(2_000),
            ]),
            bindings: try ProcessIntentProvider().bindings
        )

        let output = try object(try successValue(reply))
        XCTAssertEqual(try integer(output["exitCode"]), 0)
        XCTAssertEqual(try string(output["termination"]), "exited")
    }

    func testExecTimeoutTerminatesProcessWithoutHanging() async throws {
        let started = ContinuousClock.now
        let reply = try await invoke(
            input: .object([
                "command": .string("/bin/sleep"),
                "arguments": .array([.string("5")]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
                "timeoutMs": .integer(25),
            ]),
            bindings: try ProcessIntentProvider().bindings,
            deadline: .now.advanced(by: .seconds(2))
        )
        let elapsed = started.duration(to: .now)

        try assertFailure(
            reply,
            code: "dev.tenon.core.process-timed-out",
            reason: "process-timeout-elapsed"
        )
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testExecEscalatesToKillAndReapsChildIgnoringTerm() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-stubborn-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = ContinuousClock.now
        let reply = try await invoke(
            input: .object([
                "command": .string("/bin/sh"),
                "arguments": .array([
                    .string("-c"),
                    .string(
                        "trap '' TERM; echo $$ > \"$1\"; while :; do :; done"
                    ),
                    .string("tenon-stubborn-child"),
                    .string(pidFile.path),
                ]),
                "workingDirectory": .string(
                    FileManager.default.temporaryDirectory.path
                ),
                "timeoutMs": .integer(50),
            ]),
            bindings: try ProcessIntentProvider().bindings,
            deadline: .now.advanced(by: .seconds(2))
        )

        try assertFailure(
            reply,
            code: "dev.tenon.core.process-timed-out",
            reason: "process-timeout-elapsed"
        )
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let pid = try processID(from: pidFile)
        let disappeared = await processDisappeared(pid)
        XCTAssertTrue(disappeared)
    }

    func testExecClosesInheritedPipesAndKillsGrandchildProcessGroup() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-grandchild-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = ContinuousClock.now
        let reply = try await invoke(
            input: .object([
                "command": .string("/bin/sh"),
                "arguments": .array([
                    .string("-c"),
                    .string(
                        """
                        (trap '' TERM; while :; do sleep 1; done) & \
                        echo $! > "$1"; exit 0
                        """
                    ),
                    .string("tenon-inherited-pipe-grandchild"),
                    .string(pidFile.path),
                ]),
                "workingDirectory": .string(
                    FileManager.default.temporaryDirectory.path
                ),
            ]),
            bindings: try ProcessIntentProvider().bindings,
            deadline: .now.advanced(by: .seconds(2))
        )

        let output = try object(try successValue(reply))
        XCTAssertEqual(try integer(output["exitCode"]), 0)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let pid = try processID(from: pidFile)
        let disappeared = await processDisappeared(pid)
        XCTAssertTrue(disappeared)
    }

    func testExecDoesNotInheritArbitraryHostSecrets() async throws {
        let name = "TENON_SECRET_NOT_INHERITED_\(UUID().uuidString)"
        setenv(name, "sensitive", 1)
        defer { unsetenv(name) }

        let reply = try await invoke(
            input: .object([
                "command": .string("/usr/bin/env"),
                "arguments": .array([]),
                "workingDirectory": .string(
                    FileManager.default.temporaryDirectory.path
                ),
            ]),
            bindings: try ProcessIntentProvider().bindings
        )
        let output = try object(
            try object(try successValue(reply))["standardOutput"]
        )
        XCTAssertFalse(try string(output["text"]).contains(name))
    }

    func testExecTerminatesProducerAtCaptureLimit() async throws {
        let reply = try await invoke(
            input: .object([
                "command": .string("/usr/bin/yes"),
                "arguments": .array([]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
                "timeoutMs": .integer(2_000),
            ]),
            bindings: try ProcessIntentProvider().bindings,
            deadline: .now.advanced(by: .seconds(3))
        )

        try assertFailure(
            reply,
            code: "dev.tenon.core.process-output-unavailable",
            reason: "captured-output-limit-exceeded"
        )
    }

    func testExecReportsLaunchAndUnsupportedInputFailures() async throws {
        let bindings = try ProcessIntentProvider().bindings
        let launchReply = try await invoke(
            input: .object([
                "command": .string("/does/not/exist"),
                "arguments": .array([]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
            ]),
            bindings: bindings
        )
        try assertFailure(
            launchReply,
            code: "dev.tenon.core.process-launch-failed",
            reason: "process-could-not-launch"
        )

        let resourceReply = try await invoke(
            input: .object([
                "command": .string("/bin/cat"),
                "arguments": .array([]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
                "standardInput": .object([
                    "kind": .string("resource"),
                    "resourceID": .string("resource-1"),
                ]),
            ]),
            bindings: bindings
        )
        try assertFailure(
            resourceReply,
            code: "tenon.invalid-input"
        )
    }

    func testPastDeadlineDoesNotLaunchProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-process-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let reply = try await invoke(
            input: .object([
                "command": .string("/usr/bin/touch"),
                "arguments": .array([.string(marker.path)]),
                "workingDirectory": .string(FileManager.default.temporaryDirectory.path),
            ]),
            bindings: try ProcessIntentProvider().bindings,
            deadline: .now
        )

        try assertFailure(reply, code: "tenon.deadline-exceeded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

private extension ProcessIntentProviderTests {
    enum TestError: Error {
        case missingBinding
        case expectedSuccess
        case expectedFailure
        case unexpectedValue
    }

    func invoke(
        input: IntentValue,
        bindings: [IntentProviderBinding],
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) async throws -> IntentProviderReply {
        let intentID = try CoreIntentName.processExec.intentID
        guard let binding = bindings.first(where: { $0.intentID == intentID }) else {
            throw TestError.missingBinding
        }
        let envelope = IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: input,
            caller: IntentPrincipal(
                id: "test:process-provider",
                kind: .plugin,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: deadline,
            target: nil,
            idempotencyKey: nil
        )
        let context = IntentProviderContext(
            requestID: envelope.requestID,
            nestedSend: { request in
                .failure(
                    error: IntentError(
                        code: .kernel(.internal),
                        details: .string(request.intentID.rawValue),
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: UUID(),
                    providerID: nil
                )
            }
        )
        return try await binding.invoke(envelope: envelope, context: context)
    }

    func successValue(_ reply: IntentProviderReply) throws -> IntentValue {
        guard case let .success(value) = reply else {
            throw TestError.expectedSuccess
        }
        return value
    }

    func assertFailure(
        _ reply: IntentProviderReply,
        code: String,
        reason: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .failure(failure) = reply else {
            XCTFail("Expected failure", file: file, line: line)
            throw TestError.expectedFailure
        }
        XCTAssertEqual(failure.code.rawValue, code, file: file, line: line)
        if let reason {
            let details = try object(failure.details)
            XCTAssertEqual(
                try string(details["reason"]),
                reason,
                file: file,
                line: line
            )
        }
    }

    func object(_ value: IntentValue?) throws -> [String: IntentValue] {
        guard case let .object(object)? = value else {
            throw TestError.unexpectedValue
        }
        return object
    }

    func string(_ value: IntentValue?) throws -> String {
        guard case let .string(string)? = value else {
            throw TestError.unexpectedValue
        }
        return string
    }

    func integer(_ value: IntentValue?) throws -> Int64 {
        guard case let .integer(integer)? = value else {
            throw TestError.unexpectedValue
        }
        return integer
    }

    func processID(from url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(value) else {
            throw TestError.unexpectedValue
        }
        return pid
    }

    func processDisappeared(_ pid: pid_t) async -> Bool {
        for _ in 0 ..< 100 {
            if Darwin.kill(pid, 0) < 0, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
