// @domain: intent-bus
import Darwin
import Foundation
import os
import TenonIntentCore

/// Foundation-backed filesystem primitives for the canonical v1 core contracts.
///
/// This value only owns bindings. The app decides which provider generation aggregates and
/// activates them.
public struct FilesystemIntentProvider: Sendable {
    public let bindings: [IntentProviderBinding]

    public init() throws {
        let codes = try ErrorCodes()
        // One ledger per provider: the staged-write bounds — capacity, bytes,
        // lifetime — are all enforced against this instance.
        let stagings = FileWriteStagingRegistry()
        bindings = [
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemDirectoryList.intentID
            ) { envelope, context in
                await Self.listDirectory(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemFileRead.intentID
            ) { envelope, context in
                await Self.readFile(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemPathExists.intentID
            ) { envelope, context in
                await Self.pathExists(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemFileWrite.intentID
            ) { envelope, context in
                await Self.writeFile(
                    envelope: envelope,
                    context: context,
                    codes: codes,
                    stagings: stagings
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemDirectoryCreate.intentID
            ) { envelope, context in
                await Self.createDirectory(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemFileCreate.intentID
            ) { envelope, context in
                await Self.createFile(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemPathMove.intentID
            ) { envelope, context in
                await Self.movePath(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.filesystemPathTrash.intentID
            ) { envelope, context in
                await Self.trashPath(
                    envelope: envelope,
                    context: context,
                    codes: codes
                )
            },
        ]
    }
}

private extension FilesystemIntentProvider {
    struct ErrorCodes: Sendable {
        let pathNotFound: IntentErrorCode
        let pathAlreadyExists: IntentErrorCode
        let contentNotText: IntentErrorCode
        let filesystemFailed: IntentErrorCode

        init() throws {
            pathNotFound = .domain(
                try IntentDomainErrorCode("dev.tenon.core.path-not-found")
            )
            pathAlreadyExists = .domain(
                try IntentDomainErrorCode("dev.tenon.core.path-already-exists")
            )
            contentNotText = .domain(
                try IntentDomainErrorCode("dev.tenon.core.content-not-text")
            )
            filesystemFailed = .domain(
                try IntentDomainErrorCode("dev.tenon.core.filesystem-failed")
            )
        }
    }

    enum OperationError: Error, Sendable {
        case pathNotFound
        case pathAlreadyExists
        case contentNotText
        case contentTooLarge
        case filesystemFailed(String)
    }

    static let defaultDirectoryLimit = 100
    static let maximumDirectoryLimit = 256
    static let maximumInlineBytes = CoreIntentPayloadPolicy.maximumInlineTextCharacters

    static func authorizedPath(
        _ requestedPath: String,
        context: IntentProviderContext
    ) throws -> AuthorizedFilesystemPath {
        guard let path = context.authorizedFilesystemPath(for: requestedPath) else {
            throw OperationError.filesystemFailed(
                "authorization-binding-missing"
            )
        }
        return path
    }

    static func listDirectory(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        do {
            let input = try CoreIntentProviderSupport.object(envelope.input)
            let requestedPath = try CoreIntentProviderSupport.string("path", in: input)
            let path = try authorizedPath(requestedPath, context: context)
            let rawCursor = try CoreIntentProviderSupport.optionalString(
                "cursor",
                in: input
            )
            let requestedLimit = try CoreIntentProviderSupport.optionalInteger(
                "limit",
                in: input
            )
            let limit = requestedLimit.flatMap(Int.init(exactly:))
                ?? defaultDirectoryLimit
            guard (1 ... maximumDirectoryLimit).contains(limit) else {
                throw CoreIntentProviderInputError.missingOrInvalidField("limit")
            }
            let cursor = try directoryCursor(from: rawCursor)
            let includeMetadata = try CoreIntentProviderSupport.optionalBool(
                "includeMetadata",
                in: input
            ) ?? false

            let page = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try directoryPage(
                    path: path,
                    cursor: cursor,
                    limit: limit,
                    includeMetadata: includeMetadata,
                    deadline: envelope.deadline
                )
            }
            return .success(
                directoryOutput(
                    entries: page.entries,
                    nextCursor: page.nextCursor,
                    path: path.resolvedPath
                )
            )
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch let error as OperationError {
            return reply(for: error, codes: codes)
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "directory-list-failed"
            )
        }
    }

    static func readFile(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        do {
            let input = try CoreIntentProviderSupport.object(envelope.input)
            let requestedPath = try CoreIntentProviderSupport.string("path", in: input)
            let path = try authorizedPath(requestedPath, context: context)
            let rawCursor = try CoreIntentProviderSupport.optionalString(
                "cursor",
                in: input
            )
            let cursor = try fileReadCursor(from: rawCursor)
            let output = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try readTextFile(path: path, cursor: cursor)
            }
            return .success(output)
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch let error as OperationError {
            return reply(for: error, codes: codes)
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "file-read-failed"
            )
        }
    }

    static func pathExists(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        do {
            let input = try CoreIntentProviderSupport.object(envelope.input)
            let requestedPath = try CoreIntentProviderSupport.string("path", in: input)
            let path = try authorizedPath(requestedPath, context: context)
            let exists = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try boundPathExists(path)
            }
            return .success(.object(["exists": .bool(exists)]))
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "path-exists-failed"
            )
        }
    }

    static func writeFile(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes,
        stagings: FileWriteStagingRegistry
    ) async -> IntentProviderReply {
        do {
            let input = try CoreIntentProviderSupport.object(envelope.input)
            let requestedPath = try CoreIntentProviderSupport.string("path", in: input)
            let path = try authorizedPath(requestedPath, context: context)
            guard let text = try CoreIntentProviderSupport.optionalTextInput(
                "content",
                in: input
            ) else {
                throw CoreIntentProviderInputError.missingOrInvalidField("content")
            }
            let data = Data(text.utf8)
            guard data.count <= maximumInlineBytes else {
                throw OperationError.contentTooLarge
            }
            let rawCursor = try CoreIntentProviderSupport.optionalString(
                "cursor",
                in: input
            )
            let cursor = try fileWriteCursor(from: rawCursor)
            let commit: Bool
            if let field = input["commit"] {
                guard case let .bool(value) = field else {
                    throw CoreIntentProviderInputError.missingOrInvalidField("commit")
                }
                commit = value
            } else {
                commit = true
            }

            let nextCursor = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) { () -> String? in
                if cursor == nil, commit {
                    try atomicallyReplaceFile(path: path, data: data)
                    return nil
                }
                return try stagedWrite(
                    path: path,
                    data: data,
                    cursor: cursor,
                    commit: commit,
                    registry: stagings
                )
            }
            guard let nextCursor else { return .success(.object([:])) }
            let output = IntentValue.object(["cursor": .string(nextCursor)])
            try output.validate()
            return .success(output)
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch let error as OperationError {
            return reply(for: error, codes: codes)
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "file-write-failed"
            )
        }
    }

    static func createDirectory(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        await mutatePath(
            envelope: envelope,
            context: context,
            codes: codes,
            operationName: "directory-create"
        ) { path in
            try createBoundDirectory(path)
            return .object(["path": .string(path.resolvedPath)])
        }
    }

    static func createFile(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        await mutatePath(
            envelope: envelope,
            context: context,
            codes: codes,
            operationName: "file-create"
        ) { path in
            try createBoundFile(path)
            return .object(["path": .string(path.resolvedPath)])
        }
    }

    static func movePath(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        do {
            let input = try CoreIntentProviderSupport.object(envelope.input)
            let requestedSource = try CoreIntentProviderSupport.string(
                "sourcePath",
                in: input
            )
            let requestedDestination = try CoreIntentProviderSupport.string(
                "destinationPath",
                in: input
            )
            let source = try authorizedPath(requestedSource, context: context)
            let destination = try authorizedPath(
                requestedDestination,
                context: context
            )
            let output = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try moveBoundPath(source, to: destination)
                return IntentValue.object([
                    "path": .string(destination.resolvedPath)
                ])
            }
            return .success(output)
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch let error as OperationError {
            return reply(for: error, codes: codes)
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "path-move-failed"
            )
        }
    }

