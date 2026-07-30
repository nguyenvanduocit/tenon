import Foundation
import TenonCore
@testable import TenonIntentCore
import XCTest

final class FilesystemIntentProviderTests: XCTestCase {
    func testBindingsCoverEveryCanonicalFilesystemIntent() throws {
        let intentIDs = Set(try FilesystemIntentProvider().bindings.map(\.intentID))
        XCTAssertEqual(
            intentIDs,
            Set(
                try [
                    CoreIntentName.filesystemDirectoryList,
                    .filesystemFileRead,
                    .filesystemPathExists,
                    .filesystemFileWrite,
                    .filesystemDirectoryCreate,
                    .filesystemFileCreate,
                    .filesystemPathMove,
                    .filesystemPathTrash,
                ].map { try $0.intentID }
            )
        )
    }

    func testDirectoryListUsesBoundedCursorPages() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 23 {
            try Data().write(
                to: directory.appendingPathComponent("entry-\(index)")
            )
        }

        let provider = try FilesystemIntentProvider()
        let first = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "limit": .integer(7),
            ]),
            bindings: provider.bindings
        )
        let firstValue = try successValue(first)
        let firstObject = try object(firstValue)
        XCTAssertEqual(try array(firstObject["entries"]).count, 7)
        let firstCursor = try string(firstObject["nextCursor"])
        XCTAssertTrue(firstCursor.hasPrefix("v1:7:"))

        let second = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "cursor": .string(firstCursor),
                "limit": .integer(7),
            ]),
            bindings: provider.bindings
        )
        let secondObject = try object(try successValue(second))
        XCTAssertEqual(try array(secondObject["entries"]).count, 7)
        XCTAssertTrue(
            try string(secondObject["nextCursor"]).hasPrefix("v1:14:")
        )
    }

    func testDirectoryListLongNamesStayWithinCatalogOutputBudget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 256 {
            let name = String(format: "%03d-", index)
                + String(repeating: "x", count: 240)
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let bindings = try FilesystemIntentProvider().bindings
        let first = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "limit": .integer(256),
            ]),
            bindings: bindings
        )
        let firstValue = try successValue(first)
        try firstValue.validate()
        let firstObject = try object(firstValue)
        let firstEntries = try array(firstObject["entries"])
        XCTAssertLessThan(firstEntries.count, 256)
        let cursor = try string(firstObject["nextCursor"])
        XCTAssertTrue(cursor.hasPrefix("v1:\(firstEntries.count):"))

        let second = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "cursor": .string(cursor),
                "limit": .integer(256),
            ]),
            bindings: bindings
        )
        let secondValue = try successValue(second)
        try secondValue.validate()
        XCTAssertEqual(
            firstEntries.count
                + (try array(try object(secondValue)["entries"])).count,
            256
        )
    }

    func testAuthorizationBindingPinsSymlinkedParentDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authorizedDirectory = root.appendingPathComponent("authorized")
        let redirectedDirectory = root.appendingPathComponent("redirected")
        let link = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(
            at: authorizedDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: redirectedDirectory,
            withIntermediateDirectories: false
        )
        try Data("authorized".utf8).write(
            to: authorizedDirectory.appendingPathComponent("value.txt")
        )
        try Data("redirected".utf8).write(
            to: redirectedDirectory.appendingPathComponent("value.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: authorizedDirectory
        )

        let requestedPath = link.appendingPathComponent("value.txt").path
        let binding = try AuthorizedFilesystemPath(
            requestedPath: requestedPath
        )
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: redirectedDirectory
        )
        XCTAssertEqual(
            try binding.validatedResolvedPath(),
            authorizedDirectory.appendingPathComponent("value.txt").path
        )

        let reply = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(requestedPath)]),
            bindings: try FilesystemIntentProvider().bindings,
            authorizedPaths: [binding]
        )
        let content = try object(
            try object(try successValue(reply))["content"]
        )
        XCTAssertEqual(try string(content["text"]), "authorized")
    }

    func testDirectoryListRejectsInvalidCursorWithoutScanning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let reply = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "cursor": .string("not-a-cursor"),
            ]),
            bindings: try FilesystemIntentProvider().bindings
        )
        try assertFailure(
            reply,
            code: "dev.tenon.core.filesystem-failed",
            reason: "invalid-cursor"
        )
    }

    func testDirectoryCursorRejectsMutationBetweenPages() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("one"))
        try Data().write(to: directory.appendingPathComponent("two"))
        let bindings = try FilesystemIntentProvider().bindings

        let first = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "limit": .integer(1),
            ]),
            bindings: bindings
        )
        let cursor = try string(
            try object(try successValue(first))["nextCursor"]
        )
        try Data().write(to: directory.appendingPathComponent("three"))

        let stale = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(directory.path),
                "cursor": .string(cursor),
                "limit": .integer(1),
            ]),
            bindings: bindings
        )
        try assertFailure(
            stale,
            code: "dev.tenon.core.filesystem-failed",
            reason: "stale-cursor"
        )
    }

    func testFileReadIsBoundedAndReportsNonText() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("text.txt")
        let binaryURL = directory.appendingPathComponent("binary")
        let oversizedURL = directory.appendingPathComponent("oversized.txt")
        try Data("hello".utf8).write(to: textURL)
        try Data([0xFF, 0xFE]).write(to: binaryURL)
        try Data(
            repeating: 0x61,
            count: CoreIntentPayloadPolicy.maximumInlineTextCharacters + 1
        ).write(to: oversizedURL)

        let bindings = try FilesystemIntentProvider().bindings
        let textReply = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(textURL.path)]),
            bindings: bindings
        )
        let content = try object(
            try object(try successValue(textReply))["content"]
        )
        XCTAssertEqual(try string(content["kind"]), "inline")
        XCTAssertEqual(try string(content["text"]), "hello")
        XCTAssertEqual(try integer(content["byteCount"]), 5)

        let binaryReply = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(binaryURL.path)]),
            bindings: bindings
        )
        try assertFailure(
            binaryReply,
            code: "dev.tenon.core.content-not-text",
            reason: "content-is-not-utf8"
        )

        let oversizedReply = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(oversizedURL.path)]),
            bindings: bindings
        )
        try assertFailure(
            oversizedReply,
            code: "dev.tenon.core.filesystem-failed",
            reason: "inline-content-limit-exceeded"
        )
    }

    func testFileWriteAtomicallyReplacesExistingFileAndNeverCreatesMissingPath()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.txt")
        let missing = directory.appendingPathComponent("missing.txt")
        try Data("old".utf8).write(to: existing)

        let bindings = try FilesystemIntentProvider().bindings
        let replacement = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(existing.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("new"),
                ]),
            ]),
            bindings: bindings
        )
        _ = try successValue(replacement)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "new")

        let missingReply = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(missing.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("must-not-appear"),
                ]),
            ]),
            bindings: bindings
        )
        try assertFailure(
            missingReply,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testCreateAndMoveNeverOverwriteAndNeverCreateAncestors() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.txt")
        let source = directory.appendingPathComponent("source.txt")
        let nested = directory.appendingPathComponent("missing/child.txt")
        try Data("destination".utf8).write(to: existing)
        try Data("source".utf8).write(to: source)
        let bindings = try FilesystemIntentProvider().bindings

        let createExisting = try await invoke(
            .filesystemFileCreate,
            input: .object(["path": .string(existing.path)]),
            bindings: bindings
        )
        try assertFailure(
            createExisting,
            code: "dev.tenon.core.path-already-exists",
            reason: "path-already-exists"
        )
        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8),
            "destination"
        )

        XCTAssertThrowsError(
            try AuthorizedFilesystemPath(requestedPath: nested.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: nested.deletingLastPathComponent().path
            )
        )

        let move = try await invoke(
            .filesystemPathMove,
            input: .object([
                "sourcePath": .string(source.path),
                "destinationPath": .string(existing.path),
            ]),
            bindings: bindings
        )
        try assertFailure(
            move,
            code: "dev.tenon.core.path-already-exists",
            reason: "path-already-exists"
        )
        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8),
            "destination"
        )
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            "source"
        )
    }

    func testUnsupportedWriteShapeIsInvalidAndPastDeadlineDoesNoIO() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.txt")
        try Data("old".utf8).write(to: existing)
        let bindings = try FilesystemIntentProvider().bindings

        let resourceReply = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(existing.path),
                "content": .object([
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

        let deadlineReply = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(existing.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("new"),
                ]),
            ]),
            bindings: bindings,
            deadline: .now
        )
        try assertFailure(deadlineReply, code: "tenon.deadline-exceeded")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
    }
}

