import Foundation
@testable import TenonCore
@testable import TenonIntentCore
import os
import XCTest

@MainActor
final class PluginRuntimeConcurrencyTests: XCTestCase {
    func testCallbackMailboxCoalescesRepeatedTimerTicksWithinItsFiniteCapacity() {
        let mailbox = PluginRuntimeCallbackMailbox(capacity: 2)

        XCTAssertEqual(mailbox.enqueue(.timerFired(handle: 7)), .enqueued)
        XCTAssertEqual(mailbox.enqueue(.timerFired(handle: 7)), .coalesced)
        XCTAssertEqual(mailbox.enqueue(.cancelProvider(callToken: "call-1")), .enqueued)

        let batch = mailbox.drain()
        XCTAssertFalse(batch.overflowed)
        XCTAssertEqual(batch.events.count, 2)
        guard case let .timerFired(handle) = batch.events.first else {
            return XCTFail("first callback was not the coalesced timer tick")
        }
        XCTAssertEqual(handle, 7)
        mailbox.close()
    }

    func testCallbackMailboxMakesLifecycleCallbackOverflowExplicitAndDropsPartialBatch() {
        let mailbox = PluginRuntimeCallbackMailbox(capacity: 1)

        XCTAssertEqual(mailbox.enqueue(.cancelProvider(callToken: "call-1")), .enqueued)
        XCTAssertEqual(
            mailbox.enqueue(.processTerminated(handle: 3, status: 0)),
            .overflowed
        )

        let batch = mailbox.drain()
        XCTAssertTrue(batch.overflowed)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(mailbox.enqueue(.timerFired(handle: 7)), .overflowed)
        mailbox.close()
        XCTAssertEqual(mailbox.enqueue(.timerFired(handle: 7)), .closed)
    }

    func testProductionCallbackCapacityAccepts256AndRejects257WithoutPartialDelivery() {
        let mailbox = PluginRuntimeCallbackMailbox()

        for index in 0 ..< 256 {
            XCTAssertEqual(
                mailbox.enqueue(.cancelProvider(callToken: "call-\(index)")),
                .enqueued
            )
        }
        XCTAssertEqual(
            mailbox.enqueue(.processTerminated(handle: 257, status: 0)),
            .overflowed
        )

        let batch = mailbox.drain()
        XCTAssertTrue(batch.overflowed)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(
            mailbox.enqueue(.cancelProvider(callToken: "late")),
            .overflowed
        )
        mailbox.close()
    }

