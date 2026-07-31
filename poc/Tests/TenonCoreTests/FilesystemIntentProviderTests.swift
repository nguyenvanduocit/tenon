import Foundation
@testable import TenonCore
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

    func testFileReadReturnsWholeSmallFileWithNullCursorAndReportsNonText()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("text.txt")
        let binaryURL = directory.appendingPathComponent("binary")
        try Data("hello".utf8).write(to: textURL)
        try Data([0xFF, 0xFE]).write(to: binaryURL)

        let bindings = try FilesystemIntentProvider().bindings
        let textReply = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(textURL.path)]),
            bindings: bindings
        )
        let output = try object(try successValue(textReply))
        let content = try object(output["content"])
        XCTAssertEqual(try string(content["kind"]), "inline")
        XCTAssertEqual(try string(content["text"]), "hello")
        XCTAssertEqual(try integer(content["byteCount"]), 5)
        XCTAssertEqual(output["cursor"], .null)
        XCTAssertEqual(output["invalidated"], .bool(false))

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
    }

    func testFileReadServesLargeFileAcrossBoundedUTF8Pages() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = CoreIntentPayloadPolicy.maximumInlineTextCharacters
        // Byte `limit - 1` starts the three-byte "ệ", so the first page must back
        // off to the character boundary instead of splitting the sequence.
        let content = String(repeating: "a", count: limit - 1) + "ệ"
            + String(repeating: "b", count: limit) + "😀"
            + String(repeating: "c", count: limit / 2)
        let url = directory.appendingPathComponent("board.md")
        try Data(content.utf8).write(to: url)

        let bindings = try FilesystemIntentProvider().bindings
        var pages: [String] = []
        var cursor: String?
        for _ in 0 ..< 8 {
            var input: [String: IntentValue] = ["path": .string(url.path)]
            if let cursor { input["cursor"] = .string(cursor) }
            let reply = try await invoke(
                .filesystemFileRead,
                input: .object(input),
                bindings: bindings
            )
            let output = try object(try successValue(reply))
            XCTAssertEqual(output["invalidated"], .bool(false))
            let page = try object(output["content"])
            let text = try string(page["text"])
            XCTAssertEqual(try integer(page["byteCount"]), Int64(text.utf8.count))
            XCTAssertLessThanOrEqual(text.utf8.count, limit)
            pages.append(text)
            if case let .string(next)? = output["cursor"] {
                cursor = next
            } else {
                XCTAssertEqual(output["cursor"], .null)
                cursor = nil
                break
            }
        }
        XCTAssertNil(cursor)

        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].utf8.count, limit - 1)
        XCTAssertTrue(pages[1].hasPrefix("ệ"))
        XCTAssertEqual(Data(pages.joined().utf8), Data(content.utf8))
    }

    func testFileReadCursorReportsInvalidatedWhenFileChangesBetweenPages()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = CoreIntentPayloadPolicy.maximumInlineTextCharacters
        let url = directory.appendingPathComponent("board.md")
        try Data(repeating: 0x78, count: limit + 100).write(to: url)

        let bindings = try FilesystemIntentProvider().bindings
        let first = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(url.path)]),
            bindings: bindings
        )
        let cursor = try string(try object(try successValue(first))["cursor"])

        // Same size, different bytes: only the modification time in the cursor's
        // identity can catch this, so shifted content must never come back.
        try Data(repeating: 0x79, count: limit + 100).write(to: url)

        let stale = try await invoke(
            .filesystemFileRead,
            input: .object([
                "path": .string(url.path),
                "cursor": .string(cursor),
            ]),
            bindings: bindings
        )
        let output = try object(try successValue(stale))
        XCTAssertEqual(output["invalidated"], .bool(true))
        XCTAssertEqual(output["cursor"], .null)
        XCTAssertEqual(try string(try object(output["content"])["text"]), "")
    }

    func testFileReadFinalPageInvalidatesWhenFileChangesInsideReadWindow()
        throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = CoreIntentPayloadPolicy.maximumInlineTextCharacters
        let url = directory.appendingPathComponent("board.md")
        try Data(repeating: 0x78, count: limit + 100).write(to: url)

        let path = try AuthorizedFilesystemPath(requestedPath: url.path)
        let first = try object(
            try FilesystemIntentProvider.readTextFile(path: path, cursor: nil)
        )
        let cursor = try FilesystemIntentProvider.fileReadCursor(
            from: try string(first["cursor"])
        )

        // The final page has no next call whose identity check could catch a
        // mismatch, so a write landing after this page's identity check and before
        // its bytes are read is the one place shifted bytes could slip through.
        let output = try object(
            try FilesystemIntentProvider.readTextFile(
                path: path,
                cursor: cursor,
                interposedBeforePageRead: {
                    try Data(repeating: 0x79, count: limit + 200).write(to: url)
                }
            )
        )
        XCTAssertEqual(output["invalidated"], .bool(true))
        XCTAssertEqual(output["cursor"], .null)
        XCTAssertEqual(try string(try object(output["content"])["text"]), "")
    }

    func testFileReadRejectsMalformedOrForgedCursor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = CoreIntentPayloadPolicy.maximumInlineTextCharacters
        let url = directory.appendingPathComponent("board.md")
        try Data(repeating: 0x61, count: limit + 10).write(to: url)
        let bindings = try FilesystemIntentProvider().bindings

        for malformed in ["not-a-cursor", "v1:-4:deadbeef", "v2:1:deadbeef"] {
            let reply = try await invoke(
                .filesystemFileRead,
                input: .object([
                    "path": .string(url.path),
                    "cursor": .string(malformed),
                ]),
                bindings: bindings
            )
            try assertFailure(
                reply,
                code: "tenon.invalid-input",
                field: "cursor"
            )
        }

        // A past-the-end offset with the genuine identity is nothing this host
        // ever issued; it fails closed instead of reading beyond the file.
        let first = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(url.path)]),
            bindings: bindings
        )
        let cursor = try string(try object(try successValue(first))["cursor"])
        let components = cursor.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        XCTAssertEqual(components.count, 3)
        let forged = "\(components[0]):\(2 * limit):\(components[2])"
        let forgedReply = try await invoke(
            .filesystemFileRead,
            input: .object([
                "path": .string(url.path),
                "cursor": .string(forged),
            ]),
            bindings: bindings
        )
        try assertFailure(
            forgedReply,
            code: "tenon.invalid-input",
            field: "cursor"
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
        field: String? = nil,
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
        if let field {
            let details = try object(failure.details)
            XCTAssertEqual(
                try string(details["field"]),
                field,
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