    static func trashPath(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes
    ) async -> IntentProviderReply {
        await mutatePath(
            envelope: envelope,
            context: context,
            codes: codes,
            operationName: "path-trash"
        ) { path in
            try trashBoundPath(path)
            return .object([:])
        }
    }

    static func mutatePath(
        envelope: IntentEnvelope,
        context: IntentProviderContext,
        codes: ErrorCodes,
        operationName: String,
        operation: @escaping @Sendable (
            AuthorizedFilesystemPath
        ) throws -> IntentValue
    ) async -> IntentProviderReply {
        do {
            let input = try CoreIntentProviderSupport.object(envelope.input)
            let requestedPath = try CoreIntentProviderSupport.string(
                "path",
                in: input
            )
            let path = try authorizedPath(requestedPath, context: context)
            let output = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try operation(path)
            }
            return .success(output)
        } catch let error as CoreIntentProviderInputError {
            return CoreIntentProviderSupport.invalidInputFailure(error)
        } catch CoreIntentProviderExecutionError.deadlineExceeded {
            return .failure(
                IntentProviderFailure(code: .kernel(.deadlineExceeded))
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch let error as OperationError {
            return reply(for: error, codes: codes)
        } catch {
            return CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "\(operationName)-failed"
            )
        }
    }

    static func directoryCursor(from cursor: String?) throws -> DirectoryCursor {
        guard let cursor, !cursor.isEmpty else {
            return DirectoryCursor(offset: 0, fingerprint: nil)
        }
        let components = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1",
              let offset = Int(components[1]),
              offset >= 0,
              !components[2].isEmpty
        else {
            throw OperationError.filesystemFailed("invalid-cursor")
        }
        return DirectoryCursor(
            offset: offset,
            fingerprint: String(components[2])
        )
    }