    func testCallbackMailboxOverflowFailsGenerationAndStopsOwnedResources() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.timers.every(10, () => {});
            """,
            callbackCapacity: 0
        )

        let started = try await runtime.start()
        XCTAssertEqual(started.snapshot.phase, .active)
        let failed = await eventually {
            await runtime.snapshot().phase == .failed
        }
        XCTAssertTrue(failed)

        let resources = await runtime.resourceCounts
        XCTAssertEqual(resources.timers, 0)
        XCTAssertEqual(resources.processes, 0)
        XCTAssertEqual(resources.watchers, 0)

        _ = await runtime.shutdown()
    }

    func testFailureClearsNativeEventSubscriptions() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.events.on("workspace.changed", function () {});
            tenon.timers.every(10, function () {});
            """,
            callbackCapacity: 0
        )

        _ = try await runtime.start()
        var handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertTrue(handlesEvent)
        let failed = await eventually {
            await runtime.snapshot().phase == .failed
        }
        XCTAssertTrue(failed)

        handlesEvent = await runtime.handles(event: "workspace.changed")
        XCTAssertFalse(handlesEvent)
        _ = await runtime.shutdown()
    }

    func testProcessCapacityRejectionTerminallyRemovesJavaScriptHandler() async throws {
        let runtime = try makeRuntime(
            source: """
            for (let index = 0; index < 33; index += 1) {
              tenon.process.stream("/bin/sleep", ["5"], {});
            }
            """,
            permissions: ["process.exec"]
        )

        _ = try await runtime.start()
        let rejectedHandlerRetired = try await runtime.evaluateForTesting(
            "__tenonProcessExit(33, 0)"
        )
        XCTAssertEqual(rejectedHandlerRetired, .bool(false))
        let processCount = await runtime.resourceCounts.processes
        XCTAssertEqual(processCount, 32)
        _ = await runtime.shutdown()
    }

    func testProcessRunFailureDeliversOneTerminalExitAndRetiresHandler() async throws {
        let runtime = try makeRuntime(
            source: """
            globalThis.__processExitCount = 0;
            globalThis.__processExitStatus = null;
            tenon.process.stream("/irrelevant/injected-failure", [], {
              onExit: function (status) {
                globalThis.__processExitCount += 1;
                globalThis.__processExitStatus = status;
                tenon.statusBar.set(
                  "exit:" + status + ":" + globalThis.__processExitCount
                );
              }
            });
            """,
            permissions: ["process.exec"],
            processRun: { _ in
                throw DeterministicResourceStartError.processRun
            }
        )

        _ = try await runtime.start()
        let exitDelivered = await eventually {
            await runtime.snapshot().statusBarText == "exit:-1:1"
        }
        XCTAssertTrue(exitDelivered)
        let processState = try await runtime.evaluateForTesting(
            "[globalThis.__processExitStatus, globalThis.__processExitCount]"
        )
        XCTAssertEqual(processState, .array([.integer(-1), .integer(1)]))
        let handlerRetired = try await runtime.evaluateForTesting(
            "__tenonProcessExit(1, 0)"
        )
        XCTAssertEqual(handlerRetired, .bool(false))
        let processCount = await runtime.resourceCounts.processes
        XCTAssertEqual(processCount, 0)
        _ = await runtime.shutdown()
    }

    func testWatcherCapacityRejectionTerminallyRemovesJavaScriptHandler() async throws {
        let runtime = try makeRuntime(
            source: """
            for (let index = 0; index < 65; index += 1) {
              tenon.fs.watch("/tmp", () => {});
            }
            """,
            permissions: ["filesystem.read"]
        )

        _ = try await runtime.start()
        let rejectedHandlerRetired = try await runtime.evaluateForTesting(
            "__tenonWatchPaths(65, [])"
        )
        XCTAssertEqual(rejectedHandlerRetired, .bool(false))
        let watcherCount = await runtime.resourceCounts.watchers
        XCTAssertEqual(watcherCount, 64)
        _ = await runtime.shutdown()
    }

    func testWatcherStartFailureRetiresHandlerAndDropsLateCallback() async throws {
        let runtime = try makeRuntime(
            source: """
            globalThis.__watchCallbackCount = 0;
            tenon.fs.watch("/tmp", function () {
              globalThis.__watchCallbackCount += 1;
            });
            """,
            permissions: ["filesystem.read"],
            watcherStart: { _ in false }
        )

        _ = try await runtime.start()
        let watcherCount = await runtime.resourceCounts.watchers
        XCTAssertEqual(watcherCount, 0)
        let handlerRetired = try await runtime.evaluateForTesting(
            "__tenonWatchPaths(1, ['/tmp/late'])"
        )
        XCTAssertEqual(handlerRetired, .bool(false))
        let callbackCount = try await runtime.evaluateForTesting(
            "globalThis.__watchCallbackCount"
        )
        XCTAssertEqual(callbackCount, .integer(0))
        _ = await runtime.shutdown()
    }

    func testPathWatcherPendingBufferIsFiniteAndMakesOverflowSticky() {
        var buffer = PathWatcherPendingBuffer(capacity: 2)

        XCTAssertEqual(buffer.insert("/tmp/project/a"), .inserted)
        XCTAssertEqual(buffer.insert("/tmp/project/a"), .duplicate)
        XCTAssertEqual(buffer.insert("/tmp/project/b"), .inserted)
        XCTAssertEqual(buffer.insert("/tmp/project/c"), .overflowed)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.insert("/tmp/project/d"), .alreadyOverflowed)
    }

    func testProductionPathWatcherCapacityAccepts256AndRejects257WithoutPartialDelivery() {
        XCTAssertEqual(PathWatcher.maximumPendingPaths, 256)
        var buffer = PathWatcherPendingBuffer(
            capacity: PathWatcher.maximumPendingPaths
        )

        for index in 0 ..< 256 {
            XCTAssertEqual(
                buffer.insert("/tmp/project/\(index)"),
                .inserted
            )
        }
        XCTAssertEqual(buffer.count, 256)
        XCTAssertEqual(buffer.insert("/tmp/project/256"), .overflowed)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(buffer.drain().isEmpty)
        XCTAssertEqual(
            buffer.insert("/tmp/project/late"),
            .alreadyOverflowed
        )
    }

    func testPathWatcherOverflowIsExplicitAndRunsOffMainActor() async {
        let probe = PathWatcherCallbackProbe()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-path-watcher-\(UUID().uuidString)")
        let watcher = PathWatcher(
            path: root,
            recursive: true,
            label: "dev.tenon.path-watcher-tests",
            pendingCapacity: 2,
            onOverflow: {
                probe.recordOverflow(onMainThread: Thread.isMainThread)
            },
            onChange: { paths in
                probe.recordChange(paths)
            }
        )

        watcher.ingestForTesting([
            root.appendingPathComponent("a").path,
            root.appendingPathComponent("b").path,
            root.appendingPathComponent("c").path,
        ])

        let overflowDelivered = await eventually {
            probe.snapshot().overflowCount == 1
        }
        XCTAssertTrue(overflowDelivered)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.overflowCount, 1)
        XCTAssertFalse(snapshot.overflowRanOnMainThread)
        XCTAssertTrue(snapshot.changedPaths.isEmpty)
        watcher.stop()
    }

    func testStateEmitterCoalescesToLatestTerminalSnapshot() async throws {
        let manifest = try PluginManifest(
            id: "dev.tenon.state-emitter-tests",
            name: "state-emitter-tests",
            version: "1"
        )
        let gate = SnapshotSinkGate()
        let emitter = PluginRuntimeStateEmitter { snapshot in
            await gate.consume(snapshot)
        }

        emitter.emit(
            runtimeSnapshot(revision: 1, phase: .active, manifest: manifest)
        )
        await gate.waitUntilFirstDeliveryStarts()
        emitter.emit(
            runtimeSnapshot(revision: 2, phase: .active, manifest: manifest)
        )
        emitter.emit(
            runtimeSnapshot(revision: 3, phase: .failed, manifest: manifest)
        )
        await gate.releaseFirstDelivery()
        await emitter.finish()

        let delivered = await gate.snapshots()
        XCTAssertEqual(delivered.map(\.revision), [1, 3])
        XCTAssertEqual(delivered.last?.phase, .failed)
    }

    func testProviderPromiseUsesContextOwnedNestedSendAndOnePinnedThread() async throws {
        let provided = try IntentID("dev.tenon.runtime.work.v1")
        let nested = try IntentID("dev.tenon.runtime.nested.v1")
        let nestedProvider = try ProviderID("dev.tenon.runtime.nested")
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("dev.tenon.runtime.work.v1", async (input, call) => {
              call.progress({ completed: 1, total: 2, message: "nested" });
              const result = await call.send(
                "dev.tenon.runtime.nested.v1",
                { value: input.value },
                {
                  timeoutMs: 250,
                  idempotencyKey: "same",
                  target: { providerID: "dev.tenon.runtime.nested" },
                  caller: "forged",
                  traceID: "forged",
                  parentRequestID: "forged"
                }
              );
              if (!result.ok) throw new Error(result.error.code);
              return { value: result.value.value + 1 };
            });
            """,
            uses: [nested],
            provides: [provided]
        )

        let started = try await runtime.start()
        XCTAssertEqual(started.bindings.count, 1)
        let createdThread = try XCTUnwrap(started.snapshot.runtimeThreadIdentifier)

        let requests = RequestRecorder()
        let progress = ProgressRecorder()
        let context = IntentProviderContext(
            requestID: UUID(),
            nestedSend: { request in
                await requests.record(request)
                try? await Task.sleep(for: .milliseconds(20))
                return .success(
                    value: .object(["value": .integer(41)]),
                    requestID: UUID(),
                    providerID: nestedProvider
                )
            },
            progressSink: { value in
                await progress.record(value)
            }
        )
        let envelope = try makeEnvelope(intentID: provided, input: .object(["value": .integer(41)]))

        let reply = try await started.bindings[0].invoke(
            envelope: envelope,
            context: context
        )
        XCTAssertEqual(reply, .success(.object(["value": .integer(42)])))

        let recordedRequest = await requests.snapshot()
        let recorded = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(recorded.intentID, nested)
        XCTAssertEqual(recorded.target, nestedProvider)
        XCTAssertEqual(recorded.idempotencyKey, "same")
        XCTAssertEqual(recorded.requestedTimeout, .milliseconds(250))
        let progressValues = await progress.snapshot()
        XCTAssertEqual(progressValues.count, 1)
        let completedSnapshot = await runtime.snapshot()
        XCTAssertEqual(completedSnapshot.pendingNestedIntentCount, 0)

        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(report.createdThreadIdentifier, createdThread)
        XCTAssertEqual(report.destroyedThreadIdentifier, createdThread)
    }

    func testCancellationSettlesOnceAndCountsLateJavaScriptReply() async throws {
        let provided = try IntentID("dev.tenon.runtime.slow.v1")
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("dev.tenon.runtime.slow.v1", async () => {
              await new Promise(resolve => tenon.timers.after(40, resolve));
              return { tooLate: true };
            });
            """,
            provides: [provided]
        )

        let started = try await runtime.start()
        let context = IntentProviderContext(
            requestID: UUID(),
            nestedSend: { _ in
                return Self.failureResult()
            }
        )
        let envelope = try makeEnvelope(intentID: provided)
        let invocation = Task {
            try await started.bindings[0].invoke(envelope: envelope, context: context)
        }

        try await Task.sleep(for: .milliseconds(5))
        invocation.cancel()
        do {
            _ = try await invocation.value
            XCTFail("cancelled invocation unexpectedly returned a reply")
        } catch is CancellationError {
            // Expected: cancellation removes and resumes the Swift continuation once.
        }

        let lateReplyObserved = await eventually {
            await runtime.snapshot().lateProviderReplyCount == 1
        }
        XCTAssertTrue(lateReplyObserved)

        let report = await runtime.shutdown()
        XCTAssertEqual(report.lateProviderReplyCount, 1)
        XCTAssertEqual(report.cancelledProviderCalls, 0)
        XCTAssertEqual(report.createdThreadIdentifier, report.destroyedThreadIdentifier)
    }

    func testCancellationPropagatesToNestedSendAndCleansBothBridges() async throws {
        let provided = try IntentID("dev.tenon.runtime.cancellable.v1")
        let nested = try IntentID("dev.tenon.runtime.blocked.v1")
        let runtime = try makeRuntime(
            source: """
            globalThis.__tenonNestedSettled = false;
            tenon.intents.handle("dev.tenon.runtime.cancellable.v1", async (_, call) => {
              const result = await call.send("dev.tenon.runtime.blocked.v1", {});
              globalThis.__tenonNestedSettled = true;
              return { nestedOK: result.ok };
            });
            """,
            uses: [nested],
            provides: [provided]
        )

        let started = try await runtime.start()
        let probe = NestedCancellationProbe()
        let context = IntentProviderContext(
            requestID: UUID(),
            nestedSend: { _ in
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(2))
                    await probe.markCompleted()
                    return Self.failureResult()
                } catch is CancellationError {
                    await probe.markCancelled(taskWasCancelled: Task.isCancelled)
                    return Self.failureResult()
                } catch {
                    await probe.markCompleted()
                    return Self.failureResult()
                }
            }
        )
        let envelope = try makeEnvelope(intentID: provided)
        let invocation = Task {
            try await started.bindings[0].invoke(
                envelope: envelope,
                context: context
            )
        }

        await probe.waitUntilStarted()
        let runningSnapshot = await runtime.snapshot()
        XCTAssertEqual(runningSnapshot.pendingNestedIntentCount, 1)
        invocation.cancel()

        do {
            _ = try await invocation.value
            XCTFail("cancelled invocation unexpectedly returned a reply")
        } catch is CancellationError {
            // Expected: outer cancellation owns and cancels the nested task.
        }

        await probe.waitUntilTerminal()
        let probeSnapshot = await probe.snapshot()
        XCTAssertTrue(probeSnapshot.taskWasCancelled)
        XCTAssertFalse(probeSnapshot.completed)
        let cancelledSnapshot = await runtime.snapshot()
        XCTAssertEqual(cancelledSnapshot.pendingNestedIntentCount, 0)

        let javaScriptPromiseReleased = await eventually {
            do {
                return try await runtime.evaluateForTesting(
                    "globalThis.__tenonNestedSettled === true"
                ) == .bool(true)
            } catch {
                return false
            }
        }
        XCTAssertTrue(javaScriptPromiseReleased)

        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(report.createdThreadIdentifier, report.destroyedThreadIdentifier)
    }

    func testCancelledNeverSettlingProviderReleasesJavaScriptCallState() async throws {
        let provided = try IntentID("dev.tenon.runtime.never.v1")
        let runtime = try makeRuntime(
            source: """
            globalThis.__neverStarted = false;
            tenon.intents.handle("dev.tenon.runtime.never.v1", async () => {
              globalThis.__neverStarted = true;
              await new Promise(() => {});
              return null;
            });
            """,
            provides: [provided]
        )
        let started = try await runtime.start()
        let envelope = try makeEnvelope(intentID: provided)
        let invocation = Task {
            try await started.bindings[0].invoke(
                envelope: envelope,
                context: IntentProviderContext(
                    requestID: envelope.requestID,
                    nestedSend: { _ in Self.failureResult() }
                )
            )
        }
        let neverStarted = await eventually {
            do {
                return try await runtime.evaluateForTesting(
                    "globalThis.__neverStarted"
                ) == .bool(true)
            } catch {
                return false
            }
        }
        XCTAssertTrue(neverStarted)

        invocation.cancel()
        do {
            _ = try await invocation.value
            XCTFail("cancelled invocation unexpectedly returned")
        } catch is CancellationError {
            // Expected.
        }
        let retained = try await runtime.evaluateForTesting(
            "__tenonCancelProvider('\(envelope.requestID.uuidString)')"
        )
        XCTAssertEqual(retained, .bool(false))
        _ = await runtime.shutdown()
    }

    func testPluginCannotDeleteRuntimeCancellationHook() async throws {
        let provided = try IntentID("dev.tenon.runtime.tamper.v1")
        let nested = try IntentID("dev.tenon.runtime.tamper-nested.v1")
        let runtime = try makeRuntime(
            source: """
            globalThis.__nestedSettledAfterTamper = false;
            delete globalThis.__tenonCancelProvider;
            tenon.intents.handle("dev.tenon.runtime.tamper.v1", async (_, call) => {
              await call.send("dev.tenon.runtime.tamper-nested.v1", {});
              globalThis.__nestedSettledAfterTamper = true;
              return null;
            });
            """,
            uses: [nested],
            provides: [provided]
        )
        let started = try await runtime.start()
        let cancellationHookIsConfigurable = try await runtime.evaluateForTesting(
            "Object.getOwnPropertyDescriptor(globalThis, '__tenonCancelProvider').configurable"
        )
        XCTAssertEqual(
            cancellationHookIsConfigurable,
            .bool(false)
        )
        let probe = NestedCancellationProbe()
        let envelope = try makeEnvelope(intentID: provided)
        let invocation = Task {
            try await started.bindings[0].invoke(
                envelope: envelope,
                context: IntentProviderContext(
                    requestID: envelope.requestID,
                    nestedSend: { _ in
                        await probe.markStarted()
                        do {
                            try await Task.sleep(for: .seconds(2))
                            await probe.markCompleted()
                        } catch is CancellationError {
                            await probe.markCancelled(taskWasCancelled: Task.isCancelled)
                        } catch {
                            await probe.markCompleted()
                        }
                        return Self.failureResult()
                    }
                )
            )
        }

        await probe.waitUntilStarted()
        invocation.cancel()
        do {
            _ = try await invocation.value
            XCTFail("cancelled invocation unexpectedly returned")
        } catch is CancellationError {
            // Expected.
        }
        await probe.waitUntilTerminal()
        let nestedSettled = await eventually {
            do {
                return try await runtime.evaluateForTesting(
                    "globalThis.__nestedSettledAfterTamper"
                ) == .bool(true)
            } catch {
                return false
            }
        }
        XCTAssertTrue(nestedSettled)
        _ = await runtime.shutdown()
    }

    func testProviderProgressWorkerIsCancelledWithOuterCall() async throws {
        let provided = try IntentID("dev.tenon.runtime.progress-lifetime.v1")
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("dev.tenon.runtime.progress-lifetime.v1", async (_, call) => {
              call.progress({ completed: 1, total: 2 });
              await new Promise(() => {});
              return null;
            });
            """,
            provides: [provided]
        )
        let started = try await runtime.start()
        let progressProbe = ProgressLifetimeProbe()
        let envelope = try makeEnvelope(intentID: provided)
        let invocation = Task {
            try await started.bindings[0].invoke(
                envelope: envelope,
                context: IntentProviderContext(
                    requestID: envelope.requestID,
                    nestedSend: { _ in Self.failureResult() },
                    progressSink: { _ in
                        await progressProbe.beginDelivery()
                    }
                )
            )
        }

        await progressProbe.waitUntilStarted()
        invocation.cancel()
        do {
            _ = try await invocation.value
            XCTFail("cancelled invocation unexpectedly returned")
        } catch is CancellationError {
            // Expected.
        }
        await progressProbe.releaseDelivery()
        await progressProbe.waitUntilFinished()
        let progressTaskWasCancelled = await progressProbe.wasTaskCancelled()
        XCTAssertTrue(progressTaskWasCancelled)
        _ = await runtime.shutdown()
    }

    func testProcessCallbacksHopBackToRuntimeBeforeTouchingJavaScript() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.process.stream("/usr/bin/printf", ["callback-ok"], {
              onStdout(chunk) { tenon.statusBar.set(chunk); },
              onExit(status) { tenon.storage.set("exit", status); }
            });
            """,
            permissions: ["process.exec"]
        )

        _ = try await runtime.start()
        let receivedOutput = await eventually {
            await runtime.snapshot().statusBarText == "callback-ok"
        }
        XCTAssertTrue(receivedOutput)

        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(report.createdThreadIdentifier, report.destroyedThreadIdentifier)
    }

    func testConcurrentPromiseSettlementStressStaysLossless() async throws {
        let provided = try IntentID("dev.tenon.runtime.stress.v1")
        let nested = try IntentID("dev.tenon.runtime.echo.v1")
        let nestedProvider = try ProviderID("dev.tenon.runtime.echo")
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("dev.tenon.runtime.stress.v1", async (input, call) => {
              const result = await call.send("dev.tenon.runtime.echo.v1", input);
              if (!result.ok) throw new Error(result.error.code);
              return result.value;
            });
            """,
            uses: [nested],
            provides: [provided]
        )
        let started = try await runtime.start()
        let binding = started.bindings[0]

        var invocations: [(IntentEnvelope, IntentProviderContext)] = []
        for value in 0 ..< 200 {
            let envelope = try makeEnvelope(
                intentID: provided,
                input: .object(["value": .integer(Int64(value))])
            )
            let context = IntentProviderContext(
                requestID: envelope.requestID,
                nestedSend: { request in
                    .success(
                        value: request.input,
                        requestID: UUID(),
                        providerID: nestedProvider
                    )
                }
            )
            invocations.append((envelope, context))
        }

        let replies = try await withThrowingTaskGroup(
            of: IntentProviderReply.self,
            returning: [IntentProviderReply].self
        ) { group in
            for invocation in invocations {
                group.addTask {
                    try await binding.invoke(
                        envelope: invocation.0,
                        context: invocation.1
                    )
                }
            }
            var results: [IntentProviderReply] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(replies.count, 200)
        XCTAssertEqual(
            Set(replies.compactMap { reply -> Int64? in
                guard case let .success(.object(object)) = reply,
                      case let .integer(value)? = object["value"]
                else {
                    return nil
                }
                return value
            }),
            Set((0 ..< 200).map(Int64.init))
        )

        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(report.lateProviderReplyCount, 0)
    }

    func testMissingHandleBindingFailsStagingContract() async throws {
        let provided = try IntentID("dev.tenon.runtime.late.v1")
        let runtime = try makeRuntime(
            source: """
            tenon.timers.after(1, () => {
              tenon.intents.handle("dev.tenon.runtime.late.v1", async () => null);
            });
            """,
            provides: [provided]
        )

        do {
            _ = try await runtime.start()
            XCTFail("missing staging handler unexpectedly activated")
        } catch let error as PluginRuntimeError {
            XCTAssertEqual(error, .missingIntentHandlers([provided]))
        }

        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(report.createdThreadIdentifier, report.destroyedThreadIdentifier)
    }

    func testStagingFailureRollsBackEveryPrecreatedResource() async throws {
        let provided = try IntentID("dev.tenon.runtime.missing.v1")
        let runtime = try makeRuntime(
            source: """
            tenon.timers.every(10, function () {});
            """,
            provides: [provided]
        )

        do {
            _ = try await runtime.start()
            XCTFail("missing staging handler unexpectedly activated")
        } catch let error as PluginRuntimeError {
            XCTAssertEqual(error, .missingIntentHandlers([provided]))
        }

        let resources = await runtime.resourceCounts
        XCTAssertEqual(resources.timers, 0)
        XCTAssertEqual(resources.processes, 0)
        XCTAssertEqual(resources.watchers, 0)
        _ = await runtime.shutdown()
    }

    func testLateHandleBindingTransitionsActiveRuntimeToFailed() async throws {
        let provided = try IntentID("dev.tenon.runtime.late.v1")
        let runtime = try makeRuntime(
            source: """
            tenon.intents.handle("dev.tenon.runtime.late.v1", async () => null);
            tenon.timers.after(5, () => {
              tenon.intents.handle("dev.tenon.runtime.late.v1", async () => null);
            });
            """,
            provides: [provided]
        )

        _ = try await runtime.start()
        let failed = await eventually {
            await runtime.snapshot().phase == .failed
        }
        XCTAssertTrue(failed)

        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(report.createdThreadIdentifier, report.destroyedThreadIdentifier)
    }
}

private extension PluginRuntimeConcurrencyTests {
    actor SnapshotSinkGate {
        private var delivered: [PluginRuntimeSnapshot] = []
        private var firstDeliveryStarted = false
        private var firstDeliveryReleased = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func consume(_ snapshot: PluginRuntimeSnapshot) async {
            delivered.append(snapshot)
            guard !firstDeliveryStarted else { return }
            firstDeliveryStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            guard !firstDeliveryReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilFirstDeliveryStarts() async {
            guard !firstDeliveryStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func releaseFirstDelivery() {
            firstDeliveryReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func snapshots() -> [PluginRuntimeSnapshot] {
            delivered
        }
    }

    final class PathWatcherCallbackProbe: Sendable {
        struct Snapshot {
            let overflowCount: Int
            let overflowRanOnMainThread: Bool
            let changedPaths: [String]
        }

        private struct State {
            var overflowCount = 0
            var overflowRanOnMainThread = false
            var changedPaths: [String] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func recordOverflow(onMainThread: Bool) {
            state.withLock { state in
                state.overflowCount += 1
                state.overflowRanOnMainThread = onMainThread
            }
        }

        func recordChange(_ paths: [String]) {
            state.withLock { $0.changedPaths.append(contentsOf: paths) }
        }

        func snapshot() -> Snapshot {
            state.withLock {
                Snapshot(
                    overflowCount: $0.overflowCount,
                    overflowRanOnMainThread: $0.overflowRanOnMainThread,
                    changedPaths: $0.changedPaths
                )
            }
        }
    }

    actor RequestRecorder {
        private(set) var last: IntentProviderSendRequest?

        func record(_ request: IntentProviderSendRequest) {
            last = request
        }

        func snapshot() -> IntentProviderSendRequest? {
            last
        }
    }

    actor ProgressRecorder {
        private(set) var values: [IntentProgress] = []

        func record(_ progress: IntentProgress) {
            values.append(progress)
        }

        func snapshot() -> [IntentProgress] {
            values
        }
    }

    actor NestedCancellationProbe {
        struct Snapshot: Sendable, Equatable {
            let taskWasCancelled: Bool
            let completed: Bool
        }

        private var started = false
        private var terminal = false
        private var taskWasCancelled = false
        private var completed = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var terminalWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            guard !started else { return }
            started = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startedWaiters.append(continuation)
            }
        }

        func markCancelled(taskWasCancelled: Bool) {
            guard !terminal else { return }
            terminal = true
            self.taskWasCancelled = taskWasCancelled
            resumeTerminalWaiters()
        }

        func markCompleted() {
            guard !terminal else { return }
            terminal = true
            completed = true
            resumeTerminalWaiters()
        }

        func waitUntilTerminal() async {
            guard !terminal else { return }
            await withCheckedContinuation { continuation in
                terminalWaiters.append(continuation)
            }
        }

        private func resumeTerminalWaiters() {
            let waiters = terminalWaiters
            terminalWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func snapshot() -> Snapshot {
            Snapshot(
                taskWasCancelled: taskWasCancelled,
                completed: completed
            )
        }
    }

    actor ProgressLifetimeProbe {
        private var started = false
        private var released = false
        private var finished = false
        private var taskWasCancelled = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

        func beginDelivery() async {
            started = true
            let waitingForStart = startedWaiters
            startedWaiters.removeAll()
            for waiter in waitingForStart {
                waiter.resume()
            }
            if !released {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
            taskWasCancelled = Task.isCancelled
            finished = true
            let waitingForFinish = finishedWaiters
            finishedWaiters.removeAll()
            for waiter in waitingForFinish {
                waiter.resume()
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startedWaiters.append(continuation)
            }
        }

        func releaseDelivery() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitUntilFinished() async {
            guard !finished else { return }
            await withCheckedContinuation { continuation in
                finishedWaiters.append(continuation)
            }
        }

        func wasTaskCancelled() -> Bool {
            taskWasCancelled
        }
    }

    func makeRuntime(
        source: String,
        permissions: [String] = [],
        uses: [IntentID] = [],
        provides: [IntentID] = [],
        callbackCapacity: Int? = nil,
        processRun: @escaping @Sendable (Process) throws -> Void = {
            try $0.run()
        },
        watcherStart: @escaping @Sendable (PathWatcher) -> Bool = {
            $0.start()
        }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = try PluginManifest(
            id: PluginID("dev.tenon.runtime-tests"),
            name: "runtime-tests",
            version: "1.0.0",
            permissions: permissions,
            intents: PluginIntentManifest(
                uses: uses,
                provides: provides.map { PluginIntentProvision(name: $0) }
            )
        )
        let configuration = PluginRuntimeConfiguration(
            manifest: manifest,
            directory: directory,
            intents: PluginRuntimeIntentBridge(
                send: { _ in Self.failureResult() },
                list: { .array([]) }
            )
        )
        return try PluginRuntime(
            configuration: configuration,
            callbackCapacity: callbackCapacity ?? 256,
            processRun: processRun,
            watcherStart: watcherStart
        )
    }

    func makeEnvelope(
        intentID: IntentID,
        input: IntentValue = .null
    ) throws -> IntentEnvelope {
        IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: input,
            caller: IntentPrincipal(
                id: "test-caller",
                kind: .plugin,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: .now.advanced(by: .seconds(1)),
            target: nil,
            idempotencyKey: nil
        )
    }

    func runtimeSnapshot(
        revision: UInt64,
        phase: PluginRuntimePhase,
        manifest: PluginManifest
    ) -> PluginRuntimeSnapshot {
        PluginRuntimeSnapshot(
            revision: revision,
            manifest: manifest,
            phase: phase,
            statusBarText: nil,
            views: [],
            openViewInstances: [],
            permissionViolations: [],
            runtimeThreadIdentifier: nil,
            pendingNestedIntentCount: 0,
            lateProviderReplyCount: 0
        )
    }

    nonisolated static func failureResult() -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(.internal),
                details: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .unknown
            ),
            requestID: UUID(),
            providerID: nil
        )
    }

    func eventually(
        attempts: Int = 100,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private enum DeterministicResourceStartError: Error {
    case processRun
}
