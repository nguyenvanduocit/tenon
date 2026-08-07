import Foundation
import XCTest
@testable import TenonApp

@MainActor
final class FileDocumentIOTests: XCTestCase {
    func testCancelledLoadRetriesSamePathAndSuccessfulLoadIsNoOp() async {
        let path = "/tmp/tenon-retry.swift"
        let reader = CancelCompletingDocumentReader(retryText: "retried")
        let model = FileDocumentModel(
            io: FileDocumentIO(
                read: { request in
                    try await reader.read(request)
                },
                write: { _ in }
            )
        )

        let firstLoad = Task { @MainActor in
            await model.load(path)
        }
        await reader.waitUntilFirstReadEntered()

        firstLoad.cancel()
        await firstLoad.value
        await model.load(path)
        await model.load(path)

        let requestCount = await reader.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(model.path, path)
        XCTAssertEqual(text(in: model.state), "retried")
    }

    func testNewLoadCancelsOldLoadAndRejectsItsStaleResult() async throws {
        let firstPath = "/tmp/tenon-first.swift"
        let secondPath = "/tmp/tenon-second.swift"
        let reader = DelayedDocumentReader(
            delayedPath: firstPath,
            immediateText: "second"
        )
        let model = FileDocumentModel(
            io: FileDocumentIO(
                read: { request in
                    try await reader.read(request)
                },
                write: { _ in }
            )
        )

        let firstLoad = Task { @MainActor in
            await model.load(firstPath)
        }
        await reader.waitUntilEntered(firstPath)

        firstLoad.cancel()
        let secondLoad = Task { @MainActor in
            await model.load(secondPath)
        }
        await reader.waitUntilCancelled(firstPath)
        await waitForText("second", in: model)

        await reader.releaseDelayedRead()
        await firstLoad.value
        await secondLoad.value

        XCTAssertEqual(model.path, secondPath)
        XCTAssertEqual(text(in: model.state), "second")
    }

    func testStaleLoadFailureAfterLoadingNewPathCannotSurface() async {
        let firstPath = "/tmp/tenon-stale-load-error.swift"
        let secondPath = "/tmp/tenon-current-load.swift"
        let reader = ControlledFailingDocumentReader(
            delayedPath: firstPath,
            immediateText: "current"
        )
        let model = FileDocumentModel(
            io: FileDocumentIO(
                read: { request in
                    try await reader.read(request)
                },
                write: { _ in }
            )
        )

        let firstLoad = Task { @MainActor in
            await model.load(firstPath)
        }
        await reader.waitUntilDelayedReadEntered()

        await model.load(secondPath)
        await reader.failDelayedRead()
        await firstLoad.value

        XCTAssertEqual(model.path, secondPath)
        XCTAssertEqual(text(in: model.state), "current")
        XCTAssertNil(model.error)
    }

    func testSaveUsesSnapshotAndEditingDuringWriteRemainsDirty() async throws {
        let path = "/tmp/tenon-save-snapshot.swift"
        let writer = ControlledDocumentWriter(blockedRequestIndices: [0])
        let model = await makeTextModel(path: path, writer: writer)
        await waitForText("initial", in: model)
        model.edited("saved snapshot")

        let save = Task { @MainActor in
            await model.save()
        }
        await writer.waitUntilRequestCount(1)
        model.edited("new edit")

        await writer.release(requestAt: 0)
        await save.value

        let requests = await writer.recordedRequests()
        XCTAssertEqual(
            requests.map(\.text),
            ["saved snapshot"]
        )
        XCTAssertTrue(model.isDirty)

        model.edited("saved snapshot")
        XCTAssertFalse(model.isDirty)
    }