    static func directoryOutput(
        entries: [IntentValue],
        nextCursor: String?,
        path: String
    ) -> IntentValue {
        .object([
            "entries": .array(entries),
            "nextCursor": nextCursor.map(IntentValue.string) ?? .null,
            "path": .string(path),
        ])
    }

    static func directoryFingerprint(descriptor: Int32) throws -> String {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw OperationError.filesystemFailed(
                "directory-fingerprint-unavailable"
            )
        }
        return [
            String(metadata.st_mtimespec.tv_sec, radix: 16),
            String(metadata.st_mtimespec.tv_nsec, radix: 16),
            String(metadata.st_dev, radix: 16),
            String(metadata.st_ino, radix: 16),
        ].joined(separator: "-")
    }

    static func fileFingerprint(_ metadata: stat) -> String {
        [
            String(metadata.st_size, radix: 16),
            String(metadata.st_mtimespec.tv_sec, radix: 16),
            String(metadata.st_mtimespec.tv_nsec, radix: 16),
        ].joined(separator: "-")
    }

    static func atomicallyReplaceFile(
        path: AuthorizedFilesystemPath,
        data: Data
    ) throws {
        let parent = try openBoundParent(path)
        defer { Darwin.close(parent) }
        let metadata = try boundMetadata(path, parent: parent)
        guard (metadata.st_mode & S_IFMT) != S_IFDIR else {
            throw OperationError.filesystemFailed("path-is-directory")
        }

        let temporaryName = ".tenon-replacement-\(UUID().uuidString)"
        let temporary = temporaryName.withCString {
            openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard temporary >= 0 else { throw mapPOSIXError(errno) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporary)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString {
                    unlinkat(parent, $0, 0)
                }
            }
        }
        try writeAll(data, to: temporary)
        guard fsync(temporary) == 0 else { throw mapPOSIXError(errno) }
        let status = temporaryName.withCString { temporaryPointer in
            path.leafName.withCString { destinationPointer in
                renameat(
                    parent,
                    temporaryPointer,
                    parent,
                    destinationPointer
                )
            }
        }
        guard status == 0 else { throw mapPOSIXError(errno) }
        shouldRemoveTemporary = false
    }

    static func boundPathExists(
        _ path: AuthorizedFilesystemPath
    ) throws -> Bool {
        let parent: Int32
        do {
            parent = try openBoundParent(path)
        } catch OperationError.pathNotFound {
            // An ancestor that is still missing — or that a non-directory
            // occupies — answers the question rather than failing it; anything
            // else in the walk stays an error.
            return false
        }
        defer { Darwin.close(parent) }
        var metadata = stat()
        let status = path.leafName.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 {
            guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
                throw OperationError.filesystemFailed(
                    "authorized-path-became-symlink"
                )
            }
            return true
        }
        guard errno == ENOENT else { throw mapPOSIXError(errno) }
        return false
    }

    static func createBoundDirectory(
        _ path: AuthorizedFilesystemPath
    ) throws {
        let parent = try openBoundParent(path)
        defer { Darwin.close(parent) }
        let status = path.leafName.withCString {
            mkdirat(parent, $0, mode_t(0o700))
        }
        guard status == 0 else { throw mapPOSIXError(errno) }
    }

    static func createBoundFile(_ path: AuthorizedFilesystemPath) throws {
        let descriptor = try openBound(
            path,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode: mode_t(0o600)
        )
        Darwin.close(descriptor)
    }

    static func moveBoundPath(
        _ source: AuthorizedFilesystemPath,
        to destination: AuthorizedFilesystemPath
    ) throws {
        let sourceParent = try openBoundParent(source)
        defer { Darwin.close(sourceParent) }
        let destinationParent = try openBoundParent(destination)
        defer { Darwin.close(destinationParent) }
        _ = try boundMetadata(source, parent: sourceParent)
        let status = source.leafName.withCString { sourcePointer in
            destination.leafName.withCString { destinationPointer in
                renameatx_np(
                    sourceParent,
                    sourcePointer,
                    destinationParent,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else { throw mapPOSIXError(errno) }
    }

    static func trashBoundPath(_ path: AuthorizedFilesystemPath) throws {
        let sourceParent = try openBoundParent(path)
        defer { Darwin.close(sourceParent) }
        _ = try boundMetadata(path, parent: sourceParent)

        let trashPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .path
        let trash = Darwin.open(
            trashPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard trash >= 0 else {
            throw OperationError.filesystemFailed("trash-unavailable")
        }
        defer { Darwin.close(trash) }

        for attempt in 0 ..< 16 {
            let suffix = attempt == 0 ? "" : "-\(UUID().uuidString)"
            let destinationName = path.leafName + suffix
            let status = path.leafName.withCString { sourcePointer in
                destinationName.withCString { destinationPointer in
                    renameatx_np(
                        sourceParent,
                        sourcePointer,
                        trash,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if status == 0 { return }
            guard errno == EEXIST else { throw mapPOSIXError(errno) }
        }
        throw OperationError.filesystemFailed("trash-name-exhausted")
    }

    /// Returns an owned descriptor for the directory the leaf resolves against.
    ///
    /// The binding's use-time walk refuses to follow a symlink grown into a
    /// previously-missing component; a component that is still missing — or
    /// that a non-directory now occupies — reports not-found through the
    /// POSIX mapping.
    static func openBoundParent(
        _ path: AuthorizedFilesystemPath
    ) throws -> Int32 {
        do {
            return try path.openLeafParentDirectoryDescriptor()
        } catch AuthorizedFilesystemPathError.becameSymlink {
            throw OperationError.filesystemFailed(
                "authorized-path-became-symlink"
            )
        } catch AuthorizedFilesystemPathError.suffixComponentUnavailable(
            let code
        ) {
            throw mapPOSIXError(code)
        }
    }

    static func openBound(
        _ path: AuthorizedFilesystemPath,
        flags: Int32,
        mode: mode_t = 0
    ) throws -> Int32 {
        let parent = try openBoundParent(path)
        defer { Darwin.close(parent) }
        let descriptor = path.leafName.withCString {
            openat(parent, $0, flags, mode)
        }
        guard descriptor >= 0 else { throw mapPOSIXError(errno) }
        return descriptor
    }

    static func boundMetadata(
        _ path: AuthorizedFilesystemPath,
        parent: Int32
    ) throws -> stat {
        var metadata = stat()
        let status = path.leafName.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { throw mapPOSIXError(errno) }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw OperationError.filesystemFailed(
                "authorized-path-became-symlink"
            )
        }
        return metadata
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw mapPOSIXError(errno)
                }
            }
        }
    }

    static func mapPOSIXError(_ code: Int32) -> OperationError {
        switch code {
        case ENOENT, ENOTDIR:
            .pathNotFound
        case EEXIST:
            .pathAlreadyExists
        case ELOOP:
            .filesystemFailed("authorized-path-became-symlink")
        case EXDEV:
            .filesystemFailed("cross-volume-operation-unsupported")
        case EACCES, EPERM:
            .filesystemFailed("permission-denied")
        default:
            .filesystemFailed("posix-operation-failed-\(code)")
        }
    }

    static func mapFoundationError(_ error: Error) -> OperationError {
        let cocoa = error as? CocoaError
        switch cocoa?.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .pathNotFound
        case .fileWriteFileExists:
            return .pathAlreadyExists
        default:
            return .filesystemFailed("foundation-operation-failed")
        }
    }

    static func reply(
        for error: OperationError,
        codes: ErrorCodes
    ) -> IntentProviderReply {
        switch error {
        case .pathNotFound:
            CoreIntentProviderSupport.failure(
                code: codes.pathNotFound,
                reason: "path-not-found"
            )
        case .pathAlreadyExists:
            CoreIntentProviderSupport.failure(
                code: codes.pathAlreadyExists,
                reason: "path-already-exists"
            )
        case .contentNotText:
            CoreIntentProviderSupport.failure(
                code: codes.contentNotText,
                reason: "content-is-not-utf8"
            )
        case .contentTooLarge:
            CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: "inline-content-limit-exceeded"
            )
        case let .filesystemFailed(reason):
            CoreIntentProviderSupport.failure(
                code: codes.filesystemFailed,
                reason: reason
            )
        }
    }
}

