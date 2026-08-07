import Darwin
import Dispatch
import Foundation
import os
import XCTest
@testable import TenonCore

private actor PinnedThreadProbe {
    nonisolated let executor: PinnedThreadExecutor
    private var observedValues: Set<Int> = []

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(executor: PinnedThreadExecutor) {
        self.executor = executor
    }

    func record(_ value: Int) -> UInt64 {
        executor.checkIsolated()
        precondition(executor.isIsolatingCurrentContext() == true)
        observedValues.insert(value)
        return currentDarwinThreadIdentifier()
    }

    func observedCount() -> Int {
        observedValues.count
    }
}

@MainActor
final class PinnedThreadExecutorTests: XCTestCase {
    func testConcurrentActorCallsStayIsolatedOnTheOwnedThread() async throws {
        let executor = try PinnedThreadExecutor(
            name: "tenon.tests.actor",
            startupTimeout: 1
        )
        let probe = PinnedThreadProbe(executor: executor)

        let identifiers = await withTaskGroup(
            of: UInt64.self,
            returning: [UInt64].self
        ) { group in
            for value in 0..<256 {
                group.addTask {
                    await probe.record(value)
                }
            }

            var identifiers: [UInt64] = []
            for await identifier in group {
                identifiers.append(identifier)
            }
            return identifiers
        }

        let expectedIdentifier = try XCTUnwrap(executor.threadIdentifier)
        let observedCount = await probe.observedCount()
        let shutdownResult = await executor.shutdown(timeout: 1)

        XCTAssertEqual(Set(identifiers), [expectedIdentifier])
        XCTAssertEqual(observedCount, 256)
        XCTAssertEqual(shutdownResult, .stopped)
    }

    func testWorkerRunsAcceptedOperationsFIFOOnExactlyOneThread() async throws {
        let worker = try PinnedThreadWorker()
        guard worker.start(
            name: "tenon.tests.fifo",
            qualityOfService: .userInitiated,
            timeout: 1
        ) == .started else {
            return XCTFail("worker did not start")
        }

        let order = OSAllocatedUnfairLock(initialState: [Int]())
        let identifiers = OSAllocatedUnfairLock(initialState: [UInt64]())

        for value in 0..<2_048 {
            XCTAssertTrue(worker.enqueue {
                order.withLock { values in
                    values.append(value)
                }
                identifiers.withLock { values in
                    values.append(currentDarwinThreadIdentifier())
                }
            })
        }

        worker.requestShutdown()
        let didStop = await worker.waitUntilStopped(timeout: 2)
        XCTAssertTrue(didStop)
        XCTAssertEqual(order.withLock { $0 }, Array(0..<2_048))
        XCTAssertEqual(
            Set(identifiers.withLock { $0 }),
            Set([worker.threadIdentifier].compactMap { $0 })
        )
    }

    func testWorkerServicesRunLoopTimersOnTheOwnedThread() async throws {
        let worker = try PinnedThreadWorker()
        guard worker.start(
            name: "tenon.tests.run-loop",
            qualityOfService: .userInitiated,
            timeout: 1
        ) == .started else {
            return XCTFail("worker did not start")
        }

        let timerInstalled = DispatchSemaphore(value: 0)
        let timerFired = DispatchSemaphore(value: 0)
        let callbackIdentifier = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

        XCTAssertTrue(worker.enqueue {
            _ = Timer.scheduledTimer(
                withTimeInterval: 0.001,
                repeats: false
            ) { _ in
                callbackIdentifier.withLock { identifier in
                    identifier = currentDarwinThreadIdentifier()
                }
                timerFired.signal()
            }
            timerInstalled.signal()
        })

        let didInstallTimer = await waitForSignal(timerInstalled, timeout: 1)
        let didFireTimer = await waitForSignal(timerFired, timeout: 1)
        worker.requestShutdown()
        let didStop = await worker.waitUntilStopped(timeout: 1)

        XCTAssertTrue(didInstallTimer)
        XCTAssertTrue(didFireTimer)
        XCTAssertEqual(
            callbackIdentifier.withLock { $0 },
            worker.threadIdentifier
        )
        XCTAssertTrue(didStop)
    }

    func testShutdownIsBoundedDrainsWorkAndCanBeAwaitedAgain() async throws {
        let worker = try PinnedThreadWorker()
        guard worker.start(
            name: "tenon.tests.shutdown",
            qualityOfService: .utility,
            timeout: 1
        ) == .started else {
            return XCTFail("worker did not start")
        }

        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        XCTAssertTrue(worker.enqueue {
            operationStarted.signal()
            releaseOperation.wait()
        })
        let didStart = await waitForSignal(operationStarted, timeout: 1)
        XCTAssertTrue(didStart)

        worker.requestShutdown()
        worker.requestShutdown()
        let stoppedWhileBlocked = await worker.waitUntilStopped(timeout: 0.01)
        XCTAssertFalse(stoppedWhileBlocked)

        releaseOperation.signal()
        let stoppedAfterRelease = await worker.waitUntilStopped(timeout: 1)
        XCTAssertTrue(stoppedAfterRelease)

        worker.requestShutdown()
        let stoppedAgain = await worker.waitUntilStopped(timeout: 0)
        XCTAssertTrue(stoppedAgain)
    }

    func testExecutorShutdownIsIdempotentAndRejectsInvalidTimeout() async throws {
        let executor = try PinnedThreadExecutor(
            name: "tenon.tests.lifecycle",
            startupTimeout: 1
        )

        XCTAssertFalse(executor.isShutdown)
        let firstShutdown = await executor.shutdown(timeout: 1)
        XCTAssertEqual(firstShutdown, .stopped)
        XCTAssertTrue(executor.isShutdown)
        let secondShutdown = await executor.shutdown(timeout: 0)
        let invalidShutdown = await executor.shutdown(timeout: -.infinity)
        XCTAssertEqual(secondShutdown, .stopped)
        XCTAssertEqual(invalidShutdown, .invalidTimeout)
    }

    func testInvalidStartupTimeoutFailsBeforeStartingAThread() {
        XCTAssertThrowsError(
            try PinnedThreadExecutor(
                name: "tenon.tests.invalid-timeout",
                startupTimeout: -.infinity
            )
        ) { error in
            XCTAssertEqual(
                error as? PinnedThreadExecutor.StartupError,
                .invalidTimeout(-.infinity)
            )
        }
    }
}

private func currentDarwinThreadIdentifier() -> UInt64 {
    var identifier: UInt64 = 0
    precondition(pthread_threadid_np(nil, &identifier) == 0)
    return identifier
}

private func waitForSignal(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + timeout) == .success
            )
        }
    }
}