    func testSaveCompletionForOldPathCannotMutateNewDocument() async throws {
        let firstPath = "/tmp/tenon-save-old.swift"
        let secondPath = "/tmp/tenon-save-new.swift"
        let writer = ControlledDocumentWriter(blockedRequestIndices: [0])
        let io = FileDocumentIO(
            read: { request in
                .text(request.path == firstPath ? "first" : "second")
            },
            write: { request in
                try await writer.write(request)
            }
        )
        let model = FileDocumentModel(io: io)
        await model.load(firstPath)
        model.edited("first saved")

        let save = Task { @MainActor in
            await model.save()
        }
        await writer.waitUntilRequestCount(1)

        await model.load(secondPath)
        await writer.release(requestAt: 0)
        await save.value

        let savedPath = await writer.recordedRequests().first?.path
        XCTAssertEqual(savedPath, firstPath)
        XCTAssertEqual(model.path, secondPath)
        XCTAssertEqual(text(in: model.state), "second")
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.error)
    }

    func testStaleSaveFailureAfterPathSwitchCannotSurface() async throws {
        let firstPath = "/tmp/tenon-save-error-old.swift"
        let secondPath = "/tmp/tenon-save-error-current.swift"
        let writer = ControlledDocumentWriter(
            blockedRequestIndices: [0],
            failingRequestIndices: [0]
        )
        let io = FileDocumentIO(
            read: { request in
                .text(request.path == firstPath ? "first" : "current")
            },
            write: { request in
                try await writer.write(request)
            }
        )
        let model = FileDocumentModel(io: io)
        await model.load(firstPath)
        model.edited("save that will fail")

        let staleSave = Task { @MainActor in
            await model.save()
        }
        await writer.waitUntilRequestCount(1)

        await model.load(secondPath)
        await writer.release(requestAt: 0)
        await staleSave.value

        XCTAssertEqual(model.path, secondPath)
        XCTAssertEqual(text(in: model.state), "current")
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.error)
    }

    func testSerializedWritesMakeNewestSnapshotWin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("document.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("initial".utf8).write(to: file)

        let writer = ControlledDocumentWriter(
            blockedRequestIndices: [0],
            writesToDisk: true
        )
        let model = await makeTextModel(path: file.path, writer: writer)
        await waitForText("initial", in: model)
        model.edited("second")

        let firstSave = Task { @MainActor in
            await model.save()
        }
        await writer.waitUntilRequestCount(1)
        model.edited("third")
        let secondSave = Task { @MainActor in
            await model.save()
        }
        await yieldForPendingMainActorWork()

        let blockedRequestCount = await writer.requestCount()
        XCTAssertEqual(blockedRequestCount, 1)

        await writer.release(requestAt: 0)
        await firstSave.value
        await secondSave.value

        let requests = await writer.recordedRequests()
        XCTAssertEqual(
            requests.map(\.text),
            ["second", "third"]
        )
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "third"
        )
        XCTAssertFalse(model.isDirty)
    }

    func testCancelledQueuedWriteFinishesBeforeActiveWriteReleasesAndNextWriteRuns()
        async throws
    {
        let writer = ControlledDocumentWriter(blockedRequestIndices: [0])
        let io = FileDocumentIO(
            read: { _ in .text("") },
            write: { request in
                try await writer.write(request)
            }
        )
        let active = Task { @concurrent in
            try await io.write(
                FileDocumentWriteRequest(path: "/tmp/a", text: "A")
            )
        }
        await writer.waitUntilRequestCount(1)

        let queuedBStarted = AsyncSignal()
        let queuedB = Task { @concurrent in
            await queuedBStarted.signal()
            try await io.write(
                FileDocumentWriteRequest(path: "/tmp/b", text: "B")
            )
        }
        await queuedBStarted.wait()
        await yieldForPendingMainActorWork()

        let queuedCStarted = AsyncSignal()
        let queuedC = Task { @concurrent in
            await queuedCStarted.signal()
            try await io.write(
                FileDocumentWriteRequest(path: "/tmp/c", text: "C")
            )
        }
        await queuedCStarted.wait()
        await yieldForPendingMainActorWork()

        let cancelledBeforeRelease = expectation(
            description: "queued B completes cancellation before A releases"
        )
        let observeCancelledB = Task { @MainActor in
            do {
                try await queuedB.value
                XCTFail("Queued write B unexpectedly succeeded")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Queued write B failed with \(error)")
            }
            cancelledBeforeRelease.fulfill()
        }

        queuedB.cancel()
        await fulfillment(of: [cancelledBeforeRelease], timeout: 2)
        let requestCountBeforeRelease = await writer.requestCount()
        XCTAssertEqual(requestCountBeforeRelease, 1)

        await writer.release(requestAt: 0)
        try await active.value
        try await queuedC.value
        await observeCancelledB.value

        let writtenTexts = await writer.recordedRequests().map(\.text)
        XCTAssertEqual(writtenTexts, ["A", "C"])
    }

    func testReadAndWriteOperationsExecuteOffMainActor() async throws {
        let recorder = FileDocumentExecutionRecorder()
        let io = FileDocumentIO(
            read: { _ in
                await recorder.recordRead(
                    isMainThread: FileDocumentThreadProbe.isMainThread()
                )
                return .text("read")
            },
            write: { _ in
                await recorder.recordWrite(
                    isMainThread: FileDocumentThreadProbe.isMainThread()
                )
            }
        )

        _ = try await io.read(
            FileDocumentReadRequest(path: "/tmp/read", byteLimit: 16)
        )
        try await io.write(
            FileDocumentWriteRequest(path: "/tmp/write", text: "write")
        )

        let observation = await recorder.observation()
        XCTAssertEqual(observation.readWasOnMainThread, false)
        XCTAssertEqual(observation.writeWasOnMainThread, false)
    }

    func testLiveWriterAtomicallyReplacesFileWithoutLeavingTemporaryFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("document.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: file)

        try await FileDocumentIO.live.write(
            FileDocumentWriteRequest(path: file.path, text: "new")
        )

        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "new"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["document.swift"]
        )
    }

    func testLiveReaderAcceptsExactByteLimitAndRejectsOneByteOver() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let exact = root.appendingPathComponent("exact.txt")
        let oversized = root.appendingPathComponent("oversized.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x61, count: 8_000_000).write(to: exact)
        try Data(repeating: 0x61, count: 8_000_001).write(to: oversized)

        let exactResult = try await FileDocumentIO.live.read(
            FileDocumentReadRequest(path: exact.path, byteLimit: 8_000_000)
        )
        let oversizedResult = try await FileDocumentIO.live.read(
            FileDocumentReadRequest(
                path: oversized.path,
                byteLimit: 8_000_000
            )
        )

        XCTAssertEqual(text(in: exactResult)?.utf8.count, 8_000_000)
        guard case let .unavailable(reason) = oversizedResult else {
            return XCTFail("Expected an oversized-file state")
        }
        XCTAssertEqual(reason, "oversized.txt is larger than 8 MB.")
    }

    private func makeTextModel(
        path: String,
        writer: ControlledDocumentWriter
    ) async -> FileDocumentModel {
        let model = FileDocumentModel(
            io: FileDocumentIO(
                read: { _ in .text("initial") },
                write: { request in
                    try await writer.write(request)
                }
            )
        )
        await model.load(path)
        return model
    }

    private func waitForText(
        _ expected: String,
        in model: FileDocumentModel
    ) async {
        for _ in 0 ..< 1_000 {
            if text(in: model.state) == expected {
                return
            }
            await Task.yield()
        }
        XCTFail("Model never loaded expected text: \(expected)")
    }

    private func yieldForPendingMainActorWork() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    private func text(in state: FileDocumentModel.State) -> String? {
        guard case let .text(text) = state else {
            return nil
        }
        return text
    }

    private func text(in result: FileDocumentReadResult) -> String? {
        guard case let .text(text) = result else {
            return nil
        }
        return text
    }
}