// Internal, not fileprivate: a write landing inside one page's identity-to-read
// window cannot be staged through the public bindings, so the tests drive the
// paging pair directly. The directory pager is here for the same reason — a
// mid-page vanishing entry and the number of times a page is validated are both
// unreachable from the binding.
extension FilesystemIntentProvider {
    struct DirectoryPage: Sendable {
        let entries: [IntentValue]
        let nextCursor: String?
    }

    struct DirectoryCursor: Sendable {
        let offset: Int
        let fingerprint: String?
    }

    /// One bounded page of directory entries.
    ///
    /// The page is accounted incrementally — each candidate's own canonical
    /// encoding is added to a running total — and validated once, after the
    /// scan. Validating every prefix instead costs a full traversal and a full
    /// re-encode per entry, which is quadratic in the page.
    ///
    /// `interposedBeforeEntryMetadata` runs with an entry's name immediately
    /// before that entry is stat'ed; tests use it to make one entry vanish
    /// inside the window and assert the page still comes back.
    /// `onPageValidation` runs immediately before each validation of an
    /// assembled page, so a test can count validations instead of timing them.
    static func directoryPage(
        path: AuthorizedFilesystemPath,
        cursor: DirectoryCursor,
        limit: Int,
        includeMetadata: Bool,
        deadline: ContinuousClock.Instant,
        interposedBeforeEntryMetadata: ((String) throws -> Void)? = nil,
        onPageValidation: (() -> Void)? = nil
    ) throws -> DirectoryPage {
        let descriptor = try openBound(
            path,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard let directory = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw mapPOSIXError(errno)
        }
        defer { closedir(directory) }

        let directoryDescriptor = dirfd(directory)
        let fingerprint = try directoryFingerprint(
            descriptor: directoryDescriptor
        )
        if let expected = cursor.fingerprint, expected != fingerprint {
            throw OperationError.filesystemFailed("stale-cursor")
        }

        let limits = IntentValueLimits.default
        let iso = Date.ISO8601FormatStyle()
        // `{"entries":[…],"nextCursor":C,"path":P}` is 36 fixed bytes once the
        // canonical encoder has sorted the keys, plus the two encoded scalars,
        // plus each entry and the comma before it. The cursor is seeded at the
        // longest this page could issue, and `null` is shorter still, so the
        // running total is never optimistic.
        let encodedPathBytes = try IntentValue
            .string(path.resolvedPath)
            .canonicalJSONData()
            .count
        let longestCursorBytes = try max(
            IntentValue
                .string("v1:\(cursor.offset + limit):\(fingerprint)")
                .canonicalJSONData()
                .count,
            4
        )
        var encodedBytes = 36 + encodedPathBytes + longestCursorBytes
        // Root object, entries array, nextCursor, path. Object keys are not
        // counted as values.
        var valueCount = 4

        var scanned = 0
        var entries: [IntentValue] = []
        entries.reserveCapacity(limit)
        var hasMore = false
        while true {
            // `readdir` reports end-of-directory and failure the same way, by
            // returning nil, and separates them only through errno — which it
            // leaves untouched when the directory simply ends. Nothing may run
            // between this reset and the check on the next line: the metadata
            // formatting and the canonical encoding below both call into
            // Foundation, which is free to set errno on a call that succeeded,
            // and one stray value left there would turn a complete scan into a
            // thrown POSIX error.
            errno = 0
            guard let rawEntry = readdir(directory) else {
                if errno != 0 { throw mapPOSIXError(errno) }
                break
            }
            if scanned.isMultiple(of: 64) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw CancellationError()
                }
            }
            let nameBytes = withUnsafeBytes(of: rawEntry.pointee.d_name) {
                Array($0.prefix { $0 != 0 })
            }
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw OperationError.filesystemFailed(
                    "directory-entry-is-not-utf8"
                )
            }
            guard name != ".", name != ".." else { continue }
            if scanned < cursor.offset {
                scanned += 1
                continue
            }

            guard entries.count < limit else {
                hasMore = true
                break
            }

            // One syscall answers both questions, and it answers the kind
            // question exactly as `d_type` alone did: a known kind is never
            // re-derived from the stat, so asking for metadata cannot move an
            // entry between file and directory.
            var metadata = stat()
            var metadataAvailable = false
            if rawEntry.pointee.d_type == DT_UNKNOWN || includeMetadata {
                try interposedBeforeEntryMetadata?(name)
                let status = name.withCString {
                    fstatat(
                        directoryDescriptor,
                        $0,
                        &metadata,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                if status == 0 {
                    metadataAvailable = true
                } else if rawEntry.pointee.d_type == DT_UNKNOWN {
                    throw mapPOSIXError(errno)
                }
                // Otherwise the entry left between readdir and the stat.
                // readdir already handed the name over, so it stays in the page
                // with unknown metadata.
            }

            let isDirectory: Bool
            if rawEntry.pointee.d_type == DT_DIR {
                isDirectory = true
            } else if rawEntry.pointee.d_type == DT_UNKNOWN {
                isDirectory = (metadata.st_mode & S_IFMT) == S_IFDIR
            } else {
                isDirectory = false
            }

            var fields: [String: IntentValue] = [
                "name": .string(name),
                "isDirectory": .bool(isDirectory),
            ]
            if includeMetadata {
                fields["sizeBytes"] = metadataAvailable
                    ? .integer(Int64(metadata.st_size))
                    : .null
                fields["modifiedAt"] = metadataAvailable
                    ? .string(
                        iso.format(
                            Date(
                                timeIntervalSince1970:
                                    Double(metadata.st_mtimespec.tv_sec)
                            )
                        )
                    )
                    : .null
            }
            let candidate = IntentValue.object(fields)

            // A throw here is unreachable — NAME_MAX is 255 bytes against a
            // 64 KB string limit — and swallowing it would emit an empty page
            // that still claims more, which is an endless paging loop.
            let entryBytes = try candidate.canonicalJSONData().count
            let separator = entries.isEmpty ? 0 : 1
            let entryValues = includeMetadata ? 5 : 3
            guard encodedBytes + separator + entryBytes <= limits.maxEncodedBytes,
                  valueCount + entryValues <= limits.maxValueCount,
                  entries.count + 1 <= limits.maxCollectionCount
            else {
                hasMore = true
                break
            }
            encodedBytes += separator + entryBytes
            valueCount += entryValues
            entries.append(candidate)
            scanned += 1
        }

        while true {
            let nextCursor = hasMore
                ? "v1:\(cursor.offset + entries.count):\(fingerprint)"
                : nil
            let page = directoryOutput(
                entries: entries,
                nextCursor: nextCursor,
                path: path.resolvedPath
            )
            onPageValidation?()
            do {
                try page.validate()
            } catch {
                // The accounting above is conservative, so this is unreachable;
                // it stays because dropping the last entry on a page of one
                // would otherwise loop forever on an empty page that claims more.
                guard entries.count > 1 else {
                    throw OperationError.filesystemFailed("page-entry-too-large")
                }
                entries.removeLast()
                hasMore = true
                continue
            }
            return DirectoryPage(entries: entries, nextCursor: nextCursor)
        }
    }

    /// Where the next file page starts, and the file identity that made that byte
    /// offset mean something. Purely a value: the host keeps nothing when a caller
    /// drops one.
    struct FileReadCursor: Sendable {
        let offset: Int
        let fingerprint: String
    }

    /// Rejects anything this provider did not write. A caller cannot widen its own
    /// read by handing back a negative offset, a foreign version, or a fourth field;
    /// a cursor that fails to decode is invalid input, not a filesystem condition.
    static func fileReadCursor(from cursor: String?) throws -> FileReadCursor? {
        guard let cursor, !cursor.isEmpty else { return nil }
        let components = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1",
              let offset = Int(components[1]),
              offset >= 0,
              !components[2].isEmpty
        else {
            throw CoreIntentProviderInputError.missingOrInvalidField("cursor")
        }
        return FileReadCursor(
            offset: offset,
            fingerprint: String(components[2])
        )
    }

    /// `interposedBeforePageRead` runs inside the identity-to-read window; tests use it
    /// to land a concurrent write there and assert the page comes back invalidated
    /// instead of carrying bytes from the new arrangement.
    static func readTextFile(
        path: AuthorizedFilesystemPath,
        cursor: FileReadCursor?,
        interposedBeforePageRead: (() throws -> Void)? = nil
    ) throws -> IntentValue {
        let descriptor = try openBound(
            path,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw mapPOSIXError(errno)
        }
        guard (metadata.st_mode & S_IFMT) != S_IFDIR else {
            throw OperationError.filesystemFailed("path-is-directory")
        }

        let fingerprint = fileFingerprint(metadata)
        if let expected = cursor?.fingerprint, expected != fingerprint {
            // The offset was issued against bytes that no longer exist in that
            // arrangement; shifted content would be silently wrong, so the caller
            // starts again from the first byte.
            return IntentValue.object([
                "content": CoreIntentProviderSupport.textOutput(""),
                "cursor": .null,
                "invalidated": .bool(true),
            ])
        }

        let size = Int(metadata.st_size)
        let offset: Int
        if let cursor {
            // A cursor is only ever issued while bytes remain, so with a matching
            // identity a past-the-end offset is nothing this host wrote.
            guard cursor.offset < size else {
                throw CoreIntentProviderInputError.missingOrInvalidField("cursor")
            }
            offset = cursor.offset
        } else {
            offset = 0
        }

        let requested = min(size - offset, maximumInlineBytes)
        try interposedBeforePageRead?()
        let chunk: Data
        do {
            if offset > 0 {
                try handle.seek(toOffset: UInt64(offset))
            }
            chunk = try handle.read(upToCount: requested) ?? Data()
        } catch {
            throw mapFoundationError(error)
        }

        // The identity was captured before the bytes. A write landing between the
        // two is caught on every earlier page by the next call's identity check,
        // but the final page has no next call — so every page re-checks after the
        // read, and bytes are served only when the identity held across it.
        var verification = stat()
        guard fstat(descriptor, &verification) == 0 else {
            throw mapPOSIXError(errno)
        }
        guard fileFingerprint(verification) == fingerprint else {
            return IntentValue.object([
                "content": CoreIntentProviderSupport.textOutput(""),
                "cursor": .null,
                "invalidated": .bool(true),
            ])
        }

        // The page limit cuts at a byte position; back off from any trailing bytes
        // of a split multi-byte sequence so every page decodes on its own and no
        // character is ever divided across pages.
        var page = chunk
        var text = String(data: page, encoding: .utf8)
        if offset + chunk.count < size {
            var backoff = 0
            while text == nil, backoff < 3, !page.isEmpty {
                page = page.dropLast()
                backoff += 1
                text = String(data: page, encoding: .utf8)
            }
        }
        guard let text else { throw OperationError.contentNotText }

        let nextOffset = offset + page.count
        let hasMore = nextOffset < size
        guard !hasMore || !page.isEmpty else {
            // A page that accepts nothing while bytes remain would hand back a
            // cursor that never advances.
            throw OperationError.filesystemFailed("file-read-page-empty")
        }

        let output = IntentValue.object([
            "content": CoreIntentProviderSupport.textOutput(text),
            "cursor": hasMore
                ? .string("v1:\(nextOffset):\(fingerprint)")
                : .null,
            "invalidated": .bool(false),
        ])
        try output.validate()
        return output
    }
}

