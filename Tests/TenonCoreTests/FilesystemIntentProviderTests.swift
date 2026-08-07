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

    func testDirectoryListReportsSizeAndModificationTimeWhenRequested()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sizes = ["alpha": 0, "beta": 17, "gamma": 4_096]
        let stamps = [
            "alpha": Date(timeIntervalSince1970: 1_700_000_000),
            "beta": Date(timeIntervalSince1970: 1_712_345_678),
            "gamma": Date(timeIntervalSince1970: 1_760_000_000),
        ]
        for (name, size) in sizes {
            let url = directory.appendingPathComponent(name)
            try Data(repeating: 0x61, count: size).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: stamps[name]!],
                ofItemAtPath: url.path
            )
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("nested"),
            withIntermediateDirectories: false
        )

        let value = try assertSuccessValue(
            try await invoke(
                .filesystemDirectoryList,
                input: .object([
                    "path": .string(directory.path),
                    "includeMetadata": .bool(true),
                ]),
                bindings: try FilesystemIntentProvider().bindings
            )
        )
        let entries = try array(try object(value)["entries"])
        XCTAssertEqual(entries.count, 4)
        let iso = Date.ISO8601FormatStyle()
        for entry in entries {
            let fields = try object(entry)
            let name = try string(fields["name"])
            guard let size = sizes[name] else {
                XCTAssertEqual(name, "nested")
                XCTAssertEqual(fields["isDirectory"], IntentValue.bool(true))
                XCTAssertNotEqual(fields["sizeBytes"], IntentValue.null)
                XCTAssertNotEqual(fields["modifiedAt"], IntentValue.null)
                continue
            }
            XCTAssertEqual(fields["isDirectory"], IntentValue.bool(false))
            XCTAssertEqual(fields["sizeBytes"], .integer(Int64(size)))
            XCTAssertEqual(
                fields["modifiedAt"],
                .string(iso.format(stamps[name]!))
            )
        }
    }

    func testDirectoryListOmitsMetadataUnlessRequested() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hi".utf8).write(
            to: directory.appendingPathComponent("note.txt")
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"),
            withIntermediateDirectories: false
        )

        let bindings = try FilesystemIntentProvider().bindings
        for input in [
            IntentValue.object(["path": .string(directory.path)]),
            IntentValue.object([
                "path": .string(directory.path),
                "includeMetadata": .bool(false),
            ]),
        ] {
            let value = try assertSuccessValue(
                try await invoke(
                    .filesystemDirectoryList,
                    input: input,
                    bindings: bindings
                )
            )
            let entries = try array(try object(value)["entries"])
            XCTAssertEqual(entries.count, 2)
            for entry in entries {
                XCTAssertEqual(
                    try object(entry).keys.sorted(),
                    ["isDirectory", "name"]
                )
            }
        }
    }

    func testDirectoryListReportsTheResolvedDirectoryPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = root
            .appendingPathComponent("real")
            .appendingPathComponent("listed")
        try FileManager.default.createDirectory(
            at: listed,
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(
            to: listed.appendingPathComponent("entry.txt")
        )
        // The listed directory is reached through a symlinked parent, so the
        // spelling the caller sent and the directory the host actually opened
        // differ by construction rather than by /var-to-/private/var luck.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("real")
        )

        let requestedPath = root
            .appendingPathComponent("link")
            .appendingPathComponent("listed")
            .path
        let value = try assertSuccessValue(
            try await invoke(
                .filesystemDirectoryList,
                input: .object(["path": .string(requestedPath)]),
                bindings: try FilesystemIntentProvider().bindings
            )
        )
        let resolved = try AuthorizedFilesystemPath(
            requestedPath: requestedPath
        ).resolvedPath
        XCTAssertNotEqual(resolved, requestedPath)
        XCTAssertEqual(try string(try object(value)["path"]), resolved)
    }

    func testIncludeMetadataDoesNotChangeIsDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let sub = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link-to-file"),
            withDestinationURL: file
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link-to-dir"),
            withDestinationURL: sub
        )

        let bindings = try FilesystemIntentProvider().bindings
        var mappings: [[String: Bool]] = []
        for input in [
            IntentValue.object(["path": .string(directory.path)]),
            IntentValue.object([
                "path": .string(directory.path),
                "includeMetadata": .bool(true),
            ]),
        ] {
            let value = try assertSuccessValue(
                try await invoke(
                    .filesystemDirectoryList,
                    input: input,
                    bindings: bindings
                )
            )
            var mapping: [String: Bool] = [:]
            for entry in try array(try object(value)["entries"]) {
                let fields = try object(entry)
                guard case let .bool(isDirectory)? = fields["isDirectory"] else {
                    throw TestError.unexpectedValue
                }
                mapping[try string(fields["name"])] = isDirectory
            }
            mappings.append(mapping)
        }
        XCTAssertEqual(mappings.first, mappings.last)
        XCTAssertEqual(mappings.last?["sub"], true)
        XCTAssertEqual(mappings.last?["file.txt"], false)
        // A stat that followed the link would call this one a directory.
        XCTAssertEqual(mappings.last?["link-to-dir"], false)
        XCTAssertEqual(mappings.last?["link-to-file"], false)
    }

    func testDirectoryListMetadataIsNullWhenAnEntryVanishesMidPage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 6 {
            try Data(repeating: 0x61, count: index + 1).write(
                to: directory.appendingPathComponent("entry-\(index)")
            )
        }

        let vanishing = "entry-3"
        let page = try FilesystemIntentProvider.directoryPage(
            path: try AuthorizedFilesystemPath(requestedPath: directory.path),
            cursor: FilesystemIntentProvider.DirectoryCursor(
                offset: 0,
                fingerprint: nil
            ),
            limit: 16,
            includeMetadata: true,
            deadline: .now.advanced(by: .seconds(5)),
            interposedBeforeEntryMetadata: { name in
                guard name == vanishing else { return }
                try FileManager.default.removeItem(
                    at: directory.appendingPathComponent(name)
                )
            }
        )

        // readdir already handed the name over, so the entry stays in the page;
        // only its metadata is unknown.
        XCTAssertEqual(page.entries.count, 6)
        var sawVanished = false
        for entry in page.entries {
            let fields = try object(entry)
            let name = try string(fields["name"])
            XCTAssertEqual(fields["isDirectory"], IntentValue.bool(false))
            if name == vanishing {
                sawVanished = true
                XCTAssertEqual(fields["sizeBytes"], IntentValue.null)
                XCTAssertEqual(fields["modifiedAt"], IntentValue.null)
                continue
            }
            XCTAssertNotEqual(fields["sizeBytes"], IntentValue.null)
            XCTAssertNotEqual(fields["modifiedAt"], IntentValue.null)
        }
        XCTAssertTrue(sawVanished)
    }

    /// End-of-directory is `readdir` returning nil with errno untouched, so the
    /// scan can only tell "the directory ended" from "the scan failed" if errno
    /// is clean the instant `readdir` is called. Everything the loop body runs —
    /// the ISO-8601 formatter, the canonical encoder, both Foundation — may set
    /// errno on a call that succeeded. The interposed hook stands in for that:
    /// it dirties errno on every entry, and the page must still come back.
    func testDirectoryListIgnoresErrnoLeftSetByWorkInsideTheScan() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 5 {
            try Data(repeating: 0x61, count: index + 1).write(
                to: directory.appendingPathComponent("entry-\(index)")
            )
        }

        let page = try FilesystemIntentProvider.directoryPage(
            path: try AuthorizedFilesystemPath(requestedPath: directory.path),
            cursor: FilesystemIntentProvider.DirectoryCursor(
                offset: 0,
                fingerprint: nil
            ),
            limit: 16,
            includeMetadata: true,
            deadline: .now.advanced(by: .seconds(5)),
            interposedBeforeEntryMetadata: { _ in errno = EINVAL }
        )

        XCTAssertEqual(page.entries.count, 5)
        XCTAssertNil(page.nextCursor)
    }

    func testDirectoryListValidatesTheAssembledPageOnceInsteadOfEveryPrefix()
        throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 256 {
            try Data().write(
                to: directory.appendingPathComponent(
                    String(format: "entry-%03d", index)
                )
            )
        }

        var validations = 0
        let page = try FilesystemIntentProvider.directoryPage(
            path: try AuthorizedFilesystemPath(requestedPath: directory.path),
            cursor: FilesystemIntentProvider.DirectoryCursor(
                offset: 0,
                fingerprint: nil
            ),
            limit: 256,
            includeMetadata: false,
            deadline: .now.advanced(by: .seconds(30)),
            onPageValidation: { validations += 1 }
        )
        XCTAssertEqual(page.entries.count, 256)
        XCTAssertEqual(validations, 1)
    }

    func testDirectoryListMetadataPageStaysWithinTheOutputBudget()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 254 {
            let name = String(format: "%03d-", index)
                + String(repeating: "x", count: 240)
            try Data().write(to: directory.appendingPathComponent(name))
        }
        // The accounting encodes each entry on its own, so a name whose JSON is
        // longer than its characters has to be counted in bytes, not in scalars.
        try Data().write(
            to: directory.appendingPathComponent(
                "254-\"\\" + String(repeating: "x", count: 236)
            )
        )
        try Data().write(
            to: directory.appendingPathComponent(
                "255-" + String(repeating: "é", count: 80)
            )
        )

        let bindings = try FilesystemIntentProvider().bindings
        var counts: [Int] = []
        for includeMetadata in [false, true] {
            var total = 0
            var first = 0
            var pages = 0
            var cursor: String?
            repeat {
                pages += 1
                // 256 entries cannot need 16 pages; a page that returned nothing
                // while still issuing a cursor would otherwise spin here forever.
                guard pages <= 16 else {
                    return XCTFail("paging did not terminate")
                }
                var input: [String: IntentValue] = [
                    "path": .string(directory.path),
                    "limit": .integer(256),
                    "includeMetadata": .bool(includeMetadata),
                ]
                if let cursor {
                    input["cursor"] = .string(cursor)
                }
                let value = try assertSuccessValue(
                    try await invoke(
                        .filesystemDirectoryList,
                        input: .object(input),
                        bindings: bindings
                    )
                )
                try value.validate()
                let object = try object(value)
                let entries = try array(object["entries"])
                XCTAssertGreaterThan(entries.count, 0)
                if pages == 1 { first = entries.count }
                total += entries.count
                cursor = object["nextCursor"].flatMap { next in
                    guard case let .string(next) = next else { return nil }
                    return next
                }
            } while cursor != nil
            XCTAssertEqual(total, 256)
            counts.append(first)
        }
        XCTAssertLessThan(counts[1], counts[0])
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
        // The single-page reply is exactly the pre-paging empty object; staged
        // pages are the only replies that carry a cursor.
        XCTAssertEqual(try successValue(replacement), .object([:]))
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

        // The binding tolerates the missing ancestor so read/exists can answer
        // not-found, but creation through it still refuses to invent directories.
        let nestedBinding = try AuthorizedFilesystemPath(requestedPath: nested.path)
        XCTAssertFalse(nestedBinding.existedAtAuthorization)
        let nestedCreate = try await invoke(
            .filesystemFileCreate,
            input: .object(["path": .string(nested.path)]),
            bindings: bindings
        )
        try assertFailure(
            nestedCreate,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
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

    func testReadListAndExistsOnMissingAncestorChainAnswerNotFound() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Both the parent and the grandparent of the board are missing.
        let board = workspace.appendingPathComponent(".kanban/tasks/board.md")
        let bindings = try FilesystemIntentProvider().bindings

        let read = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(board.path)]),
            bindings: bindings
        )
        try assertFailure(
            read,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )

        let list = try await invoke(
            .filesystemDirectoryList,
            input: .object([
                "path": .string(
                    workspace.appendingPathComponent(".kanban/tasks").path
                ),
            ]),
            bindings: bindings
        )
        try assertFailure(
            list,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )

        let exists = try await invoke(
            .filesystemPathExists,
            input: .object(["path": .string(board.path)]),
            bindings: bindings
        )
        let output = try object(try successValue(exists))
        XCTAssertEqual(output["exists"], .bool(false))
    }

    func testCreateAndWriteTowardMissingAncestorReportNotFoundWithoutCreatingDirectories()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let missingDirectory = workspace.appendingPathComponent(".kanban")
        let board = missingDirectory.appendingPathComponent("tasks/board.md")
        let bindings = try FilesystemIntentProvider().bindings

        let create = try await invoke(
            .filesystemFileCreate,
            input: .object(["path": .string(board.path)]),
            bindings: bindings
        )
        try assertFailure(
            create,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )

        let write = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(board.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("must-not-appear"),
                ]),
            ]),
            bindings: bindings
        )
        try assertFailure(
            write,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )

        let directoryCreate = try await invoke(
            .filesystemDirectoryCreate,
            input: .object([
                "path": .string(
                    missingDirectory.appendingPathComponent("tasks").path
                ),
            ]),
            bindings: bindings
        )
        try assertFailure(
            directoryCreate,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingDirectory.path)
        )
    }

    func testSymlinkGrownIntoMissingSuffixAfterBindingFailsClosed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try Data("smuggled".utf8).write(
            to: outside.appendingPathComponent("board.md")
        )

        // Bind while .kanban is missing, then grow it as a symlink pointing
        // outside. The provider's suffix walk must refuse to follow it.
        let requestedPath = workspace
            .appendingPathComponent(".kanban/board.md")
            .path
        let binding = try AuthorizedFilesystemPath(requestedPath: requestedPath)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent(".kanban"),
            withDestinationURL: outside
        )

        let read = try await invoke(
            .filesystemFileRead,
            input: .object(["path": .string(requestedPath)]),
            bindings: try FilesystemIntentProvider().bindings,
            authorizedPaths: [binding]
        )
        try assertFailure(
            read,
            code: "dev.tenon.core.filesystem-failed",
            reason: "authorized-path-became-symlink"
        )
    }

    func testFileOccupyingAncestorPositionAnswersNotFoundWithoutTouchingIt()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // A user note occupies the position the board's directory would take;
        // the path cannot exist, and the note itself is never traversed.
        let note = workspace.appendingPathComponent(".kanban")
        try Data("a user note".utf8).write(to: note)
        let bindings = try FilesystemIntentProvider().bindings

        let read = try await invoke(
            .filesystemFileRead,
            input: .object([
                "path": .string(
                    workspace.appendingPathComponent(".kanban/board.md").path
                ),
            ]),
            bindings: bindings
        )
        try assertFailure(
            read,
            code: "dev.tenon.core.path-not-found",
            reason: "path-not-found"
        )

        let exists = try await invoke(
            .filesystemPathExists,
            input: .object([
                "path": .string(
                    workspace
                        .appendingPathComponent(".kanban/tasks/board.md")
                        .path
                ),
            ]),
            bindings: bindings
        )
        let output = try object(try successValue(exists))
        XCTAssertEqual(output["exists"], .bool(false))

        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            "a user note"
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

    func testFileWriteStagedPagesCommitAtomicallyWithoutIntermediateTargetContent()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("board.md")
        try Data("old".utf8).write(to: target)
        let limit = CoreIntentPayloadPolicy.maximumInlineTextCharacters
        // Three pages, each within the per-page byte bound, whose sum is well
        // past it — the whole reason staged writes exist.
        let pages = [
            String(repeating: "a", count: limit),
            "ệ" + String(repeating: "b", count: limit - 3),
            "😀" + String(repeating: "c", count: 100),
        ]
        let bindings = try FilesystemIntentProvider().bindings

        var cursor: String?
        var stagedBytes = 0
        for (index, page) in pages.enumerated() {
            let isLast = index == pages.count - 1
            var input: [String: IntentValue] = [
                "path": .string(target.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string(page),
                ]),
                "commit": .bool(isLast),
            ]
            if let cursor { input["cursor"] = .string(cursor) }
            let reply = try await invoke(
                .filesystemFileWrite,
                input: .object(input),
                bindings: bindings
            )
            let output = try object(try successValue(reply))
            stagedBytes += page.utf8.count
            if isLast {
                XCTAssertEqual(output, [:])
            } else {
                // While the staging is open the target never holds intermediate
                // content, and the staging collects pages beside it.
                XCTAssertEqual(
                    try String(contentsOf: target, encoding: .utf8),
                    "old"
                )
                XCTAssertEqual(Array(output.keys), ["cursor"])
                let next = try string(output["cursor"])
                XCTAssertTrue(next.hasPrefix("v1:\(stagedBytes):"))
                cursor = next
                let entries = try FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
                XCTAssertEqual(entries.count, 2)
                XCTAssertTrue(
                    entries.contains { $0.hasPrefix(".tenon-staging-") }
                )
            }
        }

        XCTAssertEqual(
            try Data(contentsOf: target),
            Data(pages.joined().utf8)
        )
        // The commit consumed the staging: only the target remains.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["board.md"]
        )
    }

    /// The commit is the rename, pinned by identity: after the commit the target holds
    /// the staging dot-file's own inode. A commit that instead rewrote the target in
    /// place would pass every byte and directory-listing assertion above while exposing
    /// intermediate content to concurrent readers and watchers — exactly the corruption
    /// class the staged write exists to prevent.
    func testFileWriteCommitRenamesTheStagingInodeOverTheTarget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("board.md")
        try Data("old".utf8).write(to: target)
        let bindings = try FilesystemIntentProvider().bindings

        let originalInode = try inode(atPath: target.path)
        let cursor = try await stagePage(
            target, text: "one", cursor: nil, bindings: bindings
        )
        let stagingName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first { $0.hasPrefix(".tenon-staging-") }
        )
        let stagingInode = try inode(
            atPath: directory.appendingPathComponent(stagingName).path
        )

        let reply = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(target.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("two"),
                ]),
                "cursor": .string(cursor),
                "commit": .bool(true),
            ]),
            bindings: bindings
        )
        XCTAssertEqual(try object(try successValue(reply)), [:])

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "onetwo")
        let committed = try inode(atPath: target.path)
        XCTAssertEqual(
            committed,
            stagingInode,
            "the committed bytes live in the staging's own inode — the commit was a rename"
        )
        XCTAssertNotEqual(
            committed,
            originalInode,
            "a commit that kept the target's old inode rewrote it in place"
        )
    }

    func testFileWriteRejectsMalformedForgedReplayedOrCrossTargetCursors()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("a.md")
        let other = directory.appendingPathComponent("b.md")
        try Data("old-a".utf8).write(to: target)
        try Data("old-b".utf8).write(to: other)
        let bindings = try FilesystemIntentProvider().bindings

        for malformed in [
            "not-a-cursor",
            "v1:-4:\(UUID().uuidString)",
            "v2:1:\(UUID().uuidString)",
            "v1:0:",
            "v1:0:\(UUID().uuidString)",
        ] {
            let reply = try await invoke(
                .filesystemFileWrite,
                input: .object([
                    "path": .string(target.path),
                    "content": .object([
                        "kind": .string("inline"),
                        "text": .string("page"),
                    ]),
                    "cursor": .string(malformed),
                    "commit": .bool(false),
                ]),
                bindings: bindings
            )
            try assertFailure(reply, code: "tenon.invalid-input", field: "cursor")
        }

        // A stale cursor replayed after its staging advanced is out of sequence;
        // the staging cannot be trusted to hold what any cursor promises, so it
        // is reclaimed and both cursors die.
        let first = try await stagePage(
            target, text: "one", cursor: nil, bindings: bindings
        )
        let second = try await stagePage(
            target, text: "two", cursor: first, bindings: bindings
        )
        let replayed = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(target.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("three"),
                ]),
                "cursor": .string(first),
                "commit": .bool(true),
            ]),
            bindings: bindings
        )
        try assertFailure(replayed, code: "tenon.invalid-input", field: "cursor")
        let afterReclaim = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(target.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("three"),
                ]),
                "cursor": .string(second),
                "commit": .bool(false),
            ]),
            bindings: bindings
        )
        try assertFailure(afterReclaim, code: "tenon.invalid-input", field: "cursor")

        // A cursor presented against a different target than the one its
        // staging opened on fails closed the same way.
        let crossSource = try await stagePage(
            target, text: "one", cursor: nil, bindings: bindings
        )
        let crossed = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(other.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("two"),
                ]),
                "cursor": .string(crossSource),
                "commit": .bool(false),
            ]),
            bindings: bindings
        )
        try assertFailure(crossed, code: "tenon.invalid-input", field: "cursor")

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old-a")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "old-b")
        // Every broken staging was reclaimed from disk.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .sorted(),
            ["a.md", "b.md"]
        )
    }

    func testFileWriteStagedBytesBoundOverflowFailsAndReclaimsStaging()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("board.md")
        try Data("old".utf8).write(to: target)
        let limit = CoreIntentPayloadPolicy.maximumInlineTextCharacters
        let bound = CoreIntentPayloadPolicy.maximumStagedFileWriteBytes
        let page = String(repeating: "x", count: limit)
        let bindings = try FilesystemIntentProvider().bindings

        var cursor: String?
        for _ in 0 ..< (bound / limit) {
            cursor = try await stagePage(
                target, text: page, cursor: cursor, bindings: bindings
            )
        }

        let overflowing = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(target.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string(page),
                ]),
                "cursor": .string(try XCTUnwrap(cursor)),
                "commit": .bool(false),
            ]),
            bindings: bindings
        )
        try assertFailure(
            overflowing,
            code: "dev.tenon.core.filesystem-failed",
            reason: "staged-write-limit-exceeded"
        )

        // The overflow reclaimed the staging: its cursor is dead, its dot-file
        // is gone, and the target never changed.
        let afterReclaim = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(target.path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("page"),
                ]),
                "cursor": .string(try XCTUnwrap(cursor)),
                "commit": .bool(true),
            ]),
            bindings: bindings
        )
        try assertFailure(afterReclaim, code: "tenon.invalid-input", field: "cursor")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["board.md"]
        )
    }

    func testFileWriteConcurrentStagingsAreBoundedPerProvider() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = FilesystemIntentProvider.maximumConcurrentFileWriteStagings
        let targets = try (0 ... capacity).map { index -> URL in
            let url = directory.appendingPathComponent("target-\(index).md")
            try Data("old".utf8).write(to: url)
            return url
        }
        let bindings = try FilesystemIntentProvider().bindings

        var cursors: [String] = []
        for target in targets.prefix(capacity) {
            cursors.append(
                try await stagePage(
                    target, text: "page", cursor: nil, bindings: bindings
                )
            )
        }

        let exhausted = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(targets[capacity].path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("page"),
                ]),
                "commit": .bool(false),
            ]),
            bindings: bindings
        )
        try assertFailure(
            exhausted,
            code: "dev.tenon.core.filesystem-failed",
            reason: "staging-capacity-exhausted"
        )

        // Committing one staging frees its slot.
        let committed = try await invoke(
            .filesystemFileWrite,
            input: .object([
                "path": .string(targets[0].path),
                "content": .object([
                    "kind": .string("inline"),
                    "text": .string("!"),
                ]),
                "cursor": .string(cursors[0]),
                "commit": .bool(true),
            ]),
            bindings: bindings
        )
        XCTAssertEqual(try successValue(committed), .object([:]))
        XCTAssertEqual(
            try String(contentsOf: targets[0], encoding: .utf8),
            "page!"
        )
        _ = try await stagePage(
            targets[capacity], text: "page", cursor: nil, bindings: bindings
        )
    }

    func testAbandonedFileWriteStagingExpiresAtNextUseAndFreesCapacity() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("board.md")
        try Data("old".utf8).write(to: target)
        let path = try AuthorizedFilesystemPath(requestedPath: target.path)
        let registry = FilesystemIntentProvider.FileWriteStagingRegistry()
        let opened = ContinuousClock.now

        let issued = try FilesystemIntentProvider.stagedWrite(
            path: path,
            data: Data("page".utf8),
            cursor: nil,
            commit: false,
            registry: registry,
            now: opened
        )
        let cursor = try FilesystemIntentProvider.fileWriteCursor(from: issued)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .count,
            2
        )

        // The lifetime is fixed at open — the sweep at next use reclaims the
        // ledger entry and the dot-file together, and the dead cursor is
        // indistinguishable from a forged one.
        let afterLifetime = opened.advanced(
            by: FilesystemIntentProvider.fileWriteStagingLifetime + .seconds(1)
        )
        XCTAssertThrowsError(
            try FilesystemIntentProvider.stagedWrite(
                path: path,
                data: Data("more".utf8),
                cursor: cursor,
                commit: false,
                registry: registry,
                now: afterLifetime
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreIntentProviderInputError,
                .missingOrInvalidField("cursor")
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["board.md"]
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")

        // The reclaimed slot is usable again at the same instant.
        XCTAssertNotNil(
            try FilesystemIntentProvider.stagedWrite(
                path: path,
                data: Data("fresh".utf8),
                cursor: nil,
                commit: false,
                registry: registry,
                now: afterLifetime
            )
        )
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

    /// Reports the failure before unwinding, so a rejected envelope names its
    /// error code instead of surfacing as a bare `expectedSuccess`.
    func assertSuccessValue(
        _ reply: IntentProviderReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IntentValue {
        guard case let .success(value) = reply else {
            XCTFail("Expected success, got \(reply)", file: file, line: line)
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

    /// Sends one staged (`commit: false`) write page and returns the cursor the
    /// host issued for the next page.
    func stagePage(
        _ target: URL,
        text: String,
        cursor: String?,
        bindings: [IntentProviderBinding]
    ) async throws -> String {
        var input: [String: IntentValue] = [
            "path": .string(target.path),
            "content": .object([
                "kind": .string("inline"),
                "text": .string(text),
            ]),
            "commit": .bool(false),
        ]
        if let cursor { input["cursor"] = .string(cursor) }
        let reply = try await invoke(
            .filesystemFileWrite,
            input: .object(input),
            bindings: bindings
        )
        return try string(try object(try successValue(reply))["cursor"])
    }

    func inode(atPath path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