private actor CancelCompletingDocumentReader {
    private let retryText: String
    private var requests = 0
    private var firstReadEntered = false
    private var firstReadEnteredWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var firstReadContinuation: CheckedContinuation<Void, Never>?
    private var firstReadWasCancelled = false

    init(retryText: String) {
        self.retryText = retryText
    }

    func read(
        _ request: FileDocumentReadRequest
    ) async throws -> FileDocumentReadResult {
        requests += 1
        guard requests == 1 else {
            return .text(retryText)
        }

        firstReadEntered = true
        firstReadEnteredWaiters.forEach { $0.resume() }
        firstReadEnteredWaiters.removeAll()

        await withTaskCancellationHandler {
            await waitForFirstReadCancellation()
        } onCancel: {
            Task {
                await self.finishCancelledFirstRead()
            }
        }
        return .text("cancelled stale text")
    }

    func waitUntilFirstReadEntered() async {
        guard !firstReadEntered else {
            return
        }
        await withCheckedContinuation { continuation in
            firstReadEnteredWaiters.append(continuation)
        }
    }

    func requestCount() -> Int {
        requests
    }

    private func waitForFirstReadCancellation() async {
        guard !firstReadWasCancelled else {
            return
        }
        await withCheckedContinuation { continuation in
            firstReadContinuation = continuation
        }
    }

    private func finishCancelledFirstRead() {
        firstReadWasCancelled = true
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }
}