// Internal, not fileprivate: a staging's lifetime is a fabricated instant in tests —
// neither expiry nor the capacity it frees can be exercised through the public
// bindings without waiting out real wall-clock time — so the tests drive the staged
// write machinery directly, exactly as they drive the read-paging pair above.
extension FilesystemIntentProvider {
    /// Where the next staged page must land, and the staging identity that byte
    /// count was issued against. Purely a value: the registry entry it names is
    /// the only host-owned state.
    struct FileWriteCursor: Sendable {
        let offset: Int
        let token: String
    }

    /// Rejects anything this provider did not write. A caller cannot continue a
    /// staging it never opened by handing back a negative count, a foreign
    /// version, or a fourth field; a cursor that fails to decode is invalid
    /// input, not a filesystem condition.
    static func fileWriteCursor(from cursor: String?) throws -> FileWriteCursor? {
        guard let cursor, !cursor.isEmpty else { return nil }
        let components = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1",
              let offset = Int(components[1]),
              offset >= 0,
              !components[2].isEmpty
        else {
            throw CoreIntentProviderInputError.missingOrInvalidField("cursor")
        }
        return FileWriteCursor(
            offset: offset,
            token: String(components[2])
        )
    }

    /// Open stagings one provider tracks at once. Each live entry pins one parent
    /// directory descriptor, so the ledger and the descriptors it holds are both
    /// bounded by this number.
    static let maximumConcurrentFileWriteStagings = 4

