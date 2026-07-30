import Darwin
import Foundation
import TenonIntentCore

/// Foundation-backed filesystem primitives for the canonical v1 core contracts.
///
/// This value only owns bindings. The app decides which provider generation aggregates and
/// activates them.
public struct FilesystemIntentProvider: Sendable {
    public let bindings: [IntentProviderBinding]

    public init() throws {
        let codes = try ErrorCodes()
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
                    codes: codes
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

    struct DirectoryPage: Sendable {
        let entries: [IntentValue]
        let nextCursor: String?
    }

    struct DirectoryCursor: Sendable {
        let offset: Int
        let fingerprint: String?
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

            let page = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try directoryPage(
                    path: path,
                    cursor: cursor,
                    limit: limit,
                    deadline: envelope.deadline
                )
            }
            return .success(
                .object([
                    "entries": .array(page.entries),
                    "nextCursor": page.nextCursor.map(IntentValue.string) ?? .null,
                ])
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
            let output = try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try readTextFile(path: path)
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
        codes: ErrorCodes
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

            try await CoreIntentProviderSupport.runBlocking(
                deadline: envelope.deadline,
                context: context
            ) {
                try atomicallyReplaceFile(path: path, data: data)
            }
            return .success(.object([:]))
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

    static func directoryPage(
        path: AuthorizedFilesystemPath,
        cursor: DirectoryCursor,
        limit: Int,
        deadline: ContinuousClock.Instant
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

        var scanned = 0
        var entries: [IntentValue] = []
        entries.reserveCapacity(limit)
        var hasMore = false
        errno = 0
        while let rawEntry = readdir(directory) {
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

            let isDirectory: Bool
            if rawEntry.pointee.d_type == DT_DIR {
                isDirectory = true
            } else if rawEntry.pointee.d_type == DT_UNKNOWN {
                var metadata = stat()
                let status = name.withCString {
                    fstatat(
                        directoryDescriptor,
                        $0,
                        &metadata,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard status == 0 else { throw mapPOSIXError(errno) }
                isDirectory = (metadata.st_mode & S_IFMT) == S_IFDIR
            } else {
                isDirectory = false
            }

            let candidate = IntentValue.object([
                "name": .string(name),
                "isDirectory": .bool(isDirectory),
            ])
            let candidateEntries = entries + [candidate]
            let candidateCursor =
                "v1:\(cursor.offset + candidateEntries.count):\(fingerprint)"
            let candidateOutput = directoryOutput(
                entries: candidateEntries,
                nextCursor: candidateCursor
            )
            do {
                try candidateOutput.validate()
            } catch {
                hasMore = true
                break
            }
            entries.append(candidate)
            scanned += 1
        }
        if !hasMore, errno != 0 {
            throw mapPOSIXError(errno)
        }

        return DirectoryPage(
            entries: entries,
            nextCursor: hasMore
                ? "v1:\(cursor.offset + entries.count):\(fingerprint)"
                : nil
        )
    }

    static func directoryOutput(
        entries: [IntentValue],
        nextCursor: String?
    ) -> IntentValue {
        .object([
            "entries": .array(entries),
            "nextCursor": nextCursor.map(IntentValue.string) ?? .null,
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

    static func readTextFile(
        path: AuthorizedFilesystemPath
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

        let data: Data
        do {
            data = try handle.read(upToCount: maximumInlineBytes + 1) ?? Data()
        } catch {
            throw mapFoundationError(error)
        }
        guard data.count <= maximumInlineBytes else {
            throw OperationError.contentTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OperationError.contentNotText
        }
        guard text.count <= CoreIntentPayloadPolicy.maximumInlineTextCharacters else {
            throw OperationError.contentTooLarge
        }

        let output = IntentValue.object([
            "content": CoreIntentProviderSupport.textOutput(text)
        ])
        do {
            try output.validate()
        } catch {
            throw OperationError.contentTooLarge
        }
        return output
    }

    static func atomicallyReplaceFile(
        path: AuthorizedFilesystemPath,
        data: Data
    ) throws {
        let parent = try path.duplicateParentDirectoryDescriptor()
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
        let parent = try path.duplicateParentDirectoryDescriptor()
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
        let parent = try path.duplicateParentDirectoryDescriptor()
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
        let sourceParent = try source.duplicateParentDirectoryDescriptor()
        defer { Darwin.close(sourceParent) }
        let destinationParent =
            try destination.duplicateParentDirectoryDescriptor()
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
        let sourceParent = try path.duplicateParentDirectoryDescriptor()
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

    static func openBound(
        _ path: AuthorizedFilesystemPath,
        flags: Int32,
        mode: mode_t = 0
    ) throws -> Int32 {
        let parent = try path.duplicateParentDirectoryDescriptor()
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
