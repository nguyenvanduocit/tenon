import Foundation
@testable import TenonIntentCore
import XCTest

final class IntentTelemetryTests: XCTestCase {
    func testRecordRemainsInFlightUntilLogicalAndPhysicalCompletion() async throws {
        let telemetry = try IntentTelemetry(completedCapacity: 2)
        let envelope = try makeEnvelope()
        let providerID = try ProviderID("dev.tenon.terminal")
        await telemetry.begin(envelope, inputBytes: 12)
        await telemetry.markValidated(requestID: envelope.requestID)
        await telemetry.markQueued(
            requestID: envelope.requestID,
            providerID: providerID,
            generation: 4
        )
        await telemetry.markStarted(requestID: envelope.requestID)
        await telemetry.markSettled(
            requestID: envelope.requestID,
            result: .success(
                value: .object([:]),
                requestID: envelope.requestID,
                providerID: providerID
            ),
            outputBytes: 2
        )

        var snapshot = await telemetry.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 1)
        XCTAssertTrue(snapshot.completed.isEmpty)

        await telemetry.markPhysicallyCompleted(
            requestID: envelope.requestID,
            completion: IntentMailboxPhysicalCompletion(
                requestID: envelope.requestID,
                terminal: .reply(.success(.object([:]))),
                providerReply: .success(.object([:])),
                started: true,
                isLateReply: true
            )
        )

        snapshot = await telemetry.snapshot()
        XCTAssertTrue(snapshot.inFlight.isEmpty)
        XCTAssertEqual(snapshot.completed.count, 1)
        XCTAssertEqual(snapshot.completed[0].providerID, providerID)
        XCTAssertEqual(snapshot.completed[0].generation, 4)
        XCTAssertTrue(snapshot.completed[0].lateReply)
        XCTAssertNotNil(snapshot.completed[0].queueWait)
        XCTAssertNotNil(snapshot.completed[0].handlerDuration)
        XCTAssertNotNil(snapshot.completed[0].totalDuration)
    }

    func testCompletedHistoryIsBounded() async throws {
        let telemetry = try IntentTelemetry(completedCapacity: 2)
        var requestIDs: [UUID] = []
        for _ in 0..<3 {
            let envelope = try makeEnvelope()
            requestIDs.append(envelope.requestID)
            await telemetry.begin(envelope, inputBytes: 0)
            await telemetry.markSettled(
                requestID: envelope.requestID,
                result: .failure(
                    error: IntentError(
                        code: .kernel(.cancelled),
                        details: nil,
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: envelope.requestID,
                    providerID: nil
                ),
                outputBytes: nil
            )
            await telemetry.markPhysicallyCompleted(
                requestID: envelope.requestID,
                completion: nil
            )
        }

        let snapshot = await telemetry.snapshot()
        XCTAssertEqual(snapshot.completed.map(\.requestID), Array(requestIDs.suffix(2)))
    }

    func testProgressReporterEmitsStrictIncreaseAndCoalescesLatestPendingValue() async throws {
        let sink = ProgressSinkProbe()
        let reporter = IntentProgressReporter(
            requestID: UUID(),
            minimumInterval: .milliseconds(80)
        ) { notification in
            await sink.record(notification.progress.completed)
        }

        await reporter.report(try IntentProgress(completed: 0))
        await reporter.report(try IntentProgress(completed: 0))
        await reporter.report(try IntentProgress(completed: 1))
        await reporter.report(try IntentProgress(completed: 2))

        let values = await sink.valuesReaching(2, within: .seconds(5))
        XCTAssertEqual(values, [0, 2])
    }

    func testClosingProgressReporterDropsPendingFlush() async throws {
        let sink = ProgressSinkProbe()
        let reporter = IntentProgressReporter(
            requestID: UUID(),
            minimumInterval: .seconds(1)
        ) { notification in
            await sink.record(notification.progress.completed)
        }

        await reporter.report(try IntentProgress(completed: 0))
        await reporter.report(try IntentProgress(completed: 1))
        await reporter.close()
        try await Task.sleep(for: .milliseconds(30))

        let values = await sink.values()
        XCTAssertEqual(values, [0])
    }

    private func makeEnvelope() throws -> IntentEnvelope {
        IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: try IntentID("terminal.run.v1"),
            input: .object([:]),
            caller: IntentPrincipal(
                id: "cli:main",
                kind: .cli,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: ContinuousClock.now.advanced(by: .seconds(1)),
            target: nil,
            idempotencyKey: nil
        )
    }
}

private actor ProgressSinkProbe {
    private var recordedValues: [Double] = []

    func record(_ value: Double) {
        recordedValues.append(value)
    }

    func values() -> [Double] {
        recordedValues
    }

    /// Wait for the coalesced flush to land instead of sleeping a fixed margin past the
    /// reporter's interval. What the reporter promises is that the latest pending value is
    /// delivered *after* `minimumInterval` — how promptly a loaded machine gets round to running
    /// that timer is not part of the promise, and a fixed sleep turns that difference into a
    /// failure. Returns as soon as `count` values have arrived, so the assertion that follows is
    /// still exact.
    func valuesReaching(_ count: Int, within deadline: Duration) async -> [Double] {
        let started = ContinuousClock.now
        while recordedValues.count < count, ContinuousClock.now - started < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recordedValues
    }
}