    /// A staging's whole life, fixed when it opens and never extended: within it a
    /// caller pages `maximumStagedFileWriteBytes` with generous slack, and a
    /// staging nobody commits cannot outlive it (invariant 10).
    static let fileWriteStagingLifetime: Duration = .seconds(300)

    /// One open staging: the target it will publish over, the dot-file collecting
    /// its pages, the file identity that dot-file had when this provider last
    /// touched it, and the instant the staging dies.
    struct FileWriteStaging: Sendable {
        let token: String
        let target: AuthorizedFilesystemPath
        let stagingLeafName: String
        let device: dev_t
        let inode: ino_t
        var stagedBytes: Int
        let expiresAt: ContinuousClock.Instant
    }

    /// Host-owned ledger of open stagings. Claim removes the entry while a page
    /// works on it, so exactly one in-flight call can continue a staging and a
    /// concurrent page presenting the same cursor fails closed.
    final class FileWriteStagingRegistry: Sendable {
        private let state = OSAllocatedUnfairLock(
            initialState: [String: FileWriteStaging]()
        )

        /// Removes and returns every staging past its lifetime; the caller owns
        /// unlinking their dot-files.
        func takeExpired(now: ContinuousClock.Instant) -> [FileWriteStaging] {
            state.withLock { entries in
                let expired = entries.values.filter { $0.expiresAt <= now }
                for staging in expired {
                    entries.removeValue(forKey: staging.token)
                }
                return expired
            }
        }