private extension FilesystemIntentProviderTests {
    enum TestError: Error {
        case missingBinding
        case expectedSuccess
        case expectedFailure
        case unexpectedValue
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-filesystem-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    func invoke(
        _ name: CoreIntentName,
        input: IntentValue,
        bindings: [IntentProviderBinding],
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        authorizedPaths: [AuthorizedFilesystemPath]? = nil
    ) async throws -> IntentProviderReply {
        let intentID = try name.intentID
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
                id: "test:filesystem-provider",
                kind: .plugin,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: deadline,
            target: nil,
            idempotencyKey: nil
        )
        let paths: [AuthorizedFilesystemPath]
        if let authorizedPaths {
            paths = authorizedPaths
        } else {
            let object = try object(input)
            paths = try ["path", "sourcePath", "destinationPath"]
                .compactMap { key -> String? in
                    guard case let .string(path)? = object[key] else {
                        return nil
                    }
                    return path
                }
                .map { try AuthorizedFilesystemPath(requestedPath: $0) }
        }
        let context = IntentProviderContext(
            requestID: envelope.requestID,
            authorizedFilesystemPaths: paths,
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

    func array(_ value: IntentValue?) throws -> [IntentValue] {
        guard case let .array(array)? = value else {
            throw TestError.unexpectedValue
        }
        return array
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
}