private actor DelayedDocumentReader {
    private let delayedPath: String
    private let immediateText: String
    private var enteredPaths: Set<String> = []
    private var cancelledPaths: Set<String> = []
    private var enteredWaiters: [
        String: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var cancelledWaiters: [
        String: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var delayedReadContinuation: CheckedContinuation<Void, Never>?
    private var delayedReadWasReleased = false

    init(delayedPath: String, immediateText: String) {
        self.delayedPath = delayedPath
        self.immediateText = immediateText
    }

    func read(
        _ request: FileDocumentReadRequest
    ) async throws -> FileDocumentReadResult {
        markEntered(request.path)
        guard request.path == delayedPath else {
            return .text(immediateText)
        }

        await withTaskCancellationHandler {
            await waitForDelayedRelease()
        } onCancel: {
            Task {
                await self.markCancelled(request.path)
            }
        }
        return .text("stale first")
    }

    func waitUntilEntered(_ path: String) async {
        guard !enteredPaths.contains(path) else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters[path, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ path: String) async {
        guard !cancelledPaths.contains(path) else {
            return
        }
        await withCheckedContinuation { continuation in
            cancelledWaiters[path, default: []].append(continuation)
        }
    }

    func releaseDelayedRead() {
        delayedReadWasReleased = true
        delayedReadContinuation?.resume()
        delayedReadContinuation = nil
    }

    private func waitForDelayedRelease() async {
        guard !delayedReadWasReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            delayedReadContinuation = continuation
        }
    }

    private func markEntered(_ path: String) {
        enteredPaths.insert(path)
        enteredWaiters.removeValue(forKey: path)?.forEach {
            $0.resume()
        }
    }

    private func markCancelled(_ path: String) {
        cancelledPaths.insert(path)
        cancelledWaiters.removeValue(forKey: path)?.forEach {
            $0.resume()
        }
    }
}

private actor ControlledFailingDocumentReader {
    private let delayedPath: String
    private let immediateText: String
    private var delayedReadEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var delayedReadContinuation: CheckedContinuation<Void, Never>?
    private var delayedReadWasFailed = false

    init(delayedPath: String, immediateText: String) {
        self.delayedPath = delayedPath
        self.immediateText = immediateText
    }

    func read(
        _ request: FileDocumentReadRequest
    ) async throws -> FileDocumentReadResult {
        guard request.path == delayedPath else {
            return .text(immediateText)
        }

        delayedReadEntered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await waitForFailure()
        throw FileDocumentTestError.staleLoad
    }

    func waitUntilDelayedReadEntered() async {
        guard !delayedReadEntered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func failDelayedRead() {
        delayedReadWasFailed = true
        delayedReadContinuation?.resume()
        delayedReadContinuation = nil
    }

    private func waitForFailure() async {
        guard !delayedReadWasFailed else {
            return
        }
        await withCheckedContinuation { continuation in
            delayedReadContinuation = continuation
        }
    }
}

private actor ControlledDocumentWriter {
    private let blockedRequestIndices: Set<Int>
    private let failingRequestIndices: Set<Int>
    private let writesToDisk: Bool
    private var requests: [FileDocumentWriteRequest] = []
    private var releaseContinuations: [
        Int: CheckedContinuation<Void, Never>
    ] = [:]
    private var releasedIndices: Set<Int> = []
    private var countWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]

    init(
        blockedRequestIndices: Set<Int>,
        failingRequestIndices: Set<Int> = [],
        writesToDisk: Bool = false
    ) {
        self.blockedRequestIndices = blockedRequestIndices
        self.failingRequestIndices = failingRequestIndices
        self.writesToDisk = writesToDisk
    }

    func write(_ request: FileDocumentWriteRequest) async throws {
        let index = requests.count
        requests.append(request)
        resumeCountWaiters()

        if blockedRequestIndices.contains(index),
           !releasedIndices.contains(index)
        {
            await withCheckedContinuation { continuation in
                releaseContinuations[index] = continuation
            }
        }

        if failingRequestIndices.contains(index) {
            throw FileDocumentTestError.staleSave
        }

        if writesToDisk {
            try Data(request.text.utf8).write(
                to: URL(fileURLWithPath: request.path),
                options: .atomic
            )
        }
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard requests.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters[count, default: []].append(continuation)
        }
    }

    func release(requestAt index: Int) {
        releasedIndices.insert(index)
        releaseContinuations.removeValue(forKey: index)?.resume()
    }

    func requestCount() -> Int {
        requests.count
    }

    func recordedRequests() -> [FileDocumentWriteRequest] {
        requests
    }

    private func resumeCountWaiters() {
        let readyCounts = countWaiters.keys.filter {
            requests.count >= $0
        }
        for count in readyCounts {
            countWaiters.removeValue(forKey: count)?.forEach {
                $0.resume()
            }
        }
    }
}

private actor AsyncSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else {
            return
        }
        isSignalled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignalled else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor FileDocumentExecutionRecorder {
    struct Observation: Sendable {
        let readWasOnMainThread: Bool?
        let writeWasOnMainThread: Bool?
    }

    private var readWasOnMainThread: Bool?
    private var writeWasOnMainThread: Bool?

    func recordRead(isMainThread: Bool) {
        readWasOnMainThread = isMainThread
    }

    func recordWrite(isMainThread: Bool) {
        writeWasOnMainThread = isMainThread
    }

    func observation() -> Observation {
        Observation(
            readWasOnMainThread: readWasOnMainThread,
            writeWasOnMainThread: writeWasOnMainThread
        )
    }
}

private enum FileDocumentThreadProbe {
    static func isMainThread() -> Bool {
        Thread.isMainThread
    }
}

private enum FileDocumentTestError: LocalizedError {
    case staleLoad
    case staleSave

    var errorDescription: String? {
        switch self {
        case .staleLoad:
            "Stale load failed."
        case .staleSave:
            "Stale save failed."
        }
    }
}
