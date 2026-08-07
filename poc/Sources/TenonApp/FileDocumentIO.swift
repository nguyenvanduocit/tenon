// @domain: editor-and-diff
import CoreGraphics
import Foundation
import ImageIO

struct FileDocumentReadRequest: Sendable, Equatable {
    let path: String
    let byteLimit: Int
}

enum FileDocumentReadResult: Sendable {
    case text(String)
    case image(CGImage)
    case unavailable(String)
}

struct FileDocumentWriteRequest: Sendable, Equatable {
    let path: String
    let text: String
}

/// DIRECT host I/O for one editor document. The closures are injectable so lifecycle
/// races are deterministic in tests; the live implementation performs every blocking
/// filesystem and decode operation away from MainActor.
struct FileDocumentIO: Sendable {
    typealias Read = @Sendable (
        FileDocumentReadRequest
    ) async throws -> FileDocumentReadResult
    typealias Write = @Sendable (
        FileDocumentWriteRequest
    ) async throws -> Void

    static let live = FileDocumentIO(
        read: { request in
            try await FileDocumentLiveIO.read(request)
        },
        write: { request in
            try await FileDocumentLiveIO.write(request)
        }
    )

    private let readOperation: Read
    private let writer: FileDocumentWriteCoordinator

    init(
        read: @escaping Read,
        write: @escaping Write
    ) {
        readOperation = read
        writer = FileDocumentWriteCoordinator(write: write)
    }

    func read(
        _ request: FileDocumentReadRequest
    ) async throws -> FileDocumentReadResult {
        try await readOperation(request)
    }

    func write(_ request: FileDocumentWriteRequest) async throws {
        try await writer.write(request)
    }
}

private enum FileDocumentLiveIO {
    @concurrent
    static func read(
        _ request: FileDocumentReadRequest
    ) async throws -> FileDocumentReadResult {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: request.path)

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(
               source,
               0,
               [
                   kCGImageSourceShouldCache: true,
                   kCGImageSourceShouldCacheImmediately: true,
               ] as CFDictionary
           )
        {
            try Task.checkCancellation()
            return .image(image)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FileDocumentIOError.couldNotOpen(
                (request.path as NSString).lastPathComponent
            )
        }
        defer { try? handle.close() }

        let readLimit = request.byteLimit == .max
            ? Int.max
            : request.byteLimit + 1
        let data = try handle.read(upToCount: readLimit) ?? Data()
        try Task.checkCancellation()

        let fileName = (request.path as NSString).lastPathComponent
        guard data.count <= request.byteLimit else {
            return .unavailable(
                "\(fileName) is larger than 8 MB."
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unavailable("\(fileName) isn't UTF-8 text.")
        }
        return .text(text)
    }

    @concurrent
    static func write(_ request: FileDocumentWriteRequest) async throws {
        try Task.checkCancellation()
        try Data(request.text.utf8).write(
            to: URL(fileURLWithPath: request.path),
            options: .atomic
        )
    }
}

private actor FileDocumentWriteCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let writeOperation: FileDocumentIO.Write
    private var isWriting = false
    private var waiters: [Waiter] = []

    init(write: @escaping FileDocumentIO.Write) {
        writeOperation = write
    }

    func write(_ request: FileDocumentWriteRequest) async throws {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await writeOperation(request)
    }

    private func acquire() async throws {
        guard isWriting else {
            isWriting = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(
                    Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            isWriting = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}

private enum FileDocumentIOError: LocalizedError, Sendable {
    case couldNotOpen(String)

    var errorDescription: String? {
        switch self {
        case let .couldNotOpen(fileName):
            "Couldn't open \(fileName)."
        }
    }
}
