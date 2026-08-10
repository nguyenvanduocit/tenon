// @domain: agent-lens
import Darwin
import Foundation

struct AgentTerminalIdentity: Equatable, Sendable {
    let slotID: UUID
    let surfaceToken: UUID
    let foregroundPID: UInt64
    let cwd: URL
    let title: String
}

enum AgentResolutionConfidence: String, Sendable {
    case exact
    case inferred
    case processOnly
}

struct AgentLensResolution: Equatable, Sendable {
    let provider: AgentProvider
    let sessionID: String?
    let foregroundPID: UInt64
    let transcriptURL: URL?
    let confidence: AgentResolutionConfidence
    let detail: String

    var capabilities: AgentLensCapabilities {
        transcriptURL == nil ? [.terminalInput] : .transcriptPTY
    }
}

/// Off-main semantic resolver. The foreground PID proves which process owns the PTY;
/// an open transcript FD proves the exact file when available. A recent cwd-matched file
/// is explicitly marked inferred, never silently promoted to exact identity.
actor AgentLensDiscovery {
    private let homeDirectory: URL
    private let codexSessionsRoot: URL
    private let fileManager: FileManager
    private let sessionRegistry: AgentSessionRegistry
    private let codexHookDegradation: String?
    private let claudeHookDegradation: String?
    private let processProvider: (@Sendable (UInt64) -> AgentProvider?)?
    private let processGroupProvider: (@Sendable (UInt64) -> UInt64?)?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        sessionRegistry: AgentSessionRegistry? = nil,
        codexSessionsRoot: URL? = nil,
        codexHookDegradation: String? = nil,
        claudeHookDegradation: String? = nil,
        processProvider: (@Sendable (UInt64) -> AgentProvider?)? = nil,
        processGroupProvider: (@Sendable (UInt64) -> UInt64?)? = nil
    ) {
        let resolvedCodexSessionsRoot = (codexSessionsRoot ?? homeDirectory
            .appendingPathComponent(".codex/sessions", isDirectory: true))
            .standardizedFileURL
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.codexSessionsRoot = resolvedCodexSessionsRoot
        self.fileManager = fileManager
        self.sessionRegistry = sessionRegistry ?? AgentSessionRegistry(
            allowedTranscriptRoots: [
                resolvedCodexSessionsRoot,
                homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
            ]
        )
        self.processProvider = processProvider
        self.processGroupProvider = processGroupProvider
        self.codexHookDegradation = codexHookDegradation
        self.claudeHookDegradation = claudeHookDegradation
    }

    func resolve(_ identity: AgentTerminalIdentity) async -> AgentLensResolution? {
        guard let provider = processProvider?(identity.foregroundPID)
            ?? provider(for: identity.foregroundPID)
        else { return nil }
        let roots = transcriptRoots(for: provider, cwd: identity.cwd)

        if let binding = await sessionRegistry.binding(
            paneID: identity.slotID,
            surfaceToken: identity.surfaceToken
        ), binding.provider == provider,
           binding.processGroupID == nil ||
               binding.processGroupID == processGroupID(for: identity.foregroundPID),
           let transcript = validate(binding.transcriptURL, under: roots)
        {
            return AgentLensResolution(
                provider: provider,
                sessionID: binding.sessionID,
                foregroundPID: identity.foregroundPID,
                transcriptURL: transcript,
                confidence: .exact,
                detail: "Transcript was reported by the root \(provider.displayName) session for this terminal"
            )
        }

        if provider != .codex,
           let exact = openTranscript(for: identity.foregroundPID, under: roots)
        {
            return AgentLensResolution(
                provider: provider,
                sessionID: nil,
                foregroundPID: identity.foregroundPID,
                transcriptURL: exact,
                confidence: .exact,
                detail: "Transcript is open by the foreground process"
            )
        }

        // Codex commonly has a Node foreground process and a native child with several
        // transcript FDs. Cwd + mtime cannot distinguish concurrent sessions, so Codex
        // stays process-only until its root hook reports the exact resource.
        return AgentLensResolution(
            provider: provider,
            sessionID: nil,
            foregroundPID: identity.foregroundPID,
            transcriptURL: nil,
            confidence: .processOnly,
            detail: processOnlyDetail(for: provider)
        )
    }

    private func processOnlyDetail(for provider: AgentProvider) -> String {
        let degradation = switch provider {
        case .claude: claudeHookDegradation
        case .codex: codexHookDegradation
        }
        if let degradation {
            return "\(provider.displayName) detected, but its Tenon hook is unavailable: \(degradation)"
        }
        return "\(provider.displayName) detected; waiting for its terminal-bound hook"
    }

    private func provider(for pid: UInt64) -> AgentProvider? {
        let executable = executablePath(for: pid).lowercased()
        let command = processCommand(for: pid).lowercased()
        let probe = executable + "\n" + command
        if Self.containsExecutable("claude", in: probe) || probe.contains("@anthropic-ai/claude") {
            return .claude
        }
        if Self.containsExecutable("codex", in: probe) || probe.contains("@openai/codex") {
            return .codex
        }
        return nil
    }

    private func processGroupID(for pid: UInt64) -> UInt64 {
        if let supplied = processGroupProvider?(pid) { return supplied }
        let value = getpgid(Int32(pid))
        return value > 0 ? UInt64(value) : pid
    }

    private static func containsExecutable(_ name: String, in value: String) -> Bool {
        value.contains("/\(name)") || value.contains(" \(name) ") || value.hasSuffix(" \(name)")
    }

    private func executablePath(for pid: UInt64) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard count > 0 else { return "" }
        return String(
            decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private func processCommand(for pid: UInt64) -> String {
        run(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="]
        )
    }

    private func transcriptRoots(for provider: AgentProvider, cwd: URL) -> [URL] {
        switch provider {
        case .claude:
            let slug = Self.claudeProjectSlug(cwd.standardizedFileURL.path)
            return [
                homeDirectory
                    .appendingPathComponent(".claude/projects", isDirectory: true)
                    .appendingPathComponent(slug, isDirectory: true),
            ]
        case .codex:
            return [codexSessionsRoot]
        }
    }

    private static func claudeProjectSlug(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(value) ||
                (65...90).contains(value) || (97...122).contains(value)
            return isASCIIAlphaNumeric ? Character(String(scalar)) : "-"
        })
    }

    private func openTranscript(for pid: UInt64, under roots: [URL]) -> URL? {
        let output = run(
            executable: "/usr/sbin/lsof",
            arguments: ["-Fn", "-p", String(pid)]
        )
        for line in output.split(separator: "\n") where line.first == "n" {
            let path = String(line.dropFirst())
            guard path.hasSuffix(".jsonl") else { continue }
            let candidate = URL(fileURLWithPath: path)
            if let validated = validate(candidate, under: roots) { return validated }
        }
        return nil
    }

    private func validate(_ candidate: URL, under roots: [URL]) -> URL? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == "jsonl", fileManager.fileExists(atPath: resolved.path)
        else { return nil }
        for root in roots {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved.path.hasPrefix(resolvedRoot + "/") { return resolved }
        }
        return nil
    }

    private func run(executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum AgentLensSourceError: Error, Equatable, Sendable {
    case overflow
}

/// Bounded native-protocol RESOURCE/STREAM adapter. Transport ownership stays with the
/// caller (for example an app-server process); this layer owns only frame decoding and
/// normalized-event backpressure. Cancellation flows both ways through stream termination.
struct CodexProtocolIngress: Sendable {
    private static let bufferCapacity = 1_024

    func events(
        frames: AsyncThrowingStream<Data, any Error>,
        location: String = "codex app-server"
    ) -> AsyncThrowingStream<AgentLensEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.bufferCapacity)) {
            continuation in
            let task = Task {
                let decoder = CodexProtocolFrameDecoder()
                var sequence: UInt64 = 0
                do {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        sequence += 1
                        do {
                            for event in try decoder.decode(
                                line: frame,
                                sequence: sequence,
                                location: location
                            ) {
                                guard Self.yield(event, to: continuation) else { return }
                            }
                        } catch {
                            let evidence = AgentEvidence.terminalInference(
                                "\(location):frame:\(sequence)"
                            )
                            let diagnostic = AgentLensDiagnostic(
                                id: "protocol-frame-\(sequence)",
                                severity: .warning,
                                message: (error as? AgentLensDecodeError) == .recordTooLarge
                                    ? "A native protocol frame exceeded the 2 MB safety limit"
                                    : "A malformed native protocol frame was ignored",
                                evidence: evidence
                            )
                            guard Self.yield(.diagnostic(diagnostic), to: continuation) else {
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func yield(
        _ event: AgentLensEvent,
        to continuation: AsyncThrowingStream<AgentLensEvent, any Error>.Continuation
    ) -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped:
            continuation.finish(throwing: AgentLensSourceError.overflow)
            return false
        case .terminated:
            return false
        @unknown default:
            continuation.finish(throwing: AgentLensSourceError.overflow)
            return false
        }
    }
}

/// One bounded, cancellable resource per attached transcript. It tails only a recent
/// initial window, caps an individual JSONL record, detects truncation/rotation, and
/// terminates on consumer overflow instead of silently losing semantic facts.
actor AgentTranscriptTailer {
    static let initialWindowBytes: UInt64 = 8 << 20
    private static let chunkBytes = 256 << 10
    private static let recordLimit = 2 << 20
    private static let bufferCapacity = 1_024

    func events(
        fileURL: URL,
        provider: AgentProvider,
        pollInterval: Duration = .milliseconds(180),
        initialWindowBytes: UInt64 = AgentTranscriptTailer.initialWindowBytes
    ) -> AsyncThrowingStream<AgentLensEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.bufferCapacity)) {
            continuation in
            let task = Task {
                await self.tail(
                    fileURL: fileURL,
                    provider: provider,
                    pollInterval: pollInterval,
                    initialWindowBytes: initialWindowBytes,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func tail(
        fileURL: URL,
        provider: AgentProvider,
        pollInterval: Duration,
        initialWindowBytes: UInt64,
        continuation: AsyncThrowingStream<AgentLensEvent, any Error>.Continuation
    ) async {
        let decoder = AgentTranscriptDecoder(provider: provider)
        let location = fileURL.path
        var offset: UInt64 = 0
        var pending = Data()
        var pendingStart: UInt64 = 0
        // Whether the window is still looking for a record that can begin it. Set when a seek
        // lands mid-file and when an unterminated record is abandoned: in both cases the bytes
        // on hand are the tail of something whose beginning is gone, and that is true of a
        // record split by the seek and of a `tool_result` whose call was left behind it alike.
        var seeksWindowStart = false
        var didReportMissing = false
        var didReportMalformed = false

        while !Task.isCancelled {
            do {
                // URL resource values are cached on the URL instance, so polling
                // `.fileSizeKey` there freezes at the attachment-time transcript size.
                // FileManager performs a fresh stat and observes provider appends.
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )
                guard let fileSize = attributes[.size] as? NSNumber else {
                    throw CocoaError(.fileReadUnknown)
                }
                let size = fileSize.uint64Value
                didReportMissing = false

                if offset == 0 && size > initialWindowBytes {
                    offset = size - initialWindowBytes
                    pendingStart = offset
                    seeksWindowStart = true
                    // The transcript and the byte, not a sentence about them: this is the one
                    // fact whose whole purpose is to be walked back to.
                    let evidence = AgentEvidence(
                        source: .transcript,
                        authority: .observed,
                        location: location,
                        byteOffset: offset,
                        fingerprint: "",
                        capturedAt: Date(),
                        freshness: .current
                    )
                    guard yield(.earlierHistory(evidence), to: continuation) else { return }
                } else if size < offset {
                    offset = 0
                    pendingStart = 0
                    pending.removeAll(keepingCapacity: true)
                    seeksWindowStart = false
                    let evidence = AgentEvidence.terminalInference("\(location):rotation")
                    guard yield(.reset(source: evidence), to: continuation) else { return }
                }

                if size > offset {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: offset)
                    var remaining = size - offset
                    while remaining > 0 && !Task.isCancelled {
                        let count = Int(min(UInt64(Self.chunkBytes), remaining))
                        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                            break
                        }
                        if pending.isEmpty { pendingStart = offset }
                        pending.append(chunk)
                        offset += UInt64(chunk.count)
                        remaining -= UInt64(chunk.count)

                        while let newline = pending.firstIndex(of: 0x0A) {
                            let length = pending.distance(from: pending.startIndex, to: newline)
                            let lineOffset = pendingStart
                            let line = Data(pending.prefix(length))
                            pending.removeFirst(length + 1)
                            pendingStart += UInt64(length + 1)
                            guard !line.isEmpty else { continue }
                            if seeksWindowStart {
                                guard decoder.opensHistoryWindow(line: line) else { continue }
                                seeksWindowStart = false
                            }
                            do {
                                for event in try decoder.decode(
                                    line: line,
                                    byteOffset: lineOffset,
                                    location: location
                                ) {
                                    guard yield(event, to: continuation) else { return }
                                }
                            } catch AgentLensDecodeError.recordTooLarge {
                                let evidence = AgentEvidence.terminalInference(
                                    "\(location):\(lineOffset)"
                                )
                                let diagnostic = AgentLensDiagnostic(
                                    id: "record-too-large-\(lineOffset)",
                                    severity: .warning,
                                    message: "A transcript record exceeded the 2 MB safety limit",
                                    evidence: evidence
                                )
                                guard yield(.diagnostic(diagnostic), to: continuation) else { return }
                            } catch {
                                if !didReportMalformed {
                                    didReportMalformed = true
                                    let evidence = AgentEvidence.terminalInference(
                                        "\(location):\(lineOffset)"
                                    )
                                    let diagnostic = AgentLensDiagnostic(
                                        id: "malformed-transcript-\(lineOffset)",
                                        severity: .warning,
                                        message: "The transcript contains a malformed JSON record",
                                        evidence: evidence
                                    )
                                    guard yield(.diagnostic(diagnostic), to: continuation) else {
                                        return
                                    }
                                }
                            }
                        }

                        if pending.count > Self.recordLimit {
                            pending.removeAll(keepingCapacity: true)
                            pendingStart = offset
                            seeksWindowStart = true
                            let evidence = AgentEvidence.terminalInference(
                                "\(location):oversized-record"
                            )
                            let diagnostic = AgentLensDiagnostic(
                                id: "unterminated-record-\(offset)",
                                severity: .warning,
                                message: "An unterminated transcript record exceeded the safety limit",
                                evidence: evidence
                            )
                            guard yield(.diagnostic(diagnostic), to: continuation) else { return }
                        }
                    }
                }
            } catch {
                if !didReportMissing {
                    didReportMissing = true
                    var evidence = AgentEvidence.terminalInference("\(location):missing")
                    evidence.freshness = .sourceMissing
                    let diagnostic = AgentLensDiagnostic(
                        id: "transcript-missing",
                        severity: .warning,
                        message: "Transcript temporarily unavailable; Terminal remains live",
                        evidence: evidence
                    )
                    guard yield(.diagnostic(diagnostic), to: continuation) else { return }
                }
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break
            }
        }
        continuation.finish()
    }

    private func yield(
        _ event: AgentLensEvent,
        to continuation: AsyncThrowingStream<AgentLensEvent, any Error>.Continuation
    ) -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped:
            continuation.finish(throwing: AgentLensSourceError.overflow)
            return false
        case .terminated:
            return false
        @unknown default:
            continuation.finish(throwing: AgentLensSourceError.overflow)
            return false
        }
    }
}