        /// Capacity check and insert are one step, so concurrent begins cannot
        /// overshoot the bound between checking and registering.
        func insert(_ staging: FileWriteStaging, capacity: Int) -> Bool {
            state.withLock { entries in
                guard entries.count < capacity else { return false }
                entries[staging.token] = staging
                return true
            }
        }

        func claim(token: String) -> FileWriteStaging? {
            state.withLock { $0.removeValue(forKey: token) }
        }

        func restore(_ staging: FileWriteStaging) {
            state.withLock { $0[staging.token] = staging }
        }
    }

    /// One staged page: begins a staging (nil cursor), appends to it, or commits
    /// it by atomically renaming the staging over the target. Returns the cursor
    /// naming the next page, or nil once the write is complete. Abandoned
    /// stagings are reclaimed here, at next use, rather than by a background
    /// task: the ledger is bounded, so the sweep is O(capacity) and a provider
    /// nobody writes through holds at most `maximumConcurrentFileWriteStagings`
    /// orphaned dot-files until its next write.
    static func stagedWrite(
        path: AuthorizedFilesystemPath,
        data: Data,
        cursor: FileWriteCursor?,
        commit: Bool,
        registry: FileWriteStagingRegistry,
        now: ContinuousClock.Instant = .now
    ) throws -> String? {
        for expired in registry.takeExpired(now: now) {
            discardStagingFile(of: expired)
        }
        guard let cursor else {
            // A no-cursor commit is the single-page atomic write and never
            // reaches this path, so no cursor always means "open a staging".
            return try beginStaging(
                path: path,
                data: data,
                registry: registry,
                now: now
            )
        }
        return try continueStaging(
            path: path,
            data: data,
            cursor: cursor,
            commit: commit,
            registry: registry
        )
    }

    private static func beginStaging(
        path: AuthorizedFilesystemPath,
        data: Data,
        registry: FileWriteStagingRegistry,
        now: ContinuousClock.Instant
    ) throws -> String {
        let parent = try openBoundParent(path)
        defer { Darwin.close(parent) }
        // A staged write publishes over an existing file only, exactly as the
        // single-page write does.
        let metadata = try boundMetadata(path, parent: parent)
        guard (metadata.st_mode & S_IFMT) != S_IFDIR else {
            throw OperationError.filesystemFailed("path-is-directory")
        }

        let token = UUID().uuidString
        let stagingLeafName = ".tenon-staging-\(token)"
        let descriptor = stagingLeafName.withCString {
            openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw mapPOSIXError(errno) }
        var keepStagingFile = false
        defer {
            Darwin.close(descriptor)
            if !keepStagingFile {
                _ = stagingLeafName.withCString {
                    unlinkat(parent, $0, 0)
                }
            }
        }
        try writeAll(data, to: descriptor)
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else {
            throw mapPOSIXError(errno)
        }
        let staging = FileWriteStaging(
            token: token,
            target: path,
            stagingLeafName: stagingLeafName,
            device: identity.st_dev,
            inode: identity.st_ino,
            stagedBytes: data.count,
            expiresAt: now.advanced(by: fileWriteStagingLifetime)
        )
        guard registry.insert(
            staging,
            capacity: maximumConcurrentFileWriteStagings
        ) else {
            throw OperationError.filesystemFailed("staging-capacity-exhausted")
        }
        keepStagingFile = true
        return "v1:\(staging.stagedBytes):\(token)"
    }

    private static func continueStaging(
        path: AuthorizedFilesystemPath,
        data: Data,
        cursor: FileWriteCursor,
        commit: Bool,
        registry: FileWriteStagingRegistry
    ) throws -> String? {
        guard var staging = registry.claim(token: cursor.token) else {
            // Forged, expired, or concurrently in flight — nothing this
            // provider will continue.
            throw CoreIntentProviderInputError.missingOrInvalidField("cursor")
        }
        // Past the claim, every failure reclaims the staging: a cursor
        // presented against the wrong target or out of sequence means the
        // caller's view of the staging is broken, and a broken sequence is
        // never resumed.
        do {
            guard staging.target.resolvedPath == path.resolvedPath,
                  cursor.offset == staging.stagedBytes
            else {
                throw CoreIntentProviderInputError.missingOrInvalidField("cursor")
            }
            guard staging.stagedBytes + data.count
                <= CoreIntentPayloadPolicy.maximumStagedFileWriteBytes
            else {
                throw OperationError.filesystemFailed(
                    "staged-write-limit-exceeded"
                )
            }

            let parent = try openBoundParent(path)
            defer { Darwin.close(parent) }
            let descriptor = staging.stagingLeafName.withCString {
                openat(parent, $0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw OperationError.filesystemFailed("staging-lost")
            }
            defer { Darwin.close(descriptor) }
            // The dot-file must still be the one this provider wrote, holding
            // exactly the bytes the ledger accounted for; anything else means
            // something outside the staging touched it.
            var identity = stat()
            guard fstat(descriptor, &identity) == 0,
                  identity.st_dev == staging.device,
                  identity.st_ino == staging.inode,
                  Int(identity.st_size) == staging.stagedBytes
            else {
                throw OperationError.filesystemFailed("staging-lost")
            }
            try writeAll(data, to: descriptor)
            staging.stagedBytes += data.count

            guard commit else {
                registry.restore(staging)
                return "v1:\(staging.stagedBytes):\(staging.token)"
            }

            guard fsync(descriptor) == 0 else { throw mapPOSIXError(errno) }
            var settled = stat()
            guard fstat(descriptor, &settled) == 0,
                  Int(settled.st_size) == staging.stagedBytes
            else {
                throw OperationError.filesystemFailed("staging-lost")
            }
            // The commit publishes over an existing file only, exactly as the
            // single-page write does.
            let metadata = try boundMetadata(path, parent: parent)
            guard (metadata.st_mode & S_IFMT) != S_IFDIR else {
                throw OperationError.filesystemFailed("path-is-directory")
            }
            let status = staging.stagingLeafName.withCString { stagingPointer in
                path.leafName.withCString { targetPointer in
                    renameat(parent, stagingPointer, parent, targetPointer)
                }
            }
            guard status == 0 else { throw mapPOSIXError(errno) }
            return nil
        } catch {
            discardStagingFile(of: staging)
            throw error
        }
    }

    /// Best-effort: the ledger entry is already gone, so a failure here leaves
    /// only an orphaned dot-file beside the target — the same residue an
    /// interrupted single-page write can leave — never a live staging.
    private static func discardStagingFile(of staging: FileWriteStaging) {
        guard let parent = try? openBoundParent(staging.target) else { return }
        defer { Darwin.close(parent) }
        _ = staging.stagingLeafName.withCString {
            unlinkat(parent, $0, 0)
        }
    }
}
